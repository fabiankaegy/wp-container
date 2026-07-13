import Foundation

/// Pidfile + port-file coordination so the app and `wp-container proxy serve`
/// never double-bind the HTTPS listener (PLAN.md §2f).
///
/// `~/Library/Application Support/WPContainer/proxy.pid` holds the owner pid and
/// `proxy.port` the bound port. Liveness is judged by PROBING THE RECORDED PORT
/// for an accepting listener, not by `kill(pid, 0)` (#4): a dead owner's PID can
/// be reused by an unrelated live process, and trusting it would make every
/// relaunch silently skip starting the proxy — HTTPS dead, UI toggle still on.
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

    /// The current owner, if the recorded port is actually serving.
    ///
    /// A pidfile whose recorded port does not accept connections is stale by
    /// definition — whether the pid is dead, or alive-but-reused by an
    /// unrelated process (#4) — and is cleaned up so the caller starts its own
    /// proxy. The file overrides exist for isolated testing.
    public static func current(pidFile: URL? = nil, portFile: URL? = nil) -> Status? {
        let pidURL = pidFile ?? pidFileURL
        let portURL = portFile ?? portFileURL
        guard let pidStr = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = pid_t(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return nil }
        let port = (try? String(contentsOf: portURL, encoding: .utf8))
            .flatMap { UInt16($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        // Liveness = an accepting listener on the recorded port. No port on
        // record ⇒ nothing to probe ⇒ treat as stale (claim() always writes
        // both files, so a missing port file means a torn/legacy record).
        guard let port, isPortAccepting(port) else {
            try? FileManager.default.removeItem(at: pidURL)
            try? FileManager.default.removeItem(at: portURL)
            return nil
        }
        return Status(pid: pid, port: port)
    }

    public static var isRunning: Bool { current() != nil }

    /// True when something ACCEPTS a TCP connection on 127.0.0.1:`port`.
    /// Non-blocking connect with a short (250ms) timeout — the proxy is local:
    /// a live listener accepts effectively instantly and ECONNREFUSED returns
    /// immediately, so this never noticeably delays launch.
    static func isPortAccepting(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var writeSet = fd_set()
        __darwin_fd_set(fd, &writeSet)
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        guard select(fd + 1, nil, &writeSet, nil, &timeout) > 0 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 else { return false }
        return err == 0
    }

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

    /// Release ownership only if THIS process holds the pidfile (#4) — safe to
    /// call unconditionally at termination: an instance that never claimed
    /// (or lost) the proxy won't delete another owner's record.
    public static func releaseIfOwned() {
        guard let pidStr = try? String(contentsOf: pidFileURL, encoding: .utf8),
              pid_t(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) == getpid() else { return }
        release()
    }
}
