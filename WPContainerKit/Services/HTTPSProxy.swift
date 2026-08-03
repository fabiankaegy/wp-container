import Foundation
import Network
import OSLog
import Security

/// TLS-terminating reverse proxy for trusted local HTTPS (PLAN.md §2f).
///
/// Listens on 443 (falling back to 8443), terminates TLS with the CA's wildcard
/// leaf identity, routes each request to `127.0.0.1:<site port>` by its `Host`
/// header, and injects `X-Forwarded-Proto: https` / `X-Forwarded-Host` so
/// WordPress builds correct HTTPS URLs. Containers are never touched.
///
/// Deliberately simple and correct rather than clever: TLS in, one HTTP/1.1
/// request per connection (we force `Connection: close`), a header rewrite at the
/// request boundary, then a raw bidirectional byte relay to the upstream. No
/// HTTP/2, no keep-alive multiplexing.
public final class HTTPSProxy: @unchecked Sendable {
    public enum ProxyError: Error, Sendable, CustomStringConvertible {
        case identityUnavailable(String)
        case listenerFailed(String)
        case noPortAvailable

        public var description: String {
            switch self {
            case .identityUnavailable(let s): return "TLS identity unavailable: \(s)"
            case .listenerFailed(let s):      return "listener failed: \(s)"
            case .noPortAvailable:            return "neither 443 nor 8443 could be bound"
            }
        }
    }

    public static let preferredPorts: [UInt16] = [443, 8443]
    /// Plain-HTTP listener ports for custom domains without HTTPS (PLAN.md §2i).
    public static let preferredHTTPPorts: [UInt16] = [80, 8080]

    private let ca: CertificateAuthority
    private let persistence: StorePersistence
    private let cli = ContainerCLI()
    /// Listener callbacks only. MUST be serial: Network.framework requires a
    /// serial queue — on a concurrent queue NWConnection receive/send callbacks
    /// can run out of order, which manifested as randomly truncated large
    /// responses ("The network connection was lost" on multi-MB JS bundles).
    private let queue = DispatchQueue(label: "dev.wpcontainer.httpsproxy.listener")
    private let stateLock = NSLock()

    /// A resolved routing entry: the upstream port plus the display metadata
    /// used by the friendly "site is stopped" page (#6).
    public struct Route: Sendable {
        public let port: Int
        /// Store slug usable with `wp-container start <slug>` (site or env slug).
        public let slug: String?
        public let displayName: String?
        /// Container name (`wpc-<slug>-wp` / `-mail`) + in-guest port, so the
        /// proxy can dial the container's vmnet IP directly. The published
        /// `127.0.0.1:<port>` forwarder is a FALLBACK only: Apple `container`'s
        /// forwarder discards in-flight data when the guest closes a connection
        /// while the host-side reader lags (verified with a bare NWConnection
        /// reader — slow reads via the forwarder lose the response tail, the
        /// same reads against the container IP never do), which randomly
        /// truncated multi-MB responses behind this proxy.
        public let containerName: String?
        public let containerPort: UInt16
        /// Whether `slug` names a worktree ENV rather than a parent site (issue
        /// #16). Tagged statically when the table is built — the two loops in
        /// `routes(from:)` already know which is which — so the idle sweep and
        /// the wake path never have to guess from the slug shape.
        public let isEnv: Bool
        /// For an env route, its parent site's slug — the descriptor a
        /// shared-database env needs as `dbProvider` when it is woken while the
        /// parent site is down (issue #17).
        public let parentSlug: String?

        public init(port: Int, slug: String? = nil, displayName: String? = nil,
                    containerName: String? = nil, containerPort: UInt16 = 80,
                    isEnv: Bool = false, parentSlug: String? = nil) {
            self.port = port
            self.slug = slug
            self.displayName = displayName
            self.containerName = containerName
            self.containerPort = containerPort
            self.isEnv = isEnv
            self.parentSlug = parentSlug
        }
    }

    private var listener: NWListener?
    private var httpListener: NWListener?
    private var hostMap: [String: Route] = [:]
    /// `wpc-…` container name → current vmnet IP, refreshed alongside the host
    /// map so upstream connections dial containers directly instead of the
    /// lossy published-port forwarder (see `Route.containerName`). IPs churn on
    /// every container start, so entries are only ever hints — a failed direct
    /// dial invalidates its entry and falls back to the published port.
    private var containerIPs: [String: String] = [:]
    private var refreshTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var _boundPort: UInt16?
    private var _boundHTTPPort: UInt16?
    /// SAN hosts the leaf currently covers, to detect when a reload is needed.
    private var coveredHosts: Set<String> = []

    // MARK: Idle tracking (issue #16)

