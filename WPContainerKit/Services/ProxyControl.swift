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
    /// Which env ports the live proxy actually holds (issue #16 follow-through).
    /// See `EnvPortReport`.
    public static var envPortsFileURL: URL { directory.appendingPathComponent("proxy-env-ports.json") }

    /// Runtime state of every active share, published by the proxy owner.
    public static var sharesFileURL: URL { directory.appendingPathComponent("proxy-shares.json") }

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
    public static func current(pidFile: URL? = nil, portFile: URL? = nil, sharesFile: URL? = nil) -> Status? {
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
            // The env-port report belongs to that dead owner too; a stale one
            // would claim ports nothing is serving.
            // With an overridden pidfile the sibling reports live next to it,
            // so isolated callers never touch the default directory.
            let reportDir = pidFile?.deletingLastPathComponent()
            clearEnvPorts(file: reportDir?.appendingPathComponent("proxy-env-ports.json"))
            clearShares(file: sharesFile ?? reportDir?.appendingPathComponent("proxy-shares.json"))
            return nil
        }
        return Status(pid: pid, port: port)
    }

    public static var isRunning: Bool { current() != nil }

    // MARK: - Env-port ownership report (issue #16 follow-through)

    /// Which `127.0.0.1:<env port>` sockets the live proxy holds, and which it
    /// wanted but could not take.
    ///
    /// Dropping `-p` from env containers turned a loud `container run` failure
    /// ("port already allocated") into a SILENT misroute: if some other process
    /// holds an env's port, that env's URL quietly serves whatever that process
    /// is, and neither its idle clock nor wake-on-request works. An os_log
    /// warning inside the proxy is invisible to the CLI, the MCP payloads and the
    /// app, so the proxy publishes this alongside its pidfile instead.
    ///
    /// Best-effort and advisory ONLY: it is rewritten on every reconcile (~3s) and
    /// removed on a clean stop, but a crashed proxy leaves it behind — so every
    /// consumer MUST gate on `current() != nil` first, which is exactly what
    /// `envPortOwnership(_:)` does.
    public struct EnvPortReport: Sendable, Codable {
        public var ownedPorts: [Int]
        public var conflictedPorts: [Int]
        public init(ownedPorts: [Int], conflictedPorts: [Int]) {
            self.ownedPorts = ownedPorts
            self.conflictedPorts = conflictedPorts
        }
    }

    /// What we can say about one env port right now.
    public enum EnvPortOwnership: Sendable, Equatable {
        /// No proxy is accepting at all — nothing serves any env URL.
        case noProxy
        /// A live proxy holds this port: the URL works, idle-stop and wake apply.
        case owned
        /// A live proxy wanted this port and could not take it — a pre-upgrade env
        /// container still publishing it, or a foreign process squatting on it.
        case conflicted
        /// A proxy is up but hasn't reported on this port yet (a brand-new env
        /// between creation and the next reconcile). Deliberately NOT a warning.
        case unknown
    }

    /// Publish the report (best-effort; a failure here must never affect serving).
    public static func writeEnvPorts(owned: [UInt16], conflicted: [UInt16]) {
        let report = EnvPortReport(ownedPorts: owned.map(Int.init).sorted(),
                                   conflictedPorts: conflicted.map(Int.init).sorted())
        guard let data = try? JSONEncoder().encode(report) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: envPortsFileURL, options: .atomic)
    }

    public static func clearEnvPorts(file: URL? = nil) {
        try? FileManager.default.removeItem(at: file ?? envPortsFileURL)
    }

    /// The report as written by the live proxy, or nil when there is none.
    public static func envPorts() -> EnvPortReport? {
        guard let data = try? Data(contentsOf: envPortsFileURL) else { return nil }
        return try? JSONDecoder().decode(EnvPortReport.self, from: data)
    }

    // MARK: - Share status report

    /// Publish the share statuses (best-effort; a failure here must never affect serving).
    public static func writeShares(_ statuses: [ShareStatus], file: URL? = nil) {
        let url = file ?? sharesFileURL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(statuses) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The share statuses as written by the live proxy, or empty when there are none.
    /// Consumers must gate on `current() != nil`, as a crashed proxy leaves the file behind.
    public static func shares(file: URL? = nil) -> [ShareStatus] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: file ?? sharesFileURL),
              let statuses = try? decoder.decode([ShareStatus].self, from: data) else { return [] }
        return statuses
    }

    public static func clearShares(file: URL? = nil) {
        try? FileManager.default.removeItem(at: file ?? sharesFileURL)
    }

    /// Resolve one env port to a statement we are willing to make out loud.
    public static func envPortOwnership(_ port: Int) -> EnvPortOwnership {
        guard current() != nil else { return .noProxy }
        guard let report = envPorts() else { return .unknown }
        if report.ownedPorts.contains(port) { return .owned }
        if report.conflictedPorts.contains(port) { return .conflicted }
        return .unknown
    }

    /// Why a worktree environment needs a live proxy, phrased for a warnings
    /// channel (issue #16 follow-through).
    ///
    /// An env's container publishes no host port of its own — the proxy binds
    /// `127.0.0.1:<port>` and relays to the container — so with nothing listening
    /// the env runs perfectly but its URL refuses connections. wp-cli and MCP
    /// workflows are unaffected, which is exactly why this is a warning and not an
    /// error: the start itself succeeded.
    public static let envNeedsProxyWarning =
        "Environment URLs are served by the WP Container reverse proxy, and none is "
        + "running — http://127.0.0.1:<port> will refuse connections until one is. "
        + "Launch WPContainer.app or run `wp-container proxy serve`. "
        + "(wp-cli and MCP work either way.)"

    /// A proxy IS running but does not hold this env's port — the failure mode
    /// that would otherwise be silent (see `EnvPortReport`).
    public static func envPortConflictWarning(port: Int) -> String {
        "The reverse proxy is running but does not own 127.0.0.1:\(port), so this "
        + "environment's URL and its idle-stop/wake are NOT being served. Either an "
        + "environment container started by an older build still publishes that port "
        + "(stop and start it once), or another process is holding it "
        + "(`lsof -nP -iTCP:\(port) -sTCP:LISTEN`). Run `wp-container https status` "
        + "for the proxy's own view."
    }

    /// The warning to surface for an env whose URL was just handed to somebody,
    /// or nil when there is nothing to say.
    ///
    /// Pass the env's `port` to get the precise answer. Without it this can only
    /// answer "is a proxy up at all", which is a FALSE NEGATIVE during the
    /// pre-upgrade transition and for a squatted port. `.unknown` stays silent on
    /// purpose: a port the reconcile hasn't reached yet is the happy path a few
    /// seconds early, and crying wolf there is worse than a brief silence.
    public static func envProxyWarning(port: Int? = nil) -> String? {
        guard let port else { return current() == nil ? envNeedsProxyWarning : nil }
        switch envPortOwnership(port) {
        case .noProxy:              return envNeedsProxyWarning
        case .conflicted:           return envPortConflictWarning(port: port)
        case .owned, .unknown:      return nil
        }
    }

    /// True when something ACCEPTS a TCP connection on 127.0.0.1:`port`.
    /// Non-blocking connect with a short (250ms) timeout — the proxy is local:
    /// a live listener accepts effectively instantly and ECONNREFUSED returns
    /// immediately, so this never noticeably delays launch.
    public static func isPortAccepting(_ port: UInt16) -> Bool {
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
        // The env-port report is part of this owner's record; leaving it would
        // have consumers believing ports are served after the proxy is gone.
        clearEnvPorts()
        clearShares()
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
