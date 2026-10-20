import ArgumentParser
import Foundation
import WPContainerKit

// MARK: - db (PLAN.md §2m)

/// Grouped `db` parent command — leaves room for a future `db export`.
struct DBCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "db",
        abstract: "Manage a site's database.",
        subcommands: [DBImportCommand.self]
    )
}

/// `--media` choice for `db import`. Mirrors `DBImportMediaOption`.
enum MediaOptionArg: String, ExpressibleByArgument, CaseIterable {
    case remote, skip, copy
}

// MARK: - db import

/// The import options shared by `db import` and `worktree create --import`.
struct DBImportFlags: ParsableArguments {
    @Flag(name: .customLong("scrub"), inversion: .prefixedNo,
          help: "Scrub personal data (users/comments/admin email) after import.")
    var scrub = true

    @Option(name: .long, help: "Comma-separated emails to preserve as-is when scrubbing, e.g. a@b.com,c@d.com.")
    var allowedEmails: String?

    @Option(name: .long, help: "Comma-separated email domains to preserve as-is when scrubbing, e.g. agency.com.")
    var allowedDomains: String?

    @Option(name: .long, help: "Media handling: remote (default), skip, or copy (requires --media-path).")
    var media: MediaOptionArg = .remote

    @Option(name: .long, help: "Local uploads folder to copy from; required when --media copy.")
    var mediaPath: String?

    @Flag(name: .customLong("admin"), inversion: .prefixedNo,
          help: "Create/reset the local admin/password login after import.")
    var admin = true

    @Option(name: .long, help: "Trust this URL as the dump's source instead of the detected `home` option.")
    var sourceURL: String?

    /// The options for `DatabaseImportService`, validating `--media copy`.
    func importOptions() throws -> DBImportOptions {
        let mediaOption: DBImportMediaOption
        switch media {
        case .remote: mediaOption = .remote
        case .skip: mediaOption = .skip
        case .copy:
            guard let mediaPath else { throw CLIErrorJSON("bad_args", detail: "--media copy requires --media-path <folder>.") }
            mediaOption = .copy(from: Self.expandPath(mediaPath))
        }
        return DBImportOptions(scrub: scrub, allowedEmails: Self.splitList(allowedEmails),
                               allowedDomains: Self.splitList(allowedDomains), media: mediaOption,
                               createAdmin: admin, sourceURLOverride: sourceURL)
    }

    static func expandPath(_ raw: String) -> URL {
        URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }

    static func splitList(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

struct DBImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import a .sql/.sql.gz dump into a site's or worktree env's database.",
        discussion: """
        Pipeline (PLAN.md §2m): preflight → safety backup (.backups/pre-import-\
        <timestamp>.sql beside the target's wordpress/) → import → URL migration (source \
        detected from the dump's `home` option, or --source-url) → scrub of personal data \
        (default ON) → media handling → local admin/password login (default ON) → finish. \
        If the target isn't running it is started first (pass --no-start to fail instead). \
        On any failure from the import step onward, the pre-import backup is automatically \
        re-imported (rollback) before the error is reported.

        A worktree env's import replaces only the env's own database (its schema on the \
        parent's server, or its own database container) and migrates URLs to the env's \
        URL; the parent site and other envs are untouched. For an env sharing its \
        parent's server, a dump that switches databases (`USE`, `CREATE DATABASE`, as \
        `mysqldump --databases` writes) is refused.
        """
    )

    @Argument(help: "Site slug or env slug.") var site: String
    @Argument(help: "Path to a .sql or .sql.gz dump file.") var dumpPath: String

    @OptionGroup var importFlags: DBImportFlags

