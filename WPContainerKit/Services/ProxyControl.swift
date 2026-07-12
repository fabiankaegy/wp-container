import Foundation

/// Pidfile + port-file coordination so the app and `wp-container proxy serve`
/// never double-bind the HTTPS listener (PLAN.md §2f).
///
/// `~/Library/Application Support/WPContainer/proxy.pid` holds the owner pid and
/// `proxy.port` the bound port. `isRunning` treats a live pid (kill -0) as an
/// active owner.
public enum ProxyControl {
    public static var directory: URL {
        StorePersistence.defaultURL.deletingLastPathComponent()
    }
    public static var pidFileURL: URL { directory.appendingPathComponent("proxy.pid") }
    public static var portFileURL: URL { directory.appendingPathComponent("proxy.port") }

    public struct Status: Sendable {
        public let pid: pid_t
        public let port: UInt16?
    }

    /// The current owner, if a live process holds the pidfile.
    public static func current() -> Status? {
        guard let pidStr = try? String(contentsOf: pidFileURL, encoding: .utf8),
              let pid = pid_t(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return nil }
        // kill(pid, 0) == 0 ⇒ the process exists and we can signal it.
        guard kill(pid, 0) == 0 else {
            // Stale pidfile — clean it up.
            try? FileManager.default.removeItem(at: pidFileURL)
            return nil
        }
        let port = (try? String(contentsOf: portFileURL, encoding: .utf8))
            .flatMap { UInt16($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return Status(pid: pid, port: port)
    }

    public static var isRunning: Bool { current() != nil }

    /// Claim ownership by writing this process's pid + the bound port.
    public static func claim(port: UInt16) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try String(getpid()).write(to: pidFileURL, atomically: true, encoding: .utf8)
        try String(port).write(to: portFileURL, atomically: true, encoding: .utf8)
    }

    /// Release ownership (best-effort).
    public static func release() {
        try? FileManager.default.removeItem(at: pidFileURL)
        try? FileManager.default.removeItem(at: portFileURL)
    }
}
