import Foundation

public enum WorktreeError: Error, Sendable, CustomStringConvertible {
    case parentDatabaseIPUnavailable
    case repoNotFound(String)
    /// Creation failed and the half-created env was rolled back. `short` is the
    /// first fatal line (surface this); `full` is the complete underlying text
    /// (keep behind a disclosure).
    case creationFailed(short: String, full: String)

    public var description: String {
        switch self {
        case .parentDatabaseIPUnavailable: return "Could not resolve the parent site's database IP for a live DB clone."
        case .repoNotFound(let p):         return "No git repo found at \(p)."
        case .creationFailed(let short, _): return short
        }
    }

    /// Full underlying detail for an expandable disclosure, when available.
    public var fullDetail: String? {
        if case .creationFailed(_, let full) = self { return full }
        return nil
    }

    /// The first non-empty line of an arbitrary error's best description.
    static func firstLine(of error: Error) -> String {
        let full = Self.fullText(of: error)
        for raw in full.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return line }
        }
        return full
    }

    /// The most descriptive text available for an error (typed descriptions win).
    static func fullText(of error: Error) -> String {
        if let e = error as? ContainerCLIError { return e.description }
        if let e = error as? LifecycleError { return e.description }
        if let e = error as? GitError { return e.description }
        if let e = error as? WorktreeError { return e.description }
        return "\(error)"
    }
}

