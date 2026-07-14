import AppKit
import Foundation
import Observation
import WPContainerKit

/// Outcome of registering a site's custom domain in `/etc/hosts` (PLAN.md §2l).
public enum DomainRegistrationOutcome: Sendable {
    /// The managed hosts block was written (or already correct).
    case registered
    /// The user dismissed the auth dialog, or we skipped / timed out — the site
    /// is fully created, the domain stays configured but unregistered.
    case skipped
    /// A genuine failure (not a cancellation); surfaced but non-fatal to creation.
    case failed(String)
}

/// App-level view model: owns the shared services, drives lifecycle actions as
/// `Task`s, observes lifecycle status events, and runs a periodic reconcile loop
/// that maps live container state (by label) back onto the store.
@MainActor
@Observable
public final class AppViewModel {
    public let store: SiteStore

    @ObservationIgnored let cli: ContainerCLI
    @ObservationIgnored let git: GitService
    @ObservationIgnored let lifecycle: SiteLifecycle
    @ObservationIgnored let worktrees: WorktreeEnvService
    @ObservationIgnored let systemCheck: SystemCheck
    @ObservationIgnored let ca: CertificateAuthority
    @ObservationIgnored let httpsIntegration: HTTPSIntegration
    @ObservationIgnored let proxy: HTTPSProxy
    @ObservationIgnored let dbImporter: DatabaseImportService
    @ObservationIgnored let notifications = NotificationService.shared

    /// Instances whose start/stop status notifications are suppressed because an
    /// explicit create flow is driving them (it posts a "ready"/"created"
    /// notification instead of a bare "started"). Keyed by instance UUID.
    @ObservationIgnored private var suppressStatusNotify: Set<UUID> = []

    public var selection: UUID?
    public var systemStatus: SystemCheckResult?
    public var lastError: String?
    /// Full underlying detail for the last error, when a concise summary was
    /// surfaced in `lastError` (e.g. rolled-back worktree creation). Shown behind
    /// a disclosure so the container log dump doesn't dominate the UI.
    public var lastErrorDetail: String?
    /// Whether the local CA is trusted as a root (drives the "Trust CA" prompt).
    public var caTrusted = false
    /// The port the in-app HTTPS proxy bound, once started.
    public var proxyPort: UInt16?

    /// UI-intent flags so menu commands (and buttons) can drive sheet
    /// presentation from anywhere.
    public var presentingAddSite = false
    public var presentingNewEnv = false
    public var presentingImportDB = false
    /// A dump file dropped on the site detail pane (§2m drag & drop) — set just
    /// before `presentingImportDB` so the sheet opens pre-filled with it.
    public var pendingImportDump: URL?

    /// Whether the pre-import database backup was successfully restored after
    /// the last failed `importDatabase` call — nil when the last failure (if
    /// any) wasn't a database import. Read alongside `lastError`/`lastErrorDetail`.
    public var lastImportRolledBack: Bool?

    /// WP × PHP version matrix for the setup pickers (PLAN.md §2k): starts from
    /// the cached/static matrix and is refreshed from Docker Hub at launch.
    public var versionMatrix: WordPressVersionMatrix = WordPressImageCatalog.fallbackMatrix

    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    public init() {
        let cli = ContainerCLI()
        let git = GitService()
        let lifecycle = SiteLifecycle(cli: cli)
        self.cli = cli
        self.git = git
        self.lifecycle = lifecycle
        self.worktrees = WorktreeEnvService(cli: cli, git: git, lifecycle: lifecycle)
        self.systemCheck = SystemCheck(cli: cli)
        let ca = CertificateAuthority()
        self.ca = ca
        self.httpsIntegration = HTTPSIntegration(cli: cli, ca: ca)
        self.proxy = HTTPSProxy(ca: ca)
        self.dbImporter = DatabaseImportService(cli: cli, lifecycle: lifecycle)
        self.store = SiteStore()
    }

    public var sites: [Site] { store.sites }
    public var envs: [WorktreeEnv] { store.envs }

    // MARK: - Lifecycle of the view model

    /// Idempotent: invoked once from the App's init (so the menu bar extra works
    /// without the main window) and again from the window's `.task`, which is a
    /// no-op after the first call.
    public func onAppear() async {
        guard !started else { return }
        started = true
        await store.start()
        notifications.configure()
        refreshStaleShims()
        await refreshSystemStatus()
        await refreshCATrusted()
        observeStatusEvents()
        startReconcileLoop()
        // Adopt an already-running headless proxy, if any.
        proxyPort = ProxyControl.current()?.port
        // Version pickers: show the cached matrix immediately, refresh from
        // Docker Hub in the background (never blocks launch; offline keeps the
        // cache/static fallback).
        versionMatrix = await WordPressVersionCatalog.shared.cachedMatrix()
        Task { [weak self] in
            let fresh = await WordPressVersionCatalog.shared.matrix()
            self?.versionMatrix = fresh
        }
    }

    // MARK: - HTTPS / CA / agent tools (§2d/§2f)

    public func refreshCATrusted() async {
        caTrusted = await ca.isCATrusted()
    }