    /// Slug → when the proxy last resolved a route for it. Every HTTP request
    /// already passes through `route(forHost:)`, which makes it the one free
    /// instrumentation point for "is anybody using this environment?".
    private var lastAccess: [String: Date] = [:]
    /// Slug → when the IP-refresh loop FIRST saw its wp container running.
    ///
    /// Without this, an instance nobody ever opened in a browser would have no
    /// idle clock at all and would run forever — exactly the agent-started env
    /// case this feature is for. The idle clock is
    /// `max(firstSeenRunning, lastAccess)`; the entry is dropped as soon as the
    /// container stops, so a restart re-seeds a fresh clock.
    private var firstSeenRunning: [String: Date] = [:]
    /// Slugs with a wake currently in flight, so a browser hammering refresh (or
    /// a page issuing twenty parallel asset requests) triggers exactly ONE start.
    /// Sits on top of `SiteLifecycle`'s own per-UUID claim guard (issue #5) —
    /// this one exists so the waking page can be honest about what it's doing.
    private var wakesInFlight: Set<String> = []
    /// The last wake failure per slug, shown on the waking page's next refresh
    /// so a broken wake doesn't spin silently forever. Cleared by a later
    /// successful wake.
    private var wakeFailures: [String: String] = [:]

    /// Drives idle-stop and wake-on-request (issue #16). Optional only so the
    /// proxy stays constructible without one; both real hosts (the app and
    /// `wp-container proxy serve`) pass theirs, and with nil the proxy behaves
    /// exactly as it did before this feature — no sweeps, no wakes, the plain
    /// "site is stopped" page.
    private let lifecycle: SiteLifecycle?

    private static let log = Logger(subsystem: "com.fabiankaegy.wpcontainer", category: "proxy-idle")

    public init(ca: CertificateAuthority = CertificateAuthority(),
                persistence: StorePersistence = StorePersistence(),
                lifecycle: SiteLifecycle? = nil) {
        self.ca = ca
        self.persistence = persistence
        self.lifecycle = lifecycle
    }

    /// The port the listener actually bound, once started.
    public var boundPort: UInt16? {
        stateLock.withLock { _boundPort }
    }

    /// The plain-HTTP listener port, once started.
    public var boundHTTPPort: UInt16? {
        stateLock.withLock { _boundHTTPPort }
    }

    // MARK: - Host map

    /// Replace the `<host> → port` routing table (compat overload — routes
    /// carry no display metadata, so the stopped-site page falls back to the
    /// hostname).
    public func updateHostMap(_ map: [String: Int]) {
        stateLock.withLock { hostMap = map.mapValues { Route(port: $0) } }
    }

    /// Replace the full `<host> → route` table.
    public func updateHostMap(routes: [String: Route]) {
        stateLock.withLock { hostMap = routes }
    }

    /// Route by an exact Host-header lookup, then fall back to stripping the
    /// leftmost label so subdomain-multisite subsites (`sub.<slug>.localhost`,
    /// `sub.mysite.local`) route to their network's port (PLAN.md §2i/§2j).
    ///
    /// Also stamps the route's slug as accessed NOW (issue #16). This is the
    /// single choke point every proxied request passes through — one call per
    /// request, already inside the state lock — so last-access tracking is free
    /// here and would need extra bookkeeping anywhere else.
    private func route(forHost host: String) -> Route? {
        // Strip any :port suffix and lowercase.
        var name = host.split(separator: ":").first.map { $0.lowercased() } ?? host.lowercased()
        return stateLock.withLock {
            while true {
                if let route = hostMap[name] {
                    if let slug = route.slug { lastAccess[slug] = Date() }
                    return route
                }
                guard let dot = name.firstIndex(of: ".") else { return nil }
                let rest = String(name[name.index(after: dot)...])
                if rest.isEmpty || !rest.contains(".") { return nil }
                name = rest
            }
        }
    }

    /// Build a routing table from a store envelope: every site and env is
    /// reachable at `<slug>.localhost`, and custom-domain sites also at their
    /// domain, regardless of `httpsEnabled` (the flag governs WordPress URL
    /// rewriting, not proxy reachability). Subdomain-multisite wildcards are
    /// handled by the leftmost-label fallback in `route(forHost:)`.
    public static func routes(from envelope: StoreEnvelope) -> [String: Route] {
        var map: [String: Route] = [:]
        for site in envelope.sites {
            let route = Route(port: site.port, slug: site.slug, displayName: site.name,
                              containerName: site.wpContainerName)
            map["\(site.slug).localhost"] = route
            if let domain = site.customDomain, !domain.isEmpty { map[domain.lowercased()] = route }
            // Mailpit web UI at <slug>-mail.localhost (issue #10).
            if site.mailpitEnabled, let mp = site.mailpitPort {
                map["\(site.slug)-mail.localhost"] = Route(port: mp, slug: site.slug,
                                                           displayName: "\(site.name) · Mailbox",
                                                           containerName: site.mailContainerName,
                                                           containerPort: UInt16(SiteRecipe.mailpitWebPort))
            }
        }
        for env in envelope.envs {
            map["\(env.envSlug).localhost"] = Route(port: env.port, slug: env.envSlug,
                                                    displayName: "\(env.parentSlug) · \(env.branch)",
                                                    containerName: env.wpContainerName,
                                                    isEnv: true, parentSlug: env.parentSlug)
            if env.mailpitEnabled, let mp = env.mailpitPort {
                map["\(env.envSlug)-mail.localhost"] = Route(port: mp, slug: env.envSlug,
                                                             displayName: "\(env.parentSlug) · \(env.branch) · Mailbox",
                                                             containerName: env.mailContainerName,
                                                             containerPort: UInt16(SiteRecipe.mailpitWebPort),
                                                             isEnv: true, parentSlug: env.parentSlug)
            }
        }
        return map
    }

