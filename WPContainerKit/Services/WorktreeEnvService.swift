import Foundation

public enum WorktreeError: Error, Sendable, CustomStringConvertible {
    case parentDatabaseIPUnavailable
    case repoNotFound(String)
    /// The repo path relative to `wordpress/` contains `..` (or is empty after
    /// trimming) — it would resolve outside `/var/www/html` inside the container.
    case invalidRepoPath(String)
    /// An env with this slug (same parent + branch) is already in the store. Two
    /// of them collide on hostname, container names and DB schema, and the proxy
    /// can only ever route to one.
    case duplicateEnvSlug(String)
    /// Creation failed and the half-created env was rolled back. `short` is the
    /// first fatal line (surface this); `full` is the complete underlying text
    /// (keep behind a disclosure).
    case creationFailed(short: String, full: String)

    public var description: String {
        switch self {
        case .parentDatabaseIPUnavailable: return "Could not resolve the parent site's database IP for a live DB clone."
        case .repoNotFound(let p):         return "No git repo found at \(p)."
        case .invalidRepoPath(let p):      return "Invalid repo path \"\(p)\": must be relative to wordpress/ with no \"..\" components (e.g. wp-content/plugins/my-plugin)."
        case .duplicateEnvSlug(let s):     return "An environment named \(s) already exists. Delete it first, or use a different branch."
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
        if let e = error as? SiteFoldersError { return e.description }
        if let e = error as? ImageUnavailableError { return e.description }
        return "\(error)"
    }
}

/// Creates and deletes worktree environments (PLAN.md §2b). Reuses
/// `SiteLifecycle`'s shared start/stop path so envs and sites run identically.
public actor WorktreeEnvService {
    /// What a successful `create` produced, plus the store bookkeeping only the
    /// caller can perform (issue #17).
    public struct CreationOutcome: Sendable {
        public let env: WorktreeEnv
        /// Tombstoned schemas (`Site.pendingSchemaDrops`) whose DROP succeeded
        /// during this create. The caller MUST remove exactly these from the
        /// parent site's record — and only these, so a drop that failed keeps its
        /// reminder for next time.
        public let reapedSchemas: [String]
    }

    /// What a `delete` could not finish, for the caller to persist (issue #17).
    public struct DeletionOutcome: Sendable {
        /// The env's schema, still present on a DB server that was down. The
        /// caller MUST append it to the parent site's `pendingSchemaDrops` so a
        /// later create reaps it. nil when there was nothing to drop or the drop
        /// succeeded.
        public let tombstonedSchema: String?
    }

    private let cli: ContainerCLI
    private let git: GitService
    private let lifecycle: SiteLifecycle

    public init(cli: ContainerCLI, git: GitService, lifecycle: SiteLifecycle) {
        self.cli = cli
        self.git = git
        self.lifecycle = lifecycle
    }

    /// True when a repo rel path is safe to mount under `/var/www/html/`:
    /// non-empty after trimming `/`, and free of `.`/`..` components (a
    /// `..`-laden path would shadow-mount OUTSIDE the container's docroot, #8).
    public static func isValidRepoRelPath(_ repoRelPath: String) -> Bool {
        let clean = repoRelPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !clean.isEmpty else { return false }
        return clean.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { $0 != ".." && $0 != "." && !$0.isEmpty }
    }

    /// The deterministic descriptor for an env of `parent` on `branch` — all
    /// fields except `provisioned` are knowable before any work happens. Used
    /// by callers to reserve the env (and its port) in the store atomically
    /// BEFORE the (long) creation flow runs (#3), then passed to `create` so
    /// the final record keeps the same identity.
    public static func descriptor(parent: Site, repoRelPath: String, branch: String, port: Int) -> WorktreeEnv {
        let branchSlug = Slug.make(branch)
        return WorktreeEnv(
            parentSiteID: parent.id,
            parentSlug: parent.slug,
            envSlug: WorktreeEnv.makeSlug(parentSlug: parent.slug, branch: branch),
            repoRelPath: repoRelPath,
            branch: branch,
            worktreePath: parent.worktreesFolder.appendingPathComponent(branchSlug, isDirectory: true),
            envPath: parent.envsFolder.appendingPathComponent(branchSlug, isDirectory: true),
            port: port,
            imageTag: parent.imageTag,
            provisioned: false,
            xdebugEnabled: parent.xdebugEnabled,
            elasticsearchEnabled: parent.elasticsearchEnabled,
            mailpitEnabled: parent.mailpitEnabled,
            cpuLimit: parent.cpuLimit,
            memoryLimitMB: parent.memoryLimitMB
        )
    }

    /// Build the env descriptor AND append it to `envelope`, reserving a second
    /// free port for the env's own Mailpit web UI when the parent has Mailpit
    /// enabled (issue #10). Call inside a locked `allocatePort` reserve closure
    /// (which already reserved the env's main `port`): both ports land in the
    /// same critical section, so a concurrent creator can't reuse either.
    public static func reservedDescriptor(parent: Site, repoRelPath: String, branch: String,
                                          port: Int, into envelope: inout StoreEnvelope) -> WorktreeEnv {
        var env = descriptor(parent: parent, repoRelPath: repoRelPath, branch: branch, port: port)
        if parent.mailpitEnabled {
            let taken = Set(envelope.sites.map(\.port)).union(envelope.envs.map(\.port))
                .union(envelope.sites.compactMap(\.mailpitPort))
                .union(envelope.envs.compactMap(\.mailpitPort))
                .union([port])
            env.mailpitPort = PortAllocator.firstFreePort(from: port + 1, excluding: taken)
        }
        envelope.envs.append(env)
        return env
    }

    /// Full creation flow (steps 1–6). Returns the fully provisioned env.
    ///
    /// - Parameters:
    ///   - parentIsRunning: chooses the fast CoW DB clone (stopped) vs. the live
    ///     wp-cli export/import path (running).
    ///   - port: pre-allocated by the caller (respects the store's taken set).
    ///   - reserved: when the caller already reserved a store record via
    ///     `descriptor(parent:repoRelPath:branch:port:)` (#3), pass it so the
    ///     final env keeps that identity (same UUID → the caller's replace-in-
    ///     store is a simple swap).
    ///   - provision: when true (default), seed the freshly-checked-out worktree
    ///     with the parent's gitignored runtime deps (Composer `vendor/`, built
    ///     assets, provisioned mu-plugins/plugins) so the env boots into a
    ///     working site with no manual `composer install`/`npm run build`
    ///     preamble (issue #14). Pass false for a bare checkout.
    ///   - isolatedDB: opt OUT of the shared-database default (issue #17) and
    ///     give this env its own MariaDB container — worth it only for a very
    ///     large database, where the CoW clone of a stopped parent's `database/`
    ///     folder beats a logical dump+restore. Also chosen automatically when
    ///     the safety preflight can't confirm the project honors
    ///     `WORDPRESS_DB_NAME` (see `WPConfigService.dbNameFollowsEnvironment`).
    ///
    /// On the shared-database path this also reaps `parent.pendingSchemaDrops`
    /// (the server is guaranteed up here) and reports what it dropped in the
    /// returned outcome, so the caller can clear those tombstones.
    public func create(
        parent: Site,
        parentIsRunning: Bool,
        repoRelPath: String,
        branch: String,
        from: String?,
        port: Int,
        reserved: WorktreeEnv? = nil,
        provision: Bool = true,
        isolatedDB: Bool = false
    ) async throws -> CreationOutcome {
        let fm = FileManager.default
        // Reject `..`-laden rel paths outright (#8): the shadow mount would
        // resolve outside /var/www/html inside the container.
        guard Self.isValidRepoRelPath(repoRelPath) else {
            throw WorktreeError.invalidRepoPath(repoRelPath)
        }
        // Two envs with the same slug share a hostname, a container name and a
        // schema; the proxy's route table is keyed by `<envSlug>.localhost`, so the
        // second one is silently unreachable at its own port. Refuse up front
        // rather than creating something that can never be served. (`reserved` is
        // already IN the store — that record is this create, not a duplicate.)
        let envSlug = reserved?.envSlug ?? WorktreeEnv.makeSlug(parentSlug: parent.slug, branch: branch)
        if let stored = try? await StorePersistence().load(),
           stored.envs.contains(where: { $0.envSlug == envSlug && $0.id != reserved?.id }) {
            throw WorktreeError.duplicateEnvSlug(envSlug)
        }
        let repoURL = parent.repoURL(forRelativePath: repoRelPath)

        guard fm.fileExists(atPath: repoURL.appendingPathComponent(".git").path) else {
            throw WorktreeError.repoNotFound(repoRelPath)
        }

        // The descriptor is built up front (its fields never depend on a step
        // that can fail) so rollback can target the env's containers even if the
        // failure happens AFTER they start. Inherits the parent's add-ons (§2c):
        // the env gets its own ES container; a fresh ES index is fine.
        var env = reserved ?? Self.descriptor(parent: parent, repoRelPath: repoRelPath,
                                              branch: branch, port: port)

        // Shared database by default (issue #17): the env becomes an extra
        // SCHEMA on the parent's existing MariaDB container instead of running a
        // ~470 MB VM of its own. Refused when the project's wp-config.php
        // wouldn't honor WORDPRESS_DB_NAME — that would silently write into the
        // PARENT's database, so we degrade to an isolated container and say so.
        var useSharedDB = !isolatedDB
        if useSharedDB, !WPConfigService.dbNameFollowsEnvironment(wordpressFolder: parent.wordpressFolder) {
            useSharedDB = false
            await lifecycle.recordWarnings([
                "\(parent.slug) defines DB_NAME literally in wp-config.php instead of reading \(WPConfigService.dbNameEnvironmentVariable), so this environment got its own database container rather than a schema on the parent's server.",
            ], for: env.id)
        }
        if useSharedDB {
            env.adoptSharedDatabase(schema: WorktreeEnv.schemaName(forEnvSlug: env.envSlug))
        }
        let sharedSchema = env.sharedDatabase ? env.databaseSchema : nil

        let envPath = env.envPath
        let worktreePath = env.worktreePath
        var reapedSchemas: [String] = []

        // Hold a lease on the shared DB container for the WHOLE critical section
        // (issue #17, fix for the mid-start stop race): until the env's wp
        // container exists there is nothing observable to stop `container list`
        // from concluding the server is unused, and retiring it here would fail
        // the create outright. Released explicitly on both exits below — `defer`
        // can't `await`, and the rollback must run AFTER the release so its own
        // `stopSharedDatabaseIfUnused` can actually retire the server.
        if sharedSchema != nil {
            await lifecycle.acquireDatabaseLease(env.dbContainerName)
        }

        do {
            // 1. git worktree add (create branch if new).
            try fm.createDirectory(at: parent.worktreesFolder, withIntermediateDirectories: true)
            try await git.worktreeAdd(repo: repoURL, path: worktreePath, branch: branch,
                                      createIfMissing: true, from: from)

            // 1b. Seed the checkout with the parent's gitignored runtime deps so
            // the shadow-mounted worktree isn't missing vendor/, built assets, or
            // provisioned plugins and the env boots into a working site (#14).
            // --ignore-existing keeps the branch's tracked files untouched.
            if provision {
                try await SiteFolders.seedIgnoredRuntimeDeps(from: repoURL, into: worktreePath)
            }

            // 2. Clone site files (APFS CoW).
            try fm.createDirectory(at: envPath, withIntermediateDirectories: true)
            try await SiteFolders.cloneCopyOnWrite(from: parent.wordpressFolder,
                                                   to: envPath.appendingPathComponent("wordpress", isDirectory: true))

            // 3. Clone the database.
            if let sharedSchema {
                // Shared path (issue #17): no `database/` folder and no DB
                // container for the env at all. Bring up the PARENT's server
                // (only its db container needs to be running — not its wp
                // container), then create + grant + fill the env's schema
                // entirely server-side, before the env's wp container starts.
                let parentDBHost = try await lifecycle.prepareDatabaseHost(owner: parent)
                try await cli.run(SiteRecipe.createEnvDatabaseArgs(dbHost: parentDBHost, schema: sharedSchema))
                // The server is guaranteed up right here — the one natural place
                // to reap schemas an earlier deletion tombstoned because it
                // wasn't. ONLY tombstoned names; never anything merely observed
                // on the server (see `Site.pendingSchemaDrops`).
                reapedSchemas = await reapTombstonedSchemas(dbHost: parentDBHost,
                                                            names: parent.pendingSchemaDrops,
                                                            excluding: sharedSchema)
                try await cli.run(SiteRecipe.cloneDatabaseArgs(dbHost: parentDBHost,
                                                               from: SiteRecipe.dbName, to: sharedSchema))
            } else if parentIsRunning {
                // Live path handled after the env DB is up (export/import below).
                try fm.createDirectory(at: env.databaseFolder, withIntermediateDirectories: true)
            } else {
                // Fast path: copy-on-write the parent's data directory.
                try await SiteFolders.cloneCopyOnWrite(from: parent.databaseFolder, to: env.databaseFolder)
            }

            // Pre-create the shadow mountpoint intentionally. VALIDATED gotcha: if
            // the subpath doesn't exist in the outer mount the runtime auto-creates
            // an empty dir on the HOST as a side effect; creating it ourselves keeps
            // it tidy (and it is removed with `.envs/<b>` on deletion). The CoW clone
            // usually already contains this path, but a bare repo layout may not.
            let mountpoint = env.wordpressFolder.appendingPathComponent(repoRelPath, isDirectory: true)
            try? fm.createDirectory(at: mountpoint, withIntermediateDirectories: true)

            // 4. Start env containers (shared recipe + shadow mount). For a
            // shared-database env the parent is the `dbProvider`, so no DB
            // container of its own is ever created.
            let dbHost = try await lifecycle.startContainers(env, dbProvider: parent)

            // The wp-cli work below (live DB import, URL fixes) genuinely
            // needs the DB accepting connections — the shared start path no
            // longer gates on DB readiness (issue #9), so gate explicitly here.
            try await lifecycle.waitForDatabaseReady(env, dbHost: dbHost)

            // 3b. Live DB transfer if the parent was running. Shared envs were
            // already filled server-side above (no host staging, no dump
            // buffered through a Swift String).
            if sharedSchema == nil, parentIsRunning {
                try await liveDatabaseTransfer(parent: parent, env: env, envDBHost: dbHost)
            }

            // 5. Migrate every url in the clone onto the env's own port — not
            // just the main site's two option rows (see `EnvURLMigration`).
            await lifecycle.recordWarnings(try await migrateURLs(env: env, parent: parent, dbHost: dbHost),
                                           for: env.id)

            await lifecycle.markRunning(env.id)
            env.provisioned = true
            if sharedSchema != nil {
                await lifecycle.releaseDatabaseLease(env.dbContainerName)
            }
            return CreationOutcome(env: env, reapedSchemas: reapedSchemas)
        } catch {
            // Transactional rollback: leave NO half-created env behind. Stop and
            // delete the env's containers, remove the git worktree checkout (but
            // KEEP the branch), and delete `.envs/<b>`. The caller only writes the
            // store entry on success, so there is nothing to unwind there.
            //
            // Release the lease FIRST: the DB retirement at the end of this block
            // is gated on it, and nothing below needs the server protected.
            if sharedSchema != nil {
                await lifecycle.releaseDatabaseLease(env.dbContainerName)
            }
            await lifecycle.deleteContainers(env) // stops+deletes, emits .stopped
            // A schema we may have already created on the parent's server is
            // part of the half-created env — unwind it too, or the next create
            // would clone into a stale one.
            let dropped = await dropSharedSchema(of: env, parent: parent)
            if !dropped, let sharedSchema {
                // We can't persist a tombstone from here (no store access), and
                // the caller is about to be handed an error rather than a record
                // to write. Name the leak instead: the server was up seconds ago,
                // so this is a genuinely rare path.
                await lifecycle.recordWarnings([
                    "Could not remove the database schema \(sharedSchema) from \(parent.slug)'s database server while rolling back. Drop it manually if it lingers.",
                ], for: env.id)
            }
            try? await git.worktreeRemove(repo: repoURL, path: worktreePath, force: true)
            try? fm.removeItem(at: envPath)
            // The shared path may have booted the parent's DB container purely
            // for this create (parent site stopped). Nothing needs it now, so
            // don't leave a ~470 MB VM behind for a create that failed.
            if sharedSchema != nil {
                await lifecycle.stopSharedDatabaseIfUnused(parent: parent)
            }
            throw WorktreeError.creationFailed(short: WorktreeError.firstLine(of: error),
                                               full: WorktreeError.fullText(of: error))
        }
    }

    /// Deletion: stop containers → drop the shared schema → git worktree remove
    /// → delete `.envs/<b>`.
    ///
    /// Returns what the caller still has to persist: when the schema couldn't be
    /// dropped (server down), `tombstonedSchema` must be appended to the parent
    /// site's `pendingSchemaDrops`, or the schema is never reaped.
    @discardableResult
    public func delete(_ env: WorktreeEnv, parent: Site?, keepBranch: Bool, keepWorktree: Bool) async -> DeletionOutcome {
        // Never the parent's DB container: `deleteContainers` skips it for a
        // shared-database env (issue #17).
        await lifecycle.deleteContainers(env)
        let dropped = await dropSharedSchema(of: env, parent: parent)
        if !keepWorktree, let parent {
            let repoURL = parent.repoURL(forRelativePath: env.repoRelPath)
            try? await git.worktreeRemove(repo: repoURL, path: env.worktreePath, force: true)
        }
        try? FileManager.default.removeItem(at: env.envPath)
        // Note: `keepBranch` is honored by NOT deleting the git branch here; we
        // never delete branches (worktree remove leaves the branch intact).
        _ = keepBranch
        let tombstone = (!dropped && env.sharedDatabase) ? env.databaseSchema : nil
        return DeletionOutcome(tombstonedSchema: tombstone)
    }

    // MARK: - Shared schema teardown (issue #17)

    /// Drop a shared-database env's own schema off the parent's server. Returns
    /// false ONLY when a schema that exists could not be dropped — the caller
    /// must then tombstone it.
    ///
    /// Four guards, because dropping the wrong name here would destroy a sibling
    /// env or the parent site itself (trade-off #3): the env must actually be in
    /// shared mode, the stored schema must be present, it must pass
    /// `WorktreeEnv.isManagedSchemaName` (a `wpc_`-prefixed identifier — so never
    /// `wordpress`), and the parent handed in must be the one that owns the
    /// container the env borrows.
    private func dropSharedSchema(of env: WorktreeEnv, parent: Site?) async -> Bool {
        guard env.sharedDatabase, let schema = env.databaseSchema,
              WorktreeEnv.isManagedSchemaName(schema), schema != SiteRecipe.dbName,
              let parent, parent.dbContainerName == env.dbContainerName else { return true }
        guard let dbHost = (try? await cli.ipAddress(of: env.dbContainerName)) ?? nil,
              !dbHost.isEmpty else { return false }
        let result = try? await cli.runCapturing(SiteRecipe.dropEnvDatabaseArgs(dbHost: dbHost, schema: schema))
        return result?.succeeded ?? false
    }

    /// Drop tombstoned schemas (`Site.pendingSchemaDrops`) off a live server,
    /// returning the ones whose DROP actually succeeded so the caller clears
    /// exactly those — a drop that failed keeps its reminder for next time.
    ///
    /// Every name is re-checked against `WorktreeEnv.isManagedSchemaName` even
    /// though only we ever wrote them, so a hand-edited store can't turn this
    /// into `DROP DATABASE wordpress`.
    private func reapTombstonedSchemas(dbHost: String, names: [String],
                                       excluding current: String) async -> [String] {
        var reaped: [String] = []
        for schema in Set(names) where schema != current
            && WorktreeEnv.isManagedSchemaName(schema) && schema != SiteRecipe.dbName {
            let result = try? await cli.runCapturing(SiteRecipe.dropEnvDatabaseArgs(dbHost: dbHost, schema: schema))
            if result?.succeeded == true { reaped.append(schema) }
        }
        return reaped
    }

    // MARK: - URL migration (see `EnvURLMigration`)

    /// Rewrite the parent's urls to the env's own `http://127.0.0.1:<port>`
    /// across the whole cloned database, then fix the wp-config constants that
    /// override it. Returns non-fatal warnings for the caller to surface.
    ///
    /// The parent's LOCAL url goes along with its effective one: a parent served
    /// over HTTPS or a custom domain still has `127.0.0.1:<parent port>` all
    /// through the rows its first install wrote, and left alone those point the
    /// env's clone straight back at the parent's container.
    ///
    /// Throws only what the old shallow behavior threw (the final
    /// `wp option update` + cache flush) — a failed search-replace pass is a
    /// warning, never a failed create.
    private func migrateURLs(env: WorktreeEnv, parent: Site, dbHost: String) async throws -> [String] {
        let target = EnvURLMigration.targetAuthority(port: env.port)
        let effective = parent.url.absoluteString
        let origins = EnvURLMigration.staleOrigins(
            candidates: [parent.localURL.absoluteString, effective],
            target: target, networkDomain: effective)
        let constants = (try? WPConfigService.read(wordpressFolder: env.wordpressFolder))?.constants ?? [:]
        let report = try await EnvURLMigrator(cli: cli).migrate(
            instance: env, dbHost: dbHost, wordpressFolder: env.wordpressFolder,
            origins: origins, targetAuthority: target,
            multisite: EnvURLMigration.isMultisite(networkType: parent.networkType, constants: constants),
            dryRun: false)
        return report.warnings
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