/// Creates and deletes worktree environments (PLAN.md §2b). Reuses
/// `SiteLifecycle`'s shared start/stop path so envs and sites run identically.
public actor WorktreeEnvService {
    private let cli: ContainerCLI
    private let git: GitService
    private let lifecycle: SiteLifecycle

    public init(cli: ContainerCLI, git: GitService, lifecycle: SiteLifecycle) {
        self.cli = cli
        self.git = git
        self.lifecycle = lifecycle
    }

    /// Full creation flow (steps 1–6). Returns the fully provisioned env.
    ///
    /// - Parameters:
    ///   - parentIsRunning: chooses the fast CoW DB clone (stopped) vs. the live
    ///     wp-cli export/import path (running).
    ///   - port: pre-allocated by the caller (respects the store's taken set).
    public func create(
        parent: Site,
        parentIsRunning: Bool,
        repoRelPath: String,
        branch: String,
        from: String?,
        port: Int
    ) async throws -> WorktreeEnv {
        let fm = FileManager.default
        let branchSlug = Slug.make(branch)
        let envSlug = WorktreeEnv.makeSlug(parentSlug: parent.slug, branch: branch)
        let envPath = parent.envsFolder.appendingPathComponent(branchSlug, isDirectory: true)
        let worktreePath = parent.worktreesFolder.appendingPathComponent(branchSlug, isDirectory: true)
        let repoURL = parent.repoURL(forRelativePath: repoRelPath)

        guard fm.fileExists(atPath: repoURL.appendingPathComponent(".git").path) else {
            throw WorktreeError.repoNotFound(repoRelPath)
        }

        // The descriptor is built up front (its fields never depend on a step
        // that can fail) so rollback can target the env's containers even if the
        // failure happens AFTER they start.
        var env = WorktreeEnv(
            parentSiteID: parent.id,
            parentSlug: parent.slug,
            envSlug: envSlug,
            repoRelPath: repoRelPath,
            branch: branch,
            worktreePath: worktreePath,
            envPath: envPath,
            port: port,
            imageTag: parent.imageTag,
            provisioned: false,
            // Inherit the parent's add-ons (§2c): the env gets its own es
            // container; a fresh ES index is fine (data is not cloned).
            xdebugEnabled: parent.xdebugEnabled,
            elasticsearchEnabled: parent.elasticsearchEnabled
        )

        do {
            // 1. git worktree add (create branch if new).
            try fm.createDirectory(at: parent.worktreesFolder, withIntermediateDirectories: true)
            try await git.worktreeAdd(repo: repoURL, path: worktreePath, branch: branch,
                                      createIfMissing: true, from: from)

            // 2. Clone site files (APFS CoW).
            try fm.createDirectory(at: envPath, withIntermediateDirectories: true)
            try await SiteFolders.cloneCopyOnWrite(from: parent.wordpressFolder,
                                                   to: envPath.appendingPathComponent("wordpress", isDirectory: true))

            // 3. Clone database.
            let envDatabase = envPath.appendingPathComponent("database", isDirectory: true)
            if parentIsRunning {
                // Live path handled after the env DB is up (export/import below).
                try fm.createDirectory(at: envDatabase, withIntermediateDirectories: true)
            } else {
                // Fast path: copy-on-write the parent's data directory.
                try await SiteFolders.cloneCopyOnWrite(from: parent.databaseFolder, to: envDatabase)
            }

            // Pre-create the shadow mountpoint intentionally. VALIDATED gotcha: if
            // the subpath doesn't exist in the outer mount the runtime auto-creates
            // an empty dir on the HOST as a side effect; creating it ourselves keeps
            // it tidy (and it is removed with `.envs/<b>` on deletion). The CoW clone
            // usually already contains this path, but a bare repo layout may not.
            let mountpoint = env.wordpressFolder.appendingPathComponent(repoRelPath, isDirectory: true)
            try? fm.createDirectory(at: mountpoint, withIntermediateDirectories: true)

            // 4. Start env containers (shared recipe + shadow mount).
            let dbHost = try await lifecycle.startContainers(env)

            // 3b. Live DB transfer if the parent was running.
            if parentIsRunning {
                try await liveDatabaseTransfer(parent: parent, env: env, envDBHost: dbHost)
            }

            // 5. Fix URLs for the new port.
            try await cli.run(SiteRecipe.wpUpdateURLsArgs(env, dbHost: dbHost))

            await lifecycle.markRunning(env.id)
            env.provisioned = true
            return env
        } catch {
            // Transactional rollback: leave NO half-created env behind. Stop and
            // delete the env's containers, remove the git worktree checkout (but
            // KEEP the branch), and delete `.envs/<b>`. The caller only writes the
            // store entry on success, so there is nothing to unwind there.
            await lifecycle.deleteContainers(env) // stops+deletes, emits .stopped
            try? await git.worktreeRemove(repo: repoURL, path: worktreePath, force: true)
            try? fm.removeItem(at: envPath)
            throw WorktreeError.creationFailed(short: WorktreeError.firstLine(of: error),
                                               full: WorktreeError.fullText(of: error))
        }
    }

    /// Deletion: stop containers → git worktree remove → delete `.envs/<b>`.
    public func delete(_ env: WorktreeEnv, parent: Site?, keepBranch: Bool, keepWorktree: Bool) async {
        await lifecycle.deleteContainers(env)
        if !keepWorktree, let parent {
            let repoURL = parent.repoURL(forRelativePath: env.repoRelPath)
            try? await git.worktreeRemove(repo: repoURL, path: env.worktreePath, force: true)
        }
        try? FileManager.default.removeItem(at: env.envPath)
        // Note: `keepBranch` is honored by NOT deleting the git branch here; we
        // never delete branches (worktree remove leaves the branch intact).
        _ = keepBranch
    }

    // MARK: - Live DB clone (parent running)

    private func liveDatabaseTransfer(parent: Site, env: WorktreeEnv, envDBHost: String) async throws {
        guard let parentIP = try await cli.ipAddress(of: parent.dbContainerName) else {
            throw WorktreeError.parentDatabaseIPUnavailable
        }
        // Export parent DB to SQL (stdout), stage it inside the env's wordpress
        // mount (so it's visible to the env container), then import + clean up.
        let dump = try await cli.run(SiteRecipe.wpDBExportArgs(parent, dbHost: parentIP))
        let dumpFile = env.wordpressFolder.appendingPathComponent(".wpc-clone.sql")
        try Data(dump.utf8).write(to: dumpFile, options: .atomic)
        defer { try? FileManager.default.removeItem(at: dumpFile) }
        try await cli.run(SiteRecipe.wpProxyArgs(env, dbHost: envDBHost,
                                                 wpArgs: ["db", "import", "/var/www/html/.wpc-clone.sql"]))
    }
}
