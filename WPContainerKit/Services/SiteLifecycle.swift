import Foundation
import Network

public enum LifecycleError: Error, Sendable, CustomStringConvertible {
    case databaseNotReady
    case databaseIPUnavailable
    /// The HTTP readiness probe timed out. `observed` says what the probe saw
    /// the whole time (e.g. "the port never accepted a connection" vs "kept
    /// failing with …") so the failure is self-diagnosing.
    case httpNotReady(observed: String)
    case elasticsearchNotReady
    case elasticsearchIPUnavailable
    case mailpitIPUnavailable

    public var description: String {
        switch self {
        case .databaseNotReady:    return "The database container did not become ready in time."
        case .databaseIPUnavailable: return "Could not resolve the database container's IP address."
        case .httpNotReady(let observed):
            return "WordPress did not start responding over HTTP in time (\(observed))."
        case .elasticsearchNotReady: return "The Elasticsearch container did not become ready in time."
        case .elasticsearchIPUnavailable: return "Could not resolve the Elasticsearch container's IP address."
        case .mailpitIPUnavailable: return "Could not resolve the Mailpit container's IP address."
        }
    }
}

/// Orchestrates the container lifecycle for any `RunnableInstance` (a site or a
/// worktree env) through ONE shared start/stop code path, and publishes status
/// transitions on an `AsyncStream` so view models / callers can observe them.
///
/// Start pipeline (issue #9): the db and es containers (and the Xdebug derived-
/// image check) launch CONCURRENTLY, and the wp container is gated only on the
/// db/es IPs being assigned — never on db/es READINESS. WordPress's PHP retries
/// the DB connection on every request, so apache serving before mariadb
/// finishes InnoDB init is harmless; the only paths that genuinely need the DB
/// up are one-shot wp-cli invocations (first-run provisioning, multisite
/// install, worktree URL fixes/DB import), which gate explicitly via
/// `waitForDatabaseReady`.
///
/// Re-entrancy (issue #5): an actor-held `Set<UUID>` deduplicates lifecycle
/// actions per instance. While a start/stop for an instance is in flight, any
/// conflicting action for the same instance is IGNORED (the UI already
/// disables controls in transitional states; this closes the click-before-
/// state-flips race and CLI/menu-bar spam). The guard is claimed and released
/// inside the same actor-isolated call, and every release sits in a `defer`,
/// so cancellation (ProcessRunner propagates it) always clears the guard.
public actor SiteLifecycle {
    public struct StatusEvent: Sendable {
        public let instanceID: UUID
        public let status: SiteStatus
    }

    private let cli: ContainerCLI
    private let xdebug: XdebugImageService

    /// Instances with a lifecycle action currently in flight (issue #5).
    private var inFlight: Set<UUID> = []

    /// Immutable Sendable stream — readable from any context without `await`.
    public nonisolated let events: AsyncStream<StatusEvent>
    private let continuation: AsyncStream<StatusEvent>.Continuation

    public init(cli: ContainerCLI) {
        self.cli = cli
        self.xdebug = XdebugImageService(cli: cli)
        var cont: AsyncStream<StatusEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { cont = $0 }
        self.continuation = cont
    }

    private func emit(_ id: UUID, _ status: SiteStatus) {
        continuation.yield(StatusEvent(instanceID: id, status: status))
    }

    public func markRunning(_ id: UUID) { emit(id, .running) }

    // MARK: - In-flight guard (issue #5)

    /// Claim the instance for a lifecycle action. False ⇒ another action is
    /// already in flight and the caller must no-op. Synchronous on the actor,
    /// so two racing calls can never both claim.
    private func claim(_ id: UUID) -> Bool { inFlight.insert(id).inserted }

    private func release(_ id: UUID) { inFlight.remove(id) }

    /// Whether a lifecycle action for the instance is currently in flight.
    public func isBusy(_ id: UUID) -> Bool { inFlight.contains(id) }

    // MARK: - Shared start path

    /// Ensure folders, pull images, launch db (+ es / xdebug prep) in parallel,
    /// start WP as soon as the IPs are assigned, and poll HTTP. Returns the
    /// resolved DB host IP. Emits `.starting` up front and `.error` on failure
    /// (then rethrows). Does NOT emit `.running` — callers do that after any
    /// post-start provisioning.
    ///
    /// UNGUARDED primitive: `WorktreeEnvService.create` drives it directly for
    /// a brand-new env (fresh UUID, nothing to dedupe against, and markRunning
    /// must wait for the URL fixes). UI/CLI actions go through the guarded
    /// wrappers (`startSite`, `startInstance`, `startSiteWithEnvs`).
    @discardableResult
    public func startContainers(_ inst: any RunnableInstance) async throws -> String {
        let timer = PhaseTimer(inst.containerSlug)
        emit(inst.instanceID, .starting)
        do {
            try SiteFolders.ensure(for: inst)
            // PHP overrides folder (50 MB upload limits) — must exist before
            // the wp `container run` bind-mounts it.
            try PHPConfService.ensure(for: inst)
            // Managed runtime PHP handlers (issue #13) live in php/prepend.d,
            // loaded by a single master auto_prepend — never in the project tree.
            // Ensure the loader, keep the always-on magic-login handler current,
            // sync the Mailpit handler to its enabled state, and shed any legacy
            // in-tree mu-plugins left by pre-#13 builds (even when now disabled).
            try PrependService.ensure(for: inst)
            try MagicLoginService.ensureLoginHandler(for: inst)
            if inst.mailpitEnabled {
                try MailpitService.writeHandler(phpConfFolder: inst.phpConfFolder)
            } else {
                MailpitService.removeHandler(phpConfFolder: inst.phpConfFolder)
            }
            MailpitService.cleanupLegacyMuPlugin(wordpressFolder: inst.wordpressFolder)
            RemoteMediaService.cleanupLegacyMuPlugin(wordpressFolder: inst.wordpressFolder,
                                                     phpConfFolder: inst.phpConfFolder)

            // Pull every needed image CONCURRENTLY (issue #9). A pull of an
            // already-present tag is a ~1s registry revalidation; they used to
            // run back-to-back. The wp-cli image rides along here so the first
            // wp-cli use on a php8.4 site pulls wordpress:cli-php8.4 on the
            // same progress path as the base images.
            var images = [SiteRecipe.databaseImage, inst.imageTag, SiteRecipe.cliImage(for: inst)]
            if inst.elasticsearchEnabled { images.append(SiteRecipe.elasticsearchImage) }
            if inst.mailpitEnabled { images.append(SiteRecipe.mailpitImage) }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for image in images {
                    group.addTask { [cli] in try await cli.run(SiteRecipe.pullImageArgs(image)) }
                }
                try await group.waitForAll()
            }
            timer.mark("images")

            // First-ever start: pre-seed WordPress core into the mount (see
            // SiteRecipe.seedWordPressArgs). Gate on the absence of index.php.
            let indexPHP = inst.wordpressFolder.appendingPathComponent("index.php")
            if !FileManager.default.fileExists(atPath: indexPHP.path) {
                try await cli.run(SiteRecipe.seedWordPressArgs(inst))
                timer.mark("seed")
            }

            // Launch the wp container's dependencies CONCURRENTLY (issue #9):
            // db run + IP, es run + IP (no green gate), Xdebug derived image.
            // WP needs only the IP VALUES at `container run` time.
            async let dbAddresses = launchDatabase(inst)
            async let esURL = launchElasticsearch(inst)
            async let mailHost = launchMailpit(inst)
            async let xdebugImage = ensureXdebugImage(inst)

            let (dbHost, gateway) = try await dbAddresses
            let elasticsearchURL = try await esURL
            let mailpitHost = try await mailHost
            let imageOverride = try await xdebugImage
            // Gateway (host address as seen from containers) comes from the
            // same inspect that resolved the DB IP — never hardcoded.
            let xdebugClientHost = inst.xdebugEnabled ? gateway : nil
            timer.mark("deps")

            try await cli.run(SiteRecipe.runWordPressArgs(
                inst, dbHost: dbHost, imageOverride: imageOverride,
                xdebugClientHost: xdebugClientHost, elasticsearchURL: elasticsearchURL,
                mailpitHost: mailpitHost))
            timer.mark("wp-run")
            // Make the site's own hostnames resolvable in-guest (→ host proxy)
            // so WordPress loopbacks work. Best-effort: a failure degrades to
            // the old fail-fast loopback, never blocks the start.
            if let gateway, let hostsArgs = SiteRecipe.injectLoopbackHostsArgs(inst, gateway: gateway) {
                _ = try? await cli.run(hostsArgs)
                timer.mark("loopback-hosts")
            }
            try await waitForHTTP(inst)
            timer.mark("http-ready")
            return dbHost
        } catch {
            emit(inst.instanceID, .error(Self.message(for: error)))
            throw error
        }
    }

    /// Run the DB container and resolve its (IP, gateway) as soon as assigned.
    /// The IP changes on every restart — re-inspect each start, never cache.
    private func launchDatabase(_ inst: any RunnableInstance) async throws -> (ip: String, gateway: String?) {
        try await cli.run(SiteRecipe.runDatabaseArgs(inst))
        var delay = Duration.milliseconds(100)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let record = try await cli.inspect(inst.dbContainerName).first,
               let ip = record.ipAddress, !ip.isEmpty {
                return (ip, record.gatewayAddress)
            }
            try await Task.sleep(for: delay)
            delay = min(delay * 2, .milliseconds(500))
        }
        throw LifecycleError.databaseIPUnavailable
    }

    /// Start the Elasticsearch sidecar (when enabled) and return the
    /// `http://<es-ip>:9200` URL as soon as the IP is assigned (§2c). No green
    /// gate (issue #9): ElasticPress retries, and nothing in the start path
    /// depends on cluster health — a sidecar that fails to boot surfaces via
    /// logs/reconcile, not by holding the whole site start hostage.
    private func launchElasticsearch(_ inst: any RunnableInstance) async throws -> String? {
        guard inst.elasticsearchEnabled else { return nil }
        try FileManager.default.createDirectory(at: inst.elasticsearchFolder, withIntermediateDirectories: true)
        try await cli.run(SiteRecipe.runElasticsearchArgs(inst))
        var delay = Duration.milliseconds(100)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let ip = try await cli.ipAddress(of: inst.esContainerName), !ip.isEmpty {
                return "http://\(ip):9200"
            }
            try await Task.sleep(for: delay)
            delay = min(delay * 2, .milliseconds(500))
        }
        throw LifecycleError.elasticsearchIPUnavailable
    }

    /// Start the Mailpit container (when enabled) and return its IP as soon as
    /// assigned, for `WPC_MAILPIT_HOST` injection into WordPress (issue #10). No
    /// readiness gate (matches ES, issue #9): PHPMailer connects only when mail
    /// is actually sent, long after boot; a mail container that fails surfaces
    /// via logs, not by holding the whole site start hostage. The web UI is
    /// published on the instance's assigned `mailpitPort`.
    private func launchMailpit(_ inst: any RunnableInstance) async throws -> String? {
        guard inst.mailpitEnabled, let webPort = inst.mailpitPort else { return nil }
        try FileManager.default.createDirectory(at: inst.mailpitFolder, withIntermediateDirectories: true)
        try await cli.run(SiteRecipe.runMailpitArgs(inst, webPort: webPort))
        var delay = Duration.milliseconds(100)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let ip = try await cli.ipAddress(of: inst.mailContainerName), !ip.isEmpty {
                return ip
            }
            try await Task.sleep(for: delay)
            delay = min(delay * 2, .milliseconds(500))
        }
        throw LifecycleError.mailpitIPUnavailable
    }

    /// Ensure the Xdebug derived image exists (when enabled). Cached ⇒ ~50ms.
    private func ensureXdebugImage(_ inst: any RunnableInstance) async throws -> String? {
        guard inst.xdebugEnabled else { return nil }
        return try await xdebug.ensureImage(forBaseTag: inst.imageTag)
    }

    /// Guarded start for a single instance (worktree envs, §2b): containers up,
    /// then flip to `.running`. Returns false when another action for the
    /// instance was already in flight (the start was ignored, issue #5).
    @discardableResult
    public func startInstance(_ inst: any RunnableInstance) async throws -> Bool {
        guard claim(inst.instanceID) else { return false }
        defer { release(inst.instanceID) }
        _ = try await startContainers(inst)
        markRunning(inst.instanceID)
        return true
    }

    /// Start a site, provisioning WordPress on first run. Returns the (possibly
    /// updated) `provisioned` flag so the caller can persist it. If another
    /// action for the site is already in flight the start is ignored (issue #5)
    /// and the flag is returned unchanged.
    public func startSite(_ site: Site) async throws -> Bool {
        guard claim(site.id) else { return site.provisioned }
        defer { release(site.id) }
        return try await startSiteCore(site)
    }

    /// Unguarded body of `startSite` — called with the guard already held.
    private func startSiteCore(_ site: Site) async throws -> Bool {
        let dbHost = try await startContainers(site)
        var provisioned = site.provisioned
        if !provisioned {
            do {
                // First-run provisioning is one of the two places that GENUINELY
                // needs the DB accepting connections (issue #9) — wp-cli does
                // not retry. Gate here, not in the shared start path.
                try await waitForDatabaseReady(site, dbHost: dbHost)
                if site.networkType.isMultisite {
                    try await MultisiteService(cli: cli).provision(site, dbHost: dbHost, installURL: site.url)
                } else {
                    try await cli.run(SiteRecipe.wpCoreInstallArgs(site, dbHost: dbHost))
                }
                provisioned = true
            } catch {
                emit(site.id, .error(Self.message(for: error)))
                throw error
            }
        }
        // Ensure the tool's default dev constants exist (idempotent; never
        // overwrites user-changed values) on every start (§2c-bis).
        try? WPConfigService.ensureDevelopmentConstants(wordpressFolder: site.wordpressFolder)
        emit(site.id, .running)
        return provisioned
    }

    // MARK: - Coupled site + env lifecycle (PLAN.md §2b)

    /// Outcome of a coupled start: the parent's provisioned flag, plus any
    /// errors — surfaced individually so one env failing never hides the rest.
    public struct CoupledStartOutcome: Sendable {
        public var provisioned: Bool
        /// Parent site start failure, if any (envs are still attempted).
        public var parentErrorMessage: String?
        /// Per-env failures as "<envSlug>: <message>".
        public var envErrorMessages: [String]

        /// One human-readable summary, or nil when everything started.
        public var errorSummary: String? {
            var parts: [String] = []
            if let parentErrorMessage { parts.append(parentErrorMessage) }
            parts.append(contentsOf: envErrorMessages)
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
    }

    /// Start a site AND all of its worktree envs (coupled lifecycle, §2b) —
    /// CONCURRENTLY (issue #9). Parent and envs share nothing at runtime: each
    /// env runs its own containers on its own port from its own CoW-cloned
    /// `wordpress/` + `database/` folders (see `WorktreeEnvService.create`), so
    /// there is no ordering dependency at all. A parent failure does NOT abort
    /// the env starts; every failure is surfaced individually (status events +
    /// the returned messages). Instances with an action already in flight are
    /// skipped (issue #5). Never throws: callers read `errorSummary`.
    public func startSiteWithEnvs(_ site: Site, envs: [WorktreeEnv]) async -> CoupledStartOutcome {
        var outcome = CoupledStartOutcome(provisioned: site.provisioned, envErrorMessages: [])
        // Claim everything up front, synchronously on the actor (issue #5).
        let startParent = claim(site.id)
        let claimedEnvs = envs.filter { claim($0.id) }
        defer {
            if startParent { release(site.id) }
            for env in claimedEnvs { release(env.id) }
        }

        enum Part: Sendable {
            case parent(provisioned: Bool?, error: String?)
            case env(slug: String, error: String?)
        }
        await withTaskGroup(of: Part.self) { group in
            if startParent {
                group.addTask {
                    do { return .parent(provisioned: try await self.startSiteCore(site), error: nil) }
                    catch { return .parent(provisioned: nil, error: Self.message(for: error)) }
                }
            }
            for env in claimedEnvs {
                group.addTask {
                    do {
                        _ = try await self.startContainers(env)
                        await self.markRunning(env.id)
                        return .env(slug: env.envSlug, error: nil)
                    } catch {
                        return .env(slug: env.envSlug, error: Self.message(for: error))
                    }
                }
            }
            for await part in group {
                switch part {
                case .parent(let provisioned, let error):
                    if let provisioned { outcome.provisioned = provisioned }
                    outcome.parentErrorMessage = error
                case .env(let slug, let error):
                    if let error { outcome.envErrorMessages.append("\(slug): \(error)") }
                }
            }
        }
        return outcome
    }

    /// Stop a site AND all of its worktree envs (coupled lifecycle, §2b),
    /// concurrently. Instances with an action in flight are skipped (issue #5).
    public func stopSiteWithEnvs(_ site: Site, envs: [WorktreeEnv]) async {
        let stopParent = claim(site.id)
        let claimedEnvs = envs.filter { claim($0.id) }
        defer {
            if stopParent { release(site.id) }
            for env in claimedEnvs { release(env.id) }
        }
        await withTaskGroup(of: Void.self) { group in
            if stopParent {
                group.addTask { await self.stopCore(site) }
            }
            for env in claimedEnvs {
                group.addTask { await self.stopCore(env) }
            }
        }
    }

    // MARK: - Stop / delete

    /// Guarded stop: ignored when another action for the instance is already
    /// in flight (issue #5).
    public func stop(_ inst: any RunnableInstance) async {
        guard claim(inst.instanceID) else { return }
        defer { release(inst.instanceID) }
        await stopCore(inst)
    }

    private func stopCore(_ inst: any RunnableInstance) async {
        emit(inst.instanceID, .stopping)
        // Containers run with --rm, so `stop` makes them vanish. The three
        // containers are independent — stop them concurrently (issue #9). The
        // es sidecar is stopped best-effort whether or not the flag is
        // currently set (it may have been toggled off since start).
        await withTaskGroup(of: Void.self) { group in
            for name in [inst.wpContainerName, inst.esContainerName, inst.mailContainerName, inst.dbContainerName] {
                group.addTask { [cli] in _ = try? await cli.run(SiteRecipe.stopArgs(name)) }
            }
        }
        emit(inst.instanceID, .stopped)
    }

    /// Stop + best-effort delete (non --rm leftovers, prior crash, …).
    /// Deliberately UNGUARDED: deletion is a cleanup/rollback surface and must
    /// always proceed (an in-flight start racing a delete fails and surfaces
    /// its own error, exactly as before issue #5).
    public func deleteContainers(_ inst: any RunnableInstance) async {
        await withTaskGroup(of: Void.self) { group in
            for name in [inst.wpContainerName, inst.esContainerName, inst.mailContainerName, inst.dbContainerName] {
                group.addTask { [cli] in
                    _ = try? await cli.run(SiteRecipe.stopArgs(name))
                    _ = try? await cli.run(SiteRecipe.deleteArgs(name))
                }
            }
        }
        emit(inst.instanceID, .stopped)
    }

    // MARK: - Readiness polling

    /// Wait until mariadb accepts TCP connections on `dbHost:3306` — required
    /// ONLY by one-shot wp-cli work (provisioning, multisite install, worktree
    /// URL fixes / DB import), never by the plain start path (issue #9).
    ///
    /// A TCP connect probe is equivalent to `healthcheck.sh --connect` here
    /// (mariadb's first-init temp server runs with networking off, so a
    /// successful connect means the final server is listening) and costs ~0ms
    /// per probe vs ~300ms for a `container exec`. Container IPs are
    /// host-reachable on Apple `container` (same fact the ES health poll used).
    /// Poll: 200ms initial, ×2 backoff capped at 1s.
    public func waitForDatabaseReady(_ inst: any RunnableInstance, dbHost: String,
                                     timeout: Duration = .seconds(90)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var delay = Duration.milliseconds(200)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if await Self.tcpProbe(host: dbHost, port: 3306, timeout: .seconds(2)) { return }
            try await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(1))
        }
        throw LifecycleError.databaseNotReady
    }

    /// One TCP connect attempt. True ⇒ the port accepted a connection.
    private static func tcpProbe(host: String, port: UInt16, timeout: Duration) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let once = ResumeOnce()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { cont.resume(returning: true) }
                    connection.cancel()
                case .failed, .cancelled:
                    if once.claim() { cont.resume(returning: false) }
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            // Per-attempt timeout: cancel the connection; the .cancelled state
            // resumes the continuation (via the once-guard) if nothing else has.
            let seconds = Double(timeout.components.seconds)
                + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                connection.cancel()
            }
        }
    }

    /// Guards a checked continuation against double-resume from the racing
    /// NWConnection state callbacks.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    /// Wait until the container's web server answers on 127.0.0.1:<port>.
    ///
    /// The probe's ONLY job is detecting that apache/php is up, so ANY HTTP
    /// response counts — 200, 3xx, even 500. Crucially it must NOT follow
    /// redirects: an HTTPS + custom-domain site answers the very first probe
    /// with a canonical 301 to e.g. `https://democrats.local`, and following it
    /// (URLSession's default) dead-ends when the reverse proxy isn't listening
    /// or the /etc/hosts entry is absent — misreading a perfectly healthy site
    /// as unresponsive until timeout (user-reported bug). Readiness must never
    /// depend on proxy or hosts resolution.
    ///
    /// Poll: 200ms initial, ×2 backoff capped at 1s (issue #9) — a warm apache
    /// answers in well under a second, and the old flat 2s sleep alone could
    /// add up to 2s of pure perceived latency.
    private func waitForHTTP(_ inst: any RunnableInstance, timeout: Duration = .seconds(120)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var request = URLRequest(url: inst.localURL)
        request.timeoutInterval = 5
        request.httpMethod = "HEAD"
        // What the probe saw, for a self-diagnosing timeout message. Heavy
        // codebases can take many seconds for the FIRST request (cold opcache,
        // plugin warmup) — that shows up as "accepted the connection but hasn't
        // answered", distinct from "port never accepted a connection".
        var observed = "the port never accepted a connection"
        var delay = Duration.milliseconds(200)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            do {
                let (_, response) = try await Self.probeSession.data(for: request)
                if response is HTTPURLResponse {
                    // Any status — including the canonical 301 — proves the
                    // web server is responding. Done.
                    return
                }
                observed = "got a non-HTTP response"
            } catch let error as URLError {
                switch error.code {
                case .cannotConnectToHost, .networkConnectionLost:
                    observed = "the port never accepted a connection"
                case .timedOut:
                    observed = "the connection was accepted but no response arrived within 5s (site may be warming up)"
                default:
                    observed = "kept failing with: \(error.localizedDescription)"
                }
            } catch {
                observed = "kept failing with: \(error.localizedDescription)"
            }
            try await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(1))
        }
        throw LifecycleError.httpNotReady(observed: observed)
    }

    /// URLSession that REFUSES to follow redirects (see `waitForHTTP`), with
    /// its own cookie/cache-free configuration.
    private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil // Surface the 3xx itself instead of chasing it.
        }
    }

    static func message(for error: Error) -> String {
        if let e = error as? ContainerCLIError { return e.description }
        if let e = error as? LifecycleError { return e.description }
        return "\(error)"
    }
}