    /// Whether the site's HTTPS flag is on (mirrors the persisted store value).
    public func isHTTPSEnabled(_ site: Site) -> Bool { site.httpsEnabled }

    public func setHTTPS(_ site: Site, enabled: Bool) {
        Task {
            do {
                if enabled {
                    try await httpsIntegration.enable(site)
                    await refreshProxyRouting()
                } else {
                    try await httpsIntegration.disable(site)
                    try? await ca.removeLeafCoverage(site.proxyHosts)
                }
                var updated = site
                updated.httpsEnabled = enabled
                await store.upsertSite(updated)   // @Observable → every URL surface re-renders
            } catch {
                lastError = SiteLifecycleErrorText(error)
            }
        }
    }

    /// Ensure the proxy is running and, when the app owns the listener, reload it
    /// so cert SANs + the host map pick up HTTPS/domain changes immediately
    /// (PLAN.md §2f/§2i auto-reload).
    public func refreshProxyRouting() async {
        await ensureProxyRunning()
        if proxy.boundPort != nil {
            try? await proxy.reload()
            proxyPort = proxy.boundPort
        }
    }

    // MARK: - Add-ons (§2c)

    /// The running site's Elasticsearch endpoint (`http://<es-ip>:9200`), if any.
    public func elasticsearchEndpoint(_ site: Site) async -> String? {
        guard site.elasticsearchEnabled,
              let ip = try? await cli.ipAddress(of: site.esContainerName), !ip.isEmpty else { return nil }
        return "http://\(ip):9200"
    }

    public func setXdebug(_ site: Site, enabled: Bool) { toggleAddon(site) { $0.xdebugEnabled = enabled } }
    public func setElasticsearch(_ site: Site, enabled: Bool) { toggleAddon(site) { $0.elasticsearchEnabled = enabled } }

    // MARK: - Mailpit (issue #10)

    /// Enable/disable the per-site Mailpit email catcher: write or remove the
    /// mu-plugin, allocate the mailbox web port on first enable, and restart a
    /// running site so the container recipe takes effect. The proxy's refresh
    /// loop picks up the new `<slug>-mail.localhost` host + cert SAN within a few
    /// seconds; the primary mailbox URL is the proxy-independent localhost port.
    public func setMailpit(_ site: Site, enabled: Bool) {
        Task {
            var updated = site
            if enabled {
                try? MailpitService.writeMuPlugin(wordpressFolder: site.wordpressFolder)
                if site.mailpitPort == nil {
                    // Reserve the mailbox web port inside the locked mutation.
                    let result = await store.allocatePort { port, env -> Site? in
                        guard let i = env.sites.firstIndex(where: { $0.id == site.id }) else { return nil }
                        env.sites[i].mailpitPort = port
                        env.sites[i].mailpitEnabled = true
                        return env.sites[i]
                    }
                    guard let (_, reservedSite) = result, let s = reservedSite else {
                        lastError = "No free port available for the mailbox."
                        return
                    }
                    updated = s
                } else {
                    updated.mailpitEnabled = true
                    await store.upsertSite(updated)
                }
            } else {
                try? MailpitService.removeMuPlugin(wordpressFolder: site.wordpressFolder)
                updated.mailpitEnabled = false
                await store.upsertSite(updated)
            }
            if site.status.isRunning {
                await lifecycle.stop(updated)
                do {
                    let provisioned = try await lifecycle.startSite(updated)
                    if provisioned != updated.provisioned {
                        updated.provisioned = provisioned
                        await store.upsertSite(updated)
                    }
                } catch { lastError = SiteLifecycleErrorText(error) }
            }
        }
    }

    // MARK: - Database importer (PLAN.md §2m)

    /// A step surfaced by `importDatabase` to the sheet: either the pseudo-step
    /// of starting a stopped site (never emitted by the kit — `DatabaseImportService`
    /// never starts sites itself) or one of the kit's own pipeline phases.
    public enum DBImportStep: Sendable, Equatable {
        case startingSite
        case phase(DBImportPhase)
    }

    /// Runs the full database-import pipeline for `site`, starting the site
    /// first (with a visible pseudo-step) if it isn't already running — the kit
    /// layer never does this itself (PLAN.md §2m / `DatabaseImportError.siteNotRunning`).
    /// On success, persists the dump's detected source URL onto the site record
    /// (the kit doesn't write it). On failure, `lastError`/`lastErrorDetail`/
    /// `lastImportRolledBack` are populated for the sheet's failure view.
    @discardableResult
    public func importDatabase(
        into site: Site,
        dump: URL,
        options: DBImportOptions,
        onStep: @escaping @Sendable (DBImportStep) -> Void
    ) async -> DBImportSummary? {
        lastError = nil
        lastErrorDetail = nil
        lastImportRolledBack = nil

        var current = store.site(id: site.id) ?? site
        if !current.status.isRunning {
            onStep(.startingSite)
            do {
                let provisioned = try await lifecycle.startSite(current)
                if provisioned != current.provisioned {
                    current.provisioned = provisioned
                    await store.upsertSite(current)
                }
            } catch {
                lastError = "Couldn't start the site: \(SiteLifecycleErrorText(error))"
                return nil
            }
        }

        do {
            let summary = try await dbImporter.importDatabase(into: current, dump: dump, options: options) { phase in
                Task { @MainActor in onStep(.phase(phase)) }
            }
            if let sourceURL = summary.sourceURL, sourceURL != current.lastImportSourceURL {
                current.lastImportSourceURL = sourceURL
                await store.upsertSite(current)
            }
            return summary
        } catch let error as DatabaseImportError {
            if case .phaseFailed(_, let short, let full, let rolledBack) = error {
                lastError = short
                lastErrorDetail = full
                lastImportRolledBack = rolledBack
            } else {
                lastError = error.description
            }
            return nil
        } catch {
            lastError = SiteLifecycleErrorText(error)
            return nil
        }
    }

