import Foundation
import Observation
import WPContainerKit

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

    public var selection: UUID?
    public var systemStatus: SystemCheckResult?
    public var lastError: String?

    /// UI-intent flags so menu commands (and buttons) can drive sheet
    /// presentation from anywhere.
    public var presentingAddSite = false
    public var presentingNewEnv = false

    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    public init() {
        let cli = ContainerCLI()
        let git = GitService()
        let lifecycle = SiteLifecycle(cli: cli)
        self.cli = cli
        self.git = git
        self.lifecycle = lifecycle
        self.worktrees = WorktreeEnvService(cli: cli, git: git, lifecycle: lifecycle)
        self.systemCheck = SystemCheck(cli: cli)
        self.store = SiteStore()
    }

    public var sites: [Site] { store.sites }
    public var envs: [WorktreeEnv] { store.envs }

    // MARK: - Lifecycle of the view model

    public func onAppear() async {
        await store.start()
        await refreshSystemStatus()
        observeStatusEvents()
        startReconcileLoop()
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
                self?.store.setStatus(event.status, for: event.instanceID)
            }
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
    public func reconcile() async {
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
    public func createSite(name: String, parentFolder: URL? = nil, imageTag: String = SiteRecipe.defaultWordPressImage, phpVersion: String? = nil) async -> Site? {
        let root = parentFolder ?? SiteFolders.defaultSitesRoot
        let slug = Slug.unique(name, existing: store.existingSlugs)
        guard let port = PortAllocator.firstFreePort(excluding: store.takenPorts) else {
            lastError = "No free port available."
            return nil
        }
        let site = Site(name: name, slug: slug,
                        path: root.appendingPathComponent(slug, isDirectory: true),
                        port: port, imageTag: imageTag, phpVersion: phpVersion)
        await store.upsertSite(site)
        return site
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
    public func createAndStartSite(name: String, parentFolder: URL? = nil, imageTag: String = SiteRecipe.defaultWordPressImage, phpVersion: String? = nil) async -> Site? {
        guard let site = await createSite(name: name, parentFolder: parentFolder, imageTag: imageTag, phpVersion: phpVersion) else {
            return nil
        }
        selection = site.id
        do {
            let provisioned = try await lifecycle.startSite(site)
            if provisioned != site.provisioned {
                var updated = site
                updated.provisioned = provisioned
                await store.upsertSite(updated)
            }
        } catch {
            lastError = SiteLifecycleErrorText(error)
        }
        return site
    }

    /// Awaitable worktree-env creation for the "New Branch Environment" sheet:
    /// returns the created (already-started) env so the sheet can show its URL,
    /// or nil on failure (error surfaced via `lastError`).
    public func createEnvAwaiting(parent: Site, repoRelPath: String, branch: String, from: String? = nil) async -> WorktreeEnv? {
        guard let port = PortAllocator.firstFreePort(excluding: store.takenPorts) else {
            lastError = "No free port available."
            return nil
        }
        do {
            let env = try await worktrees.create(parent: parent, parentIsRunning: parent.status.isRunning,
                                                 repoRelPath: repoRelPath, branch: branch, from: from, port: port)
            await store.upsertEnv(env)
            return env
        } catch {
            lastError = SiteLifecycleErrorText(error)
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

    public func startSite(_ site: Site) {
        Task {
            do {
                let provisioned = try await lifecycle.startSite(site)
                if provisioned != site.provisioned {
                    var updated = site
                    updated.provisioned = provisioned
                    await store.upsertSite(updated)
                }
            } catch {
                lastError = SiteLifecycleErrorText(error)
            }
        }
    }

    public func stopSite(_ site: Site) {
        Task { await lifecycle.stop(site) }
    }

    public func deleteSite(_ site: Site, trashFolder: Bool) {
        Task {
            for env in store.envs(forSite: site.id) {
                await worktrees.delete(env, parent: site, keepBranch: true, keepWorktree: false)
                await store.removeEnv(id: env.id)
            }
            await lifecycle.deleteContainers(site)
            if trashFolder {
                try? FileManager.default.trashItem(at: site.path, resultingItemURL: nil)
            }
            await store.removeSite(id: site.id)
        }
    }

    // MARK: - Worktree env actions

    public func createEnv(parent: Site, repoRelPath: String, branch: String, from: String? = nil) {
        Task {
            guard let port = PortAllocator.firstFreePort(excluding: store.takenPorts) else {
                lastError = "No free port available."
                return
            }
            let parentRunning = parent.status.isRunning
            do {
                let env = try await worktrees.create(parent: parent, parentIsRunning: parentRunning,
                                                     repoRelPath: repoRelPath, branch: branch, from: from, port: port)
                await store.upsertEnv(env)
            } catch {
                lastError = SiteLifecycleErrorText(error)
            }
        }
    }

    public func startEnv(_ env: WorktreeEnv) {
        Task {
            do { _ = try await lifecycle.startContainers(env); await lifecycle.markRunning(env.id) }
            catch { lastError = SiteLifecycleErrorText(error) }
        }
    }

    public func stopEnv(_ env: WorktreeEnv) {
        Task { await lifecycle.stop(env) }
    }

    public func deleteEnv(_ env: WorktreeEnv) {
        Task {
            let parent = store.site(id: env.parentSiteID)
            await worktrees.delete(env, parent: parent, keepBranch: true, keepWorktree: false)
            await store.removeEnv(id: env.id)
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
