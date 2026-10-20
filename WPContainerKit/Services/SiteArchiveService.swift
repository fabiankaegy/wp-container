import Foundation

/// Exports a site to a portable zip archive and imports one back.
public actor SiteArchiveService {

    // MARK: - Helpers

    /// Folders left out of an export unless the caller overrides the list.
    public static let defaultExcludes: [String] = [".git", ".svn", ".DS_Store", "__MACOSX", "node_modules", "bower_components"]

    /// Working folders of the export and import steps; never archived.
    public static let alwaysExcluded: [String] = [".wpc-export", ".wpc-import"]

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
}
