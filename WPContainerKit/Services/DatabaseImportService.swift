import Foundation

/// Typed error surface for `DatabaseImportService` (PLAN.md §2m).
public enum DatabaseImportError: Error, Sendable, CustomStringConvertible, LocalizedError {
    case dumpNotFound(String)
    case invalidDumpExtension(String)
    /// The site's DB container isn't reachable (not started). Surfaces (app/
    /// CLI/MCP) decide whether to auto-start the site and retry — this layer
    /// never starts containers itself.
    case siteNotRunning
    case decompressionFailed(String)
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    /// An allowlist entry (email or domain) failed strict format validation
    /// BEFORE it would have been interpolated into SQL.
    case invalidAllowlistEntry(String)
    /// `.remote` media was requested but no source URL is known (no override,
    /// and none could be detected).
    case sourceURLRequired
    case mediaFolderNotFound(String)
    /// The dump selects, creates or drops a database (`statement` is the first
    /// such line), refused for an env that shares its parent's database server.
    case dumpSwitchesDatabase(statement: String)
    /// A phase at/after `.importing` failed. Rollback (re-importing the
    /// pre-import backup) was attempted; `rolledBack` says whether it
    /// succeeded. The original failure is preserved in `short`/`full`.
    case phaseFailed(phase: DBImportPhase, short: String, full: String, rolledBack: Bool)

    public var description: String {
        switch self {
        case .dumpNotFound(let p):
            return "No dump file found at \(p)."
        case .invalidDumpExtension(let p):
            return "\"\(p)\" is not a .sql, .gz, or .sql.gz file."
        case .siteNotRunning:
            return "The site must be running (database reachable) before importing a database."
        case .decompressionFailed(let p):
            return "Failed to decompress \(p)."
        case .insufficientDiskSpace(let required, let available):
            let fmt = ByteCountFormatter()
            fmt.countStyle = .file
            return "Not enough free disk space for this import (needs roughly \(fmt.string(fromByteCount: required)), \(fmt.string(fromByteCount: available)) available)."
        case .invalidAllowlistEntry(let v):
            return "\"\(v)\" is not a valid email address or domain for the scrub allowlist."
        case .sourceURLRequired:
            return "Remote media requires a known source URL — none was detected in the dump and none was provided as an override."
        case .mediaFolderNotFound(let p):
            return "No folder found at \(p) to copy media from."
        case .dumpSwitchesDatabase(let statement):
            return "The dump switches databases (\(statement)), which could write into the parent site's database. "
                + "Export it without --databases (e.g. `wp db export` or `mysqldump <db>`) and import again."
        case .phaseFailed(let phase, let short, _, let rolledBack):
            let rb = rolledBack
                ? "the pre-import database was restored."
                : "rollback ALSO failed — the database may be left mid-import; the pre-import backup is still on disk."
            return "Database import failed during \(phase.rawValue) (\(short)) — \(rb)"
        }
    }

    public var errorDescription: String? { description }

    /// Full underlying detail for an expandable disclosure, when available.
    public var fullDetail: String? {
        if case .phaseFailed(_, _, let full, _) = self { return full }
        return nil
    }

    /// The first non-empty line of an arbitrary error's best description.
    static func firstLine(of error: Error) -> String {
        let full = fullText(of: error)
        for raw in full.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return line }
        }
        return full
    }

    /// The most descriptive text available for an error (typed descriptions win).
    public static func fullText(of error: Error) -> String {
        if let e = error as? ContainerCLIError { return e.description }
        if let e = error as? LifecycleError { return e.description }
        if let e = error as? DatabaseImportError { return e.description }
        return "\(error)"
    }
}

/// Progress phases of a database import, surfaced to callers via the
/// `progress` callback at the START of each phase (PLAN.md §2m).
public enum DBImportPhase: String, Sendable, CaseIterable {
    case preflight
    case backup
    case importing
    case urlMigration
    case scrubbing
    case media
    case admin
    case finishing
    case rollingBack
}

