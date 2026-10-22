import Darwin
import Foundation
import os

/// The proxy surface a share needs: one loopback listener per shared instance.
public protocol ShareListenerHost: AnyObject, Sendable {
    func openShareListener(instanceID: UUID, route: HTTPSProxy.Route, config: ShareGateConfig) async throws -> UInt16
    func updateShareConfig(instanceID: UUID, config: ShareGateConfig)
    func closeShareListener(instanceID: UUID)
    /// Whether the instance's share listener is still bound; a listener that fails is dropped.
    func isShareListenerOpen(instanceID: UUID) -> Bool
}

/// A running tunnel provider process.
public protocol ShareProcessHandle: AnyObject, Sendable {
    var pid: Int32 { get }
    /// Called once when the process exits, with its status and the last stderr lines.
    var onExit: (@Sendable (_ status: Int32, _ stderrTail: [String]) -> Void)? { get set }
    /// Stops the process and returns once it has exited.
    func terminate() async
}

/// Starts a provider process and returns its public URL once it is serving.
public protocol ShareProcessLauncher: Sendable {
    /// `launched` is called with the pid as soon as the process runs, before it is ready.
    func launch(spec: ShareLaunchSpec, provider: any ShareProvider,
                launched: @escaping @Sendable (Int32) -> Void) async throws -> (url: String, process: any ShareProcessHandle)
}

/// Launches providers as `ShareProcess`es.
public struct DefaultShareProcessLauncher: ShareProcessLauncher {
    public let readyTimeout: Duration

    public init(readyTimeout: Duration = .seconds(30)) {
        self.readyTimeout = readyTimeout
    }

    public func launch(spec: ShareLaunchSpec, provider: any ShareProvider,
                       launched: @escaping @Sendable (Int32) -> Void) async throws -> (url: String, process: any ShareProcessHandle) {
        let process = ShareProcess(spec: spec, provider: provider)
        let handle = LaunchedShareProcess(process)
        let url = try await process.start(readyTimeout: readyTimeout, launched: launched)
        return (url, handle)
    }
}

/// Wraps a `ShareProcess` and keeps its exit until `onExit` is set, so an exit that
/// happens between start and the caller installing its handler is still reported.
final class LaunchedShareProcess: ShareProcessHandle, @unchecked Sendable {
    private let process: ShareProcess
    private let lock = NSLock()
    private var handler: (@Sendable (Int32, [String]) -> Void)?
    private var exitResult: (status: Int32, stderrTail: [String])?
    private var delivered = false

    init(_ process: ShareProcess) {
        self.process = process
        process.onExit = { [weak self] status, tail in self?.recordExit(status: status, stderrTail: tail) }
    }

    var pid: Int32 { process.pid }

    /// Whether the exit has been recorded, whether or not a handler has received it.
    var hasRecordedExit: Bool { lock.withLock { exitResult != nil } }

    var onExit: (@Sendable (Int32, [String]) -> Void)? {
        get { lock.withLock { handler } }
        set {
            let pending: (Int32, [String])? = lock.withLock {
                handler = newValue
                guard newValue != nil, !delivered, let exitResult else { return nil }
                delivered = true
                return (exitResult.status, exitResult.stderrTail)
            }
            if let pending, let newValue { newValue(pending.0, pending.1) }
        }
    }

    func terminate() async {
        await process.terminate()
    }

    private func recordExit(status: Int32, stderrTail: [String]) {
        let current: (@Sendable (Int32, [String]) -> Void)? = lock.withLock {
            exitResult = (status, stderrTail)
            guard let handler, !delivered else { return nil }
            delivered = true
            return handler
        }
        current?(status, stderrTail)
    }
}

/// When a process started, as the kernel reports it.
struct ProcessStartTime: Codable, Sendable, Equatable {
    let seconds: UInt64
    let microseconds: UInt64
}

/// A provider process this proxy host started, recorded so the next host can stop it
/// after a crash.
struct SharePIDRecord: Codable, Sendable, Equatable {
    let pid: Int32
    /// The process's executable path and start time when it was recorded. A process is
    /// signalled only while both still match, so a reused pid is left alone. A record
    /// without a start time matches only a process whose parent is launchd (pid 1).
    let executable: String
    let startTime: ProcessStartTime?
    let instanceID: UUID
}

