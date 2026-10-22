import AppKit
import Foundation
import Observation
import os
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
    @ObservationIgnored let settler: EnvSettler
    @ObservationIgnored let systemCheck: SystemCheck
    @ObservationIgnored let ca: CertificateAuthority
    @ObservationIgnored let httpsIntegration: HTTPSIntegration
    @ObservationIgnored let proxy: HTTPSProxy
    @ObservationIgnored let dbImporter: DatabaseImportService
    @ObservationIgnored let archiver: SiteArchiveService
    @ObservationIgnored let notifications = NotificationService.shared

    /// Instances whose start/stop status notifications are suppressed because an
    /// explicit create flow is driving them (it posts a "ready"/"created"
    /// notification instead of a bare "started"). Keyed by instance UUID.
    @ObservationIgnored private var suppressStatusNotify: Set<UUID> = []

    /// Instances currently being stopped by the proxy's idle sweep (issue #16), so
    /// the automatic stop doesn't post a "Stopped <name>" notification. Separate
    /// from `suppressStatusNotify` because it is cleared by the `.stopped` event
    /// itself rather than by that set's short create-flow timer.
    @ObservationIgnored private var suppressIdleStopNotify: Set<UUID> = []

    /// Runtime state of each shared instance, refreshed with the reconcile tick.
    public private(set) var shareStatuses: [UUID: ShareStatus] = [:]
    /// Instances whose share request is in flight (start, request, wait for the provider).
    public private(set) var sharesStarting: Set<UUID> = []
    /// The last failure of a share request, per instance.
    public private(set) var shareErrors: [UUID: String] = [:]
    /// The store-wide default share provider; nil means the built-in default.
    public private(set) var shareDefaultProvider: String?

    /// Instances whose pending share start was stopped by the user.
    @ObservationIgnored private var shareCancelled: Set<UUID> = []
    @ObservationIgnored private let shareControl = ShareControl(persistence: StorePersistence())

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
    /// Whether macOS Local Network Privacy is currently blocking this app from
    /// reaching the containers (v0.2.0 regression: the app shipped without
    /// `NSLocalNetworkUsageDescription`, so every env 502'd and every wake timed
    /// out with no visible cause). Mirrored from the proxy by `reconcile()` and
    /// rendered as a persistent, actionable banner — persistent because it is a
    /// TCC decision that nothing the user does inside this app can clear.
    ///
    /// Only ever true for the IN-APP proxy: a headless `wp-container proxy serve`
    /// is a different process with its own permission state, and it reports the
    /// denial on its own stderr/log.
    public var localNetworkDenied = false

    /// UI-intent flags so menu commands (and buttons) can drive sheet
    /// presentation from anywhere.
    public var presentingAddSite = false
    public var presentingNewEnv = false
    public var presentingImportDB = false
    /// Drives the one-time first-run offer to install the `wp-container` CLI.
    public var presentingCLIInstallOffer = false
    /// A dump file dropped on the site detail pane (§2m drag & drop) — set just
    /// before `presentingImportDB` so the sheet opens pre-filled with it.
    public var pendingImportDump: URL?
    public var presentingExportSite = false
    /// The site the export sheet exports.
    public var exportSiteTarget: Site?
    public var presentingImportSite = false
    /// A .zip dropped on the main window's panel, which the import sheet opens with.
    public var pendingImportArchive: URL?

    /// Whether the pre-import database backup was successfully restored after
    /// the last failed `importDatabase` call — nil when the last failure (if
    /// any) wasn't a database import. Read alongside `lastError`/`lastErrorDetail`.
    public var lastImportRolledBack: Bool?

    /// Whether the last failed `importSite` call removed the partly created site.
    public var lastSiteImportRolledBack = false

    /// WP × PHP version matrix for the setup pickers (PLAN.md §2k): starts from
    /// the cached/static matrix and is refreshed from Docker Hub at launch.
    public var versionMatrix: WordPressVersionMatrix = WordPressImageCatalog.fallbackMatrix

    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var purgeTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    public init() {
        let cli = ContainerCLI()
        let git = GitService()
        let lifecycle = SiteLifecycle(cli: cli)
        self.cli = cli
        self.git = git
        self.lifecycle = lifecycle
        let worktrees = WorktreeEnvService(cli: cli, git: git, lifecycle: lifecycle)
        self.worktrees = worktrees
        self.settler = EnvSettler(persistence: StorePersistence(), lifecycle: lifecycle, worktrees: worktrees, cli: cli)
        self.systemCheck = SystemCheck(cli: cli)
        let ca = CertificateAuthority()
        self.ca = ca
        self.httpsIntegration = HTTPSIntegration(cli: cli, ca: ca)
        // The proxy owns idle-stop and wake-on-request (issue #16), so it needs
        // the same lifecycle everything else in the app drives — handing it the
        // shared instance also means its in-flight claim guard (issue #5) dedupes
        // a wake against a concurrent UI start.
        self.proxy = HTTPSProxy(ca: ca, lifecycle: lifecycle)
        self.dbImporter = DatabaseImportService(cli: cli, lifecycle: lifecycle)
        self.archiver = SiteArchiveService(cli: cli, lifecycle: lifecycle, persistence: StorePersistence())
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
        startPurgeLoop()
        installIdleStopHook()
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
        return SiteRecipe.elasticsearchURL(esHost: ip)
    }

    public func setXdebug(_ site: Site, enabled: Bool) { toggleAddon(site) { $0.xdebugEnabled = enabled } }
    public func setElasticsearch(_ site: Site, enabled: Bool) { setSidecar(SidecarAddons.elasticsearch, site, enabled: enabled) }

    // MARK: - Mailpit (issue #10)

    /// Enable/disable the per-site Mailpit email catcher. The proxy's refresh
    /// loop picks up the new `<slug>-mail.localhost` host + cert SAN within a few
    /// seconds; the primary mailbox URL is the proxy-independent localhost port.
    public func setMailpit(_ site: Site, enabled: Bool) { setSidecar(SidecarAddons.mailpit, site, enabled: enabled) }

    /// Enable/disable the per-site Redis object-cache container.
    public func setRedis(_ site: Site, enabled: Bool) { setSidecar(SidecarAddons.redis, site, enabled: enabled) }

    /// Turn a sidecar on or off (syncing its PHP handler and reserving its host
    /// port on first enable), then restart a running site so the container
    /// recipe takes effect.
    private func setSidecar(_ addon: any SidecarAddon, _ site: Site, enabled: Bool) {
        Task {
            let result: Site?
            do {
                result = try await store.setSidecar(addon, enabled: enabled, siteID: site.id)
            } catch {
                lastError = SiteLifecycleErrorText(error)
                return
            }
            guard var updated = result else {
                lastError = "No free port available for \(addon.displayName)."
                return
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

    // MARK: - Site export and import

    /// A step surfaced by `exportSite`: starting a stopped site, or one of the
    /// archive service's export phases.
    public enum SiteExportStep: Sendable, Equatable {
        case startingSite
        case phase(SiteExportPhase)
    }

    /// Exports `site` to `destination`, starting it first when it is stopped.
    /// The save panel has already confirmed replacing an existing file.
    /// On failure, sets `lastError` and returns nil.
    @discardableResult
    public func exportSite(
        _ site: Site,
        to destination: URL,
        excludes: [String],
        onStep: @escaping @Sendable (SiteExportStep) -> Void
    ) async -> SiteExportSummary? {
        lastError = nil
        lastErrorDetail = nil

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
            return try await archiver.export(current, to: destination, excludes: excludes, overwrite: true) { phase in
                Task { @MainActor in onStep(.phase(phase)) }
            }
        } catch let error as SiteArchiveError {
            lastError = error.description
            return nil
        } catch {
            lastError = SiteLifecycleErrorText(error)
            return nil
        }
    }

    /// Creates a new site from `archive`, then reloads the store, refreshes
    /// proxy routing, and selects the site. On failure, sets `lastError` and
    /// `lastSiteImportRolledBack` and returns nil.
    @discardableResult
    public func importSite(
        _ archive: URL,
        options: SiteImportOptions,
        onStep: @escaping @Sendable (SiteImportPhase) -> Void
    ) async -> SiteImportResult? {
        lastError = nil
        lastErrorDetail = nil
        lastSiteImportRolledBack = false

        let rolledBack = OSAllocatedUnfairLock(initialState: false)
        do {
            let result = try await archiver.importSite(archive: archive, options: options) { phase in
                if phase == .rollingBack { rolledBack.withLock { $0 = true } }
                Task { @MainActor in onStep(phase) }
            }
            await store.reload()
            await refreshProxyRouting()
            selection = result.site.id
            return result
        } catch let error as SiteArchiveError {
            lastError = error.description
        } catch {
            lastError = SiteLifecycleErrorText(error)
        }
        lastSiteImportRolledBack = rolledBack.withLock { $0 }
        return nil
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

    // MARK: - Idle stop (issue #16)

    /// Persist a site's auto-stop-when-idle timeout. nil = follow the default
    /// (off), 0 = never, > 0 = minutes. Nothing to restart: the proxy re-reads the
    /// store every few seconds and enforces from there.
    ///
    /// Mutates by ID inside the locked read-modify-write rather than upserting the
    /// view's whole `Site` snapshot, which could clobber a concurrent write to an
    /// unrelated field (a `pendingSchemaDrops` tombstone, a `provisioned` flip).
    public func setIdleStop(_ site: Site, minutes: Int?) {
        Task { await store.setIdleStopMinutes(minutes, siteID: site.id) }
    }

    /// Same for a worktree env.
    public func setIdleStop(_ env: WorktreeEnv, minutes: Int?) {
        Task { await store.setIdleStopMinutes(minutes, envID: env.id) }
    }

    /// Keep the generic "Stopped <name>" banner out of automatic idle stops.
    /// The status event still flows (the sidebar/detail flip to Stopped as
    /// usual) — only the notification is suppressed, because a notification
    /// about something the user did not do reads as a failure rather than as the
    /// memory housekeeping it is.
    ///
    /// The proxy calls this from inside `SiteLifecycle.stop`'s `beforeStopping`
    /// hook, i.e. only after the claim succeeded — so a stop that no-ops because
    /// another action held the claim never arms suppression and never swallows an
    /// unrelated notification. It is awaited, so the flag is always set before the
    /// `.stopping`/`.stopped` events it covers.
    ///
    /// Cleared on ARRIVAL of that `.stopped` event rather than on a timer: the
    /// verify/escalate pass makes the duration of a stop genuinely unbounded from
    /// here, so any fixed window is either too short (un-suppresses early and the
    /// banner escapes) or too long (swallows the next real stop). The long timer is
    /// only a leak guard for a stop that never emits at all.
    private func installIdleStopHook() {
        proxy.setWillIdleStopHook { [weak self] id in
            await MainActor.run {
                guard let self else { return }
                self.suppressIdleStopNotify.insert(id)
                self.clearIdleSuppressionEventually(id)
            }
        }
    }

    /// Backstop only — the normal clear happens when `.stopped` arrives.
    private func clearIdleSuppressionEventually(_ id: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            self?.suppressIdleStopNotify.remove(id)
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

    /// The single in-flight `ensureProxyRunning()` run, so concurrent callers
    /// await one attempt instead of racing (issue #16 follow-through).
    ///
    /// This became load-bearing when env starts and env creation started calling
    /// it: the early-out checks (`ProxyControl.current()`, `proxy.boundPort`) both
    /// read state that only becomes true AFTER the `await proxy.start()` inside,
    /// and every caller is on the MainActor — so two entries that suspend at that
    /// await both proceed to `start()`, double-binding listeners and spinning two
    /// refresh + idle loops in one process.
    private var ensureProxyTask: Task<Void, Never>?

    /// Start the in-app HTTPS proxy unless an external `proxy serve` already owns
    /// the listener.
    public func ensureProxyRunning() async {
        if let existing = ensureProxyTask { await existing.value; return }
        let task = Task { @MainActor [weak self] in
            await self?.startProxyIfNeeded()
            return ()
        }
        ensureProxyTask = task
        await task.value
        ensureProxyTask = nil
    }

    private func startProxyIfNeeded() async {
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

    /// Whether anything depends on the reverse proxy for its URL to work at all:
    /// an HTTPS or custom-domain site (both route through the proxy, §2f/§2i), or
    /// ANY worktree env — an env's container publishes no host port, so the proxy
    /// is what serves its domain and `127.0.0.1:<port>` URLs (issue #16
    /// follow-through).
    private var anySiteNeedsProxy: Bool {
        if !store.envs.isEmpty { return true }
        return store.sites.contains { $0.httpsEnabled || $0.customDomain != nil }
    }

    /// Start the proxy whenever anything needs it — correctness must never
    /// depend on the opt-out launch setting (user-reported: after a relaunch
    /// nothing listened on 443 and every https/custom-domain site was dead).
    public func ensureProxyIfNeeded() async {
        if anySiteNeedsProxy { await ensureProxyRunning() }
    }

    /// Cheap liveness refresh for proxy status lines, in BOTH directions: adopt an
    /// externally-owned listener (e.g. `wp-container proxy serve`) if one has
    /// appeared, and clear a recorded port that no longer accepts.
    ///
    /// Clearing matters as much as adopting now that env URLs depend on the proxy:
    /// this value is what the env pane and the Idle stop card read to decide
    /// whether to warn, and a stale non-nil made both of them quietly reassuring
    /// about a proxy that had died.
    public func refreshProxyLiveness() {
        if let port = proxyPort {
            // Our own in-process listener is authoritative for us; otherwise the
            // recorded port must actually be accepting.
            if proxy.boundPort == port { return }
            if !ProxyControl.isPortAccepting(port) { proxyPort = ProxyControl.current()?.port }
            return
        }
        proxyPort = ProxyControl.current()?.port
    }

    /// Open System Settings → Privacy & Security → Local Network, where the user
    /// enables WP Container. The only fix for `localNetworkDenied`.
    public func openLocalNetworkSettings() {
        guard let url = URL(string: HTTPSProxy.localNetworkSettingsURL) else { return }
        NSWorkspace.shared.open(url)
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
            _ = try? WPCLIShim.writeShim(for: site, siteRoot: site.path, slug: site.slug)
        }
        for site in store.sites {
            guard let root = site.agentToolsRoot else { continue }
            let url = URL(fileURLWithPath: root)
            if WPCLIShim.shimNeedsRefresh(siteRoot: url) {
                _ = try? WPCLIShim.writeShim(for: site, siteRoot: url, slug: site.slug)
            }
        }
        if WPCLIShim.routerInstalled { _ = try? WPCLIShim.writeRouter() }
    }

    /// Open an interactive wp-cli shell for the site in the chosen terminal app (§2e).
    public func openWPCLI(_ site: Site) {
        let command = WPCLIShim.interactiveTerminalCommand(for: site, slug: site.slug)
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
        // Idle-stop suppression is consumed by the `.stopped` event it was armed
        // for — checked (and cleared) before the `NSApp.isActive` early return so
        // an app that happens to be frontmost still clears the flag instead of
        // leaving it to swallow a later, genuine stop.
        var suppressedByIdleStop = false
        if suppressIdleStopNotify.contains(event.instanceID) {
            suppressedByIdleStop = true
            if event.status == .stopped { suppressIdleStopNotify.remove(event.instanceID) }
        }
        guard !NSApp.isActive else { return }
        guard !suppressedByIdleStop else { return }
        guard !suppressStatusNotify.contains(event.instanceID) else { return }
        switch event.status {
        case .running where prior != .running:
            if let site = store.site(id: event.instanceID) {
                notifications.notifyStarted(name: site.name, url: site.url, faviconFolder: site.wordpressFolder)
            } else if let env = store.env(id: event.instanceID) {
                notifications.notifyStarted(name: "\(env.parentSlug) · \(env.branch)",
                                            url: env.url, faviconFolder: env.wordpressFolder)
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
    private func clearSuppressionSoon(_ id: UUID, after delay: Duration = .seconds(3)) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            self?.suppressStatusNotify.remove(id)
        }
    }

    // MARK: - Site sharing

    public func shareStatus(for instanceID: UUID) -> ShareStatus? {
        shareStatuses[instanceID]
    }

    /// Whether the instance's share is live and still wanted, which keeps a status the proxy
    /// has not yet withdrawn from showing after a stop.
    public func isShareLive(_ instanceID: UUID) -> Bool {
        guard shareStatuses[instanceID]?.state == .live else { return false }
        let share = store.site(id: instanceID)?.share ?? store.env(id: instanceID)?.share
        return share?.active == true
    }

    /// Validates the request, starts the instance when it is stopped, requests the share
    /// and waits for the provider to report `live` or `down`.
    public func startShare(_ instanceID: UUID, request: ShareRequest) async {
        guard !sharesStarting.contains(instanceID) else { return }
        sharesStarting.insert(instanceID)
        shareErrors[instanceID] = nil
        shareCancelled.remove(instanceID)
        defer {
            sharesStarting.remove(instanceID)
            shareCancelled.remove(instanceID)
        }
        do {
            await ensureProxyRunning()
            try await shareControl.validate(instanceID: instanceID, request)
            try await startInstanceForShare(instanceID)
            guard !shareCancelled.contains(instanceID) else { throw ShareError.cancelled }
            let settings = try await shareControl.request(instanceID: instanceID, request)
            let status = try await shareControl.waitForStatus(instanceID: instanceID, requestID: settings.requestID)
            shareStatuses[instanceID] = status
            if status.state == .down {
                shareErrors[instanceID] = status.error ?? "The share could not start."
            }
        } catch ShareError.cancelled {
            shareErrors[instanceID] = nil
        } catch {
            shareErrors[instanceID] = "\(error)"
        }
        await store.reload()
    }

    public func stopShare(_ instanceID: UUID) async {
        if sharesStarting.contains(instanceID) { shareCancelled.insert(instanceID) }
        do {
            try await shareControl.stop(instanceID: instanceID)
            shareStatuses[instanceID] = nil
            shareErrors[instanceID] = nil
        } catch {
            shareErrors[instanceID] = "\(error)"
        }
        await store.reload()
    }

    /// Writes the store-wide default provider; nil restores the built-in default.
    public func setDefaultShareProvider(_ name: String?) async {
        do {
            try await shareControl.setDefaultProvider(name)
            shareDefaultProvider = name
        } catch {
            lastError = "\(error)"
        }
    }

    public func loadShareDefaultProvider() async {
        shareDefaultProvider = (try? await StorePersistence().load())?.shareDefaultProvider
    }

    /// Names of the executables in the custom share-providers directory.
    public func customShareProviders() -> [String] {
        let directory = ProxyControl.directory.appendingPathComponent("share-providers", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") && FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent($0).path) }
            .sorted()
    }

    /// Whether this app hosts the proxy, and with it every share's provider.
    public var ownsProxy: Bool { proxy.boundPort != nil }

    /// Tears down the proxy and its shares off the main thread; bounded by the proxy's own timeout.
    public func stopProxyForQuit() async {
        guard ownsProxy else { return }
        let proxy = self.proxy
        await Task.detached { proxy.stop() }.value
    }

    private func startInstanceForShare(_ instanceID: UUID) async throws {
        if let site = store.site(id: instanceID) {
            if site.status.isRunning { return }
            if !site.status.isTransitional { startSite(site) }
        } else if let env = store.env(id: instanceID) {
            if env.status.isRunning { return }
            if !env.status.isTransitional { startEnv(env) }
        } else {
            throw ShareError.instanceNotFound(instanceID)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(180))
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(500))
            if shareCancelled.contains(instanceID) { throw ShareError.cancelled }
            let status = store.site(id: instanceID)?.status ?? store.env(id: instanceID)?.status
            guard let status else { throw ShareError.instanceNotFound(instanceID) }
            if status.isRunning { return }
            if case .error(let message) = status { throw ShareStartError.instanceFailed(message) }
        }
        throw ShareStartError.instanceFailed("It did not start in time.")
    }

    /// Reads the published share statuses and notifies when a share that was live goes down.
    private func refreshShares() {
        let proxy = ProxyControl.current()
        let published = proxy == nil ? [] : ProxyControl.shares()
        var next: [UUID: ShareStatus] = [:]
        for status in published { next[status.instanceID] = status }
        for (id, status) in next where status.state == .down && shareStatuses[id]?.state == .live {
            let instance: (any RunnableInstance)? = store.site(id: id) ?? store.env(id: id)
            // A share that went down is cleared in the store, so the request id tells it
            // from one the user stopped or requested again.
            guard let instance, let share = instance.share, share.requestID == status.requestID else { continue }
            let isUp = (store.site(id: id)?.status ?? store.env(id: id)?.status)?.isRunning == true
            guard isUp else { continue }
            let name = store.env(id: id).map { "\($0.parentSlug) · \($0.branch)" } ?? instance.displayName
            notifications.notifyShareDown(name: name, error: status.error ?? "The share stopped.")
        }
        if next != shareStatuses { shareStatuses = next }
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
        purgeTask?.cancel(); purgeTask = nil
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
        // Cheap lock read; the proxy latches the denial and clears it on the first
        // successful container dial, so this both raises and retires the banner.
        localNetworkDenied = proxy.isLocalNetworkDenied
        refreshShares()
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
                                   xdebugEnabled: Bool = false, elasticsearchEnabled: Bool = false,
                                   httpsEnabled: Bool = false, wpDebug: Bool = false, scriptDebug: Bool = false) async -> Site? {
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
            var updated = site
            updated.provisioned = provisioned
            // Apply New Site Defaults (Settings → Sites) now that wp-config.php and
            // the DB exist. Only ever turns things ON — an unchecked default leaves
            // WordPress' own value untouched. New sites only.
            if wpDebug { try? WPConfigService.setBoolConstant("WP_DEBUG", true, wordpressFolder: site.wordpressFolder) }
            if scriptDebug { try? WPConfigService.setBoolConstant("SCRIPT_DEBUG", true, wordpressFolder: site.wordpressFolder) }
            if httpsEnabled {
                do {
                    try await httpsIntegration.enable(updated)
                    updated.httpsEnabled = true
                    await refreshProxyRouting()
                } catch { lastError = SiteLifecycleErrorText(error) }
            }
            await store.upsertSite(updated)
            // Install the global wp router once, if the default is on and it isn't
            // already active. Idempotent and reversible from a site's Integrations
            // settings; guarded so it never fights a user who removed it and the
            // preference is off.
            if AppSettings.defaultGlobalWPRouter, !globalWPInstalled { setGlobalWP(enabled: true) }
            notifications.notifySiteCreated(name: updated.name, url: updated.url, faviconFolder: updated.wordpressFolder)
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
    public func createEnvAwaiting(parent: Site, repoRelPath: String, branch: String, from: String? = nil,
                                  provision: Bool = true, isolatedDB: Bool = false) async -> WorktreeEnv? {
        // The new env's URL is served by the proxy, so make sure there is one
        // before the sheet shows that URL as a link (issue #16 follow-through).
        await ensureProxyRunning()
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
            let outcome = try await worktrees.create(parent: parent, parentIsRunning: parent.status.isRunning,
                                                    repoRelPath: repoRelPath, branch: branch, from: from,
                                                    port: reserved.port, reserved: reserved, provision: provision,
                                                    isolatedDB: isolatedDB)
            let env = outcome.env
            await store.upsertEnv(env)
            // Clear exactly the tombstones whose DROP succeeded (#17).
            await store.updatePendingSchemaDrops(siteID: parent.id, removing: outcome.reapedSchemas)
            notifications.notifyEnvReady(branch: env.branch, parent: parent.name,
                                         url: env.url, faviconFolder: env.wordpressFolder)
            clearSuppressionSoon(env.id)
            // e.g. the shared-database safety fallback (#17) — surfaced without
            // failing the creation.
            let warnings = await lifecycle.drainWarnings(for: env.id)
            if !warnings.isEmpty { lastError = warnings.joined(separator: "\n") }
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

    /// Start ONLY the site's own containers — worktree envs are left alone
    /// (issue #18: fan-out is opt-in). See `startSiteWithEnvs(_:)` for the
    /// coupled behavior.
    public func startSite(_ site: Site) {
        startSiteCoupled(site, includeEnvs: false)
    }

    /// Coupled lifecycle (§2b): starting a site also starts all of its worktree
    /// envs (parent first, then envs; individual failures surfaced together).
    /// Opt-in since issue #18 — exposed as a separate "Start with Environments"
    /// affordance in the UI.
    public func startSiteWithEnvs(_ site: Site) {
        startSiteCoupled(site, includeEnvs: true)
    }

    private func startSiteCoupled(_ site: Site, includeEnvs: Bool) {
        Task {
            // A start the user clicked is unambiguous activity (issue #16), so the
            // idle sweep can't park it before they've done anything with it. Wakes
            // deliberately don't stamp — that would let the sweep feed itself.
            await store.recordActivity(id: site.id)
            // Settled envs stay parked; starting one restores it.
            let envs = includeEnvs ? store.envs(forSite: site.id).filter { !$0.isSettled } : []
            // An HTTPS/custom-domain site is unreachable without the reverse
            // proxy — ensure it's listening whenever such a site starts (covers
            // proxy crashed/killed/never-started cases, §2f fix). So is every
            // worktree env in the fan-out, whose port the proxy now owns outright
            // (issue #16 follow-through).
            if site.httpsEnabled || site.customDomain != nil || !envs.isEmpty {
                await ensureProxyRunning()
            }
            let outcome = await lifecycle.startSiteWithEnvs(site, envs: envs)
            if outcome.provisioned != site.provisioned {
                var updated = site
                updated.provisioned = outcome.provisioned
                await store.upsertSite(updated)
            }
            if let summary = outcome.errorSummary {
                lastError = summary
            } else if !outcome.warnings.isEmpty {
                lastError = outcome.warnings.joined(separator: "\n")
            }
        }
    }

    /// Coupled lifecycle (§2b): stopping a site also stops its worktree envs.
    public func stopSite(_ site: Site) {
        Task {
            let envs = store.envs(forSite: site.id)
            await lifecycle.stopSiteWithEnvs(site, envs: envs)
            await surfaceStopWarnings([site.id] + envs.map(\.id))
        }
    }

    /// Surface teardown problems the stop path recorded (issue #16): a container
    /// that survived both `container stop` and `container delete` is still
    /// holding its VM's memory, which is precisely what the user is stopping to
    /// reclaim — so it goes in the error banner rather than nowhere. Matches how
    /// `startSiteCoupled` surfaces non-fatal start warnings.
    private func surfaceStopWarnings(_ ids: [UUID]) async {
        var warnings: [String] = []
        for id in ids { warnings.append(contentsOf: await lifecycle.drainWarnings(for: id)) }
        if !warnings.isEmpty { lastError = warnings.joined(separator: "\n") }
    }

    /// Whether anything this app started is currently running — the quit hook
    /// uses this to terminate immediately when there's nothing to wind down.
    public var hasRunningInstances: Bool {
        store.sites.contains { $0.status.isRunning } || store.envs.contains { $0.status.isRunning }
    }

    /// Stop every running site (and its worktree envs) so that fully quitting the
    /// app never leaves containers running in the background. Called from the
    /// app's `applicationShouldTerminate` (which defers termination until this
    /// returns). Stops run concurrently; also catches any orphan running env
    /// whose parent site is already stopped.
    public func stopAllForQuit() async {
        let lifecycle = self.lifecycle
        let runningSites = store.sites.filter { $0.status.isRunning }
        let runningSiteIDs = Set(runningSites.map(\.id))
        let orphanEnvs = store.envs.filter { $0.status.isRunning && !runningSiteIDs.contains($0.parentSiteID) }
        let siteEnvs = runningSites.map { ($0, store.envs(forSite: $0.id)) }
        // `verifyTeardown: false` — quit must not inherit the per-instance
        // verify/escalate polling (issue #16): it is bounded per stop, but N
        // instances would add up to a Dock icon bouncing for a minute, and macOS
        // will kill us anyway if `applicationShouldTerminate` takes too long.
        // Quitting keeps exactly its pre-#16 behaviour: issue the stops, go.
        await withTaskGroup(of: Void.self) { group in
            for (site, envs) in siteEnvs {
                group.addTask { await lifecycle.stopSiteWithEnvs(site, envs: envs, verifyTeardown: false) }
            }
            for env in orphanEnvs {
                group.addTask { _ = await lifecycle.stop(env, verifyTeardown: false) }
            }
        }
        // An orphan env's parent site was already stopped, so its shared DB
        // container (issue #17) is nobody's `stopCore` responsibility — retire it
        // here, after every stop above has settled, or quitting the app would
        // leave a MariaDB VM running.
        let orphanParents = Set(orphanEnvs.filter { !$0.ownsDatabaseContainer }.map(\.parentSiteID))
        for parentID in orphanParents {
            guard let parent = store.site(id: parentID) else { continue }
            await lifecycle.stopSharedDatabaseIfUnused(parent: parent)
        }
    }

    /// First-run offer to install the `wp-container` CLI. Fires at most once
    /// (guarded by `AppSettings.didOfferCLIInstall`): if the CLI is embedded but
    /// not yet installed, present the offer sheet; if it's already installed (or
    /// this build has no embedded CLI), just record that we've considered it so
    /// the offer never appears. Users can always (re)install from Settings.
    public func maybeOfferCLIInstall() {
        guard !AppSettings.didOfferCLIInstall else { return }
        guard CLIToolInstaller.embeddedCLIURL != nil else { return } // dev build w/o embed
        AppSettings.didOfferCLIInstall = true
        if CLIToolInstaller.currentState() == .notInstalled {
            presentingCLIInstallOffer = true
        }
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
            let staleHosts = site.proxyHosts + childEnvs.map { $0.domainHost }
            try? await ca.removeLeafCoverage(staleHosts)
        }
    }

    // MARK: - Worktree env actions

    public func createEnv(parent: Site, repoRelPath: String, branch: String, from: String? = nil,
                          provision: Bool = true, isolatedDB: Bool = false) {
        Task {
            // The env's URL is served by the proxy (issue #16 follow-through).
            await ensureProxyRunning()
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
                let outcome = try await worktrees.create(parent: parent, parentIsRunning: parentRunning,
                                                        repoRelPath: repoRelPath, branch: branch, from: from,
                                                        port: reserved.port, reserved: reserved, provision: provision,
                                                        isolatedDB: isolatedDB)
                let env = outcome.env
                await store.upsertEnv(env)
                // Clear exactly the tombstones whose DROP succeeded (#17).
                await store.updatePendingSchemaDrops(siteID: parent.id, removing: outcome.reapedSchemas)
                notifications.notifyEnvReady(branch: env.branch, parent: parent.name,
                                             url: env.url, faviconFolder: env.wordpressFolder)
                clearSuppressionSoon(env.id)
                let warnings = await lifecycle.drainWarnings(for: env.id)
                if !warnings.isEmpty { lastError = warnings.joined(separator: "\n") }
            } catch {
                await store.removeEnv(id: reserved.id)
                clearSuppressionSoon(reserved.id)
                lastError = SiteLifecycleErrorText(error)
                lastErrorDetail = (error as? WorktreeError)?.fullDetail
            }
        }
    }

    public func startEnv(_ env: WorktreeEnv) {
        guard !env.isSettled else { return restoreEnv(env) }
        Task {
            // An env's URL is SERVED BY THE PROXY (issue #16 follow-through): its
            // container publishes no host port, so without the proxy (on 443/80
            // for its domain, `127.0.0.1:<port>` for its loopback URL) the env
            // starts fine but nothing answers. Same
            // treatment HTTPS/custom-domain sites already get.
            await ensureProxyRunning()
            // Guarded start (issue #5): a double-click / dot-spam start while
            // one is already in flight is silently ignored by the lifecycle.
            // The parent rides along as `dbProvider` so a shared-database env can
            // boot the server it borrows when the parent site is down (#17).
            let parent = store.site(id: env.parentSiteID)
            await store.recordActivity(id: env.id)
            do { _ = try await lifecycle.startInstance(env, dbProvider: parent) }
            catch { lastError = SiteLifecycleErrorText(error) }
        }
    }

    public func stopEnv(_ env: WorktreeEnv) {
        Task {
            await lifecycle.stop(env)
            // Retire a shared DB container nothing needs any more, or a stopped
            // env would leave its parent's ~470 MB server behind (#17).
            var ids = [env.id]
            if let parent = store.site(id: env.parentSiteID) {
                await lifecycle.stopSharedDatabaseIfUnused(parent: parent)
                ids.append(parent.id)
            }
            await surfaceStopWarnings(ids)
        }
    }

    /// Delete an env. The git branch is ALWAYS kept; `keepWorktree` optionally
    /// leaves the worktree checkout on disk (§2b context-menu option).
    public func deleteEnv(_ env: WorktreeEnv, keepWorktree: Bool = false) {
        Task {
            let parent = store.site(id: env.parentSiteID)
            let outcome = await worktrees.delete(env, parent: parent, keepBranch: true, keepWorktree: keepWorktree)
            await store.removeEnv(id: env.id)
            if let parent {
                // The DB server was down, so the schemas are still there (#17) —
                // tombstone them for the next shared-env create to reap.
                await store.updatePendingSchemaDrops(siteID: parent.id, adding: outcome.tombstonedSchemas)
                await lifecycle.stopSharedDatabaseIfUnused(parent: parent)
            }
            if selection == env.id { selection = env.parentSiteID }
            try? await ca.removeLeafCoverage([env.domainHost])
        }
    }

    // MARK: - Settling (see `EnvSettlement`)

    /// Settle envs: stop each, release its ports and keep its data. Sequential,
    /// so a batch doesn't race to retire the parent's shared DB container.
    public func settleEnvs(_ envs: [WorktreeEnv]) {
        Task {
            for env in envs where !env.isSettled {
                do { try await settler.settle(env, parent: store.site(id: env.parentSiteID)) }
                catch { lastError = SiteLifecycleErrorText(error) }
                if selection == env.id { selection = env.parentSiteID }
            }
            await store.reload()
        }
    }

    /// Bring a settled env back on a port and start it. A legacy env that lands
    /// on a new port gets its URLs migrated onto its domain.
    public func restoreEnv(_ env: WorktreeEnv) {
        Task {
            await ensureProxyRunning()
            do {
                let (_, warnings) = try await settler.restore(env, parent: store.site(id: env.parentSiteID))
                if !warnings.isEmpty { lastError = warnings.joined(separator: "\n") }
            } catch {
                lastError = SiteLifecycleErrorText(error)
            }
            await store.reload()
        }
    }

    /// Purge settled envs on launch and hourly after.
    private func startPurgeLoop() {
        guard purgeTask == nil else { return }
        purgeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.purgeSettledEnvs()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// Delete envs that stayed settled past the window in Settings. A checkout
    /// with uncommitted changes stays on disk; the env itself goes either way,
    /// and the branch is always kept.
    private func purgeSettledEnvs() async {
        guard AppSettings.autoPurgeSettledEnvs else { return }
        let days = AppSettings.purgeSettledAfterDays
        let due = store.envs.filter { EnvSettlement.isDueForPurge($0, afterDays: days) }
        guard !due.isEmpty else { return }
        var kept = 0
        for env in due {
            let dirty = await git.hasUncommittedChanges(at: env.worktreePath)
            if dirty { kept += 1 }
            deleteEnv(env, keepWorktree: dirty)
        }
        notifications.notifyEnvsPurged(branches: due.map(\.branch), keptCheckouts: kept)
    }
}

/// Best-effort human-readable text for surfaced errors.
private func SiteLifecycleErrorText(_ error: Error) -> String {
    if let e = error as? ContainerCLIError { return e.description }
    if let e = error as? LifecycleError { return e.description }
    if let e = error as? GitError { return e.description }
    if let e = error as? WorktreeError { return e.description }
    if let e = error as? EnvSettlementError { return e.description }
    return "\(error)"
}

private enum ShareStartError: Error, CustomStringConvertible {
    case instanceFailed(String)

    var description: String {
        switch self {
        case .instanceFailed(let message): return "The site could not start: \(message)"
        }
    }
}
