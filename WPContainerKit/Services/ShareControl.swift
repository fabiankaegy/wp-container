import Foundation

/// A change to an instance's share settings. Unset fields leave the current value as it is.
public struct ShareRequest: Sendable {
    public var provider: String?
    /// Removes the instance's own provider so it follows the store default. Wins over `provider`.
    public var clearProvider: Bool
    /// Outer nil leaves the hostname unchanged; `.some(nil)` clears it.
    public var hostname: String??
    public var addAllow: [String]
    public var clearAllow: Bool
    public var resetPassword: Bool
    public var noAuth: Bool

    public init(provider: String? = nil, clearProvider: Bool = false, hostname: String?? = nil, addAllow: [String] = [],
                clearAllow: Bool = false, resetPassword: Bool = false, noAuth: Bool = false) {
        self.provider = provider
        self.clearProvider = clearProvider
        self.hostname = hostname
        self.addAllow = addAllow
        self.clearAllow = clearAllow
        self.resetPassword = resetPassword
        self.noAuth = noAuth
    }
}

/// Client side of site sharing, used by the CLI, MCP server and app. It writes the desired
/// state into `sites.json` and reads the runtime state the proxy host publishes.
public struct ShareControl: Sendable {
    private let persistence: StorePersistence
    private let statusFile: URL?
    private let proxyRunning: @Sendable () -> Bool

    public init(persistence: StorePersistence, statusFile: URL? = nil,
                proxyRunning: @escaping @Sendable () -> Bool = { ProxyControl.isRunning }) {
        self.persistence = persistence
        self.statusFile = statusFile
        self.proxyRunning = proxyRunning
    }

    /// Validates `req`, merges it into the instance's share settings and marks the share active.
    /// Every call stamps a fresh `requestID`, so a share that went down is retried.
    ///
    /// The proxy host stops sharing for instances that are not running, so callers start the
    /// instance before requesting a share; this method does not start it.
    @discardableResult
    public func request(instanceID: UUID, _ req: ShareRequest) async throws -> ShareSettings {
        let envelope = try await persistence.load()
        let instances = Self.instances(in: envelope)
        guard let instance = instances.first(where: { $0.instanceID == instanceID }) else {
            throw ShareError.instanceNotFound(instanceID)
        }
        let networkType = instance.networkType
        guard networkType != .subdomain else { throw ShareError.subdomainMultisite }
        guard proxyRunning() else { throw ShareError.proxyNotRunning }

        if !req.clearProvider, let provider = req.provider { _ = try ShareProviders.resolve(provider) }
        if let hostname = req.hostname, let value = hostname {
            _ = try ShareProviders.fixedURL(forHostname: value)
        }
        let allow = try req.addAllow.map { try ShareException(parsing: $0) }

        let requestID = UUID()
        let outcome = Outcome()
        try await persistence.mutateIfChanged { env in
            Self.merge(req, allow: allow, requestID: requestID, into: instanceID, in: &env,
                       statuses: ProxyControl.shares(file: statusFile), outcome: outcome)
        }
        if let error = outcome.error { throw error }
        guard let saved = outcome.settings else { throw ShareError.instanceNotFound(instanceID) }
        return saved
    }

