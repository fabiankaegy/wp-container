import Foundation

/// Builds, validates, and orders the host folders bind-mounted into a site's
/// WordPress tree (`Site.mounts`).
public enum SiteMounts {
    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        /// The host folder doesn't exist or isn't a folder.
        case hostFolderMissing(String)
        /// The path contains `:`, leaves the WordPress folder, or is the
        /// WordPress folder itself.
        case invalidPath(String)
        /// Another mount already uses this container path.
        case alreadyMounted(String)
        /// No mount uses this container path.
        case notMounted(String)

        /// Machine-readable error code for CLI JSON output.
        public var code: String {
            switch self {
            case .hostFolderMissing: return "host_folder_missing"
            case .invalidPath: return "invalid_mount_path"
            case .alreadyMounted: return "mount_exists"
            case .notMounted: return "mount_not_found"
            }
        }

        public var description: String {
            switch self {
            case .hostFolderMissing(let path): return "\(path) doesn't exist or isn't a folder."
            case .invalidPath(let path): return "\(path) must be a path inside the WordPress folder, without \":\"."
            case .alreadyMounted(let path): return "\(path) is already mounted."
            case .notMounted(let path): return "Nothing is mounted at \(path)."
            }
        }
    }

    /// The absolute container path for `raw`, which is either relative to the
    /// WordPress folder (`wp-content/plugins/example`) or absolute under it
    /// (`/var/www/html/wp-content/plugins/example`).
    public static func containerPath(_ raw: String) throws -> String {
        let root = SiteRecipe.wordpressContainerPath
        var relative = raw
        if raw.hasPrefix("/") {
            guard raw.hasPrefix(root + "/") else { throw Failure.invalidPath(raw) }
            relative = String(raw.dropFirst(root.count + 1))
        }
        let parts = relative.split(separator: "/").filter { $0 != "." }
        guard !parts.isEmpty, !parts.contains(".."), !raw.contains(":") else { throw Failure.invalidPath(raw) }
        return root + "/" + parts.joined(separator: "/")
    }

    /// A mount of the existing host folder `hostPath` at `containerPath`. A
    /// `~` is expanded and a relative `hostPath` resolves against `base`.
    public static func mount(hostPath: String, containerPath: String, relativeTo base: URL) throws -> Mount {
        let expanded = (hostPath as NSString).expandingTildeInPath
        let url = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appendingPathComponent(expanded))
            .standardizedFileURL
        // A `:` would split the `-v host:container` mount argument.
        guard !url.path.contains(":") else { throw Failure.invalidPath(hostPath) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.hostFolderMissing(hostPath)
        }
        return Mount(hostPath: url.path, containerPath: try self.containerPath(containerPath))
    }

    /// Parses `<host-folder>:<container-path>`, the form `create --mount` takes.
    public static func parse(_ spec: String, relativeTo base: URL) throws -> Mount {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw Failure.invalidPath(spec) }
        return try mount(hostPath: String(parts[0]), containerPath: String(parts[1]), relativeTo: base)
    }

    /// `mounts` plus `mount`, ordered for mounting.
    public static func adding(_ mount: Mount, to mounts: [Mount]) throws -> [Mount] {
        guard !mounts.contains(where: { $0.containerPath == mount.containerPath }) else {
            throw Failure.alreadyMounted(mount.containerPath)
        }
        var warnings: [String] = []
        return ordered(mounts + [mount], warnings: &warnings)
    }

    /// `mounts` without the one at `containerPath` (relative or absolute).
    public static func removing(containerPath raw: String, from mounts: [Mount]) throws -> [Mount] {
        let path = try containerPath(raw)
        guard mounts.contains(where: { $0.containerPath == path }) else { throw Failure.notMounted(path) }
        return mounts.filter { $0.containerPath != path }
    }

    /// Removes the folder the site start created on the host for the mount at
    /// `containerPath`, when it is still empty.
    public static func removeEmptyMountpoint(_ containerPath: String, in wordpressFolder: URL) {
        let root = SiteRecipe.wordpressContainerPath + "/"
        guard containerPath.hasPrefix(root) else { return }
        let folder = wordpressFolder.appendingPathComponent(String(containerPath.dropFirst(root.count)), isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [""]
        if contents.isEmpty { try? FileManager.default.removeItem(at: folder) }
    }

    /// One mount per destination (the first wins), shallowest destination
    /// first, so a folder mounted inside another mount lands on top of it.
    static func ordered(_ mounts: [Mount], warnings: inout [String]) -> [Mount] {
        var seen = Set<String>()
        var unique: [Mount] = []
        for mount in mounts {
            guard seen.insert(mount.containerPath).inserted else {
                warnings.append("\(mount.hostPath) maps to \(mount.containerPath), which is already mounted; skipped.")
                continue
            }
            unique.append(mount)
        }
        return unique.enumerated()
            .sorted { lhs, rhs in
                let lhsDepth = lhs.element.containerPath.split(separator: "/").count
                let rhsDepth = rhs.element.containerPath.split(separator: "/").count
                return lhsDepth == rhsDepth ? lhs.offset < rhs.offset : lhsDepth < rhsDepth
            }
            .map(\.element)
    }
}
