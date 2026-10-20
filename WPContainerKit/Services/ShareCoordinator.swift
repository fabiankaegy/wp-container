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
    func launch(spec: ShareLaunchSpec, provider: any ShareProvider) async throws -> (url: String, process: any ShareProcessHandle)
}

/// Launches providers as `ShareProcess`es.
public struct DefaultShareProcessLauncher: ShareProcessLauncher {
    public let readyTimeout: Duration

    public init(readyTimeout: Duration = .seconds(30)) {
        self.readyTimeout = readyTimeout
    }

    public func launch(spec: ShareLaunchSpec, provider: any ShareProvider) async throws -> (url: String, process: any ShareProcessHandle) {
        let process = ShareProcess(spec: spec, provider: provider)
        let handle = LaunchedShareProcess(process)
        let url = try await process.start(readyTimeout: readyTimeout)
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

/// A provider process this proxy host started, recorded so the next host can stop it
/// after a crash.
struct SharePIDRecord: Codable, Sendable, Equatable {
    let pid: Int32
    /// The process's executable path when it was recorded, compared before signalling
    /// so a reused pid is left alone.
    let executable: String
    let instanceID: UUID
}

/// Makes the running shares match the desired state in the store.
///
/// CLI, MCP and app write `share.active` and the share settings; the proxy host calls
/// `reconcile` on every refresh tick. For each active share of a running instance the
/// coordinator opens a share listener, starts the provider, and publishes the result in
/// the status file. Starting a share runs in a child task, so a slow provider never
/// holds up the proxy's tick or other shares; the status reads `starting` meanwhile.
///
/// Reconcile, `stopAll` and `reapOrphans` run one at a time in call order. A failed
/// share stays `down` and is retried only when its settings change or it is toggled
/// off and on. The coordinator is the only writer of the Cloudflare tunnel registry.
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
        /// For a refusal that cleared the desired share: the cleared settings. The
        /// status stays published until the instance's settings differ from these.
        var refusedSettings: ShareSettings?
    }

    /// Public origin given to a share listener until the provider reports its URL.
    private static let placeholderOrigin = "https://share.invalid"
    private static let log = Logger(subsystem: "com.fabiankaegy.wpcontainer", category: "share")

    private weak var host: (any ShareListenerHost)?
    private let persistence: StorePersistence
    private let launcher: any ShareProcessLauncher
    private let providers: @Sendable (String) throws -> any ShareProvider
    private let statusFile: URL?
    private let pidsFile: URL
    private let makeTunnels: @Sendable () -> CloudflaredTunnels?

    private var runtimes: [UUID: Runtime] = [:]
    private var nextAttempt = 0
    private var lastPublished: [ShareStatus]?
    private var pidRecords: [Int32: SharePIDRecord] = [:]
    private var lastOperation: Task<Void, Never>?
    private var lastRegistryOperation: Task<Void, Never>?
    private var cleanupTasks: [String: Task<Void, Never>] = [:]
    /// Tunnel records whose cleanup failed; retried by the next proxy host.
    private var failedCleanups: [CloudflareTunnelRecord] = []
    private var halted = false
    private var hasReaped = false

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
        self.pidsFile = pidsFile ?? ProxyControl.directory.appendingPathComponent("share-pids.json")
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

    /// Stops provider processes a previous proxy host left running, found in the pid
    /// file and matched by executable path. Runs once per coordinator; every call also
    /// re-enables reconcile after `stopAll`.
    public func reapOrphans() async {
        await runSerially { await self.performReap() }
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
        cleanUpTunnels(instances: instances, envelope: envelope)

        var cleared = Set<UUID>()
        for instance in instances {
            let id = instance.instanceID
            guard let share = instance.share, share.active else {
                await dropInactive(id, settings: instance.share)
                continue
            }
            guard running.contains(instance.containerSlug) else {
                cleared.insert(id)
                await tearDown(id)
                continue
            }
            let desired = Self.desired(for: instance, share: share, envelope: envelope)
            if instance.networkType.isSubdomain {
                cleared.insert(id)
                await refuse(instance, desired: desired, share: share, error: .subdomainMultisite)
                continue
            }
            await reconcileActive(instance, desired: desired, routes: routes)
        }

        let known = Set(instances.map(\.instanceID))
        for id in Array(runtimes.keys) where !known.contains(id) {
            await tearDown(id)
        }
        if !cleared.isEmpty { await clearDesired(cleared) }
        publish()
    }

