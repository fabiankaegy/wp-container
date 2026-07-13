import Foundation

public enum LifecycleError: Error, Sendable, CustomStringConvertible {
    case databaseNotReady
    case databaseIPUnavailable
    /// The HTTP readiness probe timed out. `observed` says what the probe saw
    /// the whole time (e.g. "the port never accepted a connection" vs "kept
    /// failing with …") so the failure is self-diagnosing.
    case httpNotReady(observed: String)
    case elasticsearchNotReady
    case elasticsearchIPUnavailable

    public var description: String {
        switch self {
        case .databaseNotReady:    return "The database container did not become ready in time."
        case .databaseIPUnavailable: return "Could not resolve the database container's IP address."
        case .httpNotReady(let observed):
            return "WordPress did not start responding over HTTP in time (\(observed))."
        case .elasticsearchNotReady: return "The Elasticsearch container did not become ready in time."
        case .elasticsearchIPUnavailable: return "Could not resolve the Elasticsearch container's IP address."
        }
    }
}

/// Orchestrates the container lifecycle for any `RunnableInstance` (a site or a
/// worktree env) through ONE shared start/stop code path, and publishes status
/// transitions on an `AsyncStream` so view models / callers can observe them.
public actor SiteLifecycle {
    public struct StatusEvent: Sendable {
        public let instanceID: UUID
        public let status: SiteStatus
    }

    private let cli: ContainerCLI
    private let xdebug: XdebugImageService

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

    // MARK: - Shared start path

    /// Ensure folders, pull images, start DB, wait for readiness, resolve the DB
    /// IP, start WP, and poll HTTP. Returns the resolved DB host IP. Emits
    /// `.starting` up front and `.error` on failure (then rethrows). Does NOT
    /// emit `.running` — callers do that after any post-start provisioning.
    @discardableResult
    public func startContainers(_ inst: any RunnableInstance) async throws -> String {
        let timer = PhaseTimer(inst.containerSlug)
        emit(inst.instanceID, .starting)
        do {
            try SiteFolders.ensure(for: inst)
            try await cli.run(SiteRecipe.pullImageArgs(SiteRecipe.databaseImage))
            try await cli.run(SiteRecipe.pullImageArgs(inst.imageTag))
            // Every one-shot wp-cli surface (first-run provisioning, URL fixes,
            // live DB clone, agent tools) runs on a PHP-matched cli image. Pull
            // it here so it rides the SAME progress path as the base images —
            // the first wp-cli use on a php8.4 site pulls wordpress:cli-php8.4.
            try await cli.run(SiteRecipe.pullImageArgs(SiteRecipe.cliImage(for: inst)))
            timer.mark("images")
            // First-ever start: pre-seed WordPress core into the mount (see
            // SiteRecipe.seedWordPressArgs). Gate on the absence of index.php.
            let indexPHP = inst.wordpressFolder.appendingPathComponent("index.php")
            if !FileManager.default.fileExists(atPath: indexPHP.path) {
                try await cli.run(SiteRecipe.seedWordPressArgs(inst))
                timer.mark("seed")
            }
            try await cli.run(SiteRecipe.runDatabaseArgs(inst))
            timer.mark("db-run")
            try await waitForDatabase(inst)
            timer.mark("db-ready")
            // The DB IP changes on every restart — re-inspect each start, never cache.
            let dbHost = try await resolveDatabaseHost(inst)
            timer.mark("db-ip")

            // Elasticsearch sidecar (§2c): db → es → wp start order.
            var elasticsearchURL: String? = nil
            if inst.elasticsearchEnabled {
                elasticsearchURL = try await startElasticsearch(inst)
                timer.mark("es-green")
            }

            // Xdebug (§2c): swap in the derived image + pass the host gateway.
            var imageOverride: String? = nil
            var xdebugClientHost: String? = nil
            if inst.xdebugEnabled {
                imageOverride = try await xdebug.ensureImage(forBaseTag: inst.imageTag)
                // Gateway is the same across containers on the network; read it
                // fresh from the already-running DB container (never hardcode).
                xdebugClientHost = try await cli.gatewayAddress(of: inst.dbContainerName)
                timer.mark("xdebug")
            }

            try await cli.run(SiteRecipe.runWordPressArgs(
                inst, dbHost: dbHost, imageOverride: imageOverride,
                xdebugClientHost: xdebugClientHost, elasticsearchURL: elasticsearchURL))
            timer.mark("wp-run")
            try await waitForHTTP(inst)
            timer.mark("http-ready")
            return dbHost
        } catch {
            emit(inst.instanceID, .error(Self.message(for: error)))
            throw error
        }
    }

    /// Start the Elasticsearch sidecar, wait for it to go green/yellow, and
    /// return the `http://<es-ip>:9200` URL WordPress should point at (§2c).
    private func startElasticsearch(_ inst: any RunnableInstance) async throws -> String {
        try FileManager.default.createDirectory(at: inst.elasticsearchFolder, withIntermediateDirectories: true)
        try await cli.run(SiteRecipe.runElasticsearchArgs(inst))
        let esIP = try await resolveElasticsearchHost(inst)
        try await waitForElasticsearch(esIP)
        return "http://\(esIP):9200"
    }

    /// Start a site, provisioning WordPress on first run. Returns the (possibly
    /// updated) `provisioned` flag so the caller can persist it.
    public func startSite(_ site: Site) async throws -> Bool {
        let dbHost = try await startContainers(site)
        var provisioned = site.provisioned
        if !provisioned {
            do {
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

    /// Start a site AND all of its worktree envs (coupled lifecycle, §2b).
    /// The parent is sequenced first; a parent failure does NOT abort the env
    /// starts already queued — every env is still attempted, and each failure
    /// is surfaced individually (status events + the returned messages).
    /// Never throws: callers read `errorSummary`.
    public func startSiteWithEnvs(_ site: Site, envs: [WorktreeEnv]) async -> CoupledStartOutcome {
        var outcome = CoupledStartOutcome(provisioned: site.provisioned, envErrorMessages: [])
        do {
            outcome.provisioned = try await startSite(site)
        } catch {
            outcome.parentErrorMessage = Self.message(for: error)
        }
        for env in envs {
            do {
                _ = try await startContainers(env)
                markRunning(env.id)
            } catch {
                outcome.envErrorMessages.append("\(env.envSlug): \(Self.message(for: error))")
            }
        }
        return outcome
    }

    /// Stop a site AND all of its worktree envs (coupled lifecycle, §2b).
    public func stopSiteWithEnvs(_ site: Site, envs: [WorktreeEnv]) async {
        await stop(site)
        for env in envs {
            await stop(env)
        }
    }

    // MARK: - Stop / delete

    public func stop(_ inst: any RunnableInstance) async {
        emit(inst.instanceID, .stopping)
        // Containers run with --rm, so `stop` makes them vanish. The es sidecar
        // is stopped best-effort whether or not the flag is currently set (it
        // may have been toggled off since start).
        _ = try? await cli.run(SiteRecipe.stopArgs(inst.wpContainerName))
        _ = try? await cli.run(SiteRecipe.stopArgs(inst.esContainerName))
        _ = try? await cli.run(SiteRecipe.stopArgs(inst.dbContainerName))
        emit(inst.instanceID, .stopped)
    }

    public func deleteContainers(_ inst: any RunnableInstance) async {
        _ = try? await cli.run(SiteRecipe.stopArgs(inst.wpContainerName))
        _ = try? await cli.run(SiteRecipe.stopArgs(inst.esContainerName))
        _ = try? await cli.run(SiteRecipe.stopArgs(inst.dbContainerName))
        // Best-effort delete in case anything lingers (non --rm, prior crash, …).
        _ = try? await cli.run(SiteRecipe.deleteArgs(inst.wpContainerName))
        _ = try? await cli.run(SiteRecipe.deleteArgs(inst.esContainerName))
        _ = try? await cli.run(SiteRecipe.deleteArgs(inst.dbContainerName))
        emit(inst.instanceID, .stopped)
    }

    // MARK: - Readiness polling

    private func waitForDatabase(_ inst: any RunnableInstance, timeout: Duration = .seconds(90)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let result = try await cli.runCapturing(SiteRecipe.databaseHealthcheckArgs(inst))
            if result.exitCode == 0 { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw LifecycleError.databaseNotReady
    }

    private func resolveDatabaseHost(_ inst: any RunnableInstance) async throws -> String {
        for _ in 0..<20 {
            try Task.checkCancellation()
            if let ip = try await cli.ipAddress(of: inst.dbContainerName), !ip.isEmpty {
                return ip
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw LifecycleError.databaseIPUnavailable
    }

    private func resolveElasticsearchHost(_ inst: any RunnableInstance) async throws -> String {
        for _ in 0..<20 {
            try Task.checkCancellation()
            if let ip = try await cli.ipAddress(of: inst.esContainerName), !ip.isEmpty {
                return ip
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw LifecycleError.elasticsearchIPUnavailable
    }

    /// Poll ES cluster health from the host (container IPs are host-reachable on
    /// Apple `container`). green/yellow ⇒ ready.
    private func waitForElasticsearch(_ esIP: String, timeout: Duration = .seconds(90)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        guard let url = URL(string: SiteRecipe.elasticsearchHealthURL(esHost: esIP)) else {
            throw LifecycleError.elasticsearchNotReady
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               let body = String(data: data, encoding: .utf8),
               body.contains("\"status\":\"green\"") || body.contains("\"status\":\"yellow\"") {
                return
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw LifecycleError.elasticsearchNotReady
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
            try await Task.sleep(for: .seconds(2))
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