    /// Polls until the instance publishes a `live` or `down` status for `requestID`, the id
    /// `request` returned in its settings. Statuses of earlier requests are ignored. Throws
    /// `ShareError.cancelled` when the share is stopped while waiting.
    public func waitForStatus(instanceID: UUID, requestID: UUID?,
                              timeout: Duration = .seconds(45)) async throws -> ShareStatus {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            let statuses = ProxyControl.shares(file: statusFile)
            if let status = statuses.first(where: { $0.instanceID == instanceID }),
               status.state != .starting, status.requestID == requestID {
                return status
            }
            guard proxyRunning() else { throw ShareError.proxyNotRunning }
            let envelope = try await persistence.load()
            let stillActive = Self.instances(in: envelope).first { $0.instanceID == instanceID }?.share?.active
            if stillActive == false { throw ShareError.cancelled }
            guard clock.now < deadline else { throw ShareError.timedOut }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Stops the share and keeps its credentials, hostname and exceptions.
    public func stop(instanceID: UUID) async throws {
        try await persistence.mutateIfChanged { env in
            guard var settings = Self.instances(in: env).first(where: { $0.instanceID == instanceID })?.share else {
                return false
            }
            settings.active = false
            settings.authDisabled = false
            Self.apply(settings, to: instanceID, in: &env)
            return true
        }
    }

    /// Every site and env with share settings, with its published status when there is one.
    public func list() async throws -> [(instance: any RunnableInstance, settings: ShareSettings, status: ShareStatus?)] {
        let envelope = try await persistence.load()
        let statuses = ProxyControl.shares(file: statusFile)
        return Self.instances(in: envelope).compactMap { instance in
            guard let settings = instance.share else { return nil }
            return (instance, settings, statuses.first { $0.instanceID == instance.instanceID })
        }
    }

    /// Sets the provider used by shares that name none; nil restores the built-in default.
    public func setDefaultProvider(_ name: String?) async throws {
        if let name { _ = try ShareProviders.resolve(name) }
        try await persistence.mutate { env in env.shareDefaultProvider = name }
    }

    /// Result of the merge, which runs on the store as it is when the lock is held.
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var storedError: ShareError?
        private var storedSettings: ShareSettings?

        var error: ShareError? { lock.withLock { storedError } }
        var settings: ShareSettings? { lock.withLock { storedSettings } }

        func fail(_ error: ShareError) { lock.withLock { storedError = error } }
        func succeed(_ settings: ShareSettings) { lock.withLock { storedSettings = settings } }
    }

    private static func instances(in envelope: StoreEnvelope) -> [any RunnableInstance] {
        envelope.sites.map { $0 as any RunnableInstance } + envelope.envs.map { $0 as any RunnableInstance }
    }

    private static func merge(_ req: ShareRequest, allow: [ShareException], requestID: UUID,
                              into id: UUID, in envelope: inout StoreEnvelope,
                              statuses: [ShareStatus], outcome: Outcome) -> Bool {
        let all = instances(in: envelope)
        guard let instance = all.first(where: { $0.instanceID == id }) else { return false }
        var settings = instance.share ?? ShareSettings.generated()
        if settings.password.isEmpty || req.resetPassword {
            settings.password = ShareSettings.generated().password
        }
        if req.clearProvider {
            settings.provider = nil
        } else if let provider = req.provider {
            settings.provider = provider
        }
        if let hostname = req.hostname { settings.hostname = hostname }
        if req.clearAllow { settings.allow = [] }
        for exception in allow where !settings.allow.contains(exception) {
            settings.allow.append(exception)
        }
        settings.active = true
        settings.authDisabled = req.noAuth
        settings.requestID = requestID
        if let hostname = settings.hostname,
           let clash = hostnameClash(hostname, instanceID: id, among: all, statuses: statuses) {
            outcome.fail(clash)
            return false
        }
        apply(settings, to: id, in: &envelope)
        outcome.succeed(settings)
        return true
    }

    /// The error for another active share that holds `hostname`, from its published status or
    /// its configured hostname.
    private static func hostnameClash(_ hostname: String, instanceID: UUID, among instances: [any RunnableInstance],
                                      statuses: [ShareStatus]) -> ShareError? {
        let wanted = hostname.lowercased()
        for status in statuses where status.instanceID != instanceID && status.state != .down {
            guard status.hostname?.lowercased() == wanted else { continue }
            let holder = instances.first { $0.instanceID == status.instanceID }
            guard holder?.share?.active == true else { continue }
            return .hostnameInUse(hostname: hostname, by: status.slug, providerAssigned: holder?.share?.hostname == nil)
        }
        for other in instances where other.instanceID != instanceID {
            guard let share = other.share, share.active, share.hostname?.lowercased() == wanted else { continue }
            return .hostnameInUse(hostname: hostname, by: other.containerSlug, providerAssigned: false)
        }
        return nil
    }

    private static func apply(_ settings: ShareSettings, to id: UUID, in envelope: inout StoreEnvelope) {
        if let i = envelope.sites.firstIndex(where: { $0.id == id }) {
            envelope.sites[i].share = settings
        } else if let i = envelope.envs.firstIndex(where: { $0.id == id }) {
            envelope.envs[i].share = settings
        }
    }
}