/// How to handle `wp-content/uploads` after a database import (PLAN.md §2m).
public enum DBImportMediaOption: Sendable, Equatable {
    /// Write the `wpc-remote-media` mu-plugin so missing local files are
    /// served from the dump's source host instead of broken-imaging.
    case remote
    /// Copy the contents of a local uploads folder into `wp-content/uploads`.
    case copy(from: URL)
    /// Do nothing — broken images accepted.
    case skip
}

/// Options for `DatabaseImportService.importDatabase`.
public struct DBImportOptions: Sendable {
    /// Scrub personal data (users/comments/admin email) after import. Default on.
    public var scrub: Bool
    /// Email addresses to preserve as-is when scrubbing.
    public var allowedEmails: [String]
    /// Email domains (e.g. `example.com`) to preserve as-is when scrubbing.
    public var allowedDomains: [String]
    /// How to handle `wp-content/uploads` after import.
    public var media: DBImportMediaOption
    /// Create/reset the local `admin`/`password` login after scrubbing. Default on.
    public var createAdmin: Bool
    /// Trust this URL as the dump's source instead of the detected `home` option.
    public var sourceURLOverride: String?

    public init(
        scrub: Bool = true,
        allowedEmails: [String] = [],
        allowedDomains: [String] = [],
        media: DBImportMediaOption = .remote,
        createAdmin: Bool = true,
        sourceURLOverride: String? = nil
    ) {
        self.scrub = scrub
        self.allowedEmails = allowedEmails
        self.allowedDomains = allowedDomains
        self.media = media
        self.createAdmin = createAdmin
        self.sourceURLOverride = sourceURLOverride
    }
}

/// Result of a successful `importDatabase` run.
public struct DBImportSummary: Sendable, Codable {
    /// The dump's source URL (override or detected `home` option), if any.
    public var sourceURL: String?
    /// The site's local URL the dump was migrated to.
    public var localURL: String
    /// Absolute path of the pre-import safety backup on disk.
    public var backupPath: String
    public var usersScrubbed: Int
    public var usersPreserved: Int
    public var commentsRemoved: Int
    /// Total search-replace hits across the URL-migration passes, when
    /// parseable from `wp search-replace`'s own summary line.
    public var replacementsMade: Int?
    /// `"remote"`, `"copy"`, or `"skip"` — mirrors `DBImportMediaOption`.
    public var mediaMode: String
    /// The local admin login, when `createAdmin` was on.
    public var adminUser: String?
    public var adminPassword: String?
    /// Size of the original dump file on disk, in bytes (0 if unreadable) —
    /// lets a surface show e.g. "Imported 2.4 GB dump".
    public var dumpSizeBytes: Int64
}

