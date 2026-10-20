import Foundation

/// Steps of `SiteArchiveService.export`, reported at the start of each.
public enum SiteExportPhase: String, Sendable {
    case preflight, dumpingDatabase, archiving, finishing
}

/// The result of an export.
public struct SiteExportSummary: Sendable, Codable {
    public var archive: URL
    public var bytes: Int64
    public var manifest: SiteArchiveManifest
    public var warnings: [String]

    public init(archive: URL, bytes: Int64, manifest: SiteArchiveManifest, warnings: [String]) {
        self.archive = archive
        self.bytes = bytes
        self.manifest = manifest
        self.warnings = warnings
    }
}

/// Exports a site to a portable zip archive and imports one back.
public actor SiteArchiveService {

    /// Folders left out of an export unless the caller overrides the list.
    public static let defaultExcludes: [String] = [".git", ".svn", ".DS_Store", "__MACOSX", "node_modules", "bower_components"]

    /// Working folders of the export and import steps; never archived.
    public static let alwaysExcluded: [String] = [".wpc-export", ".wpc-import"]

    private static let zipPath = "/usr/bin/zip"
    private static let rsyncPath = "/usr/bin/rsync"

    private let cli: ContainerCLI
    private let lifecycle: SiteLifecycle
    private let persistence: StorePersistence

    public init(cli: ContainerCLI, lifecycle: SiteLifecycle, persistence: StorePersistence) {
        self.cli = cli
        self.lifecycle = lifecycle
        self.persistence = persistence
    }

    // MARK: - Export

    /// Dumps the database of a running site and packages it with the site's
    /// `wordpress/` folder and its docroot mounts into `destination`.
    /// Throws `.siteNotRunning` when the database container has no address.
    public func export(
        _ site: Site,
        to destination: URL,
        excludes: [String],
        overwrite: Bool,
        progress: @escaping @Sendable (SiteExportPhase) -> Void
    ) async throws -> SiteExportSummary {
        let fm = FileManager.default
        progress(.preflight)
        let address = try await cli.ipAddress(of: site.dbContainerName)
        guard let dbHost = address, !dbHost.isEmpty else { throw SiteArchiveError.siteNotRunning }
        if fm.fileExists(atPath: destination.path), !overwrite {
            throw SiteArchiveError.outputExists(destination.path)
        }
        try await lifecycle.waitForDatabaseReady(site, dbHost: dbHost)

        let staging = site.path.appendingPathComponent(".wpc-export", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // The dump lands inside the `wordpress/` mount, where the wp-cli container can write.
        progress(.dumpingDatabase)
        let dumpFolder = site.wordpressFolder.appendingPathComponent(".wpc-export", isDirectory: true)
        try fm.createDirectory(at: dumpFolder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dumpFolder) }
        let containerPath = "/var/www/html/.wpc-export/\(SiteArchiveLayout.databaseName)"
        try await cli.run(SiteRecipe.wpDBExportToFileArgs(site, dbHost: dbHost, containerPath: containerPath))
        try fm.moveItem(at: dumpFolder.appendingPathComponent(SiteArchiveLayout.databaseName),
                        to: staging.appendingPathComponent(SiteArchiveLayout.databaseName))

        let (inlined, skipped) = Self.inlinableMounts(site.mounts)
        let manifest = SiteArchiveManifest(
            source: .init(name: site.name, slug: site.slug, url: site.url.absoluteString,
                          localURL: "http://127.0.0.1:\(site.port)"),
            wordpressVersion: Self.wordpressVersion(in: site.wordpressFolder),
            tablePrefix: (try? WPConfigService.read(wordpressFolder: site.wordpressFolder))?.tablePrefix,
            excludes: excludes,
            mountsInlined: inlined.compactMap { Self.safeRelativePath($0.relativePath) },
            settings: SiteArchiveSettings(site: site))

        progress(.archiving)
        var warnings = skipped.map {
            "Mount \($0.hostPath) -> \($0.containerPath) is outside the docroot and was not included."
        }
        warnings += try await Self.package(
            wordpressFolder: site.wordpressFolder, stagingFolder: staging, destination: destination,
            manifest: manifest, excludes: excludes, mounts: inlined, overwrite: overwrite)
        warnings += Self.externalSymlinks(in: site.wordpressFolder).map {
            "Symlink wordpress/\($0) points outside the site folder; the imported site will not have its target."
        }
        if !WPConfigService.dbHostFollowsEnvironment(wordpressFolder: site.wordpressFolder) {
            warnings.append("wp-config.php hardcodes DB_HOST; the imported site may not reach its database")
        }

        progress(.finishing)
        let attributes = try? fm.attributesOfItem(atPath: destination.path)
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return SiteExportSummary(archive: destination, bytes: bytes, manifest: manifest, warnings: warnings)
    }

    // MARK: - Helpers

    /// A host folder bind-mounted inside the docroot, copied into the archive.
    public struct InlinedMount: Equatable, Sendable {
        public let hostPath: String
        /// Path relative to the archive's `wordpress/` folder.
        public let relativePath: String

        public init(hostPath: String, relativePath: String) {
            self.hostPath = hostPath
            self.relativePath = relativePath
        }
    }

    /// `zip -x` arguments excluding each pattern at the archive root and at any depth.
    public static func zipExcludeArgs(_ patterns: [String], under root: String) -> [String] {
        var args: [String] = []
        for pattern in patterns + alwaysExcluded {
            args += ["-x", "\(root)/\(pattern)"]
            args += ["-x", "\(root)/\(pattern)/*"]
            args += ["-x", "*/\(pattern)"]
            args += ["-x", "*/\(pattern)/*"]
        }
        return args
    }

    /// Rejects absolute paths, `..` components, and top-level entries outside the archive layout.
    public static func validateEntries(_ names: [String]) throws {
        let allowedTopLevel: Set<String> = [
            SiteArchiveLayout.manifestName,
            SiteArchiveLayout.databaseName,
            SiteArchiveLayout.wordpressFolder,
        ]
        var hasManifest = false
        for name in names {
            if name.hasPrefix("/") { throw SiteArchiveError.unsafeEntry(name) }
            let components = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if components.contains("..") { throw SiteArchiveError.unsafeEntry(name) }
            guard let top = components.first, allowedTopLevel.contains(top) else {
                throw SiteArchiveError.unsafeEntry(name)
            }
            if name == SiteArchiveLayout.manifestName { hasManifest = true }
        }
        if !hasManifest { throw SiteArchiveError.notAWPCExport }
    }

    /// A slug free in the site store and as a folder under `parentFolder`.
    public static func resolveSlug(name: String, existingSlugs: Set<String>, parentFolder: URL) -> String {
        var taken = existingSlugs
        var slug = Slug.unique(name, existing: taken)
        while FileManager.default.fileExists(atPath: parentFolder.appendingPathComponent(slug).path) {
            taken.insert(slug)
            slug = Slug.unique(name, existing: taken)
        }
        return slug
    }

    /// Splits mounts into those strictly under the docroot and the rest.
    public static func inlinableMounts(_ mounts: [Mount]) -> (inlined: [InlinedMount], skipped: [Mount]) {
        let docroot = "/var/www/html/"
        var inlined: [InlinedMount] = []
        var skipped: [Mount] = []
        for mount in mounts {
            let relative = String(mount.containerPath.dropFirst(docroot.count))
            if mount.containerPath.hasPrefix(docroot), !relative.isEmpty {
                inlined.append(InlinedMount(hostPath: mount.hostPath, relativePath: relative))
            } else {
                skipped.append(mount)
            }
        }
        return (inlined, skipped)
    }

    /// `<slug>-<yyyyMMdd>.zip`
    public static func defaultFileName(slug: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return "\(slug)-\(formatter.string(from: date)).zip"
    }

    /// Writes `manifest` into `stagingFolder` and zips it, the staged
    /// `database.sql`, and `wordpressFolder` (which must be named `wordpress`)
    /// into `destination`. Each mount is copied in at its relative path.
    /// The archive is built beside `destination` and moved into place only on
    /// success. Returns warnings for mounts skipped because of an unsafe path.
    public static func package(
        wordpressFolder: URL,
        stagingFolder: URL,
        destination: URL,
        manifest: SiteArchiveManifest,
        excludes: [String],
        mounts: [InlinedMount],
        overwrite: Bool
    ) async throws -> [String] {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path), !overwrite {
            throw SiteArchiveError.outputExists(destination.path)
        }

        var warnings: [String] = []
        var safeMounts: [InlinedMount] = []
        for mount in mounts {
            if let relative = safeRelativePath(mount.relativePath) {
                safeMounts.append(InlinedMount(hostPath: mount.hostPath, relativePath: relative))
            } else {
                warnings.append("Mount \(mount.hostPath) has an unsafe path \"\(mount.relativePath)\" and was not included.")
            }
        }

        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).partial-\(UUID().uuidString).zip")
        var succeeded = false
        defer {
            if !succeeded { try? fm.removeItem(at: partial) }
        }

        try manifest.encoded().write(to: stagingFolder.appendingPathComponent(SiteArchiveLayout.manifestName))

        let root = SiteArchiveLayout.wordpressFolder
        var wordpressArgs = ["-r", "-y", "-q", "-X", partial.path, root] + zipExcludeArgs(excludes, under: root)
        for mount in safeMounts {
            wordpressArgs += ["-x", "\(root)/\(mount.relativePath)/*"]
        }
        try await runTool(zipPath, args: wordpressArgs, cwd: wordpressFolder.deletingLastPathComponent())

        let rsyncExcludes = (excludes + alwaysExcluded).map { "--exclude=\($0)" }
        for mount in safeMounts {
            let target = stagingFolder.appendingPathComponent(root, isDirectory: true)
                .appendingPathComponent(mount.relativePath, isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try await runTool(rsyncPath, args: ["-a"] + rsyncExcludes + [mount.hostPath + "/", target.path + "/"], cwd: nil)
        }

        var stagingArgs = ["-r", "-y", "-q", "-X", partial.path, SiteArchiveLayout.manifestName, SiteArchiveLayout.databaseName]
        if !safeMounts.isEmpty { stagingArgs.append(root) }
        try await runTool(zipPath, args: stagingArgs, cwd: stagingFolder)

        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: partial)
        } else {
            try fm.moveItem(at: partial, to: destination)
        }
        succeeded = true
        return warnings
    }

    /// Paths, relative to `wordpressFolder`, of symlinks whose target lies outside it.
    public static func externalSymlinks(in wordpressFolder: URL) -> [String] {
        let fm = FileManager.default
        let root = realPath(wordpressFolder.path)
        guard let enumerator = fm.enumerator(atPath: wordpressFolder.path) else { return [] }
        var links: [String] = []
        while let relative = enumerator.nextObject() as? String {
            let link = wordpressFolder.appendingPathComponent(relative)
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) else { continue }
            let base = realPath(link.deletingLastPathComponent().path)
            let absolute = destination.hasPrefix("/") ? destination : base + "/" + destination
            let target = realPath(URL(fileURLWithPath: absolute).standardizedFileURL.path)
            if target != root, !target.hasPrefix(root + "/") {
                links.append(relative)
            }
        }
        return links
    }

    /// The `$wp_version` declared in `wp-includes/version.php`.
    public static func wordpressVersion(in wordpressFolder: URL) -> String? {
        let file = wordpressFolder.appendingPathComponent("wp-includes/version.php")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let pattern = #"\$wp_version\s*=\s*['"]([^'"]+)['"]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: - Private

    /// `relativePath` without empty or `.` components, or nil when it is
    /// absolute, empty, or has a `..` component.
    private static func safeRelativePath(_ relativePath: String) -> String? {
        if relativePath.hasPrefix("/") { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
        if components.isEmpty || components.contains("..") { return nil }
        return components.joined(separator: "/")
    }

    /// `path` with symlinks resolved, or `path` itself when it does not exist.
    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Runs a packaging tool, mapping a launch failure or non-zero exit to `.toolFailed`.
    private static func runTool(_ executable: String, args: [String], cwd: URL?) async throws {
        let tool = URL(fileURLWithPath: executable).lastPathComponent
        let result: CommandResult
        do {
            result = try await ProcessRunner.run(executable: executable, args: args, cwd: cwd)
        } catch {
            throw SiteArchiveError.toolFailed(tool: tool, detail: error.localizedDescription)
        }
        guard result.succeeded else {
            let output = result.stderr.isEmpty ? result.stdout : result.stderr
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SiteArchiveError.toolFailed(tool: tool, detail: "exit \(result.exitCode): \(detail)")
        }
    }
}