    /// Compat: the port-only view of `routes(from:)`.
    public static func hostMap(from envelope: StoreEnvelope) -> [String: Int] {
        routes(from: envelope).mapValues(\.port)
    }

    /// The full set of leaf SAN hostnames the cert must cover for an envelope
    /// (includes custom domains and subdomain-multisite wildcards, §2i/§2j).
    public static func sanHosts(from envelope: StoreEnvelope) -> [String] {
        var hosts = Set<String>()
        for site in envelope.sites {
            site.proxyHosts.forEach { hosts.insert($0) }
            // Cover the mailbox hostname so https://<slug>-mail.localhost is
            // trusted when the proxy serves it (issue #10).
            if site.mailpitEnabled, site.mailpitPort != nil { hosts.insert("\(site.slug)-mail.localhost") }
        }
        for env in envelope.envs {
            hosts.insert("\(env.envSlug).localhost")
            if env.mailpitEnabled, env.mailpitPort != nil { hosts.insert("\(env.envSlug)-mail.localhost") }
        }
        return Array(hosts)
    }

    // MARK: - Lifecycle

    /// Ensure certs exist, import the identity, bind the listener, and begin
    /// serving. Refreshes the host map from the store every few seconds so
    /// CLI/app changes are picked up without a restart.
    @discardableResult
    public func start() async throws -> UInt16 {
        // Seed the host map and ensure the leaf covers every current hostname
        // (explicit SANs — the *.localhost wildcard alone isn't honored by
        // OpenSSL/curl) BEFORE importing the identity.
        var hosts: [String] = []
        if let env = try? await persistence.load() {
            updateHostMap(routes: Self.routes(from: env))
            hosts = Self.sanHosts(from: env)
        }
        // Exact-set sync (#4): covers every live hostname AND prunes SAN
        // leftovers from sites/envs deleted before SAN-removal shipped.
        try await ca.syncLeafCoverage(hosts)
        stateLock.withLock { coveredHosts = Set(hosts) }
        let identity = try await loadSecIdentity()

        let tlsOptions = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity) else {
            throw ProxyError.identityUnavailable("sec_identity_create returned nil")
        }
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)

        var lastError: Error?
        var bound: UInt16?
        for candidate in Self.preferredPorts {
            do {
                let params = NWParameters(tls: tlsOptions)
                params.allowLocalEndpointReuse = true
                let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: candidate)!)
                try await startListener(listener, port: candidate, forwardedProto: "https")
                stateLock.withLock { _boundPort = candidate; self.listener = listener }
                bound = candidate
                break
            } catch {
                lastError = error
                continue
            }
        }
        guard let boundPort = bound else { throw lastError ?? ProxyError.noPortAvailable }

        // Plain-HTTP listener for custom domains with HTTPS off (§2i). Best
        // effort: HTTPS is the primary path, so a failure here is non-fatal.
        for candidate in Self.preferredHTTPPorts {
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: candidate)!)
                try await startListener(listener, port: candidate, forwardedProto: "http")
                stateLock.withLock { _boundHTTPPort = candidate; self.httpListener = listener }
                break
            } catch { continue }
        }

        // Warm the container-IP cache so even the first requests dial direct;
        // the refresh loop keeps it current from here on.
        await refreshContainerIPs()

        startRefreshLoop()
        startIdleLoop()
        return boundPort
    }

    /// One `container list` per cycle → name→IP map for every running
    /// container. Failure leaves the previous cache in place (a stale hint is
    /// self-healing via the failed-dial fallback; an emptied cache would demote
    /// every request to the lossy forwarder).
    private func refreshContainerIPs() async {
        guard let records = try? await cli.list(all: false) else { return }
        var ips: [String: String] = [:]
        var runningSlugs = Set<String>()
        for record in records {
            if let ip = record.ipAddress, !ip.isEmpty { ips[record.name] = ip }
            // `wpc-<slug>-wp` is the container that defines "this instance is
            // running" everywhere else in the codebase (reconcile, stop
            // dependents), so it defines the idle clock too.
            if record.isRunning, let slug = Self.slug(ofWPContainer: record.name) {
                runningSlugs.insert(slug)
            }
        }
        let now = Date()
        stateLock.withLock {
            containerIPs = ips
            for slug in runningSlugs where firstSeenRunning[slug] == nil {
                firstSeenRunning[slug] = now
            }
            // Drop clocks for instances that are no longer up, so the next start
            // gets a fresh idle window instead of inheriting the previous one.
            for slug in firstSeenRunning.keys where !runningSlugs.contains(slug) {
                firstSeenRunning.removeValue(forKey: slug)
                lastAccess.removeValue(forKey: slug)
            }
        }
    }

    /// `wpc-<slug>-wp` → `<slug>`; nil for any other container name.
    private static func slug(ofWPContainer name: String) -> String? {
        guard name.hasPrefix("wpc-"), name.hasSuffix("-wp") else { return nil }
        let slug = String(name.dropFirst(4).dropLast(3))
        return slug.isEmpty ? nil : slug
    }

    public func stop() {
        refreshTask?.cancel(); refreshTask = nil
        idleTask?.cancel(); idleTask = nil
        stateLock.withLock {
            listener?.cancel()
            listener = nil
            _boundPort = nil
            httpListener?.cancel()
            httpListener = nil
            _boundHTTPPort = nil
        }
    }

    /// Rebind the listener with a freshly imported identity and reseeded host
    /// table — used after the leaf is re-issued (e.g. new custom domain, §2i) so
    /// the cert swaps without an app restart. Returns the (possibly new) port.
    @discardableResult
    public func reload() async throws -> UInt16 {
        stop()
        return try await start()
    }

    private func startListener(_ listener: NWListener, port: UInt16, forwardedProto: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.tryResume() { cont.resume() }
                case .failed(let error):
                    if resumed.tryResume() { cont.resume(throwing: ProxyError.listenerFailed("\(error)")) }
                case .cancelled:
                    if resumed.tryResume() { cont.resume(throwing: ProxyError.listenerFailed("cancelled")) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(inbound: connection, forwardedProto: forwardedProto)
            }
            listener.start(queue: queue)
        }
    }

    /// Refresh the host map from the store every few seconds, and re-issue +
    /// reload the leaf when the SAN set changes (so CLI-side domain edits are
    /// picked up by a headless proxy without a manual restart, §2i).
    private func startRefreshLoop() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                await self.refreshContainerIPs()
                guard let env = try? await self.persistence.load() else { continue }
                self.updateHostMap(routes: Self.routes(from: env))
                let wanted = Set(Self.sanHosts(from: env))
                let known = self.stateLock.withLock { self.coveredHosts }
                if wanted != known {
                    self.stateLock.withLock { self.coveredHosts = wanted }
                    // Exact-set sync (#4): new hostnames get SANs, and SANs of
                    // deleted sites/envs are pruned rather than kept forever.
                    if (try? await self.ca.syncLeafCoverage(Array(wanted))) == true {
                        try? await self.reload()
                        return // reload() spins a fresh loop
                    }
                }
            }
        }
    }

    // MARK: - Idle stop (issue #16)

    /// The idle sweep lives HERE, next to the routing table, rather than in the
    /// app's reconcile loop: the proxy is the only component that knows when each
    /// instance was last used, and it is also the only one guaranteed to exist in
    /// both hosting arrangements (inside the app, or headless via
    /// `wp-container proxy serve` — arbitrated by `ProxyControl`'s pidfile). An
    /// app-side timer would silently stop enforcing the moment the user ran the
    /// proxy headlessly.
    ///
    /// Its own 30s cadence rather than the 3s IP-refresh loop: the sweep costs a
    /// store load plus a `container list`, and a 30s granularity on a 15-minute
    /// timeout is irrelevant.
    private func startIdleLoop() {
        guard lifecycle != nil, idleTask == nil else { return }
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                await self.sweepIdleInstances()
            }
        }
    }

    /// Stop every running instance whose effective policy is enabled and whose
    /// idle clock has run out.
    ///
    /// Ordering and guards, all of them load-bearing:
    ///
    /// - ENVS FIRST, then sites. An env stop is followed by
    ///   `stopSharedDatabaseIfUnused` so the parent's ~470 MB DB VM is retired
    ///   too once nothing borrows it — without that, idling envs would reclaim
    ///   only half the memory this exists for (issue #17).
    /// - A parent site is skipped entirely while ANY of its envs' wp containers
    ///   run: its DB container may be serving them. `stopCore`'s label-based
    ///   dependent check is the backstop, but there is no reason to even start.
    /// - A site idle-stop stops ONLY the parent, never its envs — coupled stops
    ///   are a user gesture; a timer must not cascade.
    /// - `isBusy` skips anything the lifecycle already has an action in flight
    ///   for, and `wakesInFlight` skips anything mid-wake, so a request that
    ///   just revived an instance can't be immediately undone.
    private func sweepIdleInstances() async {
        guard let lifecycle else { return }
        guard let envelope = try? await persistence.load() else { return }
        guard var running = try? await runningContainerNames() else { return }
        let now = Date()

        var stoppedAnEnv = false
        for env in envelope.envs {
            guard running.contains(env.wpContainerName) else { continue }
            let timeout = env.effectiveIdleStopMinutes
            guard timeout > 0, idleMinutes(of: env.envSlug, now: now) >= Double(timeout) else { continue }
            guard !isWaking(env.envSlug), !(await lifecycle.isBusy(env.id)) else { continue }
            Self.log.info("idle-stop: env \(env.envSlug, privacy: .public) idle for \(timeout, privacy: .public)+ min")
            await lifecycle.stop(env)
            if let parent = envelope.sites.first(where: { $0.id == env.parentSiteID }) {
                await lifecycle.stopSharedDatabaseIfUnused(parent: parent)
            }
            _ = await lifecycle.drainWarnings(for: env.id)
            forgetClock(env.envSlug)
            stoppedAnEnv = true
        }
        // Re-read reality if we changed it: the snapshot above would still show
        // the envs we just stopped, needlessly deferring their parent by a cycle.
        if stoppedAnEnv, let fresh = try? await runningContainerNames() { running = fresh }

        for site in envelope.sites {
            guard running.contains(site.wpContainerName) else { continue }
            let timeout = site.effectiveIdleStopMinutes
            guard timeout > 0, idleMinutes(of: site.slug, now: now) >= Double(timeout) else { continue }
            let envSlugs = envelope.envs.filter { $0.parentSiteID == site.id }.map(\.envSlug)
            guard !envSlugs.contains(where: { running.contains("wpc-\($0)-wp") }) else { continue }
            guard !isWaking(site.slug), !(await lifecycle.isBusy(site.id)) else { continue }
            Self.log.info("idle-stop: site \(site.slug, privacy: .public) idle for \(timeout, privacy: .public)+ min")
            await lifecycle.stop(site)
            _ = await lifecycle.drainWarnings(for: site.id)
            forgetClock(site.slug)
        }
    }

    private func runningContainerNames() async throws -> Set<String> {
        Set(try await cli.list(all: true).filter(\.isRunning).map(\.name))
    }

    /// Minutes since the instance was last used, where "used" is the later of a
    /// proxied request and the moment we first saw it running. Returns 0 when
    /// neither is known (the refresh loop hasn't observed it yet), which reads as
    /// "just started" and defers the decision to the next sweep — never stopping
    /// something on no evidence.
    private func idleMinutes(of slug: String, now: Date) -> Double {
        let reference = stateLock.withLock { () -> Date? in
            let seen = firstSeenRunning[slug]
            let used = lastAccess[slug]
            guard let seen else { return used }
            guard let used else { return seen }
            return max(seen, used)
        }
        guard let reference else { return 0 }
        return max(0, now.timeIntervalSince(reference)) / 60
    }

    private func isWaking(_ slug: String) -> Bool {
        stateLock.withLock { wakesInFlight.contains(slug) }
    }

    private func forgetClock(_ slug: String) {
        stateLock.withLock {
            firstSeenRunning.removeValue(forKey: slug)
            lastAccess.removeValue(forKey: slug)
        }
    }

    // MARK: - Wake on request (issue #16)

    /// Start the instance behind a route whose upstream is down, at most once at
    /// a time, and report whether a waking page should be served instead of the
    /// plain "site is stopped" page.
    ///
    /// The pattern is Sablier's / Heroku's: answer the request immediately with a
    /// self-refreshing page rather than holding the connection open for the boot.
    /// The meta-refresh IS the progress poll — at ~1s of VM boot plus WordPress
    /// warmup, one or two refreshes land on the live site.
    private func beginWake(route: Route) -> Bool {
        guard lifecycle != nil, let slug = route.slug else { return false }
        let claimed: Bool = stateLock.withLock {
            // Count the wake itself as an access, so the instance can't come up
            // and be swept away by an idle clock that predates it.
            lastAccess[slug] = Date()
            return wakesInFlight.insert(slug).inserted
        }
        guard claimed else { return true } // already waking — page, no second start
        Task { [weak self] in await self?.performWake(slug: slug, route: route) }
        return true
    }

    private func performWake(slug: String, route: Route) async {
        guard let lifecycle else { return }
        var failure: String?
        do {
            let envelope = try await persistence.load()
            if route.isEnv {
                guard let env = envelope.envs.first(where: { $0.envSlug == slug }) else {
                    throw WakeError.vanished(slug)
                }
                // The parent rides along as `dbProvider` so a shared-database env
                // can boot the server it borrows while the parent site is down
                // (issue #17) — without it the start throws
                // `sharedDatabaseUnavailable`.
                let parent = envelope.sites.first { $0.id == env.parentSiteID }
                _ = try await lifecycle.startInstance(env, dbProvider: parent)
            } else {
                guard let site = envelope.sites.first(where: { $0.slug == slug }) else {
                    throw WakeError.vanished(slug)
                }
                let provisioned = try await lifecycle.startSite(site)
                if provisioned != site.provisioned {
                    _ = try? await persistence.mutate { env in
                        if let i = env.sites.firstIndex(where: { $0.id == site.id }) {
                            env.sites[i].provisioned = provisioned
                        }
                    }
                }
            }
            Self.log.info("wake: \(slug, privacy: .public) started on request")
        } catch {
            failure = SiteLifecycle.message(for: error)
            Self.log.error("wake: \(slug, privacy: .public) failed — \(failure ?? "", privacy: .public)")
        }
        let now = Date()
        stateLock.withLock {
            wakesInFlight.remove(slug)
            lastAccess[slug] = now
            if let failure { wakeFailures[slug] = failure } else { wakeFailures.removeValue(forKey: slug) }
        }
    }

    private enum WakeError: Error, CustomStringConvertible {
        case vanished(String)
        var description: String {
            switch self {
            case .vanished(let slug): return "\(slug) is no longer in the store."
            }
        }
    }

    // MARK: - Connection handling

    private func handle(inbound: NWConnection, forwardedProto: String) {
        // One serial queue per accepted connection (shared with its upstream):
        // serial is a Network.framework requirement (see `queue`), per-pair so
        // one slow client can't head-of-line-block every other connection.
        let connQueue = DispatchQueue(label: "dev.wpcontainer.httpsproxy.conn")
        inbound.start(queue: connQueue)
        readRequestHeader(from: inbound, accumulated: Data(), forwardedProto: forwardedProto, on: connQueue)
    }

    /// Accumulate inbound bytes until the end of the HTTP header block (CRLFCRLF).
    private func readRequestHeader(from inbound: NWConnection, accumulated: Data, forwardedProto: String, on connQueue: DispatchQueue) {
        inbound.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data, !data.isEmpty { buffer.append(data) }

            if let range = Self.headerTerminator(in: buffer) {
                let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                let bodyStart = buffer.subdata(in: range.upperBound..<buffer.endIndex)
                self.route(inbound: inbound, rawHeader: headerData, bufferedBody: bodyStart, forwardedProto: forwardedProto, on: connQueue)
                return
            }
            if error != nil || isComplete {
                inbound.cancel()
                return
            }
            if buffer.count > 1_048_576 { // 1 MiB header cap — abuse guard.
                inbound.cancel()
                return
            }
            self.readRequestHeader(from: inbound, accumulated: buffer, forwardedProto: forwardedProto, on: connQueue)
        }
    }

    private func route(inbound: NWConnection, rawHeader: Data, bufferedBody: Data, forwardedProto: String, on connQueue: DispatchQueue) {
        guard let header = String(data: rawHeader, encoding: .utf8) else { inbound.cancel(); return }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { inbound.cancel(); return }

        let host = Self.headerValue("Host", in: lines) ?? ""
        guard let target = self.route(forHost: host) else {
            self.sendHTMLResponse(to: inbound, status: "502 Bad Gateway",
                                  html: Self.unknownHostPage(host: host))
            return
        }

        let rewritten = Self.rewriteHeaders(requestLine: requestLine, lines: Array(lines.dropFirst()), host: host, proto: forwardedProto)
        let upstreamBytes: Data = {
            var bytes = Data(rewritten.utf8)
            bytes.append(bufferedBody)
            return bytes
        }()

        // Prefer dialing the container's vmnet IP directly (forwarder bypass —
        // see `Route.containerName`); the published `127.0.0.1:<port>` is the
        // last-resort candidate so unknown-IP and stale-IP cases still work.
        var candidates: [(host: String, port: UInt16)] = []
        if let name = target.containerName,
           let ip = stateLock.withLock({ containerIPs[name] }) {
            candidates.append((ip, target.containerPort))
        }
        candidates.append(("127.0.0.1", UInt16(target.port)))
        dial(candidates: candidates[...], inbound: inbound, upstreamBytes: upstreamBytes,
             host: host, target: target, on: connQueue)
    }

    /// Try each upstream candidate in order; only when the LAST one (always the
    /// published localhost port) is down does the friendly "site is stopped"
    /// page (#6) go out. Connect explicitly and only forward once the upstream
    /// is READY. On 127.0.0.1 a refused connect surfaces as
    /// `.waiting(ECONNREFUSED)` (Network.framework treats it as transient and
    /// would retry forever), so `.waiting` is treated as down — correct for
    /// localhost where a live listener accepts immediately. A dead vmnet IP
    /// instead just sits in `.preparing` while ARP times out, so every attempt
    /// also carries a 2s deadline; a failed direct dial invalidates the IP hint
    /// before falling through.
    private func dial(candidates: ArraySlice<(host: String, port: UInt16)>,
                      inbound: NWConnection, upstreamBytes: Data,
                      host: String, target: Route, on connQueue: DispatchQueue) {
        guard let candidate = candidates.first else {
            // Every upstream is down. Wake the instance on the spot (issue #16)
            // and answer with a self-refreshing "waking up" page; with no
            // lifecycle wired up (never the case in either real host process)
            // fall back to the pre-#16 "site is stopped" page.
            if beginWake(route: target) {
                let failure = target.slug.flatMap { slug in stateLock.withLock { wakeFailures[slug] } }
                sendHTMLResponse(to: inbound, status: "503 Service Unavailable",
                                 html: Self.wakingPage(host: host, route: target, failure: failure))
            } else {
                sendHTMLResponse(to: inbound, status: "502 Bad Gateway",
                                 html: Self.stoppedSitePage(host: host, route: target))
            }
            return
        }
        let isDirect = candidates.count > 1
        let upstream = NWConnection(host: NWEndpoint.Host(candidate.host),
                                    port: NWEndpoint.Port(rawValue: candidate.port)!, using: .tcp)
        let decided = ResumeOnce()
        let fail: @Sendable () -> Void = { [weak self] in
            upstream.stateUpdateHandler = nil
            upstream.cancel()
            guard let self else { inbound.cancel(); return }
            if isDirect, let name = target.containerName {
                self.stateLock.withLock { _ = self.containerIPs.removeValue(forKey: name) }
            }
            self.dial(candidates: candidates.dropFirst(), inbound: inbound,
                      upstreamBytes: upstreamBytes, host: host, target: target, on: connQueue)
        }
        upstream.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard decided.tryResume() else { return }
                upstream.stateUpdateHandler = nil
                upstream.send(content: upstreamBytes, completion: .contentProcessed { [weak self] err in
                    if err != nil { inbound.cancel(); upstream.cancel(); return }
                    // Bidirectional raw relay until either side closes.
                    self?.relay(from: upstream, to: inbound)
                    self?.relay(from: inbound, to: upstream)
                })
            case .waiting, .failed:
                guard decided.tryResume() else { return }
                fail()
            case .cancelled:
                if decided.tryResume() { inbound.cancel() }
            default:
                break
            }
        }
        connQueue.asyncAfter(deadline: .now() + 2) {
            guard decided.tryResume() else { return }
            fail()
        }
        upstream.start(queue: connQueue)
    }

    /// One-directional pump: read from `source`, write to `destination`.
    ///
    /// Two truncation hazards live here, both empirically observed as randomly
    /// cut-off multi-MB responses ("The network connection was lost"):
    ///
    /// 1. OUR teardown: cancelling `destination` the moment `source` EOFs
    ///    discards bytes still queued in the connection. So the final chunk is
    ///    sent with `isComplete: true` (flush-then-FIN) and teardown of
    ///    `destination` is gated on that send's completion, which on the
    ///    (mandatory-serial) connection queue fires after all prior sends.
    ///
    /// 2. APPLE'S forwarder: the `container` published-port forwarder that
    ///    upstream connections dial (`127.0.0.1:<port>`) drops its own buffered
    ///    data if the guest closes while the host-side READER lags — verified
    ///    with a bare NWConnection reader (slow reads via the forwarder lose
    ///    the tail; the same reads against the container IP never do). Defense:
    ///    read greedily — the next `receive` is armed immediately rather than
    ///    chained off the send completion, so this proxy is never the slow
    ///    reader. Buffering is bounded by response size, fine for local dev.
    ///
    /// Both constraints together force this shape: on EOF, enqueue the final
    /// chunk as a flush-then-FIN (`isComplete: true`) and cancel ONLY `source`.
    /// `destination` must NOT be cancelled here — not even from the final
    /// send's `.contentProcessed` completion, which fires when the stack
    /// ACCEPTS the bytes, not when they drain. Each connection is instead
    /// cancelled by its OWN pump when its peer closes: the client reads the
    /// full response (Content-Length/chunked framing tells it when), closes,
    /// and that EOF drives the opposite pump's teardown. A client that never
    /// closes leaks the pair until it does — acceptable for a local dev proxy,
    /// and browsers/curl close promptly on `Connection: close` responses.
    private func relay(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            let chunk = (data?.isEmpty == false) ? data : nil
            if isComplete || error != nil {
                destination.send(content: chunk, contentContext: .finalMessage, isComplete: true,
                                 completion: .idempotent)
                source.cancel()
                return
            }
            if let chunk {
                destination.send(content: chunk, completion: .contentProcessed { err in
                    if err != nil { source.cancel(); destination.cancel() }
                })
            }
            self.relay(from: source, to: destination)
        }
    }

    private func sendHTMLResponse(to inbound: NWConnection, status: String, html: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(html)"
        inbound.send(content: Data(response.utf8), completion: .contentProcessed { _ in inbound.cancel() })
    }

    // MARK: - Friendly 502 pages (#6)

    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Shared shell for the styled proxy pages. `refresh` adds a meta-refresh
    /// so "start the site from the app" feels instant (#6).
    private static func proxyPage(title: String, heading: String, bodyHTML: String,
                                  refreshSeconds: Int?, badge: String = "WP CONTAINER · 502",
                                  spinner: Bool = false) -> String {
        let refreshTag = refreshSeconds.map { "<meta http-equiv=\"refresh\" content=\"\($0)\">" } ?? ""
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        \(refreshTag)
        <title>\(title)</title>
        <style>
          :root { color-scheme: light dark; }
          body {
            margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
            font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            background: #f5f5f7; color: #1d1d1f;
          }
          main { max-width: 30rem; padding: 2.5rem 2.75rem; background: #fff; border-radius: 18px;
                 box-shadow: 0 10px 40px rgba(0,0,0,.08); margin: 1.5rem; }
          .badge { display: inline-block; font-size: .75rem; font-weight: 600; letter-spacing: .06em;
                   padding: .25rem .6rem; border-radius: 999px; background: rgba(255,149,0,.15); color: #b25000; }
          h1 { font-size: 1.35rem; margin: .8rem 0 .4rem; }
          p { margin: .5rem 0; color: #6e6e73; }
          code, pre { font: .85rem/1.5 ui-monospace, "SF Mono", Menlo, monospace; }
          pre { background: rgba(0,0,0,.05); padding: .7rem .9rem; border-radius: 10px; overflow-x: auto; user-select: all; }
          .hint { font-size: .8rem; opacity: .75; }
          .spinner { display: inline-block; width: 1rem; height: 1rem; margin-right: .5rem;
                     vertical-align: -.15rem; border-radius: 50%;
                     border: 2px solid rgba(255,149,0,.25); border-top-color: #b25000;
                     animation: spin .8s linear infinite; }
          @keyframes spin { to { transform: rotate(360deg); } }
          @media (prefers-reduced-motion: reduce) { .spinner { animation: none; } }
          @media (prefers-color-scheme: dark) {
            body { background: #1c1c1e; color: #f5f5f7; }
            main { background: #2c2c2e; box-shadow: 0 10px 40px rgba(0,0,0,.4); }
            .badge { background: rgba(255,159,10,.2); color: #ffb340; }
            p { color: #98989d; }
            pre { background: rgba(255,255,255,.08); }
            .spinner { border-color: rgba(255,159,10,.25); border-top-color: #ffb340; }
          }
        </style>
        </head>
        <body><main>
        <span class="badge">\(badge)</span>
        <h1>\(spinner ? "<span class=\"spinner\"></span>" : "")\(heading)</h1>
        \(bodyHTML)
        </main></body>
        </html>
        """
    }

    /// Known host, but its containers are down → tell the user how to start it.
    static func stoppedSitePage(host: String, route: Route) -> String {
        let name = htmlEscape(route.displayName ?? route.slug ?? host)
        let hostEsc = htmlEscape(host.split(separator: ":").first.map(String.init) ?? host)
        var body = "<p><code>\(hostEsc)</code> is a WP Container site, but it isn’t running right now.</p>"
        if let slug = route.slug {
            body += """
            <p>Start it from the WP Container app, or run:</p>
            <pre><code>wp-container start \(htmlEscape(slug))</code></pre>
            """
        } else {
            body += "<p>Start it from the WP Container app.</p>"
        }
        body += "<p class=\"hint\">This page reloads every 3 seconds and will show the site as soon as it’s up.</p>"
        return proxyPage(title: "\(name) is stopped — WP Container",
                         heading: "\(name) is stopped",
                         bodyHTML: body, refreshSeconds: 3)
    }

    /// Known host whose containers are down, and we've just triggered a start
    /// (issue #16). The meta-refresh doubles as the wake progress poll: the next
    /// reload either lands on the live site or re-renders this page.
    ///
    /// `failure` carries the PREVIOUS wake attempt's error when there was one, so
    /// a wake that can't succeed (e.g. a shared-database env whose parent server
    /// refuses to boot) says why instead of spinning forever. The refresh keeps
    /// going regardless — each reload re-triggers a wake, which is the desired
    /// retry behaviour for a transient failure.
    static func wakingPage(host: String, route: Route, failure: String?) -> String {
        let name = htmlEscape(route.displayName ?? route.slug ?? host)
        var body = "<p>It was stopped to free up memory. Starting it now — this usually takes a couple of seconds.</p>"
        body += "<p class=\"hint\">This page reloads every 2 seconds and will show \(route.isEnv ? "the environment" : "the site") as soon as it answers.</p>"
        if let failure {
            body += "<p><strong>The last start attempt failed:</strong></p>"
            body += "<pre><code>\(htmlEscape(failure))</code></pre>"
            if let slug = route.slug {
                body += "<p class=\"hint\">Retrying on every reload. To see the full output, run <code>wp-container start \(htmlEscape(slug))</code>.</p>"
            }
        }
        return proxyPage(title: "Waking up \(name)… — WP Container",
                         heading: "Waking up \(name)…",
                         bodyHTML: body, refreshSeconds: 2,
                         badge: "WP CONTAINER · WAKING", spinner: true)
    }

    /// Wholly-unmapped host → say so (styled, no slug hint available).
    static func unknownHostPage(host: String) -> String {
        let hostEsc = htmlEscape(host.isEmpty ? "(no Host header)" : host)
        let body = """
        <p>No WP Container site is mapped to <code>\(hostEsc)</code>.</p>
        <p class="hint">Check the site’s URL in WP Container, or <code>wp-container list</code>.</p>
        """
        return proxyPage(title: "No site here — WP Container",
                         heading: "No site mapped to this host",
                         bodyHTML: body, refreshSeconds: nil)
    }

    // MARK: - HTTP header helpers

    private static func headerTerminator(in data: Data) -> Range<Data.Index>? {
        let pattern = Data("\r\n\r\n".utf8)
        return data.range(of: pattern)
    }

    private static func headerValue(_ name: String, in lines: [String]) -> String? {
        let lower = name.lowercased()
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased() == lower {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Rebuild the header block: drop hop-by-hop/forwarding headers we own,
    /// force `Connection: close`, and inject the X-Forwarded-* pair.
    private static func rewriteHeaders(requestLine: String, lines: [String], host: String, proto: String) -> String {
        var kept: [String] = []
        for line in lines {
            if line.isEmpty { continue }
            guard let colon = line.firstIndex(of: ":") else { kept.append(line); continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            switch key {
            case "x-forwarded-proto", "x-forwarded-host", "connection", "keep-alive", "proxy-connection", "upgrade":
                continue // we set these ourselves / strip hop-by-hop
            default:
                kept.append(line)
            }
        }
        kept.append("X-Forwarded-Proto: \(proto)")
        kept.append("X-Forwarded-Host: \(host)")
        kept.append("Connection: close")
        return requestLine + "\r\n" + kept.joined(separator: "\r\n") + "\r\n\r\n"
    }

    // MARK: - Identity

    private func loadSecIdentity() async throws -> SecIdentity {
        let p12URL = await ca.leafP12URL
        let data: Data
        do { data = try Data(contentsOf: p12URL) }
        catch { throw ProxyError.identityUnavailable("cannot read \(p12URL.lastPathComponent): \(error)") }

        let options = [kSecImportExportPassphrase as String: CertificateAuthority.p12Passphrase]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else {
            throw ProxyError.identityUnavailable("SecPKCS12Import failed (OSStatus \(status))")
        }
        guard let array = items as? [[String: Any]],
              let first = array.first,
              let identityAny = first[kSecImportItemIdentity as String] else {
            throw ProxyError.identityUnavailable("no identity in PKCS#12 bundle")
        }
        return identityAny as! SecIdentity
    }
}

/// One-shot guard so a continuation is resumed exactly once across NW callbacks.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func tryResume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
