import Foundation

/// File-locked, atomic persistence for `sites.json`, shared by the app and the
/// `wp-container` CLI (both may write concurrently).
///
/// Every read-modify-write is serialized in-process by the actor and
/// cross-process by an exclusive advisory `flock` on a sidecar `.lock` file;
/// writes land atomically (temp file + rename via `Data.write(.atomic)`).
public actor StorePersistence {
    public let fileURL: URL
    private let lockURL: URL
    private let directory: URL

    public init(fileURL: URL? = nil) {
        let target = fileURL ?? StorePersistence.defaultURL
        self.fileURL = target
        self.lockURL = target.appendingPathExtension("lock")
        self.directory = target.deletingLastPathComponent()
    }

    /// `~/Library/Application Support/WPContainer/sites.json`
    public static var defaultURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("WPContainer", isDirectory: true)
            .appendingPathComponent("sites.json")
    }

    public func load() throws -> StoreEnvelope {
        try ensureDirectory()
        return try withLock { try readUnlocked() }
    }

    public func save(_ envelope: StoreEnvelope) throws {
        try ensureDirectory()
        try withLock { try writeUnlocked(envelope) }
    }

    /// Atomic read-modify-write under the cross-process lock.
    @discardableResult
    public func mutate(_ body: @Sendable (inout StoreEnvelope) -> Void) throws -> StoreEnvelope {
        try ensureDirectory()
        return try withLock {
            var envelope = (try? readUnlocked()) ?? StoreEnvelope()
            body(&envelope)
            envelope.version = StoreEnvelope.currentVersion
            try writeUnlocked(envelope)
            return envelope
        }
    }

    /// Allocate a free port and let `reserve` record it into the envelope,
    /// entirely inside the cross-process lock (fixes #3: allocating a port from
    /// a snapshot read earlier, then writing later, lets two concurrent
    /// creators both observe the same "free" port and collide). Because
    /// `PortAllocator.firstFreePort` also bind-tests each candidate, the OS-level
    /// "really free" guarantee is preserved while still holding the `flock`.
    ///
    /// `reserve` MUST record the port in `envelope` (append the new site/env —
    /// or a placeholder that a follow-up `mutate` replaces) so the port is
    /// visible as taken to the next locked reader; its return value is handed
    /// back alongside the updated envelope. Returns nil — with nothing written —
    /// only when no free port exists.
    public func allocatePort<T: Sendable>(
        from base: Int = PortAllocator.basePort,
        reserve: @Sendable (Int, inout StoreEnvelope) -> T
    ) throws -> (port: Int, value: T, envelope: StoreEnvelope)? {
        try ensureDirectory()
        return try withLock {
            var envelope = (try? readUnlocked()) ?? StoreEnvelope()
            let taken = Set(envelope.sites.map(\.port)).union(envelope.envs.map(\.port))
            guard let port = PortAllocator.firstFreePort(from: base, excluding: taken) else { return nil }
            let value = reserve(port, &envelope)
            envelope.version = StoreEnvelope.currentVersion
            try writeUnlocked(envelope)
            return (port, value, envelope)
        }
    }

    // MARK: - Internals

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func readUnlocked() throws -> StoreEnvelope {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return StoreEnvelope() }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return StoreEnvelope() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StoreEnvelope.self, from: data)
    }

    private func writeUnlocked(_ envelope: StoreEnvelope) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Acquire an exclusive advisory lock for the duration of `body`.
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            // Locking unavailable — proceed unlocked rather than deadlock.
            return try body()
        }
        defer { close(fd) } // closing releases the flock
        flock(fd, LOCK_EX)
        return try body()
    }
}
