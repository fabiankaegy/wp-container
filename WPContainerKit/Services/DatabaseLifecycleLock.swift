import Foundation
import OSLog

/// An advisory `flock(2)` lock held on a sidecar lock file, used to make an
/// operation mutually exclusive ACROSS PROCESSES.
///
/// Everything in this tool runs in several processes at once — the app, the
/// headless proxy, every `wp-container` CLI one-shot, the MCP server — and each
/// of them builds its OWN `SiteLifecycle` actor. An actor therefore guarantees
/// nothing between them; only the filesystem is shared. `StorePersistence`
/// already leans on that for `sites.json`; this is the same idiom generalised to
/// a lock that must be HELD across a sequence of `await`s rather than around one
/// synchronous read-modify-write.
///
/// The lock lives on the open file DESCRIPTION, so it is dropped by `release()`,
/// by deallocation, and — crucially — by the kernel when the owning process
/// dies. A crash can never leave a stale lock behind, which is why there is no
/// expiry, heartbeat or pid file here.
public final class FileLock: @unchecked Sendable {
    public enum Mode: Sendable {
        /// Any number of holders at once; blocks only `.exclusive`. Used for
        /// "something is depending on this right now" claims.
        case shared
        /// A single holder, and only while no shared holder exists. Used for
        /// "I am about to take this away" operations.
        case exclusive

        fileprivate var operation: Int32 {
            switch self {
            case .shared: LOCK_SH
            case .exclusive: LOCK_EX
            }
        }
    }

    public let url: URL
    private let mutex = NSLock()
    private var descriptor: Int32

    private init(url: URL, descriptor: Int32) {
        self.url = url
        self.descriptor = descriptor
    }

    /// Drop the lock. IDEMPOTENT on purpose: callers release at the earliest
    /// correct point and keep a `defer { lock.release() }` as the backstop for
    /// every other exit path, so it is normal for this to run twice.
    public func release() {
        mutex.lock()
        defer { mutex.unlock() }
        guard descriptor >= 0 else { return }
        close(descriptor) // closing the descriptor releases the flock
        descriptor = -1
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    // MARK: - Acquisition

    private enum Attempt {
        case acquired(FileLock)
        /// An incompatible lock is held right now — retrying may succeed.
        case contended
        /// The lock file itself could not be opened; retrying will not help.
        case unavailable
    }

    /// One non-blocking attempt. `nil` ⇒ either somebody holds an incompatible
    /// lock or the lock file could not be opened at all.
    public static func tryAcquire(at url: URL, mode: Mode) -> FileLock? {
        if case .acquired(let lock) = attempt(at: url, mode: mode) { return lock }
        return nil
    }

    /// Retry until `timeout` elapses, then give up and return `nil`.
    ///
    /// Deliberately built on a NON-BLOCKING `flock`: a blocking one would
    /// deadlock any process that already holds a shared lock on this file and
    /// then asks for the exclusive one — which is exactly what a stop racing one
    /// of this same process's starts looks like. Polling degrades that to
    /// "returns nil after `timeout`", and each caller applies its own fail-open
    /// or fail-closed policy to that.
    ///
    /// Honours cancellation: a cancelled task stops waiting immediately.
    public static func acquire(at url: URL, mode: Mode,
                               timeout: Duration,
                               pollInterval: Duration = .milliseconds(50)) async -> FileLock? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            switch attempt(at: url, mode: mode) {
            case .acquired(let lock):
                return lock
            case .unavailable:
                return nil
            case .contended:
                guard !Task.isCancelled, ContinuousClock.now < deadline else {
                    log.info("lock: timed out waiting for \(url.lastPathComponent, privacy: .public)")
                    return nil
                }
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    private static func attempt(at url: URL, mode: Mode) -> Attempt {
        var fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        if fd < 0, errno == ENOENT {
            // First use on a fresh install: the Application Support folder may
            // not exist yet (nothing else has written there).
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        }
        guard fd >= 0 else {
            log.error("lock: cannot open \(url.path, privacy: .public) (errno \(errno))")
            return .unavailable
        }
        guard flock(fd, mode.operation | LOCK_NB) == 0 else {
            close(fd)
            return .contended
        }
        return .acquired(FileLock(url: url, descriptor: fd))
    }

    private static let log = Logger(subsystem: "com.fabiankaegy.wpcontainer", category: "lock")
}

/// The cross-process protocol that keeps a shared MariaDB container from being
/// retired out from under a start happening in ANOTHER process (issue #17
/// follow-up).
///
/// One lock file per DB CONTAINER — `wpc-<parent>-db` — not one global lock:
/// the lock is held for the whole of a start (which can include an image pull),
/// and a single global file would make every site's start block every other
/// site's idle retirement for no reason. Keying by container name also lines up
/// exactly with `SiteLifecycle.dbLeases`, whose in-process ref-count this
/// mirrors, and with `stopSharedDatabaseIfUnused`, which retires one container.
///
/// The protocol:
/// * anything that depends on a DB container holds `.shared` for as long as it
///   depends on it (`SiteLifecycle.acquireDatabaseLease`);
/// * anything about to stop one holds `.exclusive` across its re-check AND the
///   `container stop`, so the two are atomic with respect to every other
///   process.
public enum DatabaseLifecycleLock {
    /// `~/Library/Application Support/WPContainer/db-<container>.lock`
    ///
    /// Same folder as `sites.json` and its `.lock` sidecar — the one directory
    /// every surface of the tool already agrees on.
    public static func url(forContainer name: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("WPContainer", isDirectory: true)
            .appendingPathComponent("db-\(sanitize(name)).lock")
    }

    /// How long a DEPENDANT waits for the lock before giving up and proceeding
    /// unprotected. Comfortably longer than the exclusive side ever holds it
    /// (a re-check plus one `container stop`), so this only ever expires when
    /// something is genuinely wedged.
    public static let dependentTimeout: Duration = .seconds(5)

    /// How long a RETIREMENT waits before giving up and leaving the container
    /// running. Short on purpose: a busy lock means somebody is starting
    /// something on this server, and "don't retire it" is the right answer
    /// straight away rather than after a long wait.
    public static let retirementTimeout: Duration = .seconds(3)

    /// Container names are already `wpc-<slug>-db` with a slug that is safe in a
    /// path, but a lock file is never worth a path traversal — belt and braces.
    private static func sanitize(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let cleaned = String(name.map { allowed.contains($0) ? $0 : "-" })
        return cleaned.isEmpty ? "unnamed" : cleaned
    }
}
