import Foundation

/// Filesystem helpers for site / env folder layout.
public enum SiteFolders {
    /// The built-in default root for new sites: `~/WP Container Sites`. Used as
    /// the fallback when no user override is set.
    public static var builtInDefaultSitesRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("WP Container Sites", isDirectory: true)
    }

    /// Default root for new sites: the user's override from Settings (PLAN.md
    /// §2l, `UserDefaults` key `defaultSitesRoot`) when set, else the built-in
    /// `~/WP Container Sites`. Both the app's Add Site guide and the CLI honor it.
    public static var defaultSitesRoot: URL {
        if let override = UserDefaults.standard.string(forKey: "defaultSitesRoot"),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return builtInDefaultSitesRoot
    }

    /// Ensure `wordpress/` and `database/` exist for a runnable instance.
    public static func ensure(for inst: any RunnableInstance) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: inst.wordpressFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: inst.databaseFolder, withIntermediateDirectories: true)
    }

    /// APFS copy-on-write clone (`cp -Rc`), falling back to a regular copy if
    /// CoW is unavailable. Destination's parent is created if needed.
    public static func cloneCopyOnWrite(from source: URL, to destination: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Remove an existing destination so `cp` semantics are predictable.
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        let result = try await ProcessRunner.run(
            executable: "/bin/cp",
            args: ["-Rc", source.path, destination.path]
        )
        if !result.succeeded {
            // Fallback: plain deep copy.
            if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
            try fm.copyItem(at: source, to: destination)
        }
    }
}
