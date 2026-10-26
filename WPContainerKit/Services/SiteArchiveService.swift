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

/// What `SiteArchiveService.inspect` reads from an archive without extracting it.
public struct SiteArchiveInfo: Sendable {
    public var manifest: SiteArchiveManifest
    public var uncompressedBytes: Int64
    public var entryCount: Int

    public init(manifest: SiteArchiveManifest, uncompressedBytes: Int64, entryCount: Int) {
        self.manifest = manifest
        self.uncompressedBytes = uncompressedBytes
        self.entryCount = entryCount
    }
}

/// The custom domain an imported site gets.
public enum SiteImportDomain: Sendable, Equatable {
    /// The domain recorded in the archive's settings.
    case keep
    /// A new domain, normalized before use.
    case set(String)
    /// No custom domain.
    case none
}

public struct SiteImportOptions: Sendable {
    /// The new site's name; nil uses the archive's source name.
    public var name: String?
    public var domain: SiteImportDomain
    /// The folder the site folder is created in.
    public var parentFolder: URL
    /// A group to add the site to, created when no group has this name.
    public var groupName: String?
    /// An image tag that replaces the archive's.
    public var imageOverride: String?

    public init(
        name: String? = nil,
        domain: SiteImportDomain = .keep,
        parentFolder: URL = SiteFolders.defaultSitesRoot,
        groupName: String? = nil,
        imageOverride: String? = nil
    ) {
        self.name = name
        self.domain = domain
        self.parentFolder = parentFolder
        self.groupName = groupName
        self.imageOverride = imageOverride
    }
}

/// Steps of `SiteArchiveService.importSite`, reported at the start of each.
public enum SiteImportPhase: String, Sendable {
    case validating, creatingSite, extracting, startingSite, importingDatabase,
         migratingURLs, applyingSettings, applyingDomain, finishing, rollingBack
}

/// The result of an import.
public struct SiteImportResult: Sendable {
    public var site: Site
    public var manifest: SiteArchiveManifest
    public var urlReport: URLMigrationReport
    public var warnings: [String]

    public init(site: Site, manifest: SiteArchiveManifest, urlReport: URLMigrationReport, warnings: [String]) {
        self.site = site
        self.manifest = manifest
        self.urlReport = urlReport
        self.warnings = warnings
    }
}