/// The provider processes this proxy host runs, written to the pid file on every change.
/// A provider is recorded from its launch callback, on whatever thread launched it, so
/// a crash while it starts up still leaves it in the file.
final class SharePIDFile: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.fabiankaegy.wpcontainer", category: "share")

    let file: URL
    private let lock = NSLock()
    private var records: [Int32: SharePIDRecord] = [:]

    init(file: URL) {
        self.file = file
    }

    func remember(_ pid: Int32, executable: String, instanceID: UUID) {
        lock.withLock {
            records[pid] = SharePIDRecord(pid: pid, executable: executable,
                                          startTime: ShareCoordinator.startTime(of: pid), instanceID: instanceID)
            writeLocked()
        }
    }

    func forget(_ pid: Int32) {
        lock.withLock {
            let removed = records.removeValue(forKey: pid)
            guard removed != nil else { return }
            writeLocked()
        }
    }

    /// Forgets every provider of the instance.
    func forget(instanceID: UUID) {
        lock.withLock {
            let pids = records.values.filter { $0.instanceID == instanceID }.map(\.pid)
            guard !pids.isEmpty else { return }
            for pid in pids { records.removeValue(forKey: pid) }
            writeLocked()
        }
    }

    func contains(_ pid: Int32) -> Bool {
        lock.withLock { records[pid] != nil }
    }

    /// The records in the file, which a previous proxy host may have written.
    func recorded() -> [SharePIDRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([SharePIDRecord].self, from: data)) ?? []
    }

    /// Replaces the file with this host's records.
    func write() {
        lock.withLock { writeLocked() }
    }

    private func writeLocked() {
        let sorted = records.values.sorted { $0.pid < $1.pid }
        do {
            let data = try JSONEncoder().encode(sorted)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            Self.log.error("share: could not write \(self.file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Makes the running shares match the desired state in the store.
///
/// CLI, MCP and app write `share.active` and the share settings; the proxy host calls
/// `reconcile` on every refresh tick. For each active share of a running instance the
/// coordinator opens a share listener, starts the provider, and publishes the result in
/// the status file. Starting a share runs in a child task, so a slow provider never
/// holds up the proxy's tick or other shares; the status reads `starting` meanwhile.
///
/// Reconcile, `stopAll` and `reapOrphans` run one at a time in call order. A share that
/// fails to start, loses a hostname clash or whose provider exits ends for good: it is
/// reported `down` and its desired state (with its `--no-auth`) is cleared in the store,
/// so no later proxy host reopens it. The `down` status stays published with its request
/// id until the share is requested again or the instance is deleted. The coordinator is
/// the only writer of the Cloudflare tunnel registry.
public actor ShareCoordinator {
    /// What a share should look like, derived from the store.
    private struct Desired: Equatable {
        /// The fields that need a new provider process when they change.
        struct LaunchKey: Equatable {
            var provider: String
            var hostname: String?
            var slug: String
        }

        var launchKey: LaunchKey
        var username: String
        var password: String
        var allow: [ShareException]
        var authDisabled: Bool
        var upstreamHost: String
        var localOrigins: [String]
        /// A new request retries a share that is down.
        var requestID: UUID?

        var provider: String { launchKey.provider }
        var hostname: String? { launchKey.hostname }
        var slug: String { launchKey.slug }
    }

    private enum Phase {
        case starting, live, down
        /// Being torn down; never published, and no new share starts for the instance
        /// until its resources are released.
        case stopping
    }

    /// One share as this coordinator runs it.
    private struct Runtime {
        let attempt: Int
        var instance: any RunnableInstance
        var desired: Desired
        var phase: Phase
        var task: Task<Void, Never>?
        var listenerPort: UInt16?
        var handle: (any ShareProcessHandle)?
        var executable: String?
        var url: String?
        /// The public hostname this share holds: the fixed one, or the provider's.
        var hostname: String?
        var temporary = false
        var tunnelName: String?
        var error: String?
        var warnings: [String] = []
        var updatedAt = Date()
    }

    /// Public origin given to a share listener until the provider reports its URL.
    private static let placeholderOrigin = "https://share.invalid"
    private static let log = Logger(subsystem: "com.fabiankaegy.wpcontainer", category: "share")

    private weak var host: (any ShareListenerHost)?
    private let persistence: StorePersistence
    private let launcher: any ShareProcessLauncher
    private let providers: @Sendable (String) throws -> any ShareProvider
    private let statusFile: URL?
    private let pids: SharePIDFile
    private let makeTunnels: @Sendable () -> CloudflaredTunnels?

    private var runtimes: [UUID: Runtime] = [:]
    private var nextAttempt = 0
    private var lastPublished: [ShareStatus]?
    private var lastOperation: Task<Void, Never>?
    private var lastRegistryOperation: Task<Void, Never>?
    private var cleanupTasks: [String: Task<Void, Never>] = [:]
    /// Tunnel records whose cleanup failed; retried by the next proxy host.
    private var failedCleanups: [CloudflareTunnelRecord] = []
    private var halted = false
    private var hasReaped = false
    /// Consecutive container listings that omitted an instance with a share starting
    /// or live.
    private var missedListings: [UUID: Int] = [:]

    public init(
        host: any ShareListenerHost,
        persistence: StorePersistence,
        launcher: any ShareProcessLauncher = DefaultShareProcessLauncher(),
        providers: @escaping @Sendable (String) throws -> any ShareProvider = { try ShareProviders.resolve($0) },
        statusFile: URL? = nil,
        pidsFile: URL? = nil,
        tunnels: (@Sendable () -> CloudflaredTunnels?)? = nil
    ) {
        self.host = host
        self.persistence = persistence
        self.launcher = launcher
        self.providers = providers
        self.statusFile = statusFile
        self.pids = SharePIDFile(file: pidsFile ?? ProxyControl.directory.appendingPathComponent("share-pids.json"))
        self.makeTunnels = tunnels ?? {
            ShareProviders.findExecutable("cloudflared", in: ShareProviders.defaultSearchPath)
                .map { CloudflaredTunnels(executable: $0) }
        }
    }

    // MARK: - Public

    /// Brings shares in line with `envelope`. `running` holds the container slugs of
    /// running instances; `routes` is the proxy's current routing table.
    public func reconcile(envelope: StoreEnvelope, routes: [String: HTTPSProxy.Route], running: Set<String>) async {
        await runSerially { await self.performReconcile(envelope: envelope, routes: routes, running: running) }
    }

    /// Stops every provider and listener and withdraws the status file. Desired state is
    /// kept, so the next proxy host reopens the shares. Reconcile does nothing afterwards
    /// until `reapOrphans` runs again.
    public func stopAll() async {
        await runSerially { await self.performStopAll() }
    }

    /// Stops provider processes a previous proxy host left running, and every process
    /// they started, found in the pid file and matched by executable path and start
    /// time. Runs once per coordinator; every call also re-enables reconcile after
    /// `stopAll`.
    public func reapOrphans() async {
        await runSerially { await self.performReap() }
    }

    /// When a running process started, or nil when there is none.
    static func startTime(of pid: Int32) -> ProcessStartTime? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let length = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard length == size else { return nil }
        return ProcessStartTime(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    /// The parent pid of a running process, or nil when there is none.
    static func parentPID(of pid: Int32) -> Int32? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let length = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard length == size else { return nil }
        return Int32(bitPattern: info.pbi_ppid)
    }

    /// The executable path of a running process, or nil when there is none.
    static func executablePath(of pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// Waits for every share start and tunnel cleanup in flight.
    func waitUntilIdle() async {
        var awaited = Set<Task<Void, Never>>()
        while true {
            let pending = (runtimes.values.compactMap(\.task) + Array(cleanupTasks.values)).filter { !awaited.contains($0) }
            guard !pending.isEmpty else { return }
            for task in pending {
                await task.value
                awaited.insert(task)
            }
        }
    }

    // MARK: - Reconcile

    private func runSerially(_ body: @escaping @Sendable () async -> Void) async {
        let previous = lastOperation
        let task = Task {
            await previous?.value
            await body()
        }
        lastOperation = task
        await task.value
    }

    private func performReconcile(envelope: StoreEnvelope, routes: [String: HTTPSProxy.Route], running: Set<String>) async {
        guard !halted else { return }
        let instances: [any RunnableInstance] = envelope.sites.map { $0 } + envelope.envs.map { $0 }
        cleanUpTunnels(instances: instances)

        // The request each ended share answered; a newer request is left alone.
        var ended: [UUID: UUID?] = [:]
        for instance in instances {
            let id = instance.instanceID
            guard let share = instance.share, share.active else {
                missedListings[id] = nil
                await dropInactive(id, settings: instance.share)
                continue
            }
            let desired = Self.desired(for: instance, share: share, envelope: envelope)
            guard running.contains(instance.containerSlug) else {
                // One listing can omit an instance that still runs, so a share starting
                // or live ends only after two listings in a row miss its instance.
                let misses = (missedListings[id] ?? 0) + 1
                let phase = runtimes[id]?.phase
                if misses < 2 && (phase == .live || phase == .starting) {
                    missedListings[id] = misses
                    continue
                }
                missedListings[id] = nil
                // A request this coordinator has not answered yet gets a `down` status, so
                // the client waiting on it learns why; an answered share just ends.
                if let runtime = runtimes[id], runtime.phase == .live, runtime.desired.requestID == share.requestID {
                    ended[id] = share.requestID
                    await tearDown(id)
                } else if await refuse(instance, desired: desired, share: share, error: .instanceNotRunning) {
                    ended[id] = share.requestID
                }
                continue
            }
            missedListings[id] = nil
            if instance.networkType.isSubdomain {
                if await refuse(instance, desired: desired, share: share, error: .subdomainMultisite) {
                    ended[id] = share.requestID
                }
                continue
            }
            if await reconcileActive(instance, desired: desired, routes: routes) {
                ended[id] = share.requestID
            }
        }

        let known = Set(instances.map(\.instanceID))
        for id in Array(runtimes.keys) where !known.contains(id) {
            await tearDown(id)
        }
        for id in Array(missedListings.keys) where !known.contains(id) {
            missedListings[id] = nil
        }
        // Published first, so a client that sees its share cleared also finds the reason.
        publish()
        if !ended.isEmpty { await clearDesired(ended) }
    }

    /// Returns true when the share has ended and its desired state should be cleared.
    private func reconcileActive(_ instance: any RunnableInstance, desired: Desired,
                                 routes: [String: HTTPSProxy.Route]) async -> Bool {
        let id = instance.instanceID
        if let current = runtimes[id] {
            switch current.phase {
            case .stopping:
                return false
            case .starting:
                if current.desired.launchKey != desired.launchKey {
                    await tearDown(id)
                } else {
                    runtimes[id]?.desired = desired
                    runtimes[id]?.instance = instance
                }
                return false
            case .live:
                let listenerOpen = host?.isShareListenerOpen(instanceID: id) ?? false
                if current.desired.launchKey == desired.launchKey && listenerOpen {
                    if current.desired != desired { applyGateChange(instance, desired: desired) }
                    return false
                }
                await tearDown(id)
            case .down:
                // An ended share whose store entry is still active (its clear failed or
                // has not landed yet) stays down until a new request arrives.
                if current.desired.requestID == desired.requestID { return true }
                await tearDown(id)
            }
        }
        return start(instance, desired: desired, routes: routes)
    }

    /// Settings that only affect the gate or the PHP origin map are applied to the live
    /// listener without restarting the provider.
    private func applyGateChange(_ instance: any RunnableInstance, desired: Desired) {
        let id = instance.instanceID
        guard var runtime = runtimes[id], let url = runtime.url else { return }
        runtime.desired = desired
        runtime.instance = instance
        runtime.updatedAt = Date()
        host?.updateShareConfig(instanceID: id, config: Self.gateConfig(desired, publicOrigin: url))
        do {
            try SharePHPService.activate(for: instance, publicOrigin: url)
        } catch {
            Self.log.error("share: could not update the PHP origin file for \(desired.slug, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        runtimes[id] = runtime
    }

    /// Records a new `starting` share and launches it in a child task. Returns true when
    /// the share ended at once: no proxy route, an unknown provider, or a hostname clash.
    private func start(_ instance: any RunnableInstance, desired: Desired, routes: [String: HTTPSProxy.Route]) -> Bool {
        let id = instance.instanceID
        guard runtimes[id] == nil else { return false }
        // A share being torn down still holds its hostname until it is released.
        if let hostname = desired.hostname,
           runtimes.contains(where: { $0.key != id && $0.value.phase == .stopping && $0.value.hostname == hostname }) {
            return false
        }
        nextAttempt += 1
        let attempt = nextAttempt
        var runtime = Runtime(attempt: attempt, instance: instance, desired: desired, phase: .starting,
                              hostname: desired.hostname)

        guard let route = HTTPSProxy.route(for: instance, in: routes) else {
            fail(&runtime, ShareError.noProxyRoute)
            runtimes[id] = runtime
            return true
        }
        let provider: any ShareProvider
        do {
            provider = try providers(desired.provider)
        } catch {
            fail(&runtime, error)
            runtimes[id] = runtime
            return true
        }
        runtime.temporary = desired.hostname == nil && provider.randomURLsAreTemporary
        if provider.name == "cloudflared", desired.hostname != nil {
            runtime.tunnelName = CloudflaredTunnels.tunnelName(for: desired.slug)
        }
        if let hostname = desired.hostname, let holder = claimant(of: hostname, excluding: id) {
            fail(&runtime, ShareError.hostnameInUse(hostname: hostname, by: holder.desired.slug,
                                                    providerAssigned: holder.desired.hostname == nil))
            runtimes[id] = runtime
            return true
        }
        runtime.task = Task { await self.performStart(id: id, attempt: attempt, instance: instance, provider: provider, route: route) }
        runtimes[id] = runtime
        return false
    }

    /// Preflight, Cloudflare tunnel, listener, provider launch, clash check, then live.
    /// Every step re-checks that the share is still wanted; on any failure the steps
    /// already taken are undone in reverse order.
    private func performStart(id: UUID, attempt: Int, instance: any RunnableInstance,
                              provider: any ShareProvider, route: HTTPSProxy.Route) async {
        var listenerOpened = false
        var process: (any ShareProcessHandle)?
        var phpActivated = false
        do {
            try await provider.preflight()
            var runtime = try currentAttempt(id, attempt)

            var tunnelName: String?
            if provider.name == "cloudflared", let hostname = runtime.desired.hostname {
                let name = CloudflaredTunnels.tunnelName(for: runtime.desired.slug)
                tunnelName = name
                let warnings = try await ensureTunnel(instanceID: id, tunnelName: name, hostname: hostname)
                runtimes[id]?.warnings += warnings
                runtime = try currentAttempt(id, attempt)
            }

            guard let host else { throw HTTPSProxy.ProxyError.listenerFailed("the proxy has stopped") }
            let placeholder = runtime.desired.hostname.map { "https://\($0)" } ?? Self.placeholderOrigin
            let port = try await host.openShareListener(instanceID: id, route: route,
                                                        config: Self.gateConfig(runtime.desired, publicOrigin: placeholder))
            listenerOpened = true
            runtime = try currentAttempt(id, attempt)
            runtimes[id]?.listenerPort = port
            publish()

            let upstream = URL(string: "http://127.0.0.1:\(port)")!
            let spec = try provider.launchSpec(upstream: upstream, hostname: runtime.desired.hostname,
                                               instanceSlug: runtime.desired.slug, tunnelName: tunnelName)
            let pids = self.pids
            let launched = try await launcher.launch(spec: spec, provider: provider) { pid in
                pids.remember(pid, executable: Self.executablePath(of: pid) ?? spec.executable.path, instanceID: id)
            }
            process = launched.process
            let executable = Self.executablePath(of: launched.process.pid) ?? spec.executable.path
            runtime = try currentAttempt(id, attempt)

            let reportedHost = URLComponents(string: launched.url)?.host?.lowercased() ?? launched.url
            if let expected = runtime.desired.hostname, reportedHost != expected {
                throw ShareError.hostnameMismatch(expected: expected, got: reportedHost)
            }
            if let holder = claimant(of: reportedHost, excluding: id) {
                throw ShareError.hostnameInUse(hostname: reportedHost, by: holder.desired.slug,
                                               providerAssigned: holder.desired.hostname == nil)
            }

            host.updateShareConfig(instanceID: id, config: Self.gateConfig(runtime.desired, publicOrigin: launched.url))
            phpActivated = true
            try SharePHPService.activate(for: runtime.instance, publicOrigin: launched.url)

            runtime.phase = .live
            runtime.task = nil
            runtime.url = launched.url
            runtime.hostname = reportedHost
            runtime.listenerPort = port
            runtime.handle = launched.process
            runtime.executable = executable
            runtime.error = nil
            runtime.updatedAt = Date()
            runtimes[id] = runtime
            launched.process.onExit = { [weak self] status, tail in
                Task { await self?.providerExited(id: id, attempt: attempt, status: status, stderrTail: tail) }
            }
            publish()
        } catch {
            // A launch that failed has already stopped its process.
            if let process { await process.terminate() }
            pids.forget(instanceID: id)
            if listenerOpened { host?.closeShareListener(instanceID: id) }
            if phpActivated { SharePHPService.deactivate(for: runtimes[id]?.instance ?? instance) }
            guard var runtime = runtimes[id], runtime.attempt == attempt else { return }
            if runtime.phase == .stopping {
                runtimes.removeValue(forKey: id)
                publish()
                return
            }
            fail(&runtime, error)
            runtimes[id] = runtime
            publish()
            await clearDesired([id: runtime.desired.requestID])
        }
    }

    /// The runtime of a start still in progress, or a `CancellationError` when the share
    /// was torn down or replaced meanwhile.
    private func currentAttempt(_ id: UUID, _ attempt: Int) throws -> Runtime {
        guard !Task.isCancelled, let runtime = runtimes[id], runtime.attempt == attempt, runtime.phase == .starting else {
            throw CancellationError()
        }
        return runtime
    }

    /// A provider exit after the share went live: the share is reported down with the
    /// provider's last output and ends; the user retries it with a new request.
    private func providerExited(id: UUID, attempt: Int, status: Int32, stderrTail: [String]) async {
        guard var runtime = runtimes[id], runtime.attempt == attempt, runtime.phase == .live else { return }
        host?.closeShareListener(instanceID: id)
        SharePHPService.deactivate(for: runtime.instance)
        if let handle = runtime.handle { pids.forget(handle.pid) }
        fail(&runtime, ShareError.providerStopped(status: status, stderrTail: stderrTail))
        runtimes[id] = runtime
        publish()
        await clearDesired([id: runtime.desired.requestID])
    }

    /// Removes a share whose desired state is inactive. A share that ended stays
    /// published as `down` while the store still holds the request it answered.
    private func dropInactive(_ id: UUID, settings: ShareSettings?) async {
        guard let runtime = runtimes[id] else { return }
        if runtime.phase == .down, let settings, settings.requestID == runtime.desired.requestID { return }
        await tearDown(id)
    }

    /// Publishes a refusal for a share that can never run as configured and returns true;
    /// the caller then clears its desired state. A live share is released first. A share
    /// still starting or stopping is cancelled and the refusal waits for a later tick, so
    /// no entry replaces one whose resources are still held.
    private func refuse(_ instance: any RunnableInstance, desired: Desired, share: ShareSettings, error: ShareError) async -> Bool {
        let id = instance.instanceID
        if let existing = runtimes[id] {
            switch existing.phase {
            case .down where existing.desired.requestID == share.requestID:
                return true
            case .starting, .stopping:
                await tearDown(id)
                return false
            case .live, .down:
                break
            }
        }
        await tearDown(id)
        nextAttempt += 1
        var runtime = Runtime(attempt: nextAttempt, instance: instance, desired: desired, phase: .down)
        fail(&runtime, error)
        runtimes[id] = runtime
        return true
    }

    /// Releases a share's resources and forgets it. A share still starting is cancelled
    /// and releases its own resources when its task ends.
    private func tearDown(_ id: UUID) async {
        guard var runtime = runtimes[id] else { return }
        switch runtime.phase {
        case .stopping:
            return
        case .starting:
            runtime.phase = .stopping
            runtimes[id] = runtime
            runtime.task?.cancel()
        case .down:
            runtimes.removeValue(forKey: id)
        case .live:
            runtime.phase = .stopping
            runtimes[id] = runtime
            if let handle = runtime.handle {
                await handle.terminate()
                pids.forget(handle.pid)
            }
            host?.closeShareListener(instanceID: id)
            SharePHPService.deactivate(for: runtime.instance)
            if runtimes[id]?.attempt == runtime.attempt { runtimes.removeValue(forKey: id) }
        }
    }

    private func fail(_ runtime: inout Runtime, _ error: Error) {
        runtime.phase = .down
        runtime.task = nil
        runtime.error = "\(error)"
        runtime.url = nil
        runtime.hostname = runtime.desired.hostname
        runtime.listenerPort = nil
        runtime.handle = nil
        runtime.executable = nil
        runtime.updatedAt = Date()
    }

    /// The other share that holds `hostname` while starting or live.
    private func claimant(of hostname: String, excluding id: UUID) -> Runtime? {
        runtimes.first { key, runtime in
            key != id && (runtime.phase == .starting || runtime.phase == .live) && runtime.hostname == hostname
        }?.value
    }

    /// Turns off the desired share (and its `--no-auth`) of each instance in `requests`
    /// whose stored share still carries the request id the decision was made for.
    private func clearDesired(_ requests: [UUID: UUID?]) async {
        do {
            try await persistence.mutateIfChanged { envelope in
                var changed = false
                for i in envelope.sites.indices {
                    guard let request = requests[envelope.sites[i].id] else { continue }
                    let stored = envelope.sites[i].share?.requestID
                    guard stored == request else { continue }
                    if Self.clear(&envelope.sites[i].share) { changed = true }
                }
                for i in envelope.envs.indices {
                    guard let request = requests[envelope.envs[i].id] else { continue }
                    let stored = envelope.envs[i].share?.requestID
                    guard stored == request else { continue }
                    if Self.clear(&envelope.envs[i].share) { changed = true }
                }
                return changed
            }
        } catch {
            Self.log.error("share: could not clear stopped shares in the store: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func clear(_ share: inout ShareSettings?) -> Bool {
        guard var settings = share, settings.active || settings.authDisabled else { return false }
        settings.active = false
        settings.authDisabled = false
        share = settings
        return true
    }

    private static func desired(for instance: any RunnableInstance, share: ShareSettings, envelope: StoreEnvelope) -> Desired {
        Desired(
            launchKey: .init(provider: envelope.effectiveProvider(for: share),
                             hostname: normalizedHostname(share.hostname),
                             slug: instance.containerSlug),
            username: share.username,
            password: share.password,
            allow: share.allow,
            authDisabled: share.authDisabled,
            upstreamHost: instance.shareUpstreamHost,
            localOrigins: instance.shareLocalOrigins,
            requestID: share.requestID
        )
    }

    private static func normalizedHostname(_ hostname: String?) -> String? {
        let trimmed = hostname?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func gateConfig(_ desired: Desired, publicOrigin: String) -> ShareGateConfig {
        ShareGateConfig(publicOrigin: publicOrigin, upstreamHost: desired.upstreamHost,
                        localOrigins: desired.localOrigins, username: desired.username,
                        password: desired.password, authDisabled: desired.authDisabled,
                        allow: desired.allow)
    }

    // MARK: - Status file

    /// Rewrites the status file when any published status changed or the file is missing.
    /// The file is always present while this host serves, `[]` when nothing is shared, so
    /// clients can tell a share-capable proxy host from an older one.
    private func publish() {
        let statuses = runtimes.compactMap { id, runtime in Self.status(id: id, runtime) }
            .sorted { ($0.slug, $0.instanceID.uuidString) < ($1.slug, $1.instanceID.uuidString) }
        let fileExists = FileManager.default.fileExists(atPath: (statusFile ?? ProxyControl.sharesFileURL).path)
        guard statuses != lastPublished || !fileExists else { return }
        lastPublished = statuses
        ProxyControl.writeShares(statuses, file: statusFile)
    }

    private static func status(id: UUID, _ runtime: Runtime) -> ShareStatus? {
        let state: ShareStatus.State
        switch runtime.phase {
        case .starting: state = .starting
        case .live: state = .live
        case .down: state = .down
        case .stopping: return nil
        }
        let messages = (runtime.error.map { [$0] } ?? []) + runtime.warnings
        return ShareStatus(instanceID: id, slug: runtime.desired.slug, state: state, url: runtime.url,
                           provider: runtime.desired.provider, hostname: runtime.hostname,
                           temporary: runtime.temporary, listenerPort: runtime.listenerPort,
                           pid: runtime.handle?.pid, providerExecutable: runtime.executable,
                           error: messages.isEmpty ? nil : messages.joined(separator: "\n"),
                           updatedAt: runtime.updatedAt, requestID: runtime.desired.requestID)
    }

    // MARK: - Provider pids

    private func performReap() async {
        halted = false
        guard !hasReaped else {
            publish()
            return
        }
        hasReaped = true

        var targets: [ProcessIdentity] = []
        for record in pids.recorded() where !pids.contains(record.pid) {
            guard let orphan = Self.runningProcess(record) else { continue }
            Self.log.notice("share: stopping provider \(record.executable, privacy: .public) (pid \(record.pid)) left by a previous proxy")
            // Collected before any signal, while the descendants still hang under the provider.
            targets += [orphan] + ProcessIdentity.descendants(of: orphan.pid)
        }
        targets.forEach { $0.signal(SIGTERM) }
        let deadline = Date().addingTimeInterval(3)
        while targets.contains(where: \.isAlive) {
            let now = Date()
            if now >= deadline { break }
            await ProcessIdentity.pause(.milliseconds(100))
        }
        targets.forEach { $0.signal(SIGKILL) }
        pids.write()
        // Statuses a crashed host left behind describe shares that no longer run.
        publish()
    }

    /// The recorded provider when it still runs: same pid, executable and start time. A
    /// record written without a start time matches only a process launchd adopted, which
    /// a provider whose proxy host died is.
    private static func runningProcess(_ record: SharePIDRecord) -> ProcessIdentity? {
        let path = executablePath(of: record.pid)
        guard path == record.executable, let current = ProcessIdentity.current(record.pid) else { return nil }
        if let recordedStart = record.startTime {
            return current.startTime == recordedStart ? current : nil
        }
        let parent = parentPID(of: record.pid)
        return parent == 1 ? current : nil
    }

    // MARK: - Stop

    private func performStopAll() async {
        halted = true
        for (id, runtime) in runtimes where runtime.phase == .starting {
            runtimes[id]?.phase = .stopping
            runtime.task?.cancel()
        }
        for task in runtimes.values.compactMap(\.task) {
            await task.value
        }
        for id in Array(runtimes.keys) {
            await tearDown(id)
        }
        runtimes.removeAll()
        for task in Array(cleanupTasks.values) {
            await task.value
        }
        pids.write()
        ProxyControl.clearShares(file: statusFile)
        lastPublished = nil
    }

    // MARK: - Cloudflare tunnels

    /// Runs registry work one operation at a time, in call order.
    private func withRegistry<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = lastRegistryOperation
        let task = Task { () async throws -> T in
            await previous?.value
            return try await body()
        }
        lastRegistryOperation = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Creates the named tunnel for a fixed cloudflared hostname. Records this instance
    /// holds for another tunnel or hostname are cleaned up first; their warnings are
    /// returned.
    private func ensureTunnel(instanceID: UUID, tunnelName: String, hostname: String) async throws -> [String] {
        guard let tunnels = makeTunnels() else {
            throw ShareError.providerMissingBinary(name: "cloudflared", install: "brew install cloudflared")
        }
        return try await withRegistry {
            var warnings: [String] = []
            let stale = tunnels.records().filter { record in
                guard record.instanceID == instanceID else { return false }
                guard record.tunnelName == tunnelName else { return true }
                return record.hostname != nil && record.hostname != hostname
            }
            for record in stale {
                warnings += await tunnels.cleanup(record)
            }
            try await tunnels.ensure(instanceID: instanceID, tunnelName: tunnelName, hostname: hostname)
            return warnings
        }
    }

    /// Starts cleanup of every recorded tunnel whose instance is gone, or whose instance's
    /// hostname was cleared or changed. A provider change keeps the tunnel, so switching
    /// back to cloudflared reuses it. A record stays while a share of its instance still
    /// uses that tunnel, and while a deleted instance still has a share being released; a
    /// later tick cleans it.
    private func cleanUpTunnels(instances: [any RunnableInstance]) {
        guard let tunnels = makeTunnels() else { return }
        var byID: [UUID: any RunnableInstance] = [:]
        for instance in instances where byID[instance.instanceID] == nil {
            byID[instance.instanceID] = instance
        }
        for record in tunnels.records() {
            guard cleanupTasks[record.tunnelName] == nil, !failedCleanups.contains(record) else { continue }
            let instance = byID[record.instanceID]
            let runtime = runtimes[record.instanceID]
            if instance == nil, runtime != nil { continue }
            if let instance {
                if let runtime, runtime.phase != .down, runtime.tunnelName == record.tunnelName { continue }
                let wanted = Self.normalizedHostname(instance.share?.hostname)
                let isStale = wanted == nil || (record.hostname != nil && record.hostname != wanted)
                guard isStale else { continue }
            }
            let instanceID = instance == nil ? nil : record.instanceID
            cleanupTasks[record.tunnelName] = Task {
                let warnings = (try? await self.withRegistry { await tunnels.cleanup(record) }) ?? []
                self.finishCleanup(record, warnings: warnings, instanceID: instanceID, tunnels: tunnels)
            }
        }
    }

    private func finishCleanup(_ record: CloudflareTunnelRecord, warnings: [String], instanceID: UUID?,
                               tunnels: CloudflaredTunnels) {
        cleanupTasks[record.tunnelName] = nil
        if tunnels.records().contains(record) { failedCleanups.append(record) }
        for warning in warnings {
            Self.log.warning("share: \(warning, privacy: .public)")
        }
        guard let instanceID, !warnings.isEmpty, runtimes[instanceID] != nil else { return }
        runtimes[instanceID]?.warnings += warnings
        publish()
    }
}
