import ArgumentParser
import Foundation
import WPContainerKit

// MARK: - export

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export a site to a portable zip archive.",
        discussion: """
        The archive holds the site's database, its wordpress/ folder (with \
        docroot mounts copied in), and its environment settings. `wpc import` \
        recreates the site from it on any Mac. If the site isn't running it is \
        started first (pass --no-start to fail instead). Ctrl-C cancels the \
        export and removes its partial files.
        """
    )

    @Argument(help: "Site slug.") var site: String

    @Option(name: [.short, .long], help: "Archive path (default: ./<slug>-<yyyyMMdd>.zip).")
    var output: String?

    @Option(name: .long, help: "A file or folder name to leave out; repeatable.")
    var exclude: [String] = []

    @Flag(name: .long, help: "Don't leave out .git, node_modules, and the other default excludes.")
    var noDefaultExcludes = false

    @Flag(name: .long, help: "Overwrite an existing archive at the output path.")
    var force = false

    @Flag(name: .long, help: "Don't auto-start the site if it's stopped; fail instead.")
    var noStart = false

    @OptionGroup var jsonOptions: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        let jsonMode = jsonOptions.json
        do {
            let envelope = try await ctx.load()
            guard let resolved = resolveTarget(site, in: envelope) else {
                throw CLIErrorJSON("not_found", detail: site)
            }
            guard case .site(let siteRecord) = resolved else {
                throw CLIErrorJSON("bad_args", detail: "export works on sites, not worktree environments")
            }
            // Counts as activity so idle-stop leaves the site up during a long export.
            await ctx.persistence.recordActivity(instanceID: siteRecord.instanceID)
            try await ctx.ensureRunning(resolved, envelope: envelope, noStart: noStart)

            let fileName = SiteArchiveService.defaultFileName(slug: siteRecord.slug, date: Date())
            let destination = archiveDestination(output.map { ($0 as NSString).expandingTildeInPath } ?? fileName,
                                                 fileName: fileName)
            let excludes = (noDefaultExcludes ? [] : SiteArchiveService.defaultExcludes) + exclude

            let service = SiteArchiveService(cli: ctx.cli, lifecycle: ctx.lifecycle, persistence: ctx.persistence)
            let overwrite = force
            let summary = try await runCancellingOnSignal(notice: "Export cancelled.", json: jsonMode) {
                try await service.export(siteRecord, to: destination, excludes: excludes,
                                         overwrite: overwrite) { phase in
                    guard !jsonMode else { return }
                    writeStderr("→ \(Self.progressLine(for: phase))")
                }
            }

            if jsonMode {
                emitLine(CLIJSON.string(summary))
            } else {
                let size = ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)
                emitLine("Exported \(siteRecord.slug) to \(summary.archive.path) (\(size))")
                for warning in summary.warnings { emitLine("! \(warning)") }
            }
        } catch let code as ExitCode {
            throw code
        } catch {
            throw failCommand(error, json: jsonMode)
        }
    }

    private static func progressLine(for phase: SiteExportPhase) -> String {
        switch phase {
        case .preflight: return "Checking site…"
        case .dumpingDatabase: return "Dumping database…"
        case .archiving: return "Packaging files…"
        case .finishing: return "Finishing up…"
        }
    }
}

// MARK: - import