/// Exports a site to a portable zip archive and imports one back.
public actor SiteArchiveService {

    /// Folders left out of an export unless the caller overrides the list.
    public static let defaultExcludes: [String] = [".git", ".svn", ".DS_Store", "__MACOSX", "node_modules", "bower_components"]

    /// Working folders of the export and import steps; never archived.
    public static let alwaysExcluded: [String] = [".wpc-export", ".wpc-import"]

    /// Free space an import needs, as a multiple of the archive's uncompressed size.
    public static let importSpaceFactor = 1.2

    /// Age after which an interrupted run's work folder or partial archive is swept.
    public static let staleLeftoverAge: TimeInterval = 6 * 3600

    private static let zipPath = "/usr/bin/zip"
    private static let unzipPath = "/usr/bin/unzip"
    private static let zipinfoPath = "/usr/bin/zipinfo"
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
        try Self.refuseExistingOutput(destination, overwrite: overwrite)
        Self.sweepStalePartialArchives(for: destination, now: Date())
        try await lifecycle.waitForDatabaseReady(site, dbHost: dbHost)

        // Clears working folders an interrupted export left behind.
        let staging = site.path.appendingPathComponent(".wpc-export", isDirectory: true)
        let dumpFolder = site.wordpressFolder.appendingPathComponent(".wpc-export", isDirectory: true)
        try? fm.removeItem(at: staging)
        try? fm.removeItem(at: dumpFolder)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // The dump lands inside the `wordpress/` mount, where the wp-cli container can write.
        progress(.dumpingDatabase)
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
        if !WPConfigService.dbHostFollowsEnvironment(wordpressFolder: site.wordpressFolder) {
            warnings.append("wp-config.php hardcodes DB_HOST; the imported site may not reach its database")
        }

        progress(.finishing)
        let attributes = try? fm.attributesOfItem(atPath: destination.path)
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return SiteExportSummary(archive: destination, bytes: bytes, manifest: manifest, warnings: warnings)
    }

    // MARK: - Import

    /// Creates a new site from an archive: its folder, store record, containers,
    /// and database. A failure or cancellation after the store record exists
    /// removes the site, and a group the import created, before the error is
    /// rethrown. Work folders that earlier interrupted imports left in the
    /// parent folder are swept first.
    public func importSite(
        archive: URL,
        options: SiteImportOptions,
        progress: @escaping @Sendable (SiteImportPhase) -> Void
    ) async throws -> SiteImportResult {
        let fm = FileManager.default
        func enter(_ phase: SiteImportPhase) throws {
            try Task.checkCancellation()
            progress(phase)
        }

        try enter(.validating)
        Self.sweepStaleImportFolders(in: options.parentFolder, now: Date())
        let info = try await Self.inspect(archive: archive)
        let manifest = info.manifest
        let settings = manifest.settings
        let needed = Int64((Double(info.uncompressedBytes) * Self.importSpaceFactor).rounded(.up))
        if let available = Self.availableCapacity(at: options.parentFolder), available < needed {
            throw SiteArchiveError.insufficientDiskSpace(needed: needed, available: available)
        }

        let name = options.name ?? manifest.source.name
        let domain: String?
        switch options.domain {
        case .keep:
            domain = try Self.normalizedDomain(settings.customDomain)
        case .set(let raw):
            guard let normalized = DomainService.normalize(raw) else { throw SiteArchiveError.invalidDomain(raw) }
            domain = normalized
        case .none:
            domain = nil
        }

        // The slug and domain are checked inside the locked store write that
        // records the site, so concurrent imports never claim the same ones.
        try enter(.creatingSite)
        let parentFolder = options.parentFolder
        let imageTag = options.imageOverride ?? settings.imageTag
        let groupName = options.groupName
        let allocation = try await persistence.allocatePort(reserve: { port, env -> SiteReservation in
            if let domain, env.sites.contains(where: { $0.customDomain == domain }) {
                return .domainInUse(domain)
            }
            let slug = Self.resolveSlug(name: name, existingSlugs: Set(env.sites.map(\.slug)),
                                        parentFolder: parentFolder)
            let sitePath = parentFolder.appendingPathComponent(slug, isDirectory: true)
            var site = Site(name: name, slug: slug, path: sitePath, port: port, imageTag: imageTag)
            settings.apply(to: &site)
            site.customDomain = domain
            site.imageTag = imageTag
            let createdGroupID = Self.assignGroup(named: groupName, to: &site, in: &env)
            env.sites.append(site)
            return .created(site, createdGroupID: createdGroupID)
        })
        let created: Site
        let createdGroupID: UUID?
        switch allocation?.value {
        case .created(let site, let groupID):
            created = site
            createdGroupID = groupID
        case .domainInUse(let taken):
            throw SiteArchiveError.domainInUse(taken)
        case nil:
            throw SiteArchiveError.noFreePort
        }

        var site = created
        var warnings: [String] = []
        let workFolder = options.parentFolder.appendingPathComponent(".wpc-import-\(UUID().uuidString)", isDirectory: true)
        let urlReport: URLMigrationReport
        do {
            try enter(.extracting)
            try await Self.extract(archive: archive, into: workFolder)
            try fm.createDirectory(at: site.path, withIntermediateDirectories: true)
            try fm.moveItem(at: workFolder.appendingPathComponent(SiteArchiveLayout.wordpressFolder, isDirectory: true),
                            to: site.wordpressFolder)
            try SiteFolders.ensure(for: site)
            try? WPCLIShim.writeShim(for: site, siteRoot: site.path, slug: site.slug)
            if settings.mailpitEnabled {
                if let enabled = try await persistence.setSidecar(SidecarAddons.mailpit, enabled: true, siteID: site.id) {
                    site = enabled.site
                } else {
                    warnings.append("Mailpit was not enabled: no free port is available for its web UI.")
                }
            }

            try enter(.startingSite)
            _ = try await lifecycle.startSite(site)
            let address = try await cli.ipAddress(of: site.dbContainerName)
            guard let dbHost = address, !dbHost.isEmpty else {
                throw SiteArchiveError.toolFailed(tool: "container", detail: "\(site.slug)'s database container has no address")
            }
            try await lifecycle.waitForDatabaseReady(site, dbHost: dbHost)

            try enter(.importingDatabase)
            try await importDatabase(site, dbHost: dbHost,
                                     dump: workFolder.appendingPathComponent(SiteArchiveLayout.databaseName))

            try enter(.migratingURLs)
            urlReport = try await migrateURLs(site, dbHost: dbHost, source: manifest.source)
            warnings += urlReport.warnings

            try enter(.applyingSettings)
            let flushed = (try? await cli.runCapturing(SiteRecipe.wpCacheFlushArgs(site, dbHost: dbHost)))?.succeeded ?? false
            if !flushed { warnings.append("The WordPress object cache could not be flushed.") }
            await RedisService.flush(site, cli: cli)
            if site.httpsEnabled || site.customDomain != nil {
                let ca = CertificateAuthority()
                try await ca.ensureGenerated()
                try await ca.ensureLeafCovers(site.proxyHosts)
                if site.httpsEnabled, !(await ca.isCATrusted()) {
                    warnings.append("The wpc certificate authority isn't trusted on this Mac; run `wpc https trust` or use Settings ▸ HTTPS.")
                }
            }

            try enter(.applyingDomain)
            if let customDomain = site.customDomain {
                let domains = HostsFileService.domains(for: try await persistence.load().sites)
                do {
                    try await DomainService(cli: cli).apply(site: site, hostsDomains: domains)
                } catch let cancellation as CancellationError {
                    throw cancellation
                } catch {
                    warnings.append("Couldn't register \(customDomain) in /etc/hosts: \(error)")
                }
            }
        } catch {
            progress(.rollingBack)
            // An unstructured task does not inherit cancellation, so the cleanup runs to completion.
            let discarded = site
            let lifecycle = self.lifecycle
            let persistence = self.persistence
            await Task {
                await SiteDiscard.discard(discarded, keepFolder: false, lifecycle: lifecycle, persistence: persistence)
                if let createdGroupID {
                    _ = try? await persistence.mutateIfChanged { store in
                        guard !store.sites.contains(where: { $0.groupID == createdGroupID }) else { return false }
                        store.groups.removeAll { $0.id == createdGroupID }
                        return true
                    }
                }
            }.value
            try? fm.removeItem(at: workFolder)
            throw error
        }

        progress(.finishing)
        try? fm.removeItem(at: workFolder)
        return SiteImportResult(site: site, manifest: manifest, urlReport: urlReport, warnings: warnings)
    }

    /// Lists, validates, and sizes an archive and decodes its manifest.
    /// Throws `.notAWPCExport` for a file that is not a zip or lacks the archive layout.
    public static func inspect(archive: URL) async throws -> SiteArchiveInfo {
        let listing: CommandResult
        do {
            listing = try await runTool(unzipPath, args: ["-Z1", archive.path], cwd: nil)
        } catch SiteArchiveError.toolFailed {
            try Task.checkCancellation()
            throw SiteArchiveError.notAWPCExport
        }
        let names = listing.stdout.split(whereSeparator: \.isNewline).map(String.init)
        guard names.contains(SiteArchiveLayout.manifestName) else { throw SiteArchiveError.notAWPCExport }
        try validateEntries(names)
        let wordpressPrefix = SiteArchiveLayout.wordpressFolder + "/"
        guard names.contains(SiteArchiveLayout.databaseName),
              names.contains(where: { $0.hasPrefix(wordpressPrefix) }) else {
            throw SiteArchiveError.notAWPCExport
        }

        let manifestOutput = try await runTool(unzipPath, args: ["-p", archive.path, SiteArchiveLayout.manifestName], cwd: nil)
        let manifestData = Data(manifestOutput.stdout.utf8)
        // The version is read on its own first, so a newer schema with
        // different fields still reports `.unsupportedSchema`.
        let probe = try? JSONDecoder().decode(SchemaVersionProbe.self, from: manifestData)
        guard let schemaVersion = probe?.schemaVersion else { throw SiteArchiveError.notAWPCExport }
        if schemaVersion > SiteArchiveLayout.schemaVersion {
            throw SiteArchiveError.unsupportedSchema(schemaVersion)
        }
        let manifest: SiteArchiveManifest
        do {
            manifest = try SiteArchiveManifest.decode(manifestData)
        } catch let error as SiteArchiveError {
            throw error
        } catch {
            throw SiteArchiveError.notAWPCExport
        }

        let totals = try await runTool(zipinfoPath, args: ["-t", archive.path], cwd: nil).stdout
        guard let match = totals.firstMatch(of: /(\d+) bytes uncompressed/), let bytes = Int64(match.1) else {
            throw SiteArchiveError.toolFailed(tool: "zipinfo", detail: totals.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return SiteArchiveInfo(manifest: manifest, uncompressedBytes: bytes, entryCount: names.count)
    }

    /// Unzips every entry of `archive` but its symlinks into `folder`, then
    /// recreates the symlinks under `folder/wordpress` and deletes each one that
    /// resolves outside it or does not resolve. Top-level symlinks are dropped.
    /// Throws `.unsafeEntry` for an entry stored under a symlink entry.
    public static func extract(archive: URL, into folder: URL) async throws {
        let fm = FileManager.default
        let links = try await symlinkEntries(in: archive)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var args = ["-q", "-o", archive.path, "-d", folder.path]
        if !links.isEmpty {
            args += ["-x"] + links.map(literalPattern)
        }
        try await runTool(unzipPath, args: args, cwd: nil)

        for name in links {
            guard let path = safeRelativePath(name) else { continue }
            let components = path.split(separator: "/")
            guard components.count > 1, components[0] == SiteArchiveLayout.wordpressFolder else { continue }
            // A symlink entry's data is its destination.
            let destination = try await runTool(unzipPath, args: ["-p", archive.path, literalPattern(name)], cwd: nil).stdout
            let link = folder.appendingPathComponent(path)
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
        }
        let wordpress = folder.appendingPathComponent(SiteArchiveLayout.wordpressFolder, isDirectory: true)
        for link in unsafeSymlinks(in: wordpress) {
            try fm.removeItem(at: wordpress.appendingPathComponent(link.path))
        }
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

    /// A symlink under `wordpress/` that import drops.
    public struct UnsafeSymlink: Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            /// The link resolves to a path outside the `wordpress/` folder.
            case leavesTree
            /// The link is dangling or part of a loop.
            case unresolvable
        }

        /// Path relative to the `wordpress/` folder.
        public let path: String
        public let reason: Reason

        public init(path: String, reason: Reason) {
            self.path = path
            self.reason = reason
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
    /// success. Symlinks that import would drop are left out, except those in
    /// a mount that stay inside the tree. Returns warnings for every symlink
    /// import would drop and for mounts skipped because of an unsafe path.
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
        try refuseExistingOutput(destination, overwrite: overwrite)

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
        let unsafeLinks = unsafeSymlinks(in: wordpressFolder)
        var wordpressArgs = ["-r", "-y", "-q", "-X", partial.path, root] + zipExcludeArgs(excludes, under: root)
        for mount in safeMounts {
            wordpressArgs += ["-x", "\(root)/\(mount.relativePath)/*"]
        }
        for link in unsafeLinks {
            wordpressArgs += ["-x", literalPattern("\(root)/\(link.path)")]
        }
        try await runTool(zipPath, args: wordpressArgs, cwd: wordpressFolder.deletingLastPathComponent())

        let rsyncExcludes = (excludes + alwaysExcluded).map { "--exclude=\($0)" }
        let stagedWordpress = stagingFolder.appendingPathComponent(root, isDirectory: true)
        for mount in safeMounts {
            let target = stagedWordpress.appendingPathComponent(mount.relativePath, isDirectory: true)
            // A nested mount replaces whatever the outer mount holds at its path.
            try? fm.removeItem(at: target)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try await runTool(rsyncPath, args: ["-a"] + rsyncExcludes + [mount.hostPath + "/", target.path + "/"], cwd: nil)
            let links = mountSymlinks(
                in: target, mountPath: mount.relativePath,
                stagedWordpress: stagedWordpress, hostWordpress: wordpressFolder)
            // unzip can refuse to create a link that leaves the extraction folder.
            for link in links where link.reason == .leavesTree {
                try fm.removeItem(at: stagedWordpress.appendingPathComponent(link.path))
            }
            warnings += links.map(symlinkWarning)
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
        return warnings + unsafeLinks.map(symlinkWarning)
    }

    /// Symlinks under `wordpressFolder` that resolve outside it or do not resolve.
    /// Each link is resolved by the kernel, so `..` after a symlinked folder
    /// counts from that folder's target.
    public static func unsafeSymlinks(in wordpressFolder: URL) -> [UnsafeSymlink] {
        let fm = FileManager.default
        let root = realPath(wordpressFolder.path) ?? wordpressFolder.path
        guard let enumerator = fm.enumerator(atPath: wordpressFolder.path) else { return [] }
        var links: [UnsafeSymlink] = []
        while let relative = enumerator.nextObject() as? String {
            let link = wordpressFolder.appendingPathComponent(relative)
            let isSymlink = (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil
            guard isSymlink else { continue }
            guard let target = realPath(link.path) else {
                links.append(UnsafeSymlink(path: relative, reason: .unresolvable))
                continue
            }
            if target != root, !target.hasPrefix(root + "/") {
                links.append(UnsafeSymlink(path: relative, reason: .leavesTree))
            }
        }
        return links
    }

    /// Removes `.wpc-import-*` work folders in `parentFolder` last modified more
    /// than `staleLeftoverAge` before `now`. Best effort.
    public static func sweepStaleImportFolders(in parentFolder: URL, now: Date) {
        removeStaleItems(in: parentFolder, now: now) { $0.hasPrefix(".wpc-import-") }
    }

    /// Removes partial archives that earlier exports to `destination` left beside
    /// it, when last modified more than `staleLeftoverAge` before `now`. Best effort.
    public static func sweepStalePartialArchives(for destination: URL, now: Date) {
        let prefix = ".\(destination.lastPathComponent).partial-"
        removeStaleItems(in: destination.deletingLastPathComponent(), now: now) {
            $0.hasPrefix(prefix) && $0.hasSuffix(".zip")
        }
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

    /// The outcome of recording an imported site in the store.
    private enum SiteReservation: Sendable {
        /// `createdGroupID` names the group this import added, if any.
        case created(Site, createdGroupID: UUID?)
        case domainInUse(String)
    }

    /// The part of a manifest every schema version shares.
    private struct SchemaVersionProbe: Decodable {
        let schemaVersion: Int
    }

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

    /// The export warning for a symlink that import drops.
    private static func symlinkWarning(_ link: UnsafeSymlink) -> String {
        switch link.reason {
        case .leavesTree:
            return "Symlink wordpress/\(link.path) points outside the site folder; the imported site will not have its target."
        case .unresolvable:
            return "Symlink wordpress/\(link.path) does not resolve; the imported site will not have it."
        }
    }

    /// `name` as a zip/unzip pattern that matches only itself.
    private static func literalPattern(_ name: String) -> String {
        var pattern = ""
        for character in name {
            if "\\*?[".contains(character) { pattern.append("\\") }
            pattern.append(character)
        }
        return pattern
    }

    /// Names of the symlink entries in `archive`, read from the `zipinfo` listing.
    /// Throws `.unsafeEntry` for an entry stored under one of them.
    private static func symlinkEntries(in archive: URL) async throws -> [String] {
        let listing = try await runTool(zipinfoPath, args: [archive.path], cwd: nil).stdout
        // permissions, version, system, size, type, method, date, time, name
        let entryLine = /^(\S)\S*\s+\d+\.\d+\s+\S+\s+\d+\s+\S+\s+\S+\s+\S+\s+\S+ (.+)$/
        var links: [String] = []
        var names: [String] = []
        for line in listing.split(whereSeparator: \.isNewline) {
            guard let match = line.firstMatch(of: entryLine) else { continue }
            let name = String(match.2)
            names.append(name)
            if match.1 == "l" { links.append(name) }
        }
        let linkPaths = Set(links.compactMap(safeRelativePath))
        for name in names {
            guard let path = safeRelativePath(name) else { continue }
            let components = path.split(separator: "/")
            for depth in components.indices.dropLast() {
                let parent = components[...depth].joined(separator: "/")
                if linkPaths.contains(parent) { throw SiteArchiveError.unsafeEntry(name) }
            }
        }
        return links
    }

    /// Symlinks under the staged mount folder `mountFolder` that import would drop.
    /// An absolute destination leaves the tree. A relative one is joined lexically
    /// with the link's folder; it leaves the tree when it climbs above `wordpress/`
    /// and does not resolve when it exists in neither `stagedWordpress` nor `hostWordpress`.
    private static func mountSymlinks(
        in mountFolder: URL, mountPath: String, stagedWordpress: URL, hostWordpress: URL
    ) -> [UnsafeSymlink] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: mountFolder.path) else { return [] }
        let mountComponents = mountPath.split(separator: "/").map(String.init)
        var links: [UnsafeSymlink] = []
        while let inMount = enumerator.nextObject() as? String {
            let linkPath = mountFolder.appendingPathComponent(inMount).path
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: linkPath) else { continue }
            let path = (mountComponents + inMount.split(separator: "/").map(String.init)).joined(separator: "/")
            if destination.hasPrefix("/") {
                links.append(UnsafeSymlink(path: path, reason: .leavesTree))
                continue
            }
            var resolved = mountComponents + inMount.split(separator: "/").dropLast().map(String.init)
            var climbs = false
            for component in destination.split(separator: "/").map(String.init) {
                switch component {
                case ".", "":
                    break
                case "..":
                    if resolved.isEmpty { climbs = true } else { resolved.removeLast() }
                default:
                    resolved.append(component)
                }
                if climbs { break }
            }
            if climbs {
                links.append(UnsafeSymlink(path: path, reason: .leavesTree))
                continue
            }
            let relative = resolved.joined(separator: "/")
            let staged = stagedWordpress.appendingPathComponent(relative).path
            let host = hostWordpress.appendingPathComponent(relative).path
            let exists = fm.fileExists(atPath: staged) || fm.fileExists(atPath: host)
            if !exists {
                links.append(UnsafeSymlink(path: path, reason: .unresolvable))
            }
        }
        return links
    }

    /// Throws `.outputExists` for a directory at `destination`, or for a file
    /// there unless `overwrite` is set.
    private static func refuseExistingOutput(_ destination: URL, overwrite: Bool) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue || !overwrite {
            throw SiteArchiveError.outputExists(destination.path)
        }
    }

    /// `path` with every symlink resolved by `realpath(3)`, or nil when it is
    /// missing, dangling, or loops.
    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Removes the entries of `folder` whose name matches and whose modification
    /// date is more than `staleLeftoverAge` before `now`, ignoring every error.
    private static func removeStaleItems(in folder: URL, now: Date, matching: (String) -> Bool) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        let cutoff = now.addingTimeInterval(-staleLeftoverAge)
        for name in names where matching(name) {
            let item = folder.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: item.path))?[.modificationDate] as? Date
            if let modified, modified < cutoff {
                try? fm.removeItem(at: item)
            }
        }
    }

    /// Runs an archive tool, mapping a launch failure or non-zero exit to `.toolFailed`.
    @discardableResult
    private static func runTool(_ executable: String, args: [String], cwd: URL?) async throws -> CommandResult {
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
        return result
    }

    /// `raw` normalized like `create --domain`, or nil when it is nil or empty.
    /// Throws `.invalidDomain` for a non-empty value that does not normalize.
    private static func normalizedDomain(_ raw: String?) throws -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let normalized = DomainService.normalize(raw) else { throw SiteArchiveError.invalidDomain(raw) }
        return normalized
    }

    /// Bytes available for important data on the volume holding `folder`, or
    /// on its nearest existing ancestor when `folder` does not exist yet.
    private static func availableCapacity(at folder: URL) -> Int64? {
        let fm = FileManager.default
        var candidate = folder.standardizedFileURL
        while !fm.fileExists(atPath: candidate.path), candidate.path != "/" {
            candidate = candidate.deletingLastPathComponent()
        }
        let values = try? candidate.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Puts `site` in the group named `groupName`, matched case-insensitively,
    /// adding the group to `envelope` when none matches. A blank name leaves the site ungrouped.
    /// Returns the id of the added group, or nil when none was added.
    private static func assignGroup(named groupName: String?, to site: inout Site, in envelope: inout StoreEnvelope) -> UUID? {
        guard let groupName, !groupName.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if let existing = envelope.groups.first(where: { $0.name.caseInsensitiveCompare(groupName) == .orderedSame }) {
            site.groupID = existing.id
            return nil
        }
        let group = SiteGroup(name: groupName, sortOrder: (envelope.groups.map(\.sortOrder).max() ?? -1) + 1)
        envelope.groups.append(group)
        site.groupID = group.id
        return group.id
    }

    /// Imports `dump` with `wp db import` from a staging folder inside the
    /// site's docroot, which is removed afterwards. A MySQL `ERROR nnnn` line
    /// in the output fails the import even when wp-cli exits 0.
    private func importDatabase(_ site: Site, dbHost: String, dump: URL) async throws {
        let fm = FileManager.default
        let staging = site.wordpressFolder.appendingPathComponent(".wpc-import", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.moveItem(at: dump, to: staging.appendingPathComponent(SiteArchiveLayout.databaseName))

        let containerPath = "/var/www/html/.wpc-import/\(SiteArchiveLayout.databaseName)"
        let result = try await cli.runCapturing(SiteRecipe.wpDBImportArgs(site, dbHost: dbHost, containerPath: containerPath))
        if let line = DatabaseImportService.sqlError(in: result.stdout + "\n" + result.stderr) {
            throw SiteArchiveError.toolFailed(tool: "wp db import", detail: line)
        }
        guard result.succeeded else {
            let output = result.stderr.isEmpty ? result.stdout : result.stderr
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SiteArchiveError.toolFailed(tool: "wp db import", detail: "exit \(result.exitCode): \(detail)")
        }
    }

    /// Rewrites every url the imported database and wp-config.php carry, plus
    /// the source site's public and local urls, onto `site`'s url.
    private func migrateURLs(_ site: Site, dbHost: String,
                             source: SiteArchiveManifest.Source) async throws -> URLMigrationReport {
        let migrator = EnvURLMigrator(cli: cli)
        let discovery = await migrator.discoverOrigins(instance: site, dbHost: dbHost, wordpressFolder: site.wordpressFolder)
        guard let target = EnvURLMigration.authority(from: site.url.absoluteString) else {
            throw SiteArchiveError.invalidDomain(site.url.absoluteString)
        }
        let origins = EnvURLMigration.staleOrigins(
            candidates: discovery.candidates + [source.url, source.localURL],
            target: target, networkDomain: discovery.networkDomain)
        return try await migrator.migrate(
            instance: site, dbHost: dbHost, wordpressFolder: site.wordpressFolder,
            origins: origins, targetAuthority: target, https: site.url.scheme == "https",
            multisite: EnvURLMigration.isMultisite(networkType: site.networkType, constants: discovery.constants),
            dryRun: false)
    }
}
