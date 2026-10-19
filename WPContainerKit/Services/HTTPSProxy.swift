import Foundation
import Network
import OSLog
import Security

/// TLS-terminating reverse proxy for trusted local HTTPS (PLAN.md §2f).
///
/// Listens on 443 (falling back to 8443), terminates TLS with the CA's wildcard
/// leaf identity, routes each request to the site's container by its `Host`
/// header, and injects `X-Forwarded-Proto: https` / `X-Forwarded-Host` so
/// WordPress builds correct HTTPS URLs.
///
/// SITE containers are never touched — they publish their own
/// `127.0.0.1:<port>` and this proxy is purely additive in front of them.
/// WORKTREE ENVS are different (issue #16 follow-through): their containers
/// publish NOTHING, so every way into an env runs through this proxy — its
/// domain URL (`WorktreeEnv.domainHost`, by Host on 443/80) and its legacy
/// `127.0.0.1:<env port>`, which this proxy binds itself, one loopback listener
/// per env. Both relay to the container's vmnet IP. That is what makes an env
/// observable by the idle clock and wakeable when parked — and it keeps env
/// traffic off Apple's lossy port forwarder entirely. See `envPortListeners` /
/// `RunnableInstance.publishesPort`.
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
    /// Serializes env-port reconciliation (issue #16 follow-through). Its own queue
    /// for two reasons: the occupancy pre-check is a blocking connect, and `start()`
    /// is frequently awaited from the MainActor — and it must not sit behind
    /// `queue`, whose job is answering accepts on 443/80.
    private let portQueue = DispatchQueue(label: "dev.wpcontainer.httpsproxy.ports")
    private let stateLock = NSLock()

    /// A resolved routing entry: the upstream port plus the display metadata
    /// used by the friendly "site is stopped" page (#6).
    public struct Route: Sendable {
        public let port: Int
        /// Store slug usable with `wp-container start <slug>` (site or env slug).
        public let slug: String?
        public let displayName: String?
        /// Container name (`wpc-<slug>-wp` / `-mail`) + in-guest port, so the
        /// proxy can dial the container's vmnet IP directly. For an ENV this is the
        /// ONLY upstream — its container publishes nothing and the proxy owns
        /// `127.0.0.1:<port>` itself. For a site the published
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
        /// Whether this route serves the Mailpit web UI (`<slug>-mail.localhost`,
        /// issue #10) rather than WordPress. Never a wake trigger: an unreachable
        /// mailbox says nothing about whether the instance should be started, and
        /// starting a whole site because somebody had a mailbox tab open would be
        /// a surprise.
        public let isMailbox: Bool

        public init(port: Int, slug: String? = nil, displayName: String? = nil,
                    containerName: String? = nil, containerPort: UInt16 = 80,
                    isEnv: Bool = false, parentSlug: String? = nil,
                    isMailbox: Bool = false) {
            self.port = port
            self.slug = slug
            self.displayName = displayName
            self.containerName = containerName
            self.containerPort = containerPort
            self.isEnv = isEnv
            self.parentSlug = parentSlug
            self.isMailbox = isMailbox
        }
    }

    private var listener: NWListener?
    private var httpListener: NWListener?
    private var hostMap: [String: Route] = [:]
    /// `127.0.0.1:<port>` → route, for the ENV ports this proxy owns the socket
    /// for (issue #16 follow-through). Derived from the same `routes(from:)`
    /// values as `hostMap`, restricted to `isEnv && !isMailbox`: sites keep
    /// publishing through Apple's forwarder, and an env's Mailpit web port stays
    /// published too (see `SiteRecipe.runMailpitArgs`).
    private var portMap: [UInt16: Route] = [:]
    /// The live loopback listeners keyed by the port they hold. Managed by
    /// `syncEnvPortListeners()` off the 3s refresh loop — NOT by `start()`/`stop()`
    /// alone and deliberately NOT torn down by `reload()`: a cert re-issue happens
    /// exactly when an env is created, and dropping every env's socket for the
    /// duration of a TLS rebind would break the envs that are already running.
    private var envPortListeners: [UInt16: NWListener] = [:]
    /// Ports whose listener has actually reached `.ready`. A listener sits in
    /// `envPortListeners` from the moment it is created, which is BEFORE the bind
    /// is known to have succeeded — so this, not that, is what may be reported to
    /// other processes as "the proxy is serving this env".
    private var envPortReady: Set<UInt16> = []
    /// Ports we have already complained about, so a bind that cannot succeed
    /// (typically a PRE-UPGRADE env container still publishing the port through
    /// the forwarder) logs once instead of every 3 seconds. Cleared when the port
    /// finally binds, so a later regression is reported again.
    private var portBindWarned: Set<UInt16> = []
    /// Whether the proxy is currently meant to hold env ports at all. `stop()`
    /// clears it, `start()` sets it — so a reconcile already queued when `stop()`
    /// landed releases the sockets instead of re-taking them. `reload()` leaves it
    /// alone, which is what keeps env sockets across a cert swap.
    private var acceptingEnvPorts = false
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
    /// passes through `route(forHost:)` or `route(forPort:)`, both of which call
    /// `touchLocked` — the one free instrumentation point for "is anybody using
    /// this environment?".
    ///
    /// IN-MEMORY, and only ever sees traffic THIS proxy routed. For an ENV that is
    /// now everything a browser does, including requests to its advertised
    /// `http://127.0.0.1:<port>` URL, because the proxy holds that socket itself.
    /// For a SITE, whose container still publishes its own port, a request straight
    /// to `127.0.0.1:<port>` bypasses us and is invisible here. Non-HTTP work
    /// (wp-cli, MCP) is covered by the persisted `lastActivityAt` stamp in both
    /// cases. See `IdlePolicy`.
    private var lastAccess: [String: Date] = [:]
    /// Slug → when the IP-refresh loop FIRST saw its wp container running.
    ///
    /// Without this, an instance nobody ever opened in a browser would have no
    /// idle clock at all and would run forever. The entry is dropped as soon as
    /// the container stops, so a restart re-seeds a fresh clock.
    ///
    /// IN-MEMORY, deliberately: it is an observation this process made, not a
    /// fact about the instance. Consequences, both of them fine — a proxy PROCESS
    /// restart reseeds every clock, so nothing is stopped for at least one full
    /// timeout afterwards; and an instance started while no proxy was running is
    /// first seen whenever a proxy next comes up, which gives it a fresh window
    /// rather than an immediate stop. Erring toward "leave it running" is the right
    /// bias for a memory optimisation.
    ///
    /// A `reload()` (cert re-issue) does NOT reseed anything: it goes through
    /// `stopServing()`, which touches only the listeners and the loops, never this
    /// dictionary — and since issue #16's follow-through it leaves the per-env
    /// sockets bound as well.
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
    /// In-flight `container list` for the wake gate, shared by every request that
    /// arrives while it runs — see `freshRunningNames()`.
    private var runningNamesProbe: Task<Set<String>?, Never>?

    // MARK: Local Network Privacy

    /// When we last saw macOS Local Network Privacy refuse this process's
    /// connections to the container bridge (`bridge100`, 192.168.64.0/24) — nil
    /// while access works.
    ///
    /// Sticky ON PURPOSE. The denial is a per-app TCC decision, not a per-request
    /// condition: nothing about the next dial will differ until the user grants
    /// access in System Settings. Holding it lets the pages, the CLI and the app
    /// say what is actually wrong instead of blaming the container — which is what
    /// made this cost days to find. Cleared the moment ANY container dial
    /// succeeds, so a grant self-heals within one request.
    ///
    /// It is a `Date` rather than a `Bool` purely so the log line can say when.
    private var localNetworkDeniedAt: Date?

    /// Drives idle-stop and wake-on-request (issue #16). Optional only so the
    /// proxy stays constructible without one; both real hosts (the app and
    /// `wp-container proxy serve`) pass theirs, and with nil the proxy behaves
    /// exactly as it did before this feature — no sweeps, no wakes, the plain
    /// "site is stopped" page.
    private let lifecycle: SiteLifecycle?

    /// Called — and AWAITED — immediately before an idle stop, with the
    /// instance's UUID. The app uses it to suppress the generic "Stopped <name>"
    /// notification for a stop the user didn't ask for (a banner saying the tool
    /// stopped your environment reads as a fault, not as housekeeping).
    ///
    /// Awaited rather than fire-and-forget precisely so there is no race with the
    /// `.stopped` status event the stop is about to emit.
    private var willIdleStop: (@Sendable (UUID) async -> Void)?

    /// Install the pre-idle-stop hook. Set once by the host before/just after
    /// `start()`; guarded by the same lock as the rest of the mutable state.
    public func setWillIdleStopHook(_ hook: (@Sendable (UUID) async -> Void)?) {
        stateLock.withLock { willIdleStop = hook }
    }

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

    // MARK: - Local Network Privacy (macOS 15+ TCC)

    /// Whether macOS is currently refusing this process's connections to the
    /// container network. Read by the app to raise a persistent, actionable
    /// warning — every env is unreachable while this is true, and no amount of
    /// restarting containers changes that.
    public var isLocalNetworkDenied: Bool {
        stateLock.withLock { localNetworkDeniedAt != nil }
    }

    /// `true` when a connection's path is unsatisfied specifically because Local
    /// Network Privacy denied it — as opposed to the address being unroutable or
    /// the peer refusing, both of which say something about the container.
    private static func isLocalNetworkDenied(_ connection: NWConnection) -> Bool {
        connection.currentPath?.unsatisfiedReason == .localNetworkDenied
    }

    /// Human-readable unsatisfied reason for a connection's current path, for the
    /// give-up log line. nil when the path is satisfied (i.e. the failure was the
    /// peer's answer, not the network's).
    private static func unsatisfiedReason(_ connection: NWConnection) -> String? {
        guard let path = connection.currentPath, path.status != .satisfied else { return nil }
        return String(describing: path.unsatisfiedReason)
    }

    /// Latch the denial (first time only logs) — the container is fine, we are the
    /// ones who aren't allowed to talk to it.
    private func noteLocalNetworkDenied(address: String) {
        let fresh = stateLock.withLock { () -> Bool in
            let first = localNetworkDeniedAt == nil
            localNetworkDeniedAt = Date()
            return first
        }
        guard fresh else { return }
        Self.log.error("""
        proxy: macOS blocked this app's connection to \(address, privacy: .public) \
        (Local Network privacy). Every container is unreachable until WP Container is enabled under \
        System Settings → Privacy & Security → Local Network.
        """)
    }

    /// Any successful container dial proves access was granted; drop the latch so
    /// the pages and the app stop warning without waiting for a restart.
    private func clearLocalNetworkDenied() {
        let wasDenied = stateLock.withLock { () -> Bool in
            guard localNetworkDeniedAt != nil else { return false }
            localNetworkDeniedAt = nil
            return true
        }
        guard wasDenied else { return }
        Self.log.info("proxy: local network access is working again — container dials are succeeding")
    }

    /// Fire one throwaway connection at a known container IP so a denial is known
    /// BEFORE the first request rather than after it has burnt a 10s dial budget
    /// on a 502. It doubles as the trigger for the system's one-time permission
    /// prompt, which is exactly the moment we want it: app launch, not the first
    /// page load.
    ///
    /// Best effort in every direction — no IPs yet (nothing running) means nothing
    /// to probe, and anything other than an explicit denial is ignored: a refused
    /// or unroutable address says nothing about our permission.
    private func probeLocalNetworkAccess() async {
        guard let address = stateLock.withLock({ containerIPs.values.sorted().first }) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(address), port: 80, using: .containerTCP)
        let denied = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let decided = ResumeOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready, .waiting, .failed, .cancelled:
                    // `.waiting` is where the denial shows up (Network.framework
                    // treats a prohibited path as retryable forever), so it counts
                    // as an answer here rather than as "still connecting".
                    if decided.tryResume() { cont.resume(returning: Self.isLocalNetworkDenied(connection)) }
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + 2) {
                if decided.tryResume() { cont.resume(returning: Self.isLocalNetworkDenied(connection)) }
            }
            connection.start(queue: queue)
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        if denied { noteLocalNetworkDenied(address: address) }
    }

    // MARK: - Host map

    /// Replace the `<host> → port` routing table (compat overload — routes
    /// carry no display metadata, so the stopped-site page falls back to the
    /// hostname).
    public func updateHostMap(_ map: [String: Int]) {
        updateHostMap(routes: map.mapValues { Route(port: $0) })
    }

    /// Replace the full `<host> → route` table, and with it the derived
    /// `<env port> → route` table the proxy's own loopback listeners serve.
    public func updateHostMap(routes: [String: Route]) {
        var ports: [UInt16: Route] = [:]
        for route in routes.values where route.isEnv && !route.isMailbox {
            guard let port = UInt16(exactly: route.port) else { continue }
            ports[port] = route
        }
        stateLock.withLock { hostMap = routes; portMap = ports }
    }

    /// Stamp the route's slug as accessed NOW (issue #16). Caller MUST hold
    /// `stateLock`.
    ///
    /// Shared by BOTH entry points — the Host-header lookup and the proxy-owned
    /// env-port lookup — so a request on an env's `127.0.0.1:<port>` URL feeds the
    /// idle clock exactly like one on `<slug>.localhost`. Keeping that in one place
    /// is the whole reason this is factored out.
    private func touchLocked(_ route: Route) {
        if let slug = route.slug { lastAccess[slug] = Date() }
    }

    /// Route by an exact Host-header lookup, then fall back to stripping the
    /// leftmost label so subdomain-multisite subsites (`sub.<slug>.localhost`,
    /// `sub.mysite.local`) route to their network's port (PLAN.md §2i/§2j).
    ///
    /// Also stamps the route as accessed (issue #16) — one call per request,
    /// already inside the state lock, so last-access tracking is free here.
    private func route(forHost host: String) -> Route? {
        // Strip any :port suffix and lowercase.
        var name = host.split(separator: ":").first.map { $0.lowercased() } ?? host.lowercased()
        return stateLock.withLock {
            while true {
                if let route = hostMap[name] {
                    touchLocked(route)
                    return route
                }
                guard let dot = name.firstIndex(of: ".") else { return nil }
                let rest = String(name[name.index(after: dot)...])
                if rest.isEmpty || !rest.contains(".") { return nil }
                name = rest
            }
        }
    }

    /// Route a request by WHICH proxy-owned socket it arrived on — no Host
    /// parsing at all, because the listener exists for exactly one env.
    ///
    /// nil only in the narrow window where the env was deleted from the store but
    /// its listener hasn't been closed by the next refresh tick yet.
    private func route(forPort port: UInt16) -> Route? {
        stateLock.withLock {
            guard let route = portMap[port] else { return nil }
            touchLocked(route)
            return route
        }
    }

    /// Whether THIS proxy currently holds the `127.0.0.1:<port>` socket, i.e.
    /// dialing it would land back in our own listener. Gates the loopback
    /// fallback candidate in `dial`.
    private func ownsLoopbackPort(_ port: Int) -> Bool {
        guard let port = UInt16(exactly: port) else { return false }
        return stateLock.withLock { envPortListeners[port] != nil }
    }

    /// Build a routing table from a store envelope: every site is reachable at
    /// `<slug>.localhost` and every env at its `domainHost`, and custom-domain
    /// sites also at their domain, regardless of `httpsEnabled` (the flag
    /// governs WordPress URL rewriting, not proxy reachability). Subdomain-
    /// multisite wildcards are handled by the leftmost-label fallback in
    /// `route(forHost:)`.
    ///
    /// An env route reached by Host takes the same path as one reached on the
    /// env's own `127.0.0.1:<port>` listener (see `route(inbound:…)`): the same
    /// idle-clock stamp, the same container-IP dial, the same wake gate.
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
                                                           containerPort: UInt16(SiteRecipe.mailpitWebPort),
                                                           isMailbox: true)
            }
        }
        // A settled env serves nothing until it is restored (`EnvSettlement`).
        for env in envelope.envs where !env.isSettled {
            let host = env.domainHost
            // `sites.json` can end up with two envs sharing an `envSlug` (same
            // parent + branch, created twice). They collide on this key, and since
            // `portMap` is derived from these values the loser's port is left
            // orphaned — nothing binds it and it answers `unknownHostPage`, which
            // reads as a broken env rather than as a duplicate record. First wins,
            // deterministically, and we say so.
            if let existing = map[host] {
                log.warning("""
                proxy: two environments claim \(host, privacy: .public) — \
                serving the one on port \(existing.port, privacy: .public) and ignoring \
                the one on port \(env.port, privacy: .public). Delete the duplicate \
                (wp-container env rm) so its port is freed.
                """)
                continue
            }
            map[host] = Route(port: env.port, slug: env.envSlug,
                              displayName: "\(env.parentSlug) · \(env.branch)",
                              containerName: env.wpContainerName,
                              isEnv: true, parentSlug: env.parentSlug)
            if env.mailpitEnabled, let mp = env.mailpitPort {
                map["\(env.envSlug)-mail.localhost"] = Route(port: mp, slug: env.envSlug,
                                                             displayName: "\(env.parentSlug) · \(env.branch) · Mailbox",
                                                             containerName: env.mailContainerName,
                                                             containerPort: UInt16(SiteRecipe.mailpitWebPort),
                                                             isEnv: true, parentSlug: env.parentSlug,
                                                             isMailbox: true)
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
        let subdomainParents = Set(envelope.sites.filter { $0.networkType.isSubdomain }.map(\.id))
        for env in envelope.envs {
            hosts.insert(env.domainHost)
            // A subdomain-multisite clone serves its subsites at
            // `<sub>.<env host>` (the bare-host migration pass puts them there).
            if subdomainParents.contains(env.parentSiteID) { hosts.insert("*.\(env.domainHost)") }
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
                try await startListener(listener, context: InboundContext(forwardedProto: "https"))
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
                try await startListener(listener, context: InboundContext(forwardedProto: "http"))
                stateLock.withLock { _boundHTTPPort = candidate; self.httpListener = listener }
                break
            } catch { continue }
        }

        // Warm the container-IP cache so even the first requests dial direct;
        // the refresh loop keeps it current from here on. MUST precede the env
        // port listeners: once we hold an env's port there is no loopback
        // fallback, so a request arriving before the first IP refresh would have
        // no upstream candidate at all.
        await refreshContainerIPs()
        // …and find out immediately whether we are even allowed to reach them.
        await probeLocalNetworkAccess()
        // Take ownership of every current env's `127.0.0.1:<port>` socket. From
        // here the refresh loop keeps the set in sync.
        stateLock.withLock { acceptingEnvPorts = true }
        syncEnvPortListeners()

        startRefreshLoop()
        startIdleLoop()
        return boundPort
    }

    /// One `container list` per cycle → name→IP map for every running
    /// container. Failure leaves the previous cache in place (a stale hint is
    /// self-healing: a failed dial invalidates it). Emptying the cache instead
    /// would demote every SITE request to the lossy forwarder and leave every ENV
    /// request with no upstream candidate at all.
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
            // gets a fresh idle window instead of inheriting the previous one —
            // and with them any recorded wake failure, which would otherwise be
            // rendered on a later, unrelated wake of a healthy instance.
            for slug in firstSeenRunning.keys where !runningSlugs.contains(slug) {
                firstSeenRunning.removeValue(forKey: slug)
                lastAccess.removeValue(forKey: slug)
                wakeFailures.removeValue(forKey: slug)
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
        stopServing()
        // Full teardown gives the env sockets back too — anything else would
        // leave a dead process's ports held for the next owner.
        let listeners = stateLock.withLock { () -> [NWListener] in
            acceptingEnvPorts = false
            let all = Array(envPortListeners.values)
            envPortListeners.removeAll()
            envPortReady.removeAll()
            portBindWarned.removeAll()
            return all
        }
        listeners.forEach { $0.cancel() }
        // Clean stop ⇒ withdraw the ownership report rather than leaving a file
        // claiming ports nothing serves.
        ProxyControl.clearEnvPorts()
    }

    /// Tear down the shared 443/80 listeners and the background loops, leaving the
    /// per-env loopback listeners alone. This — not `stop()` — is what `reload()`
    /// uses: a reload is a TLS identity swap, and it is triggered by a SAN change,
    /// i.e. precisely when an env was just created. Dropping every running env's
    /// socket to re-import a certificate would be a self-inflicted outage.
    private func stopServing() {
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
        stopServing()
        return try await start()
    }

    /// What an accepted connection already knows about its own destination.
    private struct InboundContext: Sendable {
        /// Value for the injected `X-Forwarded-Proto`.
        let forwardedProto: String
        /// Set only for a proxy-owned env port listener: the route is fixed by
        /// WHICH socket the request arrived on, so the Host header is irrelevant
        /// (and for an env it is `127.0.0.1:<port>`, which maps to nothing).
        let pinnedPort: UInt16?

        init(forwardedProto: String, pinnedPort: UInt16? = nil) {
            self.forwardedProto = forwardedProto
            self.pinnedPort = pinnedPort
        }
    }

    private func startListener(_ listener: NWListener, context: InboundContext) async throws {
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
                self?.handle(inbound: connection, context: context)
            }
            listener.start(queue: queue)
        }
    }

    // MARK: - Proxy-owned env ports (issue #16 follow-through)

    /// Open/close loopback listeners so the bound set matches `portMap`.
    ///
    /// Called from `start()` and from every refresh tick, which makes envs
    /// appearing and disappearing a non-event: a newly created env's port is
    /// claimed within ~3s, and a deleted env's is released just as quickly.
    /// Deliberately NOT part of `reload()` (see `stopServing()`).
    ///
    /// Failure is always per-port and never fatal: a port we cannot take stays
    /// unbound and is retried on the next tick, while every other listener — and
    /// proxy startup itself — carries on.
    ///
    /// Hops to `portQueue` and returns immediately: `start()` is awaited from the
    /// MainActor and the reconcile does blocking connects.
    private func syncEnvPortListeners() {
        portQueue.async { [weak self] in self?.reconcileEnvPortListeners() }
    }

    private func reconcileEnvPortListeners() {
        let (desired, bound) = stateLock.withLock {
            // Stopped: desire nothing, so the loop below closes everything.
            (acceptingEnvPorts ? portMap : [:], Set(envPortListeners.keys))
        }
        // Forget the complaint history for anything no longer wanted — including
        // ports we never managed to bind, which are not in `bound`. Otherwise a
        // port later reallocated to a different env would silently skip its
        // warning.
        let stale = stateLock.withLock { () -> [NWListener] in
            portBindWarned = portBindWarned.filter { desired[$0] != nil }
            let dropped = bound.subtracting(desired.keys)
            envPortReady.subtract(dropped)
            return dropped.compactMap { envPortListeners.removeValue(forKey: $0) }
        }
        stale.forEach { $0.cancel() }
        for port in Set(desired.keys).subtracting(bound) {
            openEnvPortListener(port, slug: desired[port]?.slug)
        }
        publishEnvPortReport()
    }

    /// Publish who owns what, for consumers outside this process (see
    /// `ProxyControl.EnvPortReport`). Runs at the end of every reconcile, and again
    /// whenever a listener resolves either way, so the CLI, the MCP payloads and
    /// the app can all state the difference between "no proxy", "served" and "a
    /// proxy is up but does NOT hold this env's port" — the last of which used to
    /// be visible only in os_log.
    ///
    /// A port is only reported as OWNED once its listener is `.ready`: reporting a
    /// bind that hasn't landed would be exactly the false reassurance this exists
    /// to prevent.
    private func publishEnvPortReport() {
        let (owned, conflicted, anything) = stateLock.withLock { () -> ([UInt16], [UInt16], Bool) in
            let wanted = Set(portMap.keys)
            let owned = wanted.intersection(envPortReady)
            return (Array(owned), Array(wanted.subtracting(owned)), !wanted.isEmpty)
        }
        // Nothing to say and nothing on record: don't create the file at all.
        guard anything || ProxyControl.envPorts() != nil else { return }
        ProxyControl.writeEnvPorts(owned: owned, conflicted: conflicted)
    }

    /// Bind `127.0.0.1:<port>` for one env.
    ///
    /// The occupancy pre-check is what makes the PRE-UPGRADE case (an env
    /// container started by an older build, still publishing this port through
    /// Apple's forwarder) diagnose itself instead of turning into an opaque
    /// listener failure. It is also cheap in both directions: a live listener
    /// accepts instantly and a free port refuses instantly — the 250ms timeout
    /// only applies to a port that neither accepts nor refuses.
    private func openEnvPortListener(_ port: UInt16, slug: String?) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        if ProxyControl.isPortAccepting(port) {
            warnPortUnavailable(port, slug: slug, reason: "something is already listening on it")
            return
        }
        // Loopback ONLY — an env must not become reachable from the LAN just
        // because this proxy, rather than the forwarder, holds its socket. The
        // forwarder bound `127.0.0.1:<port>`; so do we.
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        guard let listener = try? NWListener(using: params) else {
            warnPortUnavailable(port, slug: slug, reason: "the listener could not be created")
            return
        }
        // EVERY branch is identity-guarded on `listener`. Without that, a late
        // callback from a listener we already replaced would evict the CURRENT
        // listener for this port from the table — orphaning a live, bound socket
        // that no reconcile would ever notice, and (because `ownsLoopbackPort`
        // reads that table) re-enabling the `127.0.0.1:<port>` fallback candidate,
        // i.e. the self-dial recursion this design exists to avoid.
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                let isCurrent = self.stateLock.withLock { () -> Bool in
                    guard self.envPortListeners[port] === listener else { return false }
                    self.portBindWarned.remove(port)
                    self.envPortReady.insert(port)
                    return true
                }
                guard isCurrent else { listener.cancel(); return }
                Self.log.info("env port \(port, privacy: .public) is now served by the proxy")
                self.publishEnvPortReport()
            case .failed(let error):
                // Drop it so the next refresh tick retries, and say why once.
                let stale = self.stateLock.withLock { () -> NWListener? in
                    guard self.envPortListeners[port] === listener else { return nil }
                    self.envPortReady.remove(port)
                    return self.envPortListeners.removeValue(forKey: port)
                }
                guard stale != nil else { return }
                stale?.cancel()
                self.warnPortUnavailable(port, slug: slug, reason: "\(error)")
                self.publishEnvPortReport()
            case .cancelled:
                // Either our own teardown (already removed from the map) or an
                // external cancel; make sure the map can't keep a dead listener —
                // but only if the map still points at THIS one.
                self.stateLock.withLock {
                    guard self.envPortListeners[port] === listener else { return }
                    self.envPortReady.remove(port)
                    self.envPortListeners.removeValue(forKey: port)
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(inbound: connection,
                         context: InboundContext(forwardedProto: "http", pinnedPort: port))
        }
        // Re-check the flag we read before the (blocking, up-to-250ms) occupancy
        // probe: a `stop()` in that window would otherwise leave this listener
        // bound with nothing tracking it — a leaked socket on a port the next proxy
        // owner needs.
        let stored = stateLock.withLock { () -> Bool in
            guard acceptingEnvPorts else { return false }
            envPortListeners[port] = listener
            return true
        }
        guard stored else { listener.cancel(); return }
        listener.start(queue: queue)
    }

    /// One warning per port until it binds. The overwhelmingly likely cause is an
    /// env container from before this change, still publishing the port itself —
    /// which resolves the moment that env is restarted once, so the message says
    /// so rather than describing a permanent fault.
    private func warnPortUnavailable(_ port: UInt16, slug: String?, reason: String) {
        let fresh = stateLock.withLock { portBindWarned.insert(port).inserted }
        guard fresh else { return }
        let name = slug ?? "an environment"
        let message = "proxy: could not take 127.0.0.1:\(port) for \(name) — \(reason). "
            + "If that environment was started by an older build it still publishes the port itself; "
            + "restart it (wp-container stop \(name) && wp-container start \(name)) and the proxy will "
            + "take over. Retrying every few seconds."
        Self.log.warning("\(message, privacy: .public)")
        // Also on stderr: a headless `wp-container proxy serve` has no other
        // channel, and this is exactly the case a user needs to be told about.
        FileHandle.standardError.write(Data((message + "\n").utf8))
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
                // Diff the proxy-owned env ports against what is actually bound,
                // which also RETRIES any port an earlier tick couldn't take.
                self.syncEnvPortListeners()
                let wanted = Set(Self.sanHosts(from: env))
                let known = self.stateLock.withLock { self.coveredHosts }
                if wanted != known {
                    // Exact-set sync (#4): new hostnames get SANs, and SANs of
                    // deleted sites/envs are pruned rather than kept forever.
                    if (try? await self.ca.syncLeafCoverage(Array(wanted))) == true {
                        do {
                            _ = try await self.reload()
                            // Only NOW is the new set actually covered by a serving
                            // listener; recording it earlier would make a failed
                            // reload permanent by convincing the next tick there is
                            // nothing to do.
                            self.stateLock.withLock { self.coveredHosts = wanted }
                            return // reload() spun a fresh loop; this one is done
                        } catch {
                            // A failed reload (unreadable p12, 443 AND 8443 taken)
                            // used to end the refresh loop for good, because
                            // `reload()` returns only on success and this branch
                            // returned regardless. With env ports in the picture
                            // that is a total outage: stale container IPs, no
                            // reconciliation, and sockets bound with a routing
                            // table nobody updates. So: log, re-arm, retry.
                            Self.log.error("proxy: reload after a certificate change failed — \(SiteLifecycle.message(for: error), privacy: .public). Retrying.")
                            // `reload()`'s `stopServing()` cancelled THIS task, so
                            // `continue` would fall straight out of the loop.
                            self.startRefreshLoop()
                            self.startIdleLoop()
                            return
                        }
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
    /// store load plus a `container list`, and a 30s granularity on a
    /// 180-minute timeout is irrelevant.
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
    /// - An env is skipped unless THIS proxy holds its `127.0.0.1:<port>` socket:
    ///   without that, its traffic is invisible to us and a wake couldn't answer
    ///   at the URL it advertises. See the guard for the transitional case.
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
        await persistBrowserActivity(envelope.envs)

        var stoppedAnEnv = false
        for env in envelope.envs where !env.isSettled {
            guard running.contains(env.wpContainerName) else { continue }
            // An env is only idle-STOPPABLE while we own its port, because that
            // ownership is the whole basis of the env clock being trustworthy: it
            // is what makes browser traffic to `127.0.0.1:<port>` visible, and it
            // is what lets the next request wake what we parked.
            //
            // The case this protects is the transition: an env container still
            // running from a build that published its own port keeps serving
            // through the forwarder, invisible to us — and it defaults to a
            // 180-minute timeout it never asked for. Stopping it while somebody
            // browsed it would be exactly the bug that made this feature opt-in in
            // the first place. Skipping costs nothing: restart that env once and
            // the proxy takes the socket, from which point the clock is honest.
            guard ownsLoopbackPort(env.port) else { continue }
            let timeout = env.effectiveIdleStopMinutes
            guard timeout > 0 else { continue }
            // A freshly created env still on the built-in DEFAULT is exempt for
            // its first `envCreationGraceMinutes` regardless of traffic — it is
            // presumed part of an active work session. An env with an EXPLICIT
            // timeout (`idleStopMinutes != nil`) opted out of that judgment call
            // already, so the grace window never applies to it — see
            // `IdlePolicy.isExemptFromIdleStop`.
            guard !IdlePolicy.isExemptFromIdleStop(configured: env.idleStopMinutes, createdAt: env.createdAt, now: now)
            else { continue }
            guard idleMinutes(of: env.envSlug, persisted: env.lastActivityAt, now: now) >= Double(timeout) else { continue }
            guard !isWaking(env.envSlug), !(await lifecycle.isBusy(env.id)) else { continue }
            Self.log.info("idle-stop: env \(env.envSlug, privacy: .public) idle for \(timeout, privacy: .public)+ min")
            // The hook is armed INSIDE the claim (see `SiteLifecycle.stop`), so a
            // stop that loses the claim race never suppresses a notification.
            let stopped = await lifecycle.stop(env) { [weak self] in
                await self?.notifyWillIdleStop(env.id)
            }
            guard stopped else { continue }
            // Only drain what we actually acted on (the parent's warnings belong
            // to whichever flow recorded them): the env always, the parent only
            // when this call is what took its DB container down.
            var ids = [env.id]
            if let parent = envelope.sites.first(where: { $0.id == env.parentSiteID }),
               await lifecycle.stopSharedDatabaseIfUnused(parent: parent) {
                ids.append(parent.id)
            }
            await logTeardownWarnings(ids, lifecycle: lifecycle)
            forgetClock(env.envSlug)
            stoppedAnEnv = true
        }
        // Re-read reality if we changed it: the snapshot above would still show
        // the envs we just stopped, needlessly deferring their parent by a cycle.
        if stoppedAnEnv, let fresh = try? await runningContainerNames() { running = fresh }

        for site in envelope.sites {
            guard running.contains(site.wpContainerName) else { continue }
            let timeout = site.effectiveIdleStopMinutes
            guard timeout > 0 else { continue }
            guard idleMinutes(of: site.slug, persisted: site.lastActivityAt, now: now) >= Double(timeout) else { continue }
            let envSlugs = envelope.envs.filter { $0.parentSiteID == site.id }.map(\.envSlug)
            guard !envSlugs.contains(where: { running.contains("wpc-\($0)-wp") }) else { continue }
            guard !isWaking(site.slug), !(await lifecycle.isBusy(site.id)) else { continue }
            Self.log.info("idle-stop: site \(site.slug, privacy: .public) idle for \(timeout, privacy: .public)+ min")
            let stopped = await lifecycle.stop(site) { [weak self] in
                await self?.notifyWillIdleStop(site.id)
            }
            guard stopped else { continue }
            await logTeardownWarnings([site.id], lifecycle: lifecycle)
            forgetClock(site.slug)
        }
    }

    private func notifyWillIdleStop(_ id: UUID) async {
        guard let hook = stateLock.withLock({ willIdleStop }) else { return }
        await hook(id)
    }

    /// An automatic stop has nobody watching a terminal or an error banner, so a
    /// container that survived both `container stop` and `container delete`
    /// (issue #16, item 4) would otherwise vanish silently — exactly the failure
    /// mode that made the leak hard to find. Drain the warnings and log them.
    private func logTeardownWarnings(_ ids: [UUID], lifecycle: SiteLifecycle) async {
        for id in ids {
            for warning in await lifecycle.drainWarnings(for: id) {
                Self.log.error("idle-stop: \(warning, privacy: .public)")
            }
        }
    }

    private func runningContainerNames() async throws -> Set<String> {
        Set(try await cli.list(all: true).filter(\.isRunning).map(\.name))
    }

    /// `runningContainerNames()` with concurrent callers coalesced onto one
    /// `container list`.
    ///
    /// A browser hitting a stopped site doesn't make one request, it makes thirty
    /// — the document plus every asset — and each one reaches the wake gate at the
    /// same moment. Without coalescing that is thirty `container list` invocations
    /// for one answer. Sharing the in-flight probe keeps the answer exactly as
    /// fresh (nobody gets data from before their own request) at one process's
    /// cost, which is why this is a shared Task rather than a cache with a TTL: a
    /// TTL could hand back a snapshot predating a start and trigger a wake against
    /// a container that already exists — the very thing the gate is here to stop.
    /// nil ⇒ the listing FAILED, which is not the same as "nothing is running":
    /// callers must treat it as "cannot tell" and refuse to act.
    private func freshRunningNames() async -> Set<String>? {
        if let existing = stateLock.withLock({ runningNamesProbe }) {
            return await existing.value
        }
        let probe = Task<Set<String>?, Never> { [weak self] in
            guard let self else { return nil }
            return try? await self.runningContainerNames()
        }
        // Racing callers that both found nil: keep the first, and the loser simply
        // awaits the winner instead of running its own probe.
        let winner: Task<Set<String>?, Never> = stateLock.withLock {
            if let existing = runningNamesProbe { return existing }
            runningNamesProbe = probe
            return probe
        }
        let names = await winner.value
        if winner == probe { stateLock.withLock { runningNamesProbe = nil } }
        return names
    }

    /// Minutes since the instance was last used, taking the LATEST of three
    /// signals — any one of them is enough to keep an instance alive:
    ///
    /// 1. `lastAccess` — a request this proxy routed: the proxied hostnames for
    ///    anything, PLUS an env's own `127.0.0.1:<port>` URL, whose socket the
    ///    proxy owns. Only a SITE's published port bypasses us.
    /// 2. `persisted` — `lastActivityAt` from the store, written by wp-cli, MCP
    ///    tool calls, magic-login and explicit starts in ANY process. This is the
    ///    signal that makes an agent-driven env trackable at all.
    /// 3. `firstSeenRunning` — when the refresh loop first saw it up, so an
    ///    instance nobody has touched since it started still has a clock.
    ///
    /// Returns 0 when none is known, which reads as "just started" and defers to
    /// the next sweep rather than stopping something on no evidence.
    private func idleMinutes(of slug: String, persisted: Date?, now: Date) -> Double {
        let inMemory = stateLock.withLock { () -> Date? in
            let seen = firstSeenRunning[slug]
            let used = lastAccess[slug]
            guard let seen else { return used }
            guard let used else { return seen }
            return max(seen, used)
        }
        let candidates = [inMemory, persisted].compactMap { $0 }
        guard let reference = candidates.max() else { return 0 }
        return max(0, now.timeIntervalSince(reference)) / 60
    }

    /// How often browser traffic this proxy routed is written to an env's
    /// persisted `lastActivityAt`. Coarse on purpose: the stamp feeds "unused for
    /// N days" (`EnvSettlement`); the idle clock reads `lastAccess` directly.
    private static let activityPersistInterval: TimeInterval = 600

    /// Persist `lastAccess` for envs whose stored stamp is older than
    /// `activityPersistInterval`, so a proxy restart doesn't forget that an env
    /// was browsed and other processes see the same "last used" date.
    private func persistBrowserActivity(_ envs: [WorktreeEnv]) async {
        let seen = stateLock.withLock { lastAccess }
        for env in envs {
            guard let used = seen[env.envSlug] else { continue }
            if let stamp = env.lastActivityAt, used.timeIntervalSince(stamp) < Self.activityPersistInterval { continue }
            await persistence.recordActivity(instanceID: env.id, now: used,
                                             minimumInterval: Self.activityPersistInterval)
        }
    }

    private func isWaking(_ slug: String) -> Bool {
        stateLock.withLock { wakesInFlight.contains(slug) }
    }

    /// Drop every per-slug clock, including any recorded wake failure: once the
    /// instance is down, a stale error from an earlier attempt has nothing to say
    /// about the next wake and must not be rendered on its page.
    private func forgetClock(_ slug: String) {
        stateLock.withLock {
            firstSeenRunning.removeValue(forKey: slug)
            lastAccess.removeValue(forKey: slug)
            wakeFailures.removeValue(forKey: slug)
        }
    }

    // MARK: - Wake on request (issue #16)

    /// What to serve when every upstream candidate for a route is down.
    enum DownstreamOutcome: Sendable {
        /// A wake was triggered (or one is already running) — serve the waking page.
        case waking
        /// The instance's wp container IS running; it just isn't answering. Waking
        /// would issue a `container run` against a name that already exists and
        /// fail, so say what is actually true instead.
        case runningButUnresponsive
        /// The container is running and macOS is refusing to let US talk to it
        /// (Local Network Privacy). Nothing about the site is wrong, so every other
        /// page here would send the user after the wrong thing.
        case localNetworkDenied
        /// A mailbox route whose site is up but whose Mailpit container is not.
        case mailboxUnavailable
        /// Nothing can be woken from here (no lifecycle, or a mailbox route for a
        /// stopped instance) — the pre-#16 "site is stopped" page.
        case stopped
    }

    /// Decide what a down route should answer with, and trigger a wake when that
    /// is the right answer.
    ///
    /// The pattern is Sablier's / Heroku's: answer the request immediately with a
    /// self-refreshing page rather than holding the connection open for the boot.
    /// The meta-refresh IS the progress poll — at ~1s of VM boot plus WordPress
    /// warmup, one or two refreshes land on the live site.
    ///
    /// Costs one `container list` on a path that has already spent ~2s failing to
    /// dial, which buys the gate below. Without it, a wp container that is up but
    /// briefly unresponsive (Apache restarting, a request storm, a crashed worker)
    /// would get a `container run` for a name that already exists, and the user
    /// would be shown that as a wake failure.
    private func resolveDownstream(route: Route) async -> DownstreamOutcome {
        guard lifecycle != nil, let slug = route.slug else { return .stopped }
        // A wake WE started is still running: the answer is the waking page, full
        // stop — decided before `container list` is consulted, because that listing
        // is exactly what misleads here. `container run -d` returns (and the name
        // shows as running) seconds before apache accepts a connection, so a
        // wpRunning check during a wake yields `.runningButUnresponsive` — a page
        // that says "read the container logs" and, before this fix, did not
        // refresh. That turned the 2s meta-refresh of the waking page into a
        // dead end on the exact path this feature exists for.
        //
        // `wakesInFlight` is only cleared once `startInstance` returns, and that
        // await includes `waitForHTTP` — so "waking" here means "not yet serving",
        // which is precisely the question being asked.
        if isWaking(slug) { return .waking }
        // FAIL CLOSED on an unreadable container list: "I can't tell" must not be
        // read as "it's down". Waking on that guess would `container run` a name
        // that may well exist and surface the collision as a wake failure.
        guard let running = await freshRunningNames() else { return .stopped }
        // `Route` doesn't carry the wp container name for a mailbox route, but the
        // naming convention is the same everywhere else in the codebase.
        let wpRunning = running.contains("wpc-\(slug)-wp")
        // Checked before everything below: while the network is blocked NO dial can
        // succeed, so "not answering", "mailbox down" and "stopped" would all be
        // confident lies about a container that is running perfectly well.
        if wpRunning, isLocalNetworkDenied { return .localNetworkDenied }
        if route.isMailbox {
            // Never wake off a mailbox dial failure: an unreachable mailbox says
            // nothing about whether WordPress should be started, and booting a
            // whole site because a mailbox tab was left open would be a surprise.
            return wpRunning ? .mailboxUnavailable : .stopped
        }
        if wpRunning {
            // Running, but we have no address for it — either the container was
            // started by somebody else moments ago, or a dial just evicted a stale
            // hint. Both mean "coming up", not "wedged", so serve the refreshing
            // waking page. Crucially WITHOUT claiming a wake: `container run`
            // against an existing name would fail and be shown as a wake error.
            let known = route.containerName.flatMap { name in
                stateLock.withLock { containerIPs[name] }
            }
            if known == nil { return .waking }
            return .runningButUnresponsive
        }
        let claimed: Bool = stateLock.withLock {
            // Count the wake itself as an access, so the instance can't come up
            // and be swept away by an idle clock that predates it.
            lastAccess[slug] = Date()
            return wakesInFlight.insert(slug).inserted
        }
        guard claimed else { return .waking } // already waking — page, no second start
        Task { [weak self] in await self?.performWake(slug: slug, route: route) }
        return .waking
    }

    private func performWake(slug: String, route: Route) async {
        // Every exit path MUST clear `wakesInFlight`, or the slug stays wedged
        // and no later request can ever wake it again — so the whole body is one
        // do/catch with a single cleanup at the end, and there are no early
        // returns.
        var failure: String?
        do {
            guard let lifecycle else { throw WakeError.noLifecycle }
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
            // Resolve the fresh IP NOW, before releasing the wake claim. The
            // client's next meta-refresh lands ~2s from here and the periodic
            // refresh runs every 3s, so without this the first request after a
            // successful wake can still find no candidate — an env has no
            // published-port fallback to paper over that.
            if let name = route.containerName { await refreshContainerIP(name) }
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

    /// Resolve ONE container's vmnet IP right now and fold it into the shared
    /// cache. The periodic refresh is a 3s poll over every container; this is the
    /// targeted version for the two moments where waiting up to 3s is the
    /// difference between serving the site and serving a page about it.
    @discardableResult
    private func refreshContainerIP(_ name: String) async -> String? {
        // `try?` on a throwing call returning `String?` flattens to `String?`.
        guard let ip = try? await cli.ipAddress(of: name), !ip.isEmpty else { return nil }
        stateLock.withLock { containerIPs[name] = ip }
        return ip
    }

    private enum WakeError: Error, CustomStringConvertible {
        case vanished(String)
        case noLifecycle
        var description: String {
            switch self {
            case .vanished(let slug): return "\(slug) is no longer in the store."
            case .noLifecycle: return "This proxy was started without a lifecycle and cannot start containers."
            }
        }
    }

    // MARK: - Connection handling

    private func handle(inbound: NWConnection, context: InboundContext) {
        // One serial queue per accepted connection (shared with its upstream):
        // serial is a Network.framework requirement (see `queue`), per-pair so
        // one slow client can't head-of-line-block every other connection.
        let connQueue = DispatchQueue(label: "dev.wpcontainer.httpsproxy.conn")
        inbound.start(queue: connQueue)
        readRequestHeader(from: inbound, accumulated: Data(), context: context, on: connQueue)
    }

    /// Accumulate inbound bytes until the end of the HTTP header block (CRLFCRLF).
    private func readRequestHeader(from inbound: NWConnection, accumulated: Data, context: InboundContext, on connQueue: DispatchQueue) {
        inbound.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data, !data.isEmpty { buffer.append(data) }

            if let range = Self.headerTerminator(in: buffer) {
                let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                let bodyStart = buffer.subdata(in: range.upperBound..<buffer.endIndex)
                self.route(inbound: inbound, rawHeader: headerData, bufferedBody: bodyStart, context: context, on: connQueue)
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
            self.readRequestHeader(from: inbound, accumulated: buffer, context: context, on: connQueue)
        }
    }

    private func route(inbound: NWConnection, rawHeader: Data, bufferedBody: Data, context: InboundContext, on connQueue: DispatchQueue) {
        guard let header = String(data: rawHeader, encoding: .utf8) else { inbound.cancel(); return }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { inbound.cancel(); return }

        let host = Self.headerValue("Host", in: lines) ?? ""
        // A request on a proxy-owned env port resolves by SOCKET, not by Host —
        // `127.0.0.1:<port>` (what an env not yet moved onto its domain still
        // advertises and has in its database) maps to no hostname at all. An
        // env's domain URL resolves by Host like any site. Everything downstream from
        // here (dial, wake gate, waking/stopped/unresponsive pages, Retry-After)
        // is then identical for both entry points, by construction.
        let resolved = context.pinnedPort.map { self.route(forPort: $0) } ?? self.route(forHost: host)
        guard let target = resolved else {
            self.sendHTMLResponse(to: inbound, status: "502 Bad Gateway",
                                  html: Self.unknownHostPage(host: host))
            return
        }

        let rewritten = Self.rewriteHeaders(requestLine: requestLine, lines: Array(lines.dropFirst()), host: host, proto: context.forwardedProto)
        let upstreamBytes: Data = {
            var bytes = Data(rewritten.utf8)
            bytes.append(bufferedBody)
            return bytes
        }()

        // Prefer dialing the container's vmnet IP directly (forwarder bypass —
        // see `Route.containerName`); the published `127.0.0.1:<port>` is a
        // last-resort candidate so unknown-IP and stale-IP cases still work.
        //
        // …but ONLY when the container actually publishes that port. For an env
        // whose socket THIS proxy holds, `127.0.0.1:<port>` is our own listener:
        // dialing it would relay the request straight back into ourselves and
        // recurse until something ran out. Ownership is read from the live
        // listener table rather than from `Route.isEnv`, so a pre-upgrade env we
        // failed to bind keeps its working forwarder fallback.
        var candidates: [DialCandidate] = []
        if let name = target.containerName,
           let ip = stateLock.withLock({ containerIPs[name] }) {
            candidates.append(DialCandidate(host: ip, port: target.containerPort, isContainerIP: true))
        }
        if !ownsLoopbackPort(target.port), let port = UInt16(exactly: target.port) {
            candidates.append(DialCandidate(host: "127.0.0.1", port: port, isContainerIP: false))
        }
        // Whether the client would understand an HTML interstitial. An asset
        // fetch, an XHR or `curl` gets a terse machine-readable 503 instead — a
        // page of markup where a stylesheet or a JSON body was expected is worse
        // than useless (issue #16).
        let wantsHTML = Self.acceptsHTML(Self.headerValue("Accept", in: lines))
        dial(candidates: candidates[...], inbound: inbound, upstreamBytes: upstreamBytes,
             host: host, target: target, wantsHTML: wantsHTML, on: connQueue)
    }

    /// Whether an `Accept` header asks for HTML. A missing header is treated as
    /// yes: that is what a bare `curl` sends, and a human at a terminal is better
    /// served by the readable page than by a one-liner.
    static func acceptsHTML(_ accept: String?) -> Bool {
        guard let accept, !accept.isEmpty else { return true }
        let lower = accept.lowercased()
        if lower.contains("text/html") { return true }
        // `*/*` alone (curl's default) means "anything"; treat it as HTML-capable.
        // A specific non-HTML type (text/css, application/json, image/*) does not.
        return lower.contains("*/*") && !lower.contains("application/json")
    }

    /// One upstream address to try, and whether it is the container's own vmnet IP
    /// (as opposed to a published loopback port). The flag replaces the old
    /// `candidates.count > 1` heuristic for "was this a direct dial?": with the
    /// loopback fallback now conditional, a container-IP dial is frequently the
    /// ONLY candidate, and stale-IP invalidation must still fire for it.
    private struct DialCandidate: Sendable {
        let host: String
        let port: UInt16
        let isContainerIP: Bool
    }

    /// Whether a connect error is a definitive answer FROM THE NETWORK, as opposed
    /// to our own patience expiring: something at that address said no, or the
    /// address is not routable. Those are the cases where a cached vmnet IP is
    /// plausibly stale and re-resolving it is the useful response.
    ///
    /// A deadline expiry is deliberately NOT in this set. It says nothing about
    /// whether the IP is right — and evicting on it is actively harmful now that an
    /// env has no published-port fallback: it throws away the only address we have
    /// because one connect was slow. (On this machine that is not hypothetical: the
    /// macOS 27 beta's L4S handling corrupts ECT(1) SYN checksums to container IPs,
    /// adding a fixed ~2s penalty to the first connect — exactly the old deadline.)
    private static func invalidatesIPHint(_ error: NWError?) -> Bool {
        guard let error else { return false }
        if case .posix(let code) = error {
            switch code {
            case .ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ECONNRESET:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Try each upstream candidate in order; only when the last one is down does
    /// the friendly "site is stopped" page (#6) — or, since #16, the waking page —
    /// go out. An EMPTY candidate list first tries to resolve the container's IP on
    /// demand (a just-started env may not have been picked up by the 3s poll yet)
    /// and only then answers with a page.
    ///
    /// Connect explicitly and only forward once the upstream is READY. Two very
    /// different regimes live here:
    ///
    /// - A PUBLISHED loopback port, or a container IP with a fallback behind it:
    ///   be quick. On 127.0.0.1 a refused connect surfaces as
    ///   `.waiting(ECONNREFUSED)` (Network.framework treats it as transient and
    ///   would retry forever), so `.waiting` means down — correct for localhost,
    ///   where a live listener accepts immediately — under a 2s deadline.
    /// - The container IP as the SOLE candidate (every env): be patient. There is
    ///   nothing to fall through to, so a single slow connect is the difference
    ///   between the site and a 502. `.waiting` is treated as "still connecting"
    ///   until our own (longer) deadline unless the error is a definitive refusal,
    ///   the deadline is 5s, and the candidate gets one retry.
    private func dial(candidates: ArraySlice<DialCandidate>,
                      inbound: NWConnection, upstreamBytes: Data,
                      host: String, target: Route, wantsHTML: Bool,
                      attempt: Int = 1, triedContainerIP: String? = nil,
                      on connQueue: DispatchQueue) {
        guard let candidate = candidates.first else {
            Task { [weak self] in
                guard let self else { inbound.cancel(); return }
                // Last chance before we render a page ABOUT the instance instead of
                // the instance: ask `container inspect` for its address directly.
                // The periodic cache is a 3s poll, and something started moments ago
                // (by a wake, by the CLI, by another process) simply isn't in it yet.
                //
                // Only worth it for an address we have NOT already failed against.
                // `ip != triedContainerIP` is what keeps this from re-dialing the
                // same dead IP for another full deadline — which would otherwise add
                // ~10s to every stopped SITE's page, since a site always has a
                // container-IP candidate to burn first.
                if let name = target.containerName,
                   let ip = await self.refreshContainerIP(name), ip != triedContainerIP {
                    let retry = DialCandidate(host: ip, port: target.containerPort, isContainerIP: true)
                    connQueue.async {
                        self.dial(candidates: [retry][...], inbound: inbound,
                                  upstreamBytes: upstreamBytes, host: host, target: target,
                                  wantsHTML: wantsHTML, triedContainerIP: ip, on: connQueue)
                    }
                    return
                }
                // Every upstream is down. Deciding what to answer needs a fresh
                // `container list` (see `resolveDownstream`), so it happens off the
                // connection queue and the response is dispatched back onto it — the
                // NWConnection's sends must stay on the queue it was started with.
                let outcome = await self.resolveDownstream(route: target)
                let failure = target.slug.flatMap { slug in
                    self.stateLock.withLock { self.wakeFailures[slug] }
                }
                connQueue.async {
                    self.respondDown(outcome, to: inbound, host: host, target: target,
                                     failure: failure, wantsHTML: wantsHTML)
                }
            }
            return
        }
        // No fallback behind a container IP ⇒ this dial is the env's only chance.
        let isSoleContainerIP = candidate.isContainerIP && candidates.count == 1
        let deadlineSeconds: Double = isSoleContainerIP ? 5 : 2
        let maxAttempts = isSoleContainerIP ? 2 : 1
        let upstream = NWConnection(host: NWEndpoint.Host(candidate.host),
                                    port: NWEndpoint.Port(rawValue: candidate.port)!, using: .containerTCP)
        let decided = ResumeOnce()
        /// `evictHint`: whether to forget the cached IP (see `invalidatesIPHint`).
        /// `reason`: what ended this attempt, for the log line below.
        /// `allowRetry`: false for a verdict a second identical attempt cannot change.
        let giveUp: @Sendable (_ evictHint: Bool, _ reason: String, _ allowRetry: Bool) -> Void = { [weak self] evictHint, reason, allowRetry in
            // Read the path BEFORE cancelling: a cancelled connection reports none,
            // and the unsatisfied reason is the single most useful field here.
            let pathReason = Self.unsatisfiedReason(upstream)
            upstream.stateUpdateHandler = nil
            upstream.cancel()
            guard let self else { inbound.cancel(); return }
            // Every give-up, always. This path was completely silent, which is why
            // a blanket network denial looked exactly like a stopped container for
            // days: the branded 502 was the only evidence either way.
            let where_ = "\(target.slug ?? host)\(target.isMailbox ? " (mailbox)" : "")"
            let path = pathReason.map { " path unsatisfied: \($0)." } ?? ""
            Self.log.notice("""
            proxy: dial gave up for \(where_, privacy: .public) → \
            \(candidate.host, privacy: .public):\(candidate.port, privacy: .public) \
            (attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public)): \
            \(reason, privacy: .public).\(path, privacy: .public)
            """)
            if evictHint, candidate.isContainerIP, let name = target.containerName {
                self.stateLock.withLock { _ = self.containerIPs.removeValue(forKey: name) }
            }
            // Whichever address we just failed against, remember it if it was the
            // container's — the empty-candidate path uses it to avoid re-dialing an
            // IP that has already had its chance.
            let tried = candidate.isContainerIP ? candidate.host : triedContainerIP
            if allowRetry, attempt < maxAttempts {
                // Same candidate, one more time: a first connect lost to a slow
                // vmnet path usually succeeds immediately afterwards.
                self.dial(candidates: candidates, inbound: inbound,
                          upstreamBytes: upstreamBytes, host: host, target: target,
                          wantsHTML: wantsHTML, attempt: attempt + 1,
                          triedContainerIP: tried, on: connQueue)
            } else {
                self.dial(candidates: candidates.dropFirst(), inbound: inbound,
                          upstreamBytes: upstreamBytes, host: host, target: target,
                          wantsHTML: wantsHTML, triedContainerIP: tried,
                          on: connQueue)
            }
        }
        upstream.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard decided.tryResume() else { return }
                upstream.stateUpdateHandler = nil
                // A container we just reached is proof the network isn't blocked.
                if candidate.isContainerIP { self?.clearLocalNetworkDenied() }
                upstream.send(content: upstreamBytes, completion: .contentProcessed { [weak self] err in
                    if err != nil { inbound.cancel(); upstream.cancel(); return }
                    // Bidirectional raw relay until either side closes.
                    self?.relay(from: upstream, to: inbound)
                    self?.relay(from: inbound, to: upstream)
                })
            case .waiting(let error):
                // macOS Local Network Privacy: the path is `unsatisfied (Local
                // network prohibited)` and Network.framework will sit in `.waiting`
                // forever. Waiting out the 5s deadline twice, then rendering a page
                // that blames the container, is precisely how this regression hid.
                // Fail now, latch it, and let `resolveDownstream` say the truth.
                if Self.isLocalNetworkDenied(upstream) {
                    guard decided.tryResume() else { return }
                    self?.noteLocalNetworkDenied(address: candidate.host)
                    giveUp(false, "macOS denied local network access", false)
                    return
                }
                // On the sole-container-IP path, `.waiting` is the stack saying
                // "not yet, still retrying" — which is the truth while a guest's
                // network comes up. Let the deadline decide instead of bailing on
                // the first hiccup; a definitive refusal still short-circuits.
                if isSoleContainerIP, !Self.invalidatesIPHint(error) { return }
                guard decided.tryResume() else { return }
                giveUp(Self.invalidatesIPHint(error), "waiting: \(error)", true)
            case .failed(let error):
                guard decided.tryResume() else { return }
                giveUp(Self.invalidatesIPHint(error), "failed: \(error)", true)
            case .cancelled:
                if decided.tryResume() { inbound.cancel() }
            default:
                break
            }
        }
        connQueue.asyncAfter(deadline: .now() + deadlineSeconds) {
            guard decided.tryResume() else { return }
            // Our patience, not the network's answer: keep the IP hint.
            giveUp(false, "no answer within \(Int(deadlineSeconds))s", true)
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

    private func sendHTMLResponse(to inbound: NWConnection, status: String, html: String,
                                  retryAfterSeconds: Int? = nil) {
        sendResponse(to: inbound, status: status, contentType: "text/html; charset=utf-8",
                     body: html, retryAfterSeconds: retryAfterSeconds)
    }

    private func sendResponse(to inbound: NWConnection, status: String, contentType: String,
                              body: String, retryAfterSeconds: Int? = nil) {
        // `Retry-After` on a 503 is what tells non-browser clients (and any proxy
        // or fetch-retry layer in between) that this is a transient wait with a
        // known duration rather than an outage — the meta-refresh only helps a
        // browser rendering the HTML variant.
        let retry = retryAfterSeconds.map { "Retry-After: \($0)\r\n" } ?? ""
        let response = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\n\(retry)Cache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
        inbound.send(content: Data(response.utf8), completion: .contentProcessed { _ in inbound.cancel() })
    }

    /// Write the answer for a route whose upstreams are all down.
    private func respondDown(_ outcome: DownstreamOutcome, to inbound: NWConnection,
                             host: String, target: Route, failure: String?, wantsHTML: Bool) {
        let name = target.displayName ?? target.slug ?? host
        switch outcome {
        case .waking:
            guard wantsHTML else {
                sendResponse(to: inbound, status: "503 Service Unavailable",
                             contentType: "text/plain; charset=utf-8",
                             body: "\(name) was stopped to free memory and is starting up. Retry in a moment.\n",
                             retryAfterSeconds: 2)
                return
            }
            sendHTMLResponse(to: inbound, status: "503 Service Unavailable",
                             html: Self.wakingPage(host: host, route: target, failure: failure),
                             retryAfterSeconds: 2)
        case .runningButUnresponsive:
            guard wantsHTML else {
                sendResponse(to: inbound, status: "502 Bad Gateway",
                             contentType: "text/plain; charset=utf-8",
                             body: "\(name) is running but did not answer. Check its logs.\n")
                return
            }
            sendHTMLResponse(to: inbound, status: "502 Bad Gateway",
                             html: Self.unresponsivePage(host: host, route: target))
        case .localNetworkDenied:
            guard wantsHTML else {
                sendResponse(to: inbound, status: "502 Bad Gateway",
                             contentType: "text/plain; charset=utf-8",
                             body: """
                             macOS is blocking WP Container from reaching local containers, so \(name) \
                             cannot be served. Enable WP Container under System Settings > Privacy & \
                             Security > Local Network, then reload.
                             """ + "\n")
                return
            }
            sendHTMLResponse(to: inbound, status: "502 Bad Gateway",
                             html: Self.localNetworkDeniedPage(host: host, route: target))
        case .mailboxUnavailable:
            guard wantsHTML else {
                sendResponse(to: inbound, status: "502 Bad Gateway",
                             contentType: "text/plain; charset=utf-8",
                             body: "The mailbox container for \(name) is not running.\n")
                return
            }
            sendHTMLResponse(to: inbound, status: "502 Bad Gateway",
                             html: Self.mailboxUnavailablePage(host: host, route: target))
        case .stopped:
            guard wantsHTML else {
                sendResponse(to: inbound, status: "502 Bad Gateway",
                             contentType: "text/plain; charset=utf-8",
                             body: "\(name) is not running.\n")
                return
            }
            sendHTMLResponse(to: inbound, status: "502 Bad Gateway",
                             html: Self.stoppedSitePage(host: host, route: target))
        }
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
          a { color: #0071e3; }
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
            a { color: #6cb4ff; }
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

    /// The wp container IS running but nothing answered on either upstream
    /// (issue #16). Distinct from the stopped page on purpose: telling somebody to
    /// start a site that is already started sends them in the wrong direction, and
    /// this is NOT a wake case — `container run` against an existing name just
    /// fails.
    ///
    /// It DOES refresh, on a slower 5s cadence than the waking page. The reasons
    /// this page appears are mostly self-clearing — a heavy codebase's cold-opcache
    /// first request, apache restarting, a request storm — and a page that recovers
    /// by itself beats one that strands the user on instructions they didn't need.
    /// The slower interval keeps it from hammering an instance already in trouble.
    static func unresponsivePage(host: String, route: Route) -> String {
        let name = htmlEscape(route.displayName ?? route.slug ?? host)
        var body = "<p><code>\(htmlEscape(hostOnly(host)))</code> is running, but its web server didn’t answer.</p>"
        body += "<p>WordPress may still be warming up after a start, or PHP/Apache may have stopped responding.</p>"
        if let slug = route.slug {
            body += """
            <p>This page retries every 5 seconds. If it doesn’t clear, look at the logs:</p>
            <pre><code>container logs wpc-\(htmlEscape(slug))-wp</code></pre>
            <p class="hint">If it stays unresponsive: <code>wp-container stop \(htmlEscape(slug)) &amp;&amp; wp-container start \(htmlEscape(slug))</code>.</p>
            """
        }
        return proxyPage(title: "\(name) isn’t responding — WP Container",
                         heading: "\(name) isn’t responding",
                         bodyHTML: body, refreshSeconds: 5)
    }

    /// Deep link to System Settings → Privacy & Security → Local Network. Shared
    /// with the app's warning banner so both routes to the fix land in one place.
    public static let localNetworkSettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"

    /// macOS is refusing this app's connections to the container network, so every
    /// container is unreachable no matter what state it is in (v0.2.0 regression:
    /// the app shipped without `NSLocalNetworkUsageDescription`, and a denied app
    /// never even gets the permission prompt).
    ///
    /// Refreshes every 5s so granting access in System Settings clears the page on
    /// its own — the grant takes effect immediately and the very next dial
    /// succeeds, which also clears the proxy's latch.
    static func localNetworkDeniedPage(host: String, route: Route) -> String {
        let name = htmlEscape(route.displayName ?? route.slug ?? host)
        var body = """
        <p>macOS is blocking WP Container from reaching your local containers, so it can’t serve
        <code>\(htmlEscape(hostOnly(host)))</code>. \(name) itself is fine.</p>
        <p>To fix it, allow WP Container on the local network:</p>
        <p><a href="\(localNetworkSettingsURL)">Open System Settings → Privacy &amp; Security → Local Network</a>,
        turn <strong>WP Container</strong> on, then reload this page.</p>
        """
        body += "<p class=\"hint\">This page reloads every 5 seconds and will show the site as soon as access is granted.</p>"
        return proxyPage(title: "WP Container needs Local Network access",
                         heading: "WP Container needs Local Network access",
                         bodyHTML: body, refreshSeconds: 5,
                         badge: "WP CONTAINER · BLOCKED")
    }

    /// A `<slug>-mail.localhost` route whose site is up but whose Mailpit
    /// container isn't (issue #10 + #16). Deliberately not a wake: the mailbox is a
    /// sidecar, and nothing about an unreachable inbox implies WordPress should be
    /// started or restarted behind the user's back.
    static func mailboxUnavailablePage(host: String, route: Route) -> String {
        let name = htmlEscape(route.displayName ?? route.slug ?? host)
        var body = "<p>The site is running, but its Mailpit container isn’t — so there’s no mailbox to show.</p>"
        if let slug = route.slug {
            body += """
            <p>Mailpit launches with the site, so it needs a restart to come up:</p>
            <pre><code>wp-container stop \(htmlEscape(slug)) &amp;&amp; wp-container start \(htmlEscape(slug))</code></pre>
            <p class="hint">If Mailpit is switched off for this site, turn it on first: <code>wp-container mailpit on \(htmlEscape(slug))</code>.</p>
            """
        }
        return proxyPage(title: "\(name) is unavailable — WP Container",
                         heading: "Mailbox unavailable",
                         bodyHTML: body, refreshSeconds: nil)
    }

    /// Hostname without any `:port` suffix.
    private static func hostOnly(_ host: String) -> String {
        host.split(separator: ":").first.map(String.init) ?? host
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