    @Flag(name: .long, help: "Don't auto-start the site if it's stopped; fail instead.")
    var noStart = false

    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        let jsonMode = output.json
        do {
            let options = try importFlags.importOptions()

            let envelope = try await ctx.load()
            guard let resolved = resolveTarget(site, in: envelope) else {
                throw CLIErrorJSON("not_found", detail: site)
            }
            let inst = resolved.instance
            let publicURL: URL
            switch resolved {
            case .site(let s): publicURL = s.url
            case .env(let e): publicURL = e.url
            }
            // A long-running import against an idle-stop-enabled target must not
            // get swept mid-import — count it as activity up front (issue #16),
            // mirroring `wp`/`login`/the MCP dispatcher's stamp-before-work.
            await ctx.persistence.recordActivity(instanceID: inst.instanceID)

            // Auto-start (the kit never starts a site itself — DatabaseImportError
            // .siteNotRunning would be thrown instead; §2m brief: surfaces decide).
            // `ensureRunning` prints its own stderr notice when it has to start
            // something; `--no-start` opts out and leaves the not-running case to
            // `DatabaseImportService` (which throws `.siteNotRunning`).
            try await ctx.ensureRunning(resolved, envelope: envelope, noStart: noStart)

            let importer = DatabaseImportService(cli: ctx.cli, lifecycle: ctx.lifecycle)
            let dumpURL = DBImportFlags.expandPath(dumpPath)
            let summary = try await importer.importDatabase(into: inst, publicURL: publicURL, dump: dumpURL,
                                                            options: options) { phase in
                guard !jsonMode else { return }
                emitLine("→ \(Self.progressLine(for: phase))")
            }

            // Persist a site's detected/overridden source URL — the kit does not write it.
            if case .site(let siteRecord) = resolved, let detectedSource = summary.sourceURL {
                _ = try? await ctx.persistence.mutate { env in
                    if let i = env.sites.firstIndex(where: { $0.id == siteRecord.id }) {
                        env.sites[i].lastImportSourceURL = detectedSource
                    }
                }
            }

            if jsonMode {
                emitLine(CLIJSON.string(DBImportResultJSON(from: summary, site: site)))
            } else {
                emitLine(Self.summaryText(summary, site: site))
            }
        } catch let dbError as DatabaseImportError {
            Self.reportImportError(dbError, json: jsonMode)
            throw ExitCode.failure
        } catch {
            throw failCommand(error, json: jsonMode)
        }
    }

    // MARK: - Helpers

    static func progressLine(for phase: DBImportPhase) -> String {
        switch phase {
        case .preflight: return "Checking site and dump…"
        case .backup: return "Backing up current database…"
        case .importing: return "Importing dump…"
        case .urlMigration: return "Migrating URLs…"
        case .scrubbing: return "Scrubbing personal data…"
        case .media: return "Handling media…"
        case .admin: return "Setting up local admin…"
        case .finishing: return "Finishing up…"
        case .rollingBack: return "Rolling back to the pre-import backup…"
        }
    }

    static func summaryText(_ summary: DBImportSummary, site: String) -> String {
        let sizeFmt = ByteCountFormatter()
        sizeFmt.countStyle = .file
        var lines = ["Imported database into \(site)."]
        if let source = summary.sourceURL { lines.append("  Source:       \(source)") }
        lines.append("  Local:        \(summary.localURL)")
        lines.append("  Backup:       \(summary.backupPath)")
        lines.append("  Dump size:    \(sizeFmt.string(fromByteCount: summary.dumpSizeBytes))")
        lines.append("  Users:        \(summary.usersScrubbed) scrubbed, \(summary.usersPreserved) preserved")
        lines.append("  Comments:     \(summary.commentsRemoved) removed")
        if let replacements = summary.replacementsMade { lines.append("  Replacements: \(replacements)") }
        lines.append("  Media:        \(summary.mediaMode)")
        if let user = summary.adminUser, let pass = summary.adminPassword {
            lines.append("  Admin:        \(user) / \(pass)")
        }
        return lines.joined(separator: "\n")
    }

    /// A `phaseFailed` error always reports phase + short message + whether the
    /// DB was rolled back; the full underlying detail is only in --json output
    /// (kept out of the default text summary, which stays short).
    static func reportImportError(_ error: DatabaseImportError, json: Bool) {
        if case .phaseFailed(let phase, let short, let full, let rolledBack) = error {
            if json {
                struct ImportErrorJSON: Encodable {
                    let error = "import_failed"
                    let phase: String
                    let short: String
                    let full: String
                    let rolledBack: Bool
                }
                let payload = ImportErrorJSON(phase: phase.rawValue, short: short, full: full, rolledBack: rolledBack)
                FileHandle.standardError.write(Data((CLIJSON.string(payload) + "\n").utf8))
            } else {
                let rollbackNote = rolledBack
                    ? "database rolled back to the pre-import backup."
                    : "rollback ALSO failed — restore manually from the .backups/ folder."
                FileHandle.standardError.write(Data(("Import failed during \(phase.rawValue) — \(short) (\(rollbackNote))\n").utf8))
            }
            return
        }
        let cliError = CLIErrorJSON("import_failed", detail: error.description)
        if json {
            FileHandle.standardError.write(Data((CLIJSON.string(cliError) + "\n").utf8))
        } else {
            FileHandle.standardError.write(Data(("\(cliError.error): \(cliError.detail ?? "")\n").utf8))
        }
    }
}

/// `wp-container db import --json` output: `DBImportSummary` plus the site slug.
/// Defined here (not in WPContainerKit's CLIModels) since it's a CLI-surface
/// concern, not part of the kit's public contract.
struct DBImportResultJSON: Encodable {
    let site: String
    let sourceURL: String?
    let localURL: String
    let backupPath: String
    let usersScrubbed: Int
    let usersPreserved: Int
    let commentsRemoved: Int
    let replacementsMade: Int?
    let mediaMode: String
    let adminUser: String?
    let adminPassword: String?
    let dumpSizeBytes: Int64

    init(from summary: DBImportSummary, site: String) {
        self.site = site
        self.sourceURL = summary.sourceURL
        self.localURL = summary.localURL
        self.backupPath = summary.backupPath
        self.usersScrubbed = summary.usersScrubbed
        self.usersPreserved = summary.usersPreserved
        self.commentsRemoved = summary.commentsRemoved
        self.replacementsMade = summary.replacementsMade
        self.mediaMode = summary.mediaMode
        self.adminUser = summary.adminUser
        self.adminPassword = summary.adminPassword
        self.dumpSizeBytes = summary.dumpSizeBytes
    }
}
