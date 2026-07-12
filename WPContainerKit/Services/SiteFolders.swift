import Foundation

/// Filesystem helpers for site / env folder layout.
public enum SiteFolders {
    /// Default root for new sites: `~/WP Container Sites`.
    public static var defaultSitesRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("WP Container Sites", isDirectory: true)
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