/// Pure SQL-statement builders for the scrub step (PLAN.md §2m), wp-scrubber-
/// inspired (https://github.com/10up/wp-scrubber). Kept as static functions
/// (plain values in → `[String]` SQL statements out) rather than folded into
/// the service, so they're reviewable/unit-testable in isolation from the
/// container/process layer.
///
/// SQL-injection care: `allowedEmails`/`allowedDomains` are user-supplied (UI
/// text field / CLI flag / MCP argument) and get interpolated into raw SQL run
/// via `wp db query` — wp-cli offers no parameterized-query path here. Every
/// value is validated against a strict format BEFORE it is escaped and
/// interpolated; anything that fails validation is rejected with
/// `DatabaseImportError.invalidAllowlistEntry` rather than silently dropped or
/// (worse) passed through.
public enum DBScrubSQL {
    /// Deliberately strict email validator — good enough to reject anything
    /// that isn't a plain address (no quotes/backslashes/whitespace/SQL
    /// metacharacters can sneak through disguised as a "clever" email).
    static func isValidEmail(_ s: String) -> Bool {
        let pattern = #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    /// Strict hostname validator (dot-separated labels of letters/digits/hyphens).
    static func isValidDomain(_ s: String) -> Bool {
        let pattern = #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    /// Validate an allowlist, throwing on the first entry that fails its
    /// format check. MUST be called before ANY of these values reach SQL.
    public static func validate(allowedEmails: [String], allowedDomains: [String]) throws {
        for e in allowedEmails where !isValidEmail(e) {
            throw DatabaseImportError.invalidAllowlistEntry(e)
        }
        for d in allowedDomains where !isValidDomain(d) {
            throw DatabaseImportError.invalidAllowlistEntry(d)
        }
    }

    /// MySQL single-quoted-string escape. Only ever called on
    /// already-`validate`d input.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''")
    }

    /// `WHERE` fragment selecting the users a scrub should touch: excludes the
    /// tool's own admin email and every allowlisted email/domain.
    static func scrubWhereClause(allowedEmails: [String], allowedDomains: [String], adminEmail: String) -> String {
        let notIn = Array(Set([adminEmail] + allowedEmails))
        let emailList = notIn.map { "'\(escape($0))'" }.joined(separator: ", ")
        var clause = "WHERE user_email NOT IN (\(emailList))"
        if !allowedDomains.isEmpty {
            let domainList = allowedDomains.map { "'\(escape($0))'" }.joined(separator: ", ")
            clause += " AND SUBSTRING_INDEX(user_email, '@', -1) NOT IN (\(domainList))"
        }
        return clause
    }

    public static func countAllUsersSQL(tablePrefix: String) -> String {
        "SELECT COUNT(*) FROM \(tablePrefix)users"
    }

    public static func countUsersToScrubSQL(tablePrefix: String, allowedEmails: [String],
                                            allowedDomains: [String], adminEmail: String) -> String {
        "SELECT COUNT(*) FROM \(tablePrefix)users " +
            scrubWhereClause(allowedEmails: allowedEmails, allowedDomains: allowedDomains, adminEmail: adminEmail)
    }

    public static func countCommentsSQL(tablePrefix: String) -> String {
        "SELECT COUNT(*) FROM \(tablePrefix)comments"
    }

    /// The ordered scrub statements. Each is run as its own `wp db query`
    /// invocation (no reliance on multi-statement support in the mysql CLI).
    ///
    /// Order matters: the usermeta blank-out runs BEFORE the users table is
    /// mutated, because it re-derives the "which users are being scrubbed" set
    /// from the SAME `user_email`-based `WHERE` clause used for the counts —
    /// if the users table's `user_email` were rewritten first, that `WHERE`
    /// would no longer match the original (pre-scrub) rows.
    public static func scrubStatements(tablePrefix: String, allowedEmails: [String],
                                       allowedDomains: [String], adminEmail: String) -> [String] {
        let whereClause = scrubWhereClause(allowedEmails: allowedEmails, allowedDomains: allowedDomains, adminEmail: adminEmail)
        return [
            """
            UPDATE \(tablePrefix)usermeta SET meta_value = '' \
            WHERE meta_key IN ('first_name', 'last_name', 'nickname', 'description') \
            AND user_id IN (SELECT ID FROM \(tablePrefix)users \(whereClause))
            """,
            """
            UPDATE \(tablePrefix)users SET user_pass = MD5(UUID()), \
            user_email = CONCAT('user', ID, '@example.com'), display_name = CONCAT('User ', ID), \
            user_activation_key = '' \(whereClause)
            """,
            "DELETE FROM \(tablePrefix)usermeta WHERE meta_key = 'session_tokens'",
            "TRUNCATE TABLE \(tablePrefix)commentmeta",
            "TRUNCATE TABLE \(tablePrefix)comments",
            "UPDATE \(tablePrefix)posts SET comment_count = 0",
            "UPDATE \(tablePrefix)options SET option_value = 'admin@example.com' WHERE option_name = 'admin_email'",
            "DELETE FROM \(tablePrefix)options WHERE option_name = 'new_admin_email'",
        ]
    }
}

/// Imports a `.sql`/`.sql.gz` dump into a running site: safety backup → import
/// → URL migration → optional scrub → media handling → optional local admin
/// (PLAN.md §2m). Kit-first design: this is the ENTIRE pipeline; the app
/// sheet, CLI `db import` subcommand, and MCP `db_import` tool are thin
/// surfaces over it (same shape as Mailpit, §2e).
///
/// Mirrors `WorktreeEnvService`'s shape: an actor holding the shared `cli` /
/// `lifecycle` dependencies rather than static functions, since the pipeline
/// needs actor-serialized access to no mutable state of its own but benefits
/// from the same DI story the rest of the kit uses.
public actor DatabaseImportService {
    private let cli: ContainerCLI
    private let lifecycle: SiteLifecycle

    public init(cli: ContainerCLI, lifecycle: SiteLifecycle) {
        self.cli = cli
        self.lifecycle = lifecycle
    }

    /// Full pipeline. `progress` fires at the START of each phase. Staged
    /// files under `wordpress/.wpc-import/` are cleaned up on every exit path.
    ///
    /// Does NOT start the site: if its DB container isn't reachable this
    /// throws `.siteNotRunning` immediately — callers decide whether to start
    /// the site and retry.
    public func importDatabase(
        into site: Site,
        dump: URL,
        options: DBImportOptions,
        progress: @escaping @Sendable (DBImportPhase) -> Void
    ) async throws -> DBImportSummary {
        try await importDatabase(into: site, publicURL: site.url, dump: dump, options: options, progress: progress)
    }

    /// The pipeline for a site or a worktree env. URLs are migrated to
    /// `publicURL` (the env's advertised URL), the backup lands in the
    /// instance's own `.backups/`, and every wp-cli step targets the instance's
    /// own schema. For an env that shares its parent's database server, a dump
    /// that switches databases (`USE`, `CREATE`/`DROP DATABASE`) is refused,
    /// since it could write into the parent's or a sibling's schema.
    public func importDatabase(
        into inst: any RunnableInstance,
        publicURL: URL,
        dump: URL,
        options: DBImportOptions,
        progress: @escaping @Sendable (DBImportPhase) -> Void
    ) async throws -> DBImportSummary {
        progress(.preflight)
        let root = inst.wordpressFolder.deletingLastPathComponent()

        let ext = dump.pathExtension.lowercased()
        guard ["sql", "gz"].contains(ext) else {
            throw DatabaseImportError.invalidDumpExtension(dump.lastPathComponent)
        }
        guard FileManager.default.fileExists(atPath: dump.path) else {
            throw DatabaseImportError.dumpNotFound(dump.path)
        }

        // Site must already be running — never auto-started here (§2m brief:
        // surfaces decide whether to start-and-retry).
        guard let dbHost = try await cli.ipAddress(of: inst.dbContainerName), !dbHost.isEmpty else {
            throw DatabaseImportError.siteNotRunning
        }
        try await lifecycle.waitForDatabaseReady(inst, dbHost: dbHost)

        let dumpSizeBytes = ((try? FileManager.default.attributesOfItem(atPath: dump.path))?[.size] as? NSNumber)?.int64Value ?? 0
        try Self.checkDiskSpace(dumpBytes: dumpSizeBytes, isGzip: ext == "gz", root: root)

        // Stage the dump INSIDE the wordpress/ mount so the one-shot wp-cli
        // container can see it. `.wpc-import/` is always removed on exit.
        let stagingDir = inst.wordpressFolder.appendingPathComponent(".wpc-import", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        let stagedDump = stagingDir.appendingPathComponent("dump.sql")
        if ext == "gz" {
            try await Self.decompressGzip(from: dump, to: stagedDump)
        } else {
            if FileManager.default.fileExists(atPath: stagedDump.path) {
                try FileManager.default.removeItem(at: stagedDump)
            }
            try FileManager.default.copyItem(at: dump, to: stagedDump)
        }
        let containerDumpPath = "/var/www/html/.wpc-import/dump.sql"

        if !inst.ownsDatabaseContainer, let statement = Self.databaseSwitch(inDumpFile: stagedDump) {
            throw DatabaseImportError.dumpSwitchesDatabase(statement: statement)
        }

        // Remote media needs a KNOWN source URL. Best-effort pre-scan the
        // staged dump so this fails fast here rather than at phase 6 — the
        // authoritative source (post-import `wp option get home`) is checked
        // again in the media step regardless, since this scan can miss.
        if case .remote = options.media, options.sourceURLOverride == nil {
            guard Self.detectSourceURL(inDumpFile: stagedDump) != nil else {
                throw DatabaseImportError.sourceURLRequired
            }
        }

        // Safety backup — one command away from undone (PLAN.md §2m step 2).
        // Exported to a FILE inside the mount (never stdout→String — a
        // multi-GB export must never be buffered through a Swift String),
        // then moved out of the transient staging dir onto the host.
        progress(.backup)
        let backupsDir = root.appendingPathComponent(".backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        let backupURL = backupsDir.appendingPathComponent("pre-import-\(Self.timestamp()).sql")
        let backupStagedURL = stagingDir.appendingPathComponent("backup.sql")
        try await cli.run(SiteRecipe.wpDBExportToFileArgs(
            inst, dbHost: dbHost, containerPath: "/var/www/html/.wpc-import/backup.sql"))
        if FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.removeItem(at: backupURL)
        }
        try FileManager.default.moveItem(at: backupStagedURL, to: backupURL)

        // From here on, ANY failure (including the import itself) attempts a
        // rollback before rethrowing — the DB may already be half-written.
        var currentPhase: DBImportPhase = .importing
        do {
            progress(.importing)
            try await importSQL(inst, dbHost: dbHost, containerPath: containerDumpPath)

            currentPhase = .urlMigration
            progress(.urlMigration)
            let migration = try await migrateURLs(inst: inst, publicURL: publicURL, dbHost: dbHost, override: options.sourceURLOverride)

            var usersScrubbed = 0
            var usersPreserved = 0
            var commentsRemoved = 0
            if options.scrub {
                currentPhase = .scrubbing
                progress(.scrubbing)
                (usersScrubbed, usersPreserved, commentsRemoved) = try await scrub(inst: inst, dbHost: dbHost, options: options)
            }

            currentPhase = .media
            progress(.media)
            let mediaMode = try await handleMedia(inst: inst, media: options.media, sourceURL: migration.source)

            if options.createAdmin {
                currentPhase = .admin
                progress(.admin)
                try await ensureAdmin(inst: inst, dbHost: dbHost)
            }

            currentPhase = .finishing
            progress(.finishing)
            try await cli.run(SiteRecipe.wpCacheFlushArgs(inst, dbHost: dbHost))
            await RedisService.flush(inst, cli: cli)

            return DBImportSummary(
                sourceURL: migration.source,
                localURL: migration.local,
                backupPath: backupURL.path,
                usersScrubbed: usersScrubbed,
                usersPreserved: usersPreserved,
                commentsRemoved: commentsRemoved,
                replacementsMade: migration.replacements,
                mediaMode: mediaMode,
                adminUser: options.createAdmin ? SiteRecipe.adminUser : nil,
                adminPassword: options.createAdmin ? SiteRecipe.adminPassword : nil,
                dumpSizeBytes: dumpSizeBytes
            )
        } catch {
            progress(.rollingBack)
            let rolledBack = await attemptRollback(inst: inst, dbHost: dbHost, backupURL: backupURL)
            throw DatabaseImportError.phaseFailed(
                phase: currentPhase,
                short: DatabaseImportError.firstLine(of: error),
                full: DatabaseImportError.fullText(of: error),
                rolledBack: rolledBack
            )
        }
    }

    // MARK: - URL migration

    private func migrateURLs(inst: any RunnableInstance, publicURL: URL, dbHost: String, override: String?)
        async throws -> (source: String?, local: String, replacements: Int?) {
        let localURL = publicURL.absoluteString
        var source = override
        if source == nil {
            let raw = try await cli.run(SiteRecipe.wpOptionGetArgs(inst, dbHost: dbHost, option: "home"))
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            source = trimmed.isEmpty ? nil : trimmed
        }
        guard let sourceURL = source, sourceURL != localURL else {
            return (source, localURL, nil)
        }

        let primaryOutput = try await cli.run(SiteRecipe.wpSearchReplaceArgs(inst, dbHost: dbHost, source: sourceURL, target: localURL))
        var total = 0
        var anyParsed = false
        if let count = EnvURLMigration.parseReplacementCount(primaryOutput) {
            total += count
            anyParsed = true
        }

        // Best-effort protocol-relative and bare-host variants — only when
        // both URLs parse cleanly to a host (PLAN.md §2m: "only if straightforward").
        if let srcHost = URL(string: sourceURL)?.host, let tgtHost = URL(string: localURL)?.host {
            let srcPort = URL(string: sourceURL)?.port
            let tgtPort = URL(string: localURL)?.port
            let srcRelative = "//\(srcHost)" + (srcPort.map { ":\($0)" } ?? "")
            let tgtRelative = "//\(tgtHost)" + (tgtPort.map { ":\($0)" } ?? "")
            if srcRelative != tgtRelative {
                if let out = try? await cli.run(SiteRecipe.wpSearchReplaceArgs(inst, dbHost: dbHost, source: srcRelative, target: tgtRelative)),
                   let count = EnvURLMigration.parseReplacementCount(out) {
                    total += count
                    anyParsed = true
                }
            }
            let srcBareHost = String(srcRelative.dropFirst(2))
            let tgtBareHost = String(tgtRelative.dropFirst(2))
            if srcBareHost != tgtBareHost, srcBareHost != sourceURL {
                if let out = try? await cli.run(SiteRecipe.wpSearchReplaceArgs(inst, dbHost: dbHost, source: srcBareHost, target: tgtBareHost)),
                   let count = EnvURLMigration.parseReplacementCount(out) {
                    total += count
                    anyParsed = true
                }
            }
        }

        // Belt-and-braces (mirrors `SiteRecipe.wpSetURLsArgs`, used for HTTPS
        // toggling): make sure home/siteurl land on the local URL regardless of
        // whether search-replace's row-scan touched the `options` table oddly.
        try await cli.run(SiteRecipe.wpSetURLsArgs(inst, dbHost: dbHost, url: localURL))

        return (sourceURL, localURL, anyParsed ? total : nil)
    }

    // MARK: - Scrub

    private func scrub(inst: any RunnableInstance, dbHost: String, options: DBImportOptions)
        async throws -> (scrubbed: Int, preserved: Int, commentsRemoved: Int) {
        try DBScrubSQL.validate(allowedEmails: options.allowedEmails, allowedDomains: options.allowedDomains)

        var tablePrefix = "wp_"
        if let parsed = try? WPConfigService.read(wordpressFolder: inst.wordpressFolder),
           let prefix = parsed.tablePrefix, !prefix.isEmpty {
            tablePrefix = prefix
        }

        // Counts captured BEFORE any mutation.
        let totalUsers = try await queryScalarInt(inst: inst, dbHost: dbHost,
                                                  sql: DBScrubSQL.countAllUsersSQL(tablePrefix: tablePrefix))
        let toScrub = try await queryScalarInt(inst: inst, dbHost: dbHost, sql: DBScrubSQL.countUsersToScrubSQL(
            tablePrefix: tablePrefix, allowedEmails: options.allowedEmails,
            allowedDomains: options.allowedDomains, adminEmail: SiteRecipe.adminEmail))
        let commentsRemoved = try await queryScalarInt(inst: inst, dbHost: dbHost,
                                                       sql: DBScrubSQL.countCommentsSQL(tablePrefix: tablePrefix))

        for sql in DBScrubSQL.scrubStatements(tablePrefix: tablePrefix, allowedEmails: options.allowedEmails,
                                              allowedDomains: options.allowedDomains, adminEmail: SiteRecipe.adminEmail) {
            try await cli.run(SiteRecipe.wpDBQueryArgs(inst, dbHost: dbHost, sql: sql))
        }

        return (toScrub, max(totalUsers - toScrub, 0), commentsRemoved)
    }

    private func queryScalarInt(inst: any RunnableInstance, dbHost: String, sql: String) async throws -> Int {
        let out = try await cli.run(SiteRecipe.wpDBQueryArgs(inst, dbHost: dbHost, sql: sql, skipColumnNames: true))
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // MARK: - Media

    private func handleMedia(inst: any RunnableInstance, media: DBImportMediaOption, sourceURL: String?) async throws -> String {
        switch media {
        case .remote:
            guard let sourceURL else { throw DatabaseImportError.sourceURLRequired }
            try RemoteMediaService.writeHandler(phpConfFolder: inst.phpConfFolder, sourceBaseURL: sourceURL)
            return "remote"
        case .copy(let from):
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: from.path, isDirectory: &isDir), isDir.boolValue else {
                throw DatabaseImportError.mediaFolderNotFound(from.path)
            }
            try Self.copyMediaContents(from: from, to: inst.wordpressFolder.appendingPathComponent("wp-content/uploads", isDirectory: true))
            return "copy"
        case .skip:
            return "skip"
        }
    }

    /// Copy the CONTENTS of `source` into `destination` (merge, overwriting
    /// existing files) — `FileManager.copyItem` already uses an APFS clonefile
    /// for same-volume copies, so no explicit `cp -c` shell-out is needed.
    private static func copyMediaContents(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let items = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for item in items {
            let dest = destination.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: item, to: dest)
        }
    }

    // MARK: - Local admin

    private func ensureAdmin(inst: any RunnableInstance, dbHost: String) async throws {
        let existing = try await cli.runCapturing(SiteRecipe.wpUserGetArgs(inst, dbHost: dbHost, user: SiteRecipe.adminUser))
        if existing.succeeded {
            try await cli.run(SiteRecipe.wpUserUpdateAdminPasswordArgs(inst, dbHost: dbHost))
            try await cli.run(SiteRecipe.wpUserSetRoleAdminArgs(inst, dbHost: dbHost))
        } else {
            try await cli.run(SiteRecipe.wpUserCreateAdminArgs(inst, dbHost: dbHost))
        }
    }

    // MARK: - SQL import

    /// `wp db import` of a staged file. wp-cli exits 0 even when a statement
    /// fails (the client keeps going), so a MySQL `ERROR nnnn` line in its
    /// output is treated as a failed import too.
    private func importSQL(_ inst: any RunnableInstance, dbHost: String, containerPath: String) async throws {
        let args = SiteRecipe.wpDBImportArgs(inst, dbHost: dbHost, containerPath: containerPath)
        let result = try await cli.runCapturing(args)
        if let line = Self.sqlError(in: result.stdout + "\n" + result.stderr) {
            throw SQLImportError(message: line)
        }
        guard result.succeeded else {
            throw ContainerCLIError(command: args, exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
        }
    }

    /// A statement in the dump failed; `message` is the MySQL client's error line.
    struct SQLImportError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// The first MySQL client error line (`ERROR 1146 (42S02) at line 2 …`), if any.
    static func sqlError(in output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .first { $0.firstMatch(of: /^ERROR \d+ \([0-9A-Z]{5}\)/) != nil }
            .map(String.init)
    }

    // MARK: - Rollback

    /// Re-import the pre-import backup. Returns whether it succeeded; never throws.
    private func attemptRollback(inst: any RunnableInstance, dbHost: String, backupURL: URL) async -> Bool {
        let stagingDir = inst.wordpressFolder.appendingPathComponent(".wpc-import", isDirectory: true)
        let rollbackFile = stagingDir.appendingPathComponent("rollback.sql")
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: rollbackFile.path) {
                try FileManager.default.removeItem(at: rollbackFile)
            }
            try FileManager.default.copyItem(at: backupURL, to: rollbackFile)
            defer { try? FileManager.default.removeItem(at: rollbackFile) }
            try await importSQL(inst, dbHost: dbHost, containerPath: "/var/www/html/.wpc-import/rollback.sql")
            return true
        } catch {
            return false
        }
    }