    // MARK: - Resource limits (issue #11)

    /// Persist a site's optional CPU/memory caps. Unlike the add-on toggles this
    /// does NOT restart a running site: limits are a `container run` argument, so
    /// they take effect on the next start (the Resources card shows a hint).
    public func setResources(_ site: Site, cpuLimit: Int?, memoryLimitMB: Int?) {
        Task {
            var updated = site
            updated.cpuLimit = cpuLimit
            updated.memoryLimitMB = memoryLimitMB
            await store.upsertSite(updated)
        }
    }

    /// Persist an add-on flag change and restart the site when it is running so
    /// the new container recipe takes effect.
    private func toggleAddon(_ site: Site, _ apply: @escaping (inout Site) -> Void) {
        Task {
            var updated = site
            apply(&updated)
            await store.upsertSite(updated)
            if site.status.isRunning {
                await lifecycle.stop(updated)
                do {
                    let provisioned = try await lifecycle.startSite(updated)
                    if provisioned != updated.provisioned {
                        updated.provisioned = provisioned
                        await store.upsertSite(updated)
                    }
                } catch { lastError = SiteLifecycleErrorText(error) }
            }
        }
    }

    // MARK: - Custom domain (§2i)

    public func setDomain(_ site: Site, domain: String) {
        Task {
            guard let normalized = DomainService.normalize(domain) else {
                lastError = "\"\(domain)\" is not a valid hostname."
                return
            }
            if store.sites.contains(where: { $0.id != site.id && $0.customDomain == normalized }) {
                lastError = "\"\(normalized)\" is already used by another site."
                return
            }
            var updated = site
            updated.customDomain = normalized
            await store.upsertSite(updated)
            // Bring the app frontmost so the /etc/hosts admin dialog is visible.
            NSApp.activate(ignoringOtherApps: true)
            do {
                let all = store.sites.compactMap(\.customDomain)
                try await DomainService(cli: cli, ca: ca).apply(site: updated, allCustomDomains: all)
                await refreshProxyRouting()
            } catch let error as HostsFileService.HostsError {
                // A dismissed dialog leaves the domain configured but
                // unregistered (the Domain card offers "Register now"); other
                // hosts errors surface.
                if case .cancelled = error {} else { lastError = error.description }
            } catch { lastError = SiteLifecycleErrorText(error) }
        }
    }

    public func clearDomain(_ site: Site) {
        Task {
            var updated = site
            updated.customDomain = nil
            await store.upsertSite(updated)
            do {
                let all = store.sites.compactMap(\.customDomain)
                try await DomainService(cli: cli, ca: ca).apply(site: updated, allCustomDomains: all)
                await refreshProxyRouting()
            } catch { lastError = SiteLifecycleErrorText(error) }
        }
    }

    // MARK: - WordPress / PHP versions (§2k)

    /// Change the site's image tag (PHP/WP version) — files/DB untouched — and
    /// restart when running.
    public func changeImageTag(_ site: Site, imageTag: String, phpLabel: String?) {
        Task {
            var updated = site
            updated.imageTag = imageTag
            updated.phpVersion = phpLabel
            await store.upsertSite(updated)
            if site.status.isRunning {
                await lifecycle.stop(updated)
                do { _ = try await lifecycle.startSite(updated) }
                catch { lastError = SiteLifecycleErrorText(error) }
            }
        }
    }

    /// Run `wp core update` (+ db) via a one-shot wp-cli container.
    public func updateWordPressCore(_ site: Site) {
        Task {
            guard let dbHost = try? await cli.ipAddress(of: site.dbContainerName), !dbHost.isEmpty else {
                lastError = "Start the site before updating WordPress core."
                return
            }
            do {
                try await cli.run(SiteRecipe.wpCoreUpdateArgs(site, dbHost: dbHost))
                notifications.notifyCoreUpdated(name: site.name)
            }
            catch { lastError = SiteLifecycleErrorText(error) }
        }
    }