struct ImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Create a new site from a wpc export archive.",
        discussion: """
        Creates the site folder and record, extracts the files, starts the site, \
        imports the database, and migrates its URLs to the new site's URL. \
        Users are kept as they were. The site keeps the archive's custom domain \
        unless --domain or --no-domain is given. A failure, or Ctrl-C, removes \
        the new site again before the command exits.
        """
    )

    @Argument(help: "Path to a .zip made by `wpc export`.") var archive: String

    @Option(name: .long, help: "Name for the new site (default: the exported site's name).")
    var name: String?

    @Option(name: .long, help: "Custom domain for the new site, e.g. mysite.local.")
    var domain: String?

    @Flag(name: .long, help: "Give the new site no custom domain.")
    var noDomain = false

    @Option(name: .long, help: "Parent folder (default: ~/WP Container Sites).")
    var path: String?

    @Option(name: .long, help: "Sidebar group name (created if it doesn't exist).")
    var group: String?

    @Option(name: .long, help: "Full WordPress image tag override (e.g. wordpress:php8.3-apache).")
    var image: String?

    @OptionGroup var jsonOptions: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        let jsonMode = jsonOptions.json
        do {
            if domain != nil && noDomain {
                throw CLIErrorJSON("bad_args", detail: "--domain and --no-domain cannot be used together.")
            }
            let domainChoice: SiteImportDomain
            if noDomain {
                domainChoice = .none
            } else if let domain {
                domainChoice = .set(domain)
            } else {
                domainChoice = .keep
            }
            let parentFolder = path.map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            } ?? SiteFolders.defaultSitesRoot
            let options = SiteImportOptions(name: name, domain: domainChoice, parentFolder: parentFolder,
                                            groupName: group, imageOverride: image)
            let archiveURL = URL(fileURLWithPath: (archive as NSString).expandingTildeInPath).standardizedFileURL

            let service = SiteArchiveService(cli: ctx.cli, lifecycle: ctx.lifecycle, persistence: ctx.persistence)
            let result = try await runCancellingOnSignal(notice: "Import cancelled.", json: jsonMode) {
                try await service.importSite(archive: archiveURL, options: options) { phase in
                    guard !jsonMode else { return }
                    writeStderr("→ \(Self.progressLine(for: phase))")
                }
            }

            var site = result.site
            site.status = await ctx.lifecycle.isWPContainerRunning(site) ? .running : .stopped
            if jsonMode {
                let envelope = try? await ctx.load()
                let groupName = site.groupID.flatMap { id in envelope?.groups.first { $0.id == id }?.name }
                let payload = SiteImportResultJSON(site: SiteJSON(from: site, group: groupName),
                                                   warnings: result.warnings,
                                                   replacements: result.urlReport.replacements)
                emitLine(CLIJSON.string(payload))
            } else {
                emitLine("Imported \(site.slug) at \(site.url.absoluteString)")
                for warning in result.warnings { emitLine("! \(warning)") }
            }
        } catch let code as ExitCode {
            throw code
        } catch {
            throw failCommand(error, json: jsonMode)
        }
    }

    private static func progressLine(for phase: SiteImportPhase) -> String {
        switch phase {
        case .validating: return "Checking archive…"
        case .creatingSite: return "Creating site…"
        case .extracting: return "Extracting files…"
        case .startingSite: return "Starting site…"
        case .importingDatabase: return "Importing database…"
        case .migratingURLs: return "Migrating URLs…"
        case .applyingSettings: return "Applying settings…"
        case .applyingDomain: return "Applying custom domain…"
        case .finishing: return "Finishing up…"
        case .rollingBack: return "Removing the partly imported site…"
        }
    }
}

/// `wp-container import --json` output.
private struct SiteImportResultJSON: Encodable {
    let site: SiteJSON
    let warnings: [String]
    let replacements: Int
}

/// An existing directory receives the archive under `fileName`.
func archiveDestination(_ path: String, fileName: String) -> URL {
    var destination = URL(fileURLWithPath: path).standardizedFileURL
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
        destination.appendPathComponent(fileName)
    }
    return destination
}

/// Runs `work` in a task that SIGINT and SIGTERM cancel, so its cleanup runs
/// before the process exits. When a signal ends the work early, prints
/// `notice` to stderr and throws exit code 130.
func runCancellingOnSignal<T: Sendable>(
    notice: String,
    json: Bool,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    let task = Task { try await work() }
    let sources = [SIGINT, SIGTERM].map { signalNumber -> DispatchSourceSignal in
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
        source.setEventHandler { task.cancel() }
        source.resume()
        return source
    }
    defer { sources.forEach { $0.cancel() } }

    let result = await task.result
    if case .failure = result, task.isCancelled {
        let line = json ? CLIJSON.string(CLIErrorJSON("cancelled", detail: notice)) : notice
        writeStderr(line)
        throw ExitCode(130)
    }
    return try result.get()
}

private func writeStderr(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}
