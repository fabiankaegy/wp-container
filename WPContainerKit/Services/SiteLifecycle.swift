import Foundation
import Network
import OSLog

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
    /// A shared-database env was started without its parent's descriptor while
    /// the parent's DB container wasn't already up, so there is nothing to
    /// connect to and nothing that may legitimately start it (issue #17).
    case sharedDatabaseUnavailable(container: String)

    public var description: String {
        switch self {
        case .databaseNotReady:    return "The database container did not become ready in time."
        case .databaseIPUnavailable: return "Could not resolve the database container's IP address."
        case .httpNotReady(let observed):
            return "WordPress did not start responding over HTTP in time (\(observed))."
        case .elasticsearchNotReady: return "The Elasticsearch container did not become ready in time."
        case .elasticsearchIPUnavailable: return "Could not resolve the Elasticsearch container's IP address."
        case .mailpitIPUnavailable: return "Could not resolve the Mailpit container's IP address."
        case .sharedDatabaseUnavailable(let name):
            return "This environment shares its parent site's database container (\(name)), which is not running — start the parent site first."
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
    /// Shared across every caller in the process — parent site, every env,
    /// `WorktreeEnvService.create` — so image-pull dedupe spans the whole
    /// coupled start, not just one instance (issue #18).
    private let images: ImagePullService

    /// Instances with a lifecycle action currently in flight (issue #5).
    private var inFlight: Set<UUID> = []

    /// In-flight DB-container boots keyed by CONTAINER NAME (issue #17), so a
    /// coupled start of a parent site plus N shared-database envs issues exactly
    /// one `container run` for the one server they share. See
    /// `ensureDatabaseContainer`.
    private var dbBoots: [String: Task<Void, Error>] = [:]

    /// Outstanding claims on a DB container by CONTAINER NAME (issue #17).
    ///
    /// Everything that decides whether a shared DB container is still needed reads
    /// `container list`, which can only see instances that already HAVE a wp
    /// container. An instance still inside its start pipeline (image ensure, core
    /// seed, `container run`) or a worktree env being created is invisible there,
    /// and stopping the server under it fails the operation outright. A lease
    /// makes that in-flight work visible.
    ///
    /// In-PROCESS only. A second `wp-container` process starting an env while this
    /// one retires the server remains theoretically racy; that would need a
    /// cross-process lock and is deliberately not attempted.
    private var dbLeases: [String: Int] = [:]

    /// Image-pull fallback warnings recorded per instance (issue #18) — e.g. a
    /// pull that failed but degraded to a local image. Drained by callers that
    /// want to surface them (never thrown; these are not failures).
    private var pendingWarnings: [UUID: [String]] = [:]

    /// Immutable Sendable stream — readable from any context without `await`.
    public nonisolated let events: AsyncStream<StatusEvent>
    private let continuation: AsyncStream<StatusEvent>.Continuation

    public init(cli: ContainerCLI) {
        self.cli = cli
        self.xdebug = XdebugImageService(cli: cli)
        self.images = ImagePullService(cli: cli)
        var cont: AsyncStream<StatusEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { cont = $0 }
        self.continuation = cont
    }

    /// Record non-fatal warnings against an instance, for a caller to `drain`
    /// and surface however suits its layer. Used for image-pull fallbacks
    /// (issue #18) and the shared-database safety fallback (issue #17).
    public func recordWarnings(_ new: [String], for id: UUID) {
        guard !new.isEmpty else { return }
        pendingWarnings[id, default: []].append(contentsOf: new)
    }

    /// Drain and clear any warnings recorded for the instance since the last
    /// drain (image-pull fallbacks, etc.). Callers surface these to the user
    /// however is appropriate for their layer (stderr, MCP payload, …).
    public func drainWarnings(for id: UUID) -> [String] {
        pendingWarnings.removeValue(forKey: id) ?? []
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

    // MARK: - Database container leases (issue #17)

    /// Claim the named DB container for work in progress. MUST be paired with
    /// `releaseDatabaseLease` on every exit path. `WorktreeEnvService.create`
    /// holds one across its whole shared-database critical section; every
    /// `startContainers` holds one for its duration.
    public func acquireDatabaseLease(_ name: String) {
        dbLeases[name, default: 0] += 1
    }

    public func releaseDatabaseLease(_ name: String) {
        guard let count = dbLeases[name] else { return }
        if count <= 1 { dbLeases.removeValue(forKey: name) } else { dbLeases[name] = count - 1 }
    }

    /// Whether anything in this process is currently relying on the named DB
    /// container. Nothing may stop it while true.
    public func isDatabaseLeased(_ name: String) -> Bool { (dbLeases[name] ?? 0) > 0 }

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
    ///
    /// - Parameter dbProvider: the instance that OWNS the DB container `inst`
    ///   borrows — i.e. the parent site of a shared-database env (issue #17).
    ///   Required whenever `!inst.ownsDatabaseContainer` and that container is
    ///   not already up; ignored otherwise.
    @discardableResult
    public func startContainers(_ inst: any RunnableInstance, pullPolicy: PullPolicy = .ifMissing,
                                dbProvider: (any RunnableInstance)? = nil) async throws -> String {
        let timer = PhaseTimer(inst.containerSlug)
        emit(inst.instanceID, .starting)
        // Nothing may retire this DB container while we're mid-start (issue #17):
        // until the `container run` below lands there is no wp container for
        // `container list` to see, so a concurrent env stop would otherwise
        // conclude the server is unused and pull it out from under us.
        acquireDatabaseLease(inst.dbContainerName)
        defer { releaseDatabaseLease(inst.dbContainerName) }
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

            // Ensure every needed image is present CONCURRENTLY (issue #9),
            // routed through the shared `ImagePullService` (issue #18): it
            // dedupes in-flight pulls per tag across the whole process and
            // short-circuits to zero network when the tag is already local
            // under `.ifMissing`. `startSiteWithEnvs` pre-resolves the site's
            // whole image set before the env fan-out even starts, so in the
            // common coupled-start case every call here is a cache hit. The
            // wp-cli image rides along here so the first wp-cli use on a
            // php8.4 site pulls wordpress:cli-php8.4 on the same path as the
            // base images.
            var imageTags = [SiteRecipe.databaseImage, inst.imageTag, SiteRecipe.cliImage(for: inst)]
            if inst.elasticsearchEnabled { imageTags.append(SiteRecipe.elasticsearchImage) }
            if inst.mailpitEnabled { imageTags.append(SiteRecipe.mailpitImage) }
            var imageWarnings: [String] = []
            try await withThrowingTaskGroup(of: String?.self) { group in
                for tag in imageTags {
                    group.addTask { [images] in try await images.ensure(tag, policy: pullPolicy) }
                }
                for try await warning in group {
                    if let warning { imageWarnings.append(warning) }
                }
            }
            recordWarnings(imageWarnings, for: inst.instanceID)
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
            async let dbAddresses = launchDatabase(inst, provider: dbProvider)
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

    /// Resolve the (IP, gateway) of the DB container this instance talks to,
    /// starting it first when the instance owns it. The IP changes on every
    /// restart — re-inspect each start, never cache.
    ///
    /// Shared-database env (issue #17): there is no `container run` for the env
    /// at all. If the parent's container is already up we just read its address;
    /// if it isn't, we boot it from the PROVIDER's descriptor (its name, data
    /// folder, labels and caps) — so starting one env of a stopped site boots a
    /// single DB VM that every sibling env then shares.
    private func launchDatabase(_ inst: any RunnableInstance,
                                provider: (any RunnableInstance)?) async throws -> (ip: String, gateway: String?) {
        // Whoever may legitimately `container run` this name: the instance
        // itself, or the parent site it borrows the container from.
        let owner: (any RunnableInstance)?
        if inst.ownsDatabaseContainer {
            owner = inst
        } else if let provider, provider.dbContainerName == inst.dbContainerName,
                  provider.ownsDatabaseContainer {
            owner = provider
        } else {
            owner = nil
        }
        try await ensureDatabaseContainer(named: inst.dbContainerName, owner: owner)
        return try await databaseAddresses(named: inst.dbContainerName)
    }

    /// Poll a DB container's (IP, gateway) until assigned (15s deadline).
    private func databaseAddresses(named name: String) async throws -> (ip: String, gateway: String?) {
        var delay = Duration.milliseconds(100)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let record = try await cli.inspect(name).first,
               let ip = record.ipAddress, !ip.isEmpty {
                return (ip, record.gatewayAddress)
            }
            try await Task.sleep(for: delay)
            delay = min(delay * 2, .milliseconds(500))
        }
        throw LifecycleError.databaseIPUnavailable
    }

    /// Boot the DB container OWNED by `owner` if it isn't already up, and return
    /// its IP once the server accepts connections.
    ///
    /// Lets `WorktreeEnvService` create and seed a shared env's schema (issue
    /// #17) BEFORE the env's own wp container starts, so the env is never served
    /// from an empty database. Idempotent, and deduped against the concurrent
    /// boots a coupled start issues.
    public func prepareDatabaseHost(owner: any RunnableInstance) async throws -> String {
        _ = try? await images.ensure(SiteRecipe.databaseImage, policy: .ifMissing)
        try await ensureDatabaseContainer(named: owner.dbContainerName, owner: owner)
        let (ip, _) = try await databaseAddresses(named: owner.dbContainerName)
        try await waitForDatabaseReady(owner, dbHost: ip)
        return ip
    }

    /// Boot the named DB container if it isn't already running, at most ONCE per
    /// name process-wide.
    ///
    /// Shared databases (issue #17) turn a coupled start into N+1 instances all
    /// wanting the SAME `wpc-<parent>-db` up: without dedupe the parent and its
    /// envs race on `container run --name`, and every loser fails the whole
    /// instance start. The in-flight `Task` map collapses them onto one boot; a
    /// container that already exists but is not running (a crash left it behind)
    /// is deleted and recreated rather than waited on forever.
    ///
    /// `owner` is nil when nobody present may create it — a shared-database env
    /// started without its parent's descriptor. That's only fatal if the
    /// container isn't already up.
    private func ensureDatabaseContainer(named name: String, owner: (any RunnableInstance)?) async throws {
        if let inFlight = dbBoots[name] { return try await inFlight.value }
        let task = Task<Void, Error> { [cli] in
            let existing = try await cli.inspect(name).first
            if let existing, existing.isRunning { return }
            guard let owner else { throw LifecycleError.sharedDatabaseUnavailable(container: name) }
            if existing != nil { _ = try? await cli.run(SiteRecipe.deleteArgs(name)) }
            try SiteFolders.ensure(for: owner)
            try await cli.run(SiteRecipe.runDatabaseArgs(owner))
        }
        dbBoots[name] = task
        defer { dbBoots[name] = nil }
        try await task.value
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
    ///
    /// Pass `dbProvider` (the parent site) when starting a shared-database env
    /// (issue #17) so its DB container can be booted if the parent is down.
    @discardableResult
    public func startInstance(_ inst: any RunnableInstance, pullPolicy: PullPolicy = .ifMissing,
                              dbProvider: (any RunnableInstance)? = nil) async throws -> Bool {
        guard claim(inst.instanceID) else { return false }
        defer { release(inst.instanceID) }
        _ = try await startContainers(inst, pullPolicy: pullPolicy, dbProvider: dbProvider)
        markRunning(inst.instanceID)
        return true
    }

    /// Start a site, provisioning WordPress on first run. Returns the (possibly
    /// updated) `provisioned` flag so the caller can persist it. If another
    /// action for the site is already in flight the start is ignored (issue #5)
    /// and the flag is returned unchanged.
    public func startSite(_ site: Site, pullPolicy: PullPolicy = .ifMissing) async throws -> Bool {
        guard claim(site.id) else { return site.provisioned }
        defer { release(site.id) }
        return try await startSiteCore(site, pullPolicy: pullPolicy)
    }

    /// Unguarded body of `startSite` — called with the guard already held.
    private func startSiteCore(_ site: Site, pullPolicy: PullPolicy = .ifMissing) async throws -> Bool {
        let dbHost = try await startContainers(site, pullPolicy: pullPolicy)
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
        /// Non-fatal warnings (issue #18) — e.g. an image pull that failed but
        /// fell back to a local copy. Never affects `errorSummary`.
        public var warnings: [String] = []

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
    ///
    /// Pass `envs: []` to start only the parent (the CLI/MCP/app default since
    /// issue #18 — env fan-out is opt-in via `--with-envs`/`with_envs`).
    ///
    /// Before the fan-out, every DISTINCT image tag needed by the parent + all
    /// envs is resolved exactly once up front (issue #18) via the shared
    /// `ImagePullService` — the per-instance `ensure` calls inside
    /// `startContainers` below then hit the local-image cache with zero
    /// network, so an N-env cold-cache start still issues exactly one pull per
    /// distinct tag instead of one per (tag × instance).
    public func startSiteWithEnvs(_ site: Site, envs: [WorktreeEnv],
                                  pullPolicy: PullPolicy = .ifMissing) async -> CoupledStartOutcome {
        var outcome = CoupledStartOutcome(provisioned: site.provisioned, envErrorMessages: [])

        var neededImages: Set<String> = []
        func collectImages(_ inst: any RunnableInstance) {
            neededImages.insert(SiteRecipe.databaseImage)
            neededImages.insert(inst.imageTag)
            neededImages.insert(SiteRecipe.cliImage(for: inst))
            if inst.elasticsearchEnabled { neededImages.insert(SiteRecipe.elasticsearchImage) }
            if inst.mailpitEnabled { neededImages.insert(SiteRecipe.mailpitImage) }
        }
        collectImages(site)
        for env in envs { collectImages(env) }
        for tag in neededImages {
            // Hard failures (e.g. `.never` with a missing image) are swallowed
            // here — they surface properly per-instance below, when
            // `startContainers`'s own `ensure` call retries and throws for
            // real, attributing the failure to whichever instance(s) need it.
            if let warning = try? await images.ensure(tag, policy: pullPolicy) {
                outcome.warnings.append(warning)
            }
        }

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
                    do { return .parent(provisioned: try await self.startSiteCore(site, pullPolicy: pullPolicy), error: nil) }
                    catch { return .parent(provisioned: nil, error: Self.message(for: error)) }
                }
            }
            for env in claimedEnvs {
                group.addTask {
                    do {
                        // `dbProvider: site` — a shared-database env borrows the
                        // parent's DB container and may need it booted (#17).
                        _ = try await self.startContainers(env, pullPolicy: pullPolicy, dbProvider: site)
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
        if startParent { outcome.warnings.append(contentsOf: drainWarnings(for: site.id)) }
        for env in claimedEnvs { outcome.warnings.append(contentsOf: drainWarnings(for: env.id)) }
        return outcome
    }

    /// Stop a site AND all of its worktree envs (coupled lifecycle, §2b).
    /// Instances with an action in flight are skipped (issue #5).
    ///
    /// The envs go down first (concurrently among themselves), THEN the parent.
    /// Ordering matters since issue #17: the parent's `stopCore` refuses to stop
    /// a DB container a live env is still borrowing, so stopping them at the same
    /// time would race and could leave the server running.
    ///
    /// `verifyTeardown: false` skips the post-stop verify/escalate pass — used by
    /// the app's quit path, which stops every instance at once and must not add
    /// N × a few seconds of polling to the time the Dock icon keeps bouncing.
    public func stopSiteWithEnvs(_ site: Site, envs: [WorktreeEnv],
                                 verifyTeardown: Bool = true) async {
        let stopParent = claim(site.id)
        let claimedEnvs = envs.filter { claim($0.id) }
        defer {
            if stopParent { release(site.id) }
            for env in claimedEnvs { release(env.id) }
        }
        await withTaskGroup(of: Void.self) { group in
            for env in claimedEnvs {
                group.addTask { await self.stopCore(env, verify: verifyTeardown) }
            }
        }
        if stopParent { await stopCore(site, verify: verifyTeardown) }
    }

    // MARK: - Stop / delete

    /// Guarded stop. Returns false when another action for the instance was
    /// already in flight, in which case NOTHING happened (issue #5) — callers that
    /// arm state around a stop (the proxy's notification suppression) must key off
    /// this rather than assume the stop ran.
    ///
    /// `beforeStopping` runs after the claim succeeds and before any container is
    /// touched, i.e. only on the path that genuinely proceeds. That ordering is the
    /// whole point: it lets a caller prepare for the `.stopping`/`.stopped` events
    /// with no window in which they could arrive first.
    @discardableResult
    public func stop(_ inst: any RunnableInstance, verifyTeardown: Bool = true,
                     beforeStopping: (@Sendable () async -> Void)? = nil) async -> Bool {
        guard claim(inst.instanceID) else { return false }
        defer { release(inst.instanceID) }
        await beforeStopping?()
        await stopCore(inst, verify: verifyTeardown)
        return true
    }

    private func stopCore(_ inst: any RunnableInstance, verify: Bool = true) async {
        emit(inst.instanceID, .stopping)
        // Containers run with --rm, so `stop` SHOULD make them vanish — but
        // issue #16 caught one reported `stopped` by `container ls` whose shim
        // and `com.apple.Virtualization.VirtualMachine` xpc process were still
        // alive holding ~219 MB. So the stop is no longer assumed: it is
        // verified, escalated to `container delete`, and anything that survives
        // both is surfaced rather than swallowed (see `verifyTeardown`).
        //
        // The containers are independent — stop them concurrently (issue #9).
        // The es sidecar is stopped best-effort whether or not the flag is
        // currently set (it may have been toggled off since start).
        var names = Self.ownedContainerNames(of: inst)
        // Restarting a parent site (an Xdebug/Mailpit/domain/HTTPS toggle,
        // `site_restart`) must not bounce the DB container out from under a
        // live shared-database env (issue #17): the env's wp container had the
        // old DB IP baked in at `container run` time and cannot pick up a new
        // one. `stopSiteWithEnvs` stops envs BEFORE the parent, so a genuine
        // whole-family stop still takes the server down.
        if inst.ownsDatabaseContainer {
            // `||` can't short-circuit across an `await`, so spell it out: the
            // lease check is free, the container listing is not.
            var keepDatabase = isDatabaseLeased(inst.dbContainerName)
            if !keepDatabase { keepDatabase = await hasRunningSharedDatabaseDependents(inst) }
            if keepDatabase { names.removeAll { $0 == inst.dbContainerName } }
        }
        var problems: [String] = []
        await withTaskGroup(of: String?.self) { group in
            for name in names {
                group.addTask { [cli] in
                    do {
                        _ = try await cli.run(SiteRecipe.stopArgs(name))
                        return nil
                    } catch {
                        // "No such container" is the normal case for a sidecar
                        // that was never started (es/mail toggled off), NOT a
                        // failure — everything else is worth reporting.
                        guard !Self.isMissingContainerError(error) else { return nil }
                        return "`container stop \(name)` failed: \(Self.message(for: error))"
                    }
                }
            }
            for await problem in group {
                if let problem { problems.append(problem) }
            }
        }
        if verify { problems.append(contentsOf: await verifyTeardown(of: names)) }
        if !problems.isEmpty {
            for problem in problems { Self.log.error("stop: \(problem, privacy: .public)") }
            recordWarnings(problems, for: inst.instanceID)
        }
        // Emitted only after the verify/escalate pass, so a caller that restarts
        // (addon toggles, `site_restart`) genuinely waits for teardown instead of
        // racing a half-dead VM for the container name.
        emit(inst.instanceID, .stopped)
    }

    /// Confirm the named containers are really gone, escalating anything that
    /// lingers to `container delete`, and describe whatever survives both.
    ///
    /// Why this exists (issue #16): `container stop` returning 0 is not proof of
    /// teardown. A container was observed sitting in `container list --all` as
    /// `stopped` while its shim and `com.apple.Virtualization.VirtualMachine`
    /// process stayed alive holding ~219 MB — precisely the memory the idle-stop
    /// work is trying to reclaim. `container delete` is the only path that
    /// reliably reaps that record (it is what `deleteContainers` always did).
    ///
    /// Bounded on purpose: `--rm` teardown is normally sub-second, so the poll
    /// gives it ~5s before escalating and ~2s after, and never blocks a stop for
    /// longer than that. Listing failures are treated as "cannot tell" — we do
    /// NOT invent a survivor, because a spurious `container delete` of a
    /// perfectly healthy neighbour would be far worse than a missed warning.
    ///
    /// Only a name that lingers in a NON-running state is escalated. A name that
    /// is back to `running` was re-created by somebody else between our stop and
    /// our poll — another `wp-container` process, an MCP `site_start`, a wake —
    /// and deleting it would kill a container we no longer own, then tell the user
    /// to force-delete a perfectly healthy environment. There is no IPC to
    /// arbitrate that, so the only correct move is to leave it alone silently: the
    /// stop we were asked for did happen, and what exists now is somebody else's.
    private func verifyTeardown(of names: [String]) async -> [String] {
        guard !names.isEmpty else { return [] }
        let lingering = await Self.pollUntilGone(names, cli: cli, deadline: .seconds(5))
        guard !lingering.isEmpty else { return [] }
        var escalated: [String] = []
        for record in lingering {
            guard !record.isRunning else {
                Self.log.info("stop: \(record.name, privacy: .public) is running again — concurrently restarted by another process, leaving it alone")
                continue
            }
            Self.log.warning("stop: \(record.name, privacy: .public) still present (\(record.status, privacy: .public)) after `container stop` — escalating to `container delete`")
            _ = try? await cli.run(SiteRecipe.deleteArgs(record.name))
            escalated.append(record.name)
        }
        guard !escalated.isEmpty else { return [] }
        // Re-check the escalated ones only, and again ignore any that came back
        // running in the meantime.
        let survivors = await Self.pollUntilGone(escalated, cli: cli, deadline: .seconds(2))
        return survivors.filter { !$0.isRunning }.map {
            "\($0.name) survived both `container stop` and `container delete` — its VM process may still be holding memory. Check `container list --all` and, if it is still there, `container delete --force \($0.name)`."
        }
    }

    /// Poll `container list --all` until none of `names` is listed any more, and
    /// return the RECORDS still there when the deadline passes (empty ⇒ all gone).
    ///
    /// Records rather than names because the caller must distinguish "stopped but
    /// not reaped" (the leak worth escalating) from "running again" (somebody
    /// else's container, hands off). Sorted by name so output is deterministic.
    private static func pollUntilGone(_ names: [String], cli: ContainerCLI,
                                      deadline: Duration) async -> [ContainerRecord] {
        let wanted = Set(names)
        let end = ContinuousClock.now.advanced(by: deadline)
        var present: [ContainerRecord] = []
        while true {
            guard let records = try? await cli.list(all: true) else { return [] } // cannot tell
            present = records.filter { wanted.contains($0.name) }
            if present.isEmpty || ContinuousClock.now >= end { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return present.sorted { $0.name < $1.name }
    }

    /// Whether a failed `container stop`/`delete` merely means the container was
    /// not there — the expected outcome for a sidecar that never ran.
    private static func isMissingContainerError(_ error: Error) -> Bool {
        guard let e = error as? ContainerCLIError else { return false }
        let text = (e.stderr + " " + e.stdout).lowercased()
        return text.contains("not found") || text.contains("no such")
            || text.contains("does not exist")
    }

    private static let log = Logger(subsystem: "com.fabiankaegy.wpcontainer", category: "lifecycle")

    /// Every container this instance may stop or delete. A shared-database env
    /// (issue #17) is deliberately EXCLUDED from its DB container: that server
    /// belongs to the parent site and to every sibling env, so tearing it down
    /// from an env would take them all offline. See
    /// `stopSharedDatabaseIfUnused` for the counterpart that does retire it once
    /// nothing needs it.
    private static func ownedContainerNames(of inst: any RunnableInstance) -> [String] {
        var names = [inst.wpContainerName, inst.esContainerName, inst.mailContainerName]
        if inst.ownsDatabaseContainer { names.append(inst.dbContainerName) }
        return names
    }

    /// Whether a running worktree env is currently borrowing this site's database
    /// container (issue #17).
    ///
    /// Read from live container LABELS rather than the store, because the
    /// lifecycle has no store access — and labels are the reconciliation ground
    /// truth anyway.
    ///
    /// FAILS CLOSED: if `container list` errors we report a dependent, because
    /// mistaking "I can't tell" for "nothing needs it" takes a live env's database
    /// away, while the opposite merely leaves a VM running a bit longer.
    private func hasRunningSharedDatabaseDependents(_ site: any RunnableInstance) async -> Bool {
        guard site.envLabel == nil else { return false } // an env has no dependents
        guard let records = try? await cli.list(all: true) else { return true }
        return Self.hasBorrowingEnv(in: records.filter(\.isRunning), siteSlug: site.siteSlug)
    }

    /// Does any running env of `siteSlug` borrow the site's DB container? An env
    /// counts as *borrowing* when it has no running `wpc-<envSlug>-db` of its own,
    /// which is exactly what shared mode means at the container level.
    private static func hasBorrowingEnv(in running: [ContainerRecord], siteSlug: String) -> Bool {
        let names = Set(running.map(\.name))
        return running.contains { record in
            guard let envSlug = record.envLabel, record.siteLabel == siteSlug,
                  record.name == "wpc-\(envSlug)-wp" else { return false }
            return !names.contains("wpc-\(envSlug)-db")
        }
    }

    /// Retire a shared DB container that nothing needs any more (issue #17,
    /// trade-off #2): after stopping an env whose database lives on the parent's
    /// server, stop that server too — but ONLY when nothing holds a lease on it,
    /// the parent's own wp container is down, and no sibling env is still
    /// borrowing it. Otherwise a stopped env would leave a ~470 MB DB VM behind
    /// forever, which is the whole memory win this change exists for.
    ///
    /// Needs no store access — dependents are read from container labels, which
    /// beats a possibly-stale store snapshot anyway. Idempotent, best-effort and
    /// FAIL-CLOSED at every step, so it is safe to call on any env stop.
    ///
    /// Returns whether it actually stopped the container, so a caller can drain
    /// the parent's warnings only when this is the flow that produced them.
    ///
    /// CROSS-PROCESS EXPOSURE (unresolved, by decision): the dependent check and
    /// the stop cannot be one atomic operation. The listing is re-read immediately
    /// before the stop to shrink the window as far as a `container` CLI without a
    /// transactional API allows, but a second `wp-container` process (or the app)
    /// that starts a shared-database env in the few milliseconds between the last
    /// check and the stop can still lose its server. `dbLeases` closes this within
    /// ONE process; closing it across processes would need a cross-process lock
    /// around whole lifecycle operations, which is deliberately not attempted. The
    /// blast radius is one failed start with a clear
    /// `sharedDatabaseUnavailable` error and a retry that works.
    @discardableResult
    public func stopSharedDatabaseIfUnused(parent: Site) async -> Bool {
        // In-flight starts/creates are invisible to `container list`.
        guard !isDatabaseLeased(parent.dbContainerName) else { return false }
        guard await isSharedDatabaseRetirable(parent) else { return false }
        // Re-check on the freshest possible listing: everything above may have
        // been true several hundred milliseconds ago, and an env that started in
        // the meantime must not lose its database.
        guard !isDatabaseLeased(parent.dbContainerName) else { return false }
        guard await isSharedDatabaseRetirable(parent) else { return false }
        _ = try? await cli.run(SiteRecipe.stopArgs(parent.dbContainerName))
        // Same verify/escalate pass as `stopCore` (issue #16): a DB VM that
        // survives its `stop` is ~470 MB of exactly the memory this retirement
        // exists to reclaim.
        let problems = await verifyTeardown(of: [parent.dbContainerName])
        if !problems.isEmpty {
            for problem in problems { Self.log.error("stop: \(problem, privacy: .public)") }
            recordWarnings(problems, for: parent.instanceID)
        }
        return true
    }

    /// Whether the parent's DB container is up and nothing visible needs it.
    /// FAIL-CLOSED: a listing error reports "not retirable", because mistaking
    /// "I can't tell" for "nothing needs it" takes a live env's database away.
    private func isSharedDatabaseRetirable(_ parent: Site) async -> Bool {
        guard let records = try? await cli.list(all: true) else { return false }
        let running = records.filter(\.isRunning)
        let names = Set(running.map(\.name))
        guard names.contains(parent.dbContainerName) else { return false }
        guard !names.contains(parent.wpContainerName) else { return false }
        return !Self.hasBorrowingEnv(in: running, siteSlug: parent.slug)
    }

    /// Stop + best-effort delete (non --rm leftovers, prior crash, …).
    /// Deliberately UNGUARDED: deletion is a cleanup/rollback surface and must
    /// always proceed (an in-flight start racing a delete fails and surfaces
    /// its own error, exactly as before issue #5).
    public func deleteContainers(_ inst: any RunnableInstance) async {
        await withTaskGroup(of: Void.self) { group in
            // Never the parent's DB container for a shared-database env (#17).
            for name in Self.ownedContainerNames(of: inst) {
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
        if let e = error as? ImageUnavailableError { return e.description }
        return "\(error)"
    }
}