    // MARK: - Preflight helpers

    private static func timestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: Date())
    }

    /// Rough "is there clearly not enough room" guard (PLAN.md §2m: "verify
    /// dump size vs free disk"). Best-effort and deliberately generous: a
    /// gzip-compressed SQL dump commonly deflates ~6-10x, so a staged
    /// decompressed copy plus the pre-import backup export can together need
    /// several times the compressed file's size. Not exact — dumps >2GB are a
    /// known non-goal (§2m) — just enough to fail fast before burning minutes
    /// on an import that was never going to fit.
    private static func checkDiskSpace(dumpBytes: Int64, isGzip: Bool, root: URL) throws {
        guard dumpBytes > 0 else { return }
        let estimatedNeed = isGzip ? dumpBytes * 8 : dumpBytes * 3
        guard let available = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else {
            return
        }
        if available < estimatedNeed {
            throw DatabaseImportError.insufficientDiskSpace(requiredBytes: estimatedNeed, availableBytes: available)
        }
    }

    /// Best-effort scan of a STAGED (already decompressed) SQL dump for the
    /// WordPress `home` option value, BEFORE any import happens — so the
    /// remote-media preflight check can fail fast without waiting for phase
    /// 4's authoritative `wp option get home`. Reads in bounded chunks so a
    /// multi-GB dump is never buffered whole into memory; gives up (returns
    /// nil, meaning "not detected" — not "definitely absent") past a scan cap.
    static func detectSourceURL(inDumpFile url: URL, scanCapBytes: Int = 200 * 1024 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let regex = try? NSRegularExpression(pattern: #"'home'\s*,\s*'((?:\\.|[^'\\])*)'"#) else { return nil }

        var tail = ""
        var scanned = 0
        let chunkSize = 4 * 1024 * 1024
        while scanned < scanCapBytes {
            guard let data = try? handle.read(upToCount: chunkSize), !data.isEmpty else { break }
            scanned += data.count
            let chunkText = tail + String(decoding: data, as: UTF8.self)
            let ns = chunkText as NSString
            if let m = regex.firstMatch(in: chunkText, range: NSRange(location: 0, length: ns.length)) {
                let raw = ns.substring(with: m.range(at: 1))
                return raw.replacingOccurrences(of: "\\'", with: "'").replacingOccurrences(of: "\\\\", with: "\\")
            }
            // Keep a small tail overlap in case a match straddles the chunk boundary.
            tail = String(chunkText.suffix(256))
        }
        return nil
    }

    /// The first statement in a STAGED dump that selects, creates or drops a
    /// database (`USE`, `CREATE DATABASE`/`SCHEMA`, `DROP DATABASE`/`SCHEMA`,
    /// as `mysqldump --databases` writes), trimmed to its opening words; nil
    /// when there is none. Scans the whole file, reading only the start of each
    /// line, so a multi-GB dump is never held in memory.
    static func databaseSwitch(inDumpFile url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let prefixLength = 40
        var lineStart: [UInt8] = []
        var collecting = true
        var found: String?

        func check(_ bytes: [UInt8]) -> String? {
            let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            let upper = text.uppercased()
            let switches = ["USE ", "USE`", "CREATE DATABASE", "CREATE SCHEMA", "DROP DATABASE", "DROP SCHEMA"]
            return switches.contains { upper.hasPrefix($0) } ? text : nil
        }

        while found == nil, let chunk = try? handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            chunk.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                var i = 0
                while i < raw.count, found == nil {
                    if collecting {
                        let byte = base[i]
                        i += 1
                        if byte == 0x0A {
                            found = check(lineStart)
                            lineStart.removeAll(keepingCapacity: true)
                            continue
                        }
                        lineStart.append(byte)
                        if lineStart.count == prefixLength {
                            found = check(lineStart)
                            collecting = false
                        }
                    } else {
                        // Skip the rest of a long line (an INSERT can run to megabytes).
                        guard let newline = memchr(base + i, 0x0A, raw.count - i) else { i = raw.count; break }
                        i = UnsafeRawPointer(newline) - UnsafeRawPointer(base) + 1
                        lineStart.removeAll(keepingCapacity: true)
                        collecting = true
                    }
                }
            }
        }
        if found == nil, collecting, !lineStart.isEmpty { found = check(lineStart) }
        return found
    }

    /// Decompress a `.gz` dump directly to `destination` via `/usr/bin/gzip
    /// -dc`, streaming through a `FileHandle` so a multi-GB dump is never
    /// buffered through a `String`/`Data` in memory the way `ProcessRunner`
    /// (which captures full output) would.
    private static func decompressGzip(from source: URL, to destination: URL) async throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let outHandle = FileHandle(forWritingAtPath: destination.path) else {
            throw DatabaseImportError.decompressionFailed(source.path)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = ["-dc", source.path]
            process.standardOutput = outHandle
            let errPipe = Pipe()
            process.standardError = errPipe
            process.terminationHandler = { proc in
                try? outHandle.close()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0 {
                    cont.resume(returning: ())
                } else {
                    let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(throwing: DatabaseImportError.decompressionFailed(
                        msg.isEmpty ? source.path : "\(source.path): \(msg)"))
                }
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