    private func reconcileActive(_ instance: any RunnableInstance, desired: Desired, routes: [String: HTTPSProxy.Route]) async {
        let id = instance.instanceID
        if let current = runtimes[id] {
            switch current.phase {
            case .stopping:
                return
            case .starting:
                if current.desired.launchKey != desired.launchKey {
                    await tearDown(id)
                } else {
                    runtimes[id]?.desired = desired
                }
                return
            case .live:
                let listenerOpen = host?.isShareListenerOpen(instanceID: id) ?? false
                if current.desired.launchKey == desired.launchKey && listenerOpen {
                    if current.desired != desired { applyGateChange(instance, desired: desired) }
                    return
                }
                await tearDown(id)
            case .down:
                if current.refusedSettings == nil && current.desired == desired { return }
                await tearDown(id)
            }
        }
        start(instance, desired: desired, routes: routes)
    }

    /// Settings that only affect the gate or the PHP origin map are applied to the live
    /// listener without restarting the provider.
    private func applyGateChange(_ instance: any RunnableInstance, desired: Desired) {
        let id = instance.instanceID
        guard var runtime = runtimes[id], let url = runtime.url else { return }
        runtime.desired = desired
        runtime.instance = instance
        host?.updateShareConfig(instanceID: id, config: Self.gateConfig(desired, publicOrigin: url))
        do {
            try SharePHPService.activate(for: instance, publicOrigin: url)
        } catch {
            Self.log.error("share: could not update the PHP origin file for \(desired.slug, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        runtimes[id] = runtime
    }

    /// Records a new `starting` share and launches it in a child task. An instance the
    /// proxy has no route for yet is left for a later tick.
    private func start(_ instance: any RunnableInstance, desired: Desired, routes: [String: HTTPSProxy.Route]) {
        let id = instance.instanceID
        guard runtimes[id] == nil, let route = HTTPSProxy.route(for: instance, in: routes) else { return }
        nextAttempt += 1
        let attempt = nextAttempt
        var runtime = Runtime(attempt: attempt, instance: instance, desired: desired, phase: .starting,
                              hostname: desired.hostname)

        let provider: any ShareProvider
        do {
            provider = try providers(desired.provider)
        } catch {
            fail(&runtime, error)
            runtimes[id] = runtime
            return
        }
        runtime.temporary = desired.hostname == nil && provider.randomURLsAreTemporary
        if let hostname = desired.hostname, let holder = claimant(of: hostname, excluding: id) {
            fail(&runtime, ShareError.hostnameInUse(hostname: hostname, by: holder.desired.slug,
                                                    providerAssigned: holder.desired.hostname == nil))
            runtimes[id] = runtime
            return
        }
        runtime.task = Task { await self.performStart(id: id, attempt: attempt, instance: instance, provider: provider, route: route) }
        runtimes[id] = runtime
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
                runtimes[id]?.tunnelName = name
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
            let launched = try await launcher.launch(spec: spec, provider: provider)
            process = launched.process
            let executable = Self.executablePath(of: launched.process.pid) ?? spec.executable.path
            rememberPID(launched.process.pid, executable: executable, instanceID: id)
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
            if let process {
                await process.terminate()
                forgetPID(process.pid)
            }
            if listenerOpened { host?.closeShareListener(instanceID: id) }
            if phpActivated { SharePHPService.deactivate(for: instance) }
            guard var runtime = runtimes[id], runtime.attempt == attempt else { return }
            if runtime.phase == .stopping {
                runtimes.removeValue(forKey: id)
            } else {
                fail(&runtime, error)
                runtimes[id] = runtime
            }
            publish()
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
    /// provider's last output and left for the user to stop or retry.
    private func providerExited(id: UUID, attempt: Int, status: Int32, stderrTail: [String]) {
        guard var runtime = runtimes[id], runtime.attempt == attempt, runtime.phase == .live else { return }
        host?.closeShareListener(instanceID: id)
        SharePHPService.deactivate(for: runtime.instance)
        if let handle = runtime.handle { forgetPID(handle.pid) }
        fail(&runtime, ShareError.providerStopped(status: status, stderrTail: stderrTail))
        runtimes[id] = runtime
        publish()
    }

    /// Removes a share whose desired state is inactive. A refusal stays published while
    /// the settings it cleared are unchanged.
    private func dropInactive(_ id: UUID, settings: ShareSettings?) async {
        guard let runtime = runtimes[id] else { return }
        if let refused = runtime.refusedSettings, refused == settings { return }
        await tearDown(id)
    }

    /// Publishes a refusal for a share that can never run as configured; the caller
    /// clears its desired state. A share already running for the instance is released
    /// first.
    private func refuse(_ instance: any RunnableInstance, desired: Desired, share: ShareSettings, error: ShareError) async {
        let id = instance.instanceID
        var cleared = share
        cleared.active = false
        cleared.authDisabled = false
        if let existing = runtimes[id], existing.phase == .down, existing.refusedSettings == cleared { return }
        await tearDown(id)
        nextAttempt += 1
        var runtime = Runtime(attempt: nextAttempt, instance: instance, desired: desired, phase: .down)
        runtime.refusedSettings = cleared
        fail(&runtime, error)
        runtimes[id] = runtime
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
                forgetPID(handle.pid)
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

    /// Turns off the desired share (and its `--no-auth`) of each instance in `ids`.
    private func clearDesired(_ ids: Set<UUID>) async {
        do {
            try await persistence.mutateIfChanged { envelope in
                var changed = false
                for i in envelope.sites.indices where ids.contains(envelope.sites[i].id) {
                    if Self.clear(&envelope.sites[i].share) { changed = true }
                }
                for i in envelope.envs.indices where ids.contains(envelope.envs[i].id) {
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
            localOrigins: instance.shareLocalOrigins
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

    /// Rewrites the status file when any published status changed.
    private func publish() {
        let statuses = runtimes.compactMap { id, runtime in Self.status(id: id, runtime) }
            .sorted { ($0.slug, $0.instanceID.uuidString) < ($1.slug, $1.instanceID.uuidString) }
        guard statuses != lastPublished else { return }
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
                           updatedAt: runtime.updatedAt)
    }

    // MARK: - Provider pids

    private func rememberPID(_ pid: Int32, executable: String, instanceID: UUID) {
        pidRecords[pid] = SharePIDRecord(pid: pid, executable: executable, instanceID: instanceID)
        writePIDs()
    }

    private func forgetPID(_ pid: Int32) {
        guard pidRecords.removeValue(forKey: pid) != nil else { return }
        writePIDs()
    }

    private func writePIDs() {
        let records = pidRecords.values.sorted { $0.pid < $1.pid }
        do {
            let data = try JSONEncoder().encode(records)
            try FileManager.default.createDirectory(at: pidsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: pidsFile, options: .atomic)
        } catch {
            Self.log.error("share: could not write \(self.pidsFile.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func performReap() async {
        halted = false
        guard !hasReaped else { return }
        hasReaped = true

        let recorded: [SharePIDRecord] = (try? Data(contentsOf: pidsFile))
            .flatMap { try? JSONDecoder().decode([SharePIDRecord].self, from: $0) } ?? []
        let orphans = recorded.filter { record in
            pidRecords[record.pid] == nil && Self.executablePath(of: record.pid) == record.executable
        }
        for orphan in orphans {
            Self.log.notice("share: stopping provider \(orphan.executable, privacy: .public) (pid \(orphan.pid)) left by a previous proxy")
            kill(orphan.pid, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(3)
        var alive = orphans
        while !alive.isEmpty && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            alive = alive.filter { Self.executablePath(of: $0.pid) == $0.executable }
        }
        for survivor in alive where Self.executablePath(of: survivor.pid) == survivor.executable {
            kill(survivor.pid, SIGKILL)
        }
        writePIDs()
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
        writePIDs()
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

    /// Starts cleanup of every recorded tunnel whose instance is gone, or whose instance
    /// no longer wants that cloudflared hostname. Instances with a share in progress are
    /// skipped; their start cleans up their own records.
    private func cleanUpTunnels(instances: [any RunnableInstance], envelope: StoreEnvelope) {
        guard let tunnels = makeTunnels() else { return }
        var byID: [UUID: any RunnableInstance] = [:]
        for instance in instances where byID[instance.instanceID] == nil {
            byID[instance.instanceID] = instance
        }
        for record in tunnels.records() {
            guard cleanupTasks[record.tunnelName] == nil, !failedCleanups.contains(record) else { continue }
            let instance = byID[record.instanceID]
            if let instance {
                let phase = runtimes[record.instanceID]?.phase
                if phase == .starting || phase == .live || phase == .stopping { continue }
                let wanted = Self.cloudflareHostname(of: instance, envelope: envelope)
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

    /// The fixed hostname the instance wants a named cloudflared tunnel for, if any.
    private static func cloudflareHostname(of instance: any RunnableInstance, envelope: StoreEnvelope) -> String? {
        guard envelope.effectiveProvider(for: instance.share) == "cloudflared" else { return nil }
        return normalizedHostname(instance.share?.hostname)
    }
}
