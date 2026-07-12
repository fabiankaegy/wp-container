import Foundation

public enum WorktreeError: Error, Sendable, CustomStringConvertible {
    case parentDatabaseIPUnavailable
    case repoNotFound(String)

    public var description: String {
        switch self {
        case .parentDatabaseIPUnavailable: return "Could not resolve the parent site's database IP for a live DB clone."
        case .repoNotFound(let p):         return "No git repo found at \(p)."
        }
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
            provisioned: false
        )

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
