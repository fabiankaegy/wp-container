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

    /// Like `mutate`, but `body` reports whether it actually changed anything and
    /// the file is only rewritten when it did.
    ///
    /// Exists for the throttled activity stamp below: an unconditional `mutate`
    /// would rewrite `sites.json` on every wp-cli call and every MCP tool call,
    /// and every one of those writes wakes the app's `DispatchSource` watcher and
    /// makes it reload. A no-op write is not free here.
    @discardableResult
    public func mutateIfChanged(_ body: @Sendable (inout StoreEnvelope) -> Bool) throws -> StoreEnvelope {
        try ensureDirectory()
        return try withLock {
            var envelope = (try? readUnlocked()) ?? StoreEnvelope()
            guard body(&envelope) else { return envelope }
            envelope.version = StoreEnvelope.currentVersion
            try writeUnlocked(envelope)
            return envelope
        }
    }

    /// Stamp `lastActivityAt` on the site or env with this id (issue #16),
    /// skipping the write when the existing stamp is already newer than
    /// `minimumInterval`.
    ///
    /// Every surface that represents deliberate use calls this — wp-cli, MCP tool
    /// dispatch, magic-login, explicit starts — which is what lets the idle sweep
    /// see an agent that drives an environment without ever going through the
    /// proxy. The throttle keeps a chatty agent from turning that into a
    /// write-per-call; one minute of granularity is nothing against timeouts
    /// measured in minutes.
    ///
    /// Deliberately best-effort and non-throwing: failing to record activity must
    /// never fail the operation the user actually asked for. The cost of a lost
    /// stamp is bounded — the worst case is an instance being stopped a bit early
    /// and woken again on the next request.
    public func recordActivity(instanceID: UUID, now: Date = Date(),
                               minimumInterval: TimeInterval = 60) {
        _ = try? mutateIfChanged { envelope in
            func isFresh(_ stamp: Date?) -> Bool {
                guard let stamp else { return false }
                // `> now` guards a clock that jumped backwards: a stamp from the
                // future would otherwise suppress every write forever.
                return stamp <= now && now.timeIntervalSince(stamp) < minimumInterval
            }
            if let i = envelope.sites.firstIndex(where: { $0.id == instanceID }) {
                guard !isFresh(envelope.sites[i].lastActivityAt) else { return false }
                envelope.sites[i].lastActivityAt = now
                return true
            }
            if let i = envelope.envs.firstIndex(where: { $0.id == instanceID }) {
                guard !isFresh(envelope.envs[i].lastActivityAt) else { return false }
                envelope.envs[i].lastActivityAt = now
                return true
            }
            return false
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
            // Include sidecar host ports (Mailpit's web UI, issue #10) so one is
            // never handed out again as a site/env port or another sidecar's.
            let taken = PortAllocator.reservedPorts(sites: envelope.sites, envs: envelope.envs)
            guard let port = PortAllocator.firstFreePort(from: base, excluding: taken) else { return nil }
            let value = reserve(port, &envelope)
            envelope.version = StoreEnvelope.currentVersion
            try writeUnlocked(envelope)
            return (port, value, envelope)
        }
    }

    /// Turn `addon` on or off for a site and sync its PHP handler. The first
    /// enable of an addon that publishes a host port reserves the port in the
    /// same locked write; the port stays reserved after a disable. Returns the
    /// updated site and store, or nil when the site is gone or no port is free.
    public func setSidecar(_ addon: any SidecarAddon, enabled: Bool,
                           siteID: UUID) throws -> (site: Site, envelope: StoreEnvelope)? {
        guard let site = try load().sites.first(where: { $0.id == siteID }) else { return nil }
        let envelope: StoreEnvelope
        if enabled, addon.publishesHostPort, addon.hostPort(of: site) == nil {
            guard let result = try allocatePort(reserve: { port, env -> Bool in
                guard let i = env.sites.firstIndex(where: { $0.id == siteID }) else { return false }
                addon.setHostPort(port, on: &env.sites[i])
                addon.setEnabled(true, on: &env.sites[i])
                return true
            }), result.value else { return nil }
            envelope = result.envelope
        } else {
            envelope = try mutate { env in
                if let i = env.sites.firstIndex(where: { $0.id == siteID }) { addon.setEnabled(enabled, on: &env.sites[i]) }
            }
        }
        guard let updated = envelope.sites.first(where: { $0.id == siteID }) else { return nil }
        if let handler = addon.handler {
            if enabled {
                try handler.write(phpConfFolder: updated.phpConfFolder)
            } else {
                handler.remove(phpConfFolder: updated.phpConfFolder)
            }
        }
        return (updated, envelope)
    }

    // MARK: - Sharing

    /// Turn off the instance's share and its `--no-auth`, keeping its credentials,
    /// hostname and exceptions. Writes nothing when the share is already inactive or
    /// the instance is gone.
    public func endShare(instanceID: UUID) throws {
        try mutateIfChanged { envelope in
            if let i = envelope.sites.firstIndex(where: { $0.id == instanceID }) {
                return Self.endShare(&envelope.sites[i].share)
            }
            if let i = envelope.envs.firstIndex(where: { $0.id == instanceID }) {
                return Self.endShare(&envelope.envs[i].share)
            }
            return false
        }
    }

    private static func endShare(_ share: inout ShareSettings?) -> Bool {
        guard var settings = share, settings.active || settings.authDisabled else { return false }
        settings.active = false
        settings.authDisabled = false
        share = settings
        return true
    }

    // MARK: - Settling (see `EnvSettlement`)

    /// Mark an env settled at `now`, which releases its ports to the allocator
    /// and drops it from the proxy's routes. Stopping its containers is the
    /// caller's job. Returns the updated env, or nil when it is gone.
    public func settleEnv(id: UUID, now: Date = Date()) throws -> WorktreeEnv? {
        let envelope = try mutateIfChanged { envelope in
            guard let i = envelope.envs.firstIndex(where: { $0.id == id }), !envelope.envs[i].isSettled else { return false }
            envelope.envs[i].settledAt = now
            return true
        }
        return envelope.envs.first { $0.id == id }
    }

    /// Clear an env's settled mark and give its ports back: the ones it had when
    /// they are still free, otherwise the next free ones, all in one locked
    /// write so a concurrent creator can't take them. Returns the updated env
    /// and whether its main port changed (an env still on its loopback URL then
    /// needs its URLs migrated), or nil when it is gone or no port is free.
    public func restoreEnv(id: UUID) throws -> (env: WorktreeEnv, portChanged: Bool)? {
        try ensureDirectory()
        return try withLock {
            var envelope = (try? readUnlocked()) ?? StoreEnvelope()
            guard let i = envelope.envs.firstIndex(where: { $0.id == id }) else { return nil }
            var env = envelope.envs[i]
            guard env.isSettled else { return (env, false) }
            // The env itself is settled, so none of its ports are in this set.
            var taken = PortAllocator.reservedPorts(sites: envelope.sites, envs: envelope.envs)
            func claim(_ previous: Int?, from base: Int) -> Int? {
                if let previous, !taken.contains(previous), PortAllocator.isPortFree(previous) { return previous }
                return PortAllocator.firstFreePort(from: base, excluding: taken)
            }
            guard let port = claim(env.port, from: PortAllocator.basePort) else { return nil }
            taken.insert(port)
            let portChanged = port != env.port
            env.port = port
            for addon in SidecarAddons.enabled(for: env) where addon.publishesHostPort {
                guard let hostPort = claim(addon.hostPort(of: env), from: port + 1) else { return nil }
                addon.setHostPort(hostPort, on: &env)
                taken.insert(hostPort)
            }
            env.settledAt = nil
            envelope.envs[i] = env
            envelope.version = StoreEnvelope.currentVersion
            try writeUnlocked(envelope)
            return (env, portChanged)
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
        // The store holds share passwords, so only the user may read it.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
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