    /// Live WordPress version (`wp core version`) when the site is running.
    public func liveWordPressVersion(_ site: Site) async -> String? {
        guard let dbHost = try? await cli.ipAddress(of: site.dbContainerName), !dbHost.isEmpty else { return nil }
        let result = try? await cli.runCapturing(SiteRecipe.wpCoreVersionArgs(site, dbHost: dbHost))
        let v = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty == false) ? v : nil
    }

    /// Multisite subsites (`wp site list`) when running (§2j).
    public func subsites(_ site: Site) async -> [(blogID: String, url: String)] {
        guard site.networkType.isMultisite,
              let dbHost = try? await cli.ipAddress(of: site.dbContainerName), !dbHost.isEmpty,
              let result = try? await cli.runCapturing(SiteRecipe.wpSiteListArgs(site, dbHost: dbHost)),
              let data = result.stdout.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.map { row in
            let id = (row["blog_id"].map { "\($0)" }) ?? "?"
            let url = (row["url"] as? String) ?? ""
            return (id, url)
        }
    }

    // MARK: - WP debug constants (§2c-bis)

    /// Read the current debug/dev constants from wp-config (missing = false/off).
    public func devConstants(_ site: Site) -> (debug: [String: Bool], mode: String, environment: String) {
        let folder = site.wordpressFolder
        var debug: [String: Bool] = [:]
        for name in WPConfigService.debugConstants {
            debug[name] = WPConfigService.boolConstant(name, wordpressFolder: folder)
        }
        let parsed = try? WPConfigService.read(wordpressFolder: folder)
        let mode = parsed?.constants[WPConfigService.developmentModeConstant] ?? ""
        let env = parsed?.constants[WPConfigService.environmentTypeConstant] ?? ""
        return (debug, mode, env)
    }

    public func setDebugConstant(_ site: Site, name: String, enabled: Bool) {
        do { try WPConfigService.setBoolConstant(name, enabled, wordpressFolder: site.wordpressFolder) }
        catch { lastError = "\(error)" }
    }

    public func setDevelopmentMode(_ site: Site, mode: String) {
        do {
            if mode.isEmpty {
                try WPConfigService.setConstant(WPConfigService.developmentModeConstant, value: "", rawValue: false, wordpressFolder: site.wordpressFolder)
            } else {
                try WPConfigService.setConstant(WPConfigService.developmentModeConstant, value: mode, rawValue: false, wordpressFolder: site.wordpressFolder)
            }
        } catch { lastError = "\(error)" }
    }

    // MARK: - Global `wp` router (§2e follow-up)

    public var globalWPInstalled: Bool { ShellPathService.isInstalled() && WPCLIShim.routerInstalled }

    public func setGlobalWP(enabled: Bool) {
        Task {
            do {
                if enabled {
                    _ = try WPCLIShim.writeRouter()
                    let order = await ShellPathService.wpOnPath()
                    if order.first != WPCLIShim.routerPath { try ShellPathService.apply(install: true) }
                } else {
                    try ShellPathService.apply(install: false)
                    WPCLIShim.removeRouter()
                }
            } catch { lastError = "Global wp router: \(error)" }
        }
    }

    /// Start the in-app HTTPS proxy unless an external `proxy serve` already owns
    /// the listener.
    public func ensureProxyRunning() async {
        if let status = ProxyControl.current() { proxyPort = status.port; return }
        if proxy.boundPort != nil { proxyPort = proxy.boundPort; return }
        do {
            let port = try await proxy.start()
            try? ProxyControl.claim(port: port)
            proxyPort = port
        } catch {
            lastError = "HTTPS proxy: \(error)"
            notifications.notifyProxyFailed(reason: Self.proxyFailureReason(error))
        }
    }

    /// Actionable one-line reason for a proxy start failure (PLAN Task 1: "port
    /// busy" and friends).
    private static func proxyFailureReason(_ error: Error) -> String {
        guard let e = error as? HTTPSProxy.ProxyError else { return "\(error)" }
        switch e {
        case .noPortAvailable:
            return "Ports 443 and 8443 are both busy. Quit whatever is using them, then start the proxy again."
        case .listenerFailed(let detail):
            return "The proxy couldn’t bind its port (\(detail)). Another process may be holding 443 or 8443."
        case .identityUnavailable(let detail):
            return "The TLS certificate couldn’t be loaded (\(detail)). Re-trust the WP Container CA in Settings."
        }
    }

    /// Whether any site depends on the reverse proxy for its URL to work at
    /// all (HTTPS or a custom domain — both route through the proxy, §2f/§2i).
    private var anySiteNeedsProxy: Bool {
        store.sites.contains { $0.httpsEnabled || $0.customDomain != nil }
    }

    /// Start the proxy whenever anything needs it — correctness must never
    /// depend on the opt-out launch setting (user-reported: after a relaunch
    /// nothing listened on 443 and every https/custom-domain site was dead).
    public func ensureProxyIfNeeded() async {
        if anySiteNeedsProxy { await ensureProxyRunning() }
    }

    /// Cheap liveness refresh for proxy status lines: adopt an externally-owned
    /// listener (e.g. `wp-container proxy serve`) if one has appeared.
    public func refreshProxyLiveness() {
        if proxyPort == nil { proxyPort = ProxyControl.current()?.port }
    }

    /// Install the local CA as a trusted root (prompts for admin), then refresh.
    public func trustCA() {
        Task {
            do {
                try await ca.trustCA()
                await refreshCATrusted()
            } catch {
                lastError = "\(error)"
            }
        }
    }

    public func agentToolsEnabled(_ site: Site) -> Bool { AgentToolsService.isEnabled(site: site) }

    /// Enable agent tools at a chosen placement root (default: the site folder;
    /// or a wp-content repo root where the user opens their IDE — §2d rework).
    public func enableAgentTools(_ site: Site, root: URL? = nil, docName: String? = nil) {
        Task {
            do {
                let rootURL = root ?? site.path
                let repoRel = repoRelPath(root: rootURL, site: site)
                let result = try AgentToolsService.enable(site: site, root: rootURL, docName: docName, repoRelPath: repoRel)
                var updated = site
                updated.agentToolsRoot = result.root
                updated.agentToolsDoc = result.docName
                await store.upsertSite(updated)
            } catch { lastError = "\(error)" }
        }
    }

    public func disableAgentTools(_ site: Site) {
        Task {
            do {
                let rootURL = site.agentToolsRoot.map { URL(fileURLWithPath: $0) } ?? site.path
                try AgentToolsService.disable(site: site, root: rootURL, docName: site.agentToolsDoc)
                var updated = site
                updated.agentToolsRoot = nil
                updated.agentToolsDoc = nil
                await store.upsertSite(updated)
            } catch { lastError = "\(error)" }
        }
    }

    /// Relative path of `root` under the site's `wordpress/`, or nil.
    private func repoRelPath(root: URL, site: Site) -> String? {
        let wp = site.wordpressFolder.resolvingSymlinksInPath().path
        let r = root.resolvingSymlinksInPath().path
        guard r != wp, r.hasPrefix(wp + "/") else { return nil }
        return String(r.dropFirst(wp.count + 1))
    }

    /// Rewrite site `wp` shims (and the global router) whose format is stale, so
    /// improvements ship automatically on the next launch (PLAN.md §2e).
    private func refreshStaleShims() {
        for site in store.sites where WPCLIShim.shimNeedsRefresh(siteRoot: site.path) {
            _ = try? WPCLIShim.writeShim(slug: site.slug, siteRoot: site.path,
                                         cliImage: WordPressImageCatalog.cliImage(for: site.imageTag))
        }
        for site in store.sites {
            guard let root = site.agentToolsRoot else { continue }
            let url = URL(fileURLWithPath: root)
            if WPCLIShim.shimNeedsRefresh(siteRoot: url) {
                _ = try? WPCLIShim.writeShim(slug: site.slug, siteRoot: url, wordpressFolder: site.wordpressFolder,
                                             cliImage: WordPressImageCatalog.cliImage(for: site.imageTag))
            }
        }
        if WPCLIShim.routerInstalled { _ = try? WPCLIShim.writeRouter() }
    }

    /// Open an interactive wp-cli shell for the site in Terminal.app (§2e).
    public func openWPCLI(_ site: Site) {
        let command = WPCLIShim.interactiveTerminalCommand(slug: site.slug, wordpressFolder: site.wordpressFolder,
                                                            cliImage: WordPressImageCatalog.cliImage(for: site.imageTag))
        SystemActions.openTerminalRunning(command)
    }

    public func refreshSystemStatus() async {
        systemStatus = await systemCheck.check()
    }

    public func startSystemService() async {
        do {
            try await systemCheck.startSystem()
            await refreshSystemStatus()
        } catch {
            lastError = "\(error)"
        }
    }

    private func observeStatusEvents() {
        guard statusTask == nil else { return }
        let events = lifecycle.events
        statusTask = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                let prior = self.store.status(for: event.instanceID)
                self.store.setStatus(event.status, for: event.instanceID)
                self.notifyStatusTransition(event, prior: prior)
            }
        }
    }

    /// Fire a start/stop notification for a genuine run-state transition, but
    /// ONLY when the app is not frontmost (menu-bar-first mode — a start/stop the
    /// user triggered from a visible window needs no notification, PLAN Task 1)
    /// and not while an explicit create flow owns the instance (that flow posts
    /// its own "created"/"ready" notification instead of a bare "started").
    private func notifyStatusTransition(_ event: SiteLifecycle.StatusEvent, prior: SiteStatus?) {
        guard !NSApp.isActive else { return }
        guard !suppressStatusNotify.contains(event.instanceID) else { return }
        switch event.status {
        case .running where prior != .running:
            if let site = store.site(id: event.instanceID) {
                notifications.notifyStarted(name: site.name, url: site.url, faviconFolder: site.wordpressFolder)
            } else if let env = store.env(id: event.instanceID) {
                notifications.notifyStarted(name: "\(env.parentSlug) · \(env.branch)",
                                            url: env.localURL, faviconFolder: env.wordpressFolder)
            }
        case .stopped where prior != nil && prior != .stopped:
            // `prior != nil` skips a first-observation stop (e.g. deleting a
            // never-tracked instance), so a delete of an already-stopped site is
            // silent.
            if let site = store.site(id: event.instanceID) {
                notifications.notifyStopped(name: site.name)
            } else if let env = store.env(id: event.instanceID) {
                notifications.notifyStopped(name: "\(env.parentSlug) · \(env.branch)")
            }
        default:
            break
        }
    }

    /// Stop suppressing an instance's start/stop notifications after a short
    /// delay, so any buffered `.running`/`.stopped` event emitted during the
    /// create flow has drained (and been suppressed) first.
    private func clearSuppressionSoon(_ id: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.suppressStatusNotify.remove(id)
        }
    }

    // MARK: - Reconcile loop (every 5s while active)

    private func startReconcileLoop() {
        guard reconcileTask == nil else { return }
        reconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reconcile()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    public func stopLoops() {
        reconcileTask?.cancel(); reconcileTask = nil
        statusTask?.cancel(); statusTask = nil
    }

    /// Map live containers by label and update statuses, without clobbering
    /// in-flight transitional states.
    ///
    /// Also re-reads `sites.json` from disk first: `SiteStore`'s `DispatchSource`
    /// watcher re-establishes itself on every external atomic-replace write (the
    /// CLI's `StorePersistence.save` always writes temp-file + rename), which is
    /// usually instant, but a burst of rapid successive external writes (e.g. two
    /// concurrent CLI mutations) can race the cancel-then-reopen sequence and
    /// leave the watcher silently not observing further changes until the app
    /// relaunches. Piggybacking a `reload()` on this already-running 5s loop is a
    /// cheap, self-healing backstop so external edits (including group deletes,
    /// which have no other status-polling path) always surface within 5s even if
    /// that race is ever hit — matching the "poll as a backstop" reconciliation
    /// PLAN.md already specifies for container status.
    public func reconcile() async {
        await store.reload()
        guard let records = try? await cli.list(all: true) else { return }
        let running = Set(records.filter { $0.isRunning }.map { $0.name })

        for site in store.sites where !site.status.isTransitional {
            let isUp = running.contains(site.wpContainerName)
            store.setStatus(isUp ? .running : .stopped, for: site.id)
        }
        for env in store.envs where !env.status.isTransitional {
            let isUp = running.contains(env.wpContainerName)
            store.setStatus(isUp ? .running : .stopped, for: env.id)
        }
    }

    // MARK: - Site actions

    @discardableResult
    public func createSite(name: String, parentFolder: URL? = nil, imageTag: String = SiteRecipe.defaultWordPressImage,
                           phpVersion: String? = nil, groupID: UUID? = nil,
                           networkType: NetworkType = .none, customDomain: String? = nil,
                           xdebugEnabled: Bool = false, elasticsearchEnabled: Bool = false) async -> Site? {
        let root = parentFolder ?? SiteFolders.defaultSitesRoot
        let slug = Slug.unique(name, existing: store.existingSlugs)
        let sitePath = root.appendingPathComponent(slug, isDirectory: true)
        // Allocate the port INSIDE the cross-process-locked store mutation (#3
        // follow-up): the port is picked from the store's current taken set AND
        // the new site is appended in the same critical section, so a concurrent
        // creator (the app again, or the CLI) can never observe the same port as
        // free. Mirrors `wp-container create`.
        let result = await store.allocatePort { port, envelope in
            let site = Site(name: name, slug: slug, path: sitePath,
                            port: port, imageTag: imageTag, phpVersion: phpVersion, groupID: groupID,
                            xdebugEnabled: xdebugEnabled, elasticsearchEnabled: elasticsearchEnabled,
                            customDomain: customDomain, networkType: networkType)
            envelope.sites.append(site)
            return site
        }
        guard let (_, site) = result else {
            lastError = "No free port available."
            return nil
        }
        return site
    }

    // MARK: - Group actions (PLAN.md §2g)

    public func addGroup(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task { await store.addGroup(name: trimmed) }
    }

    public func renameGroup(_ group: SiteGroup, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task { await store.renameGroup(id: group.id, to: trimmed) }
    }

    public func deleteGroup(_ group: SiteGroup) {
        Task { await store.deleteGroup(id: group.id) }
    }

    public func moveSite(_ site: Site, toGroup groupID: UUID?) {
        Task { await store.moveSite(site.id, toGroup: groupID) }
    }

    /// Debug helper used by the placeholder UI.
    public func addDummySite() {
        Task {
            let n = store.sites.count + 1
            _ = await createSite(name: "Demo Site \(n)")
        }
    }

    /// Create a site AND start it (seeding + provisioning), awaiting completion
    /// so a creation sheet can drive inline progress off the emitted status
    /// events. Selects the new site. Returns nil on failure (error surfaced via
    /// `lastError`).
    @discardableResult
    public func createAndStartSite(name: String, parentFolder: URL? = nil, imageTag: String = SiteRecipe.defaultWordPressImage,
                                   phpVersion: String? = nil, groupID: UUID? = nil,
                                   networkType: NetworkType = .none, customDomain: String? = nil,
                                   xdebugEnabled: Bool = false, elasticsearchEnabled: Bool = false) async -> Site? {
        guard let site = await createSite(name: name, parentFolder: parentFolder, imageTag: imageTag, phpVersion: phpVersion,
                                          groupID: groupID, networkType: networkType, customDomain: customDomain,
                                          xdebugEnabled: xdebugEnabled, elasticsearchEnabled: elasticsearchEnabled) else {
            return nil
        }
        selection = site.id
        // Suppress the bare "started" notification for this site — the create
        // flow posts a "site ready"/"couldn't create" notification instead.
        suppressStatusNotify.insert(site.id)
        do {
            let provisioned = try await lifecycle.startSite(site)
            if provisioned != site.provisioned {
                var updated = site
                updated.provisioned = provisioned
                await store.upsertSite(updated)
            }
            notifications.notifySiteCreated(name: site.name, url: site.url, faviconFolder: site.wordpressFolder)
        } catch {
            let text = SiteLifecycleErrorText(error)
            lastError = text
            notifications.notifySiteCreationFailed(name: site.name, error: text)
        }
        clearSuppressionSoon(site.id)
        // NOTE: custom-domain registration (the blocking /etc/hosts admin prompt)
        // is intentionally NOT done here. The Add Site sheet drives it as a
        // separate, honestly-labelled, skippable step via `registerCustomDomain`
        // (PLAN.md §2l) so an unnoticed auth dialog never appears to hang.
        return site
    }

    /// Register `site`'s custom domain in `/etc/hosts` (+ cert SANs + proxy +
    /// WordPress URLs). Brings the app frontmost first so the admin/Touch-ID
    /// dialog appears above our windows, and honors `Task` cancellation — a
    /// cancelled Task SIGTERMs the pending `osascript`, dismissing the dialog.
    /// A user-dismissed dialog (or a skip/timeout cancellation) resolves to
    /// `.skipped`, never a failure: the site is already created and running.
    public func registerCustomDomain(_ site: Site) async -> DomainRegistrationOutcome {
        guard let domain = site.customDomain, !domain.isEmpty else { return .registered }
        // Encourage the auth dialog to attach above our sheet.
        NSApp.activate(ignoringOtherApps: true)
        do {
            let all = store.sites.compactMap(\.customDomain)
            try await DomainService(cli: cli, ca: ca).apply(site: site, allCustomDomains: all)
            await refreshProxyRouting()
            return .registered
        } catch {
            // Any error under a cancelled Task is a deliberate skip/timeout (the
            // osascript child was SIGTERM'd) — never a failure to surface.
            if Task.isCancelled { return .skipped }
            if let hostsError = error as? HostsFileService.HostsError,
               case .cancelled = hostsError { return .skipped }
            let text = SiteLifecycleErrorText(error)
            lastError = text
            return .failed(text)
        }
    }

    /// Whether a site's configured custom domain currently has a `/etc/hosts`
    /// entry. False (unregistered) is the state the Domain card flags with a
    /// "Register now" affordance.
    public func isDomainRegistered(_ site: Site) -> Bool {
        guard let domain = site.customDomain, !domain.isEmpty else { return true }
        return HostsFileService.isRegistered(domain)
    }

    /// Awaitable worktree-env creation for the "New Branch Environment" sheet:
    /// returns the created (already-started) env so the sheet can show its URL,
    /// or nil on failure (error surfaced via `lastError`).
    public func createEnvAwaiting(parent: Site, repoRelPath: String, branch: String, from: String? = nil) async -> WorktreeEnv? {
        // Allocate the port AND reserve the env descriptor in ONE locked store
        // mutation (#3 follow-up) — same pattern the CLI/MCP worktree-create use.
        // The reserved record keeps the final env's UUID so `upsertEnv` (success)
        // or `removeEnv` (rollback) is a simple by-id swap.
        guard let (_, reserved) = await store.allocatePort(reserve: { port, envelope in
            WorktreeEnvService.reservedDescriptor(parent: parent, repoRelPath: repoRelPath, branch: branch, port: port, into: &envelope)
        }) else {
            lastError = "No free port available."
            return nil
        }
        // Suppress the env's bare "started" notification (its `.running` fires
        // inside `create`); the "environment ready" notification stands in.
        suppressStatusNotify.insert(reserved.id)
        do {
            let env = try await worktrees.create(parent: parent, parentIsRunning: parent.status.isRunning,
                                                 repoRelPath: repoRelPath, branch: branch, from: from,
                                                 port: reserved.port, reserved: reserved)
            await store.upsertEnv(env)
            notifications.notifyEnvReady(branch: env.branch, parent: parent.name,
                                         url: env.localURL, faviconFolder: env.wordpressFolder)
            clearSuppressionSoon(env.id)
            return env
        } catch {
            await store.removeEnv(id: reserved.id)
            clearSuppressionSoon(reserved.id)
            lastError = SiteLifecycleErrorText(error)
            lastErrorDetail = (error as? WorktreeError)?.fullDetail
            return nil
        }
    }

    /// Repos discovered under a site's `wp-content` (for the env sheet's picker).
    public func repos(for site: Site) async -> [GitRepo] {
        await git.repos(under: site.wordpressFolder)
    }

    /// Branch names in a repo (for the env sheet's autocomplete).
    public func branches(inRepo repo: GitRepo) async -> [String] {
        (try? await git.branches(repo: repo.absolutePath)) ?? []
    }

    public var selectedSite: Site? {
        guard let selection else { return nil }
        return store.site(id: selection)
    }

    /// The selected worktree env, when the sidebar selection is an env row (§2b).
    public var selectedEnv: WorktreeEnv? {
        guard let selection else { return nil }
        return store.env(id: selection)
    }

    /// Coupled lifecycle (§2b): starting a site also starts all of its worktree
    /// envs (parent first, then envs; individual failures surfaced together).
    public func startSite(_ site: Site) {
        Task {
            // An HTTPS/custom-domain site is unreachable without the reverse
            // proxy — ensure it's listening whenever such a site starts (covers
            // proxy crashed/killed/never-started cases, §2f fix).
            if site.httpsEnabled || site.customDomain != nil {
                await ensureProxyRunning()
            }
            let envs = store.envs(forSite: site.id)
            let outcome = await lifecycle.startSiteWithEnvs(site, envs: envs)
            if outcome.provisioned != site.provisioned {
                var updated = site
                updated.provisioned = outcome.provisioned
                await store.upsertSite(updated)
            }
            if let summary = outcome.errorSummary {
                lastError = summary
            }
        }
    }

    /// Coupled lifecycle (§2b): stopping a site also stops its worktree envs.
    public func stopSite(_ site: Site) {
        Task { await lifecycle.stopSiteWithEnvs(site, envs: store.envs(forSite: site.id)) }
    }

    public func deleteSite(_ site: Site, trashFolder: Bool) {
        Task {
            let childEnvs = store.envs(forSite: site.id)
            for env in childEnvs {
                await worktrees.delete(env, parent: site, keepBranch: true, keepWorktree: false)
                await store.removeEnv(id: env.id)
            }
            await lifecycle.deleteContainers(site)
            if trashFolder {
                try? FileManager.default.trashItem(at: site.path, resultingItemURL: nil)
            }
            await store.removeSite(id: site.id)
            // Drop this site's (and its envs') hostnames from the trusted
            // leaf's SAN set now that they're gone.
            let staleHosts = site.proxyHosts + childEnvs.map { "\($0.envSlug).localhost" }
            try? await ca.removeLeafCoverage(staleHosts)
        }
    }

    // MARK: - Worktree env actions

    public func createEnv(parent: Site, repoRelPath: String, branch: String, from: String? = nil) {
        Task {
            // Port + env reservation in one locked mutation (#3 follow-up).
            guard let (_, reserved) = await store.allocatePort(reserve: { port, envelope in
                WorktreeEnvService.reservedDescriptor(parent: parent, repoRelPath: repoRelPath, branch: branch, port: port, into: &envelope)
            }) else {
                lastError = "No free port available."
                return
            }
            let parentRunning = parent.status.isRunning
            suppressStatusNotify.insert(reserved.id)
            do {
                let env = try await worktrees.create(parent: parent, parentIsRunning: parentRunning,
                                                     repoRelPath: repoRelPath, branch: branch, from: from,
                                                     port: reserved.port, reserved: reserved)
                await store.upsertEnv(env)
                notifications.notifyEnvReady(branch: env.branch, parent: parent.name,
                                             url: env.localURL, faviconFolder: env.wordpressFolder)
                clearSuppressionSoon(env.id)
            } catch {
                await store.removeEnv(id: reserved.id)
                clearSuppressionSoon(reserved.id)
                lastError = SiteLifecycleErrorText(error)
                lastErrorDetail = (error as? WorktreeError)?.fullDetail
            }
        }
    }

    public func startEnv(_ env: WorktreeEnv) {
        Task {
            // Guarded start (issue #5): a double-click / dot-spam start while
            // one is already in flight is silently ignored by the lifecycle.
            do { _ = try await lifecycle.startInstance(env) }
            catch { lastError = SiteLifecycleErrorText(error) }
        }
    }

    public func stopEnv(_ env: WorktreeEnv) {
        Task { await lifecycle.stop(env) }
    }

    /// Delete an env. The git branch is ALWAYS kept; `keepWorktree` optionally
    /// leaves the worktree checkout on disk (§2b context-menu option).
    public func deleteEnv(_ env: WorktreeEnv, keepWorktree: Bool = false) {
        Task {
            let parent = store.site(id: env.parentSiteID)
            await worktrees.delete(env, parent: parent, keepBranch: true, keepWorktree: keepWorktree)
            await store.removeEnv(id: env.id)
            if selection == env.id { selection = env.parentSiteID }
            try? await ca.removeLeafCoverage(["\(env.envSlug).localhost"])
        }
    }
}

/// Best-effort human-readable text for surfaced errors.
private func SiteLifecycleErrorText(_ error: Error) -> String {
    if let e = error as? ContainerCLIError { return e.description }
    if let e = error as? LifecycleError { return e.description }
    if let e = error as? GitError { return e.description }
    if let e = error as? WorktreeError { return e.description }
    return "\(error)"
}
