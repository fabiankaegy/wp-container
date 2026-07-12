import Foundation
import Observation

/// Observable, `@MainActor` store of sites + worktree envs, backed by the
/// file-locked `StorePersistence`. Because the `wp-container` CLI writes the
/// same file, the store watches it with a `DispatchSource` and live-reloads
/// external changes.
///
/// Runtime `status` is held in an in-memory map (never persisted) and re-applied
/// after every reload so CLI-triggered reloads don't wipe live status.
@MainActor
@Observable
public final class SiteStore {
    public private(set) var sites: [Site] = []
    public private(set) var envs: [WorktreeEnv] = []

    @ObservationIgnored private let persistence: StorePersistence
    @ObservationIgnored private var statusByID: [UUID: SiteStatus] = [:]
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var watchedFD: Int32 = -1

    public init(persistence: StorePersistence = StorePersistence()) {
        self.persistence = persistence
    }

    deinit {
        // The source's cancel handler closes the watched fd; just cancel here.
        watcher?.cancel()
    }

    /// Load from disk and begin watching for external changes.
    public func start() async {
        await reload()
        startWatching()
    }

    public func reload() async {
        guard let envelope = try? await persistence.load() else { return }
        sites = envelope.sites
        envs = envelope.envs
        applyStatuses()
    }

    // MARK: - Derived sets

    public var takenPorts: Set<Int> {
        Set(sites.map(\.port)).union(envs.map(\.port))
    }
    public var existingSlugs: Set<String> {
        Set(sites.map(\.slug))
    }
    public var existingEnvSlugs: Set<String> {
        Set(envs.map(\.envSlug))
    }

    public func site(id: UUID) -> Site? { sites.first { $0.id == id } }
    public func env(id: UUID) -> WorktreeEnv? { envs.first { $0.id == id } }
    public func envs(forSite siteID: UUID) -> [WorktreeEnv] { envs.filter { $0.parentSiteID == siteID } }

    // MARK: - Mutations (write-through to disk under lock)

    public func upsertSite(_ site: Site) async {
        await apply { env in
            if let i = env.sites.firstIndex(where: { $0.id == site.id }) {
                env.sites[i] = site
            } else {
                env.sites.append(site)
            }
        }
    }

    public func removeSite(id: UUID) async {
        statusByID[id] = nil
        await apply { env in
            env.sites.removeAll { $0.id == id }
            env.envs.removeAll { $0.parentSiteID == id }
        }
    }

    public func upsertEnv(_ wtEnv: WorktreeEnv) async {
        await apply { store in
            if let i = store.envs.firstIndex(where: { $0.id == wtEnv.id }) {
                store.envs[i] = wtEnv
            } else {
                store.envs.append(wtEnv)
            }
        }
    }

    public func removeEnv(id: UUID) async {
        statusByID[id] = nil
        await apply { env in env.envs.removeAll { $0.id == id } }
    }

    /// Update runtime status (not persisted). Ignored for unknown ids.
    public func setStatus(_ status: SiteStatus, for id: UUID) {
        statusByID[id] = status
        if let i = sites.firstIndex(where: { $0.id == id }) { sites[i].status = status }
        if let i = envs.firstIndex(where: { $0.id == id }) { envs[i].status = status }
    }

    // MARK: - Internals

    private func apply(_ body: @escaping @Sendable (inout StoreEnvelope) -> Void) async {
        guard let envelope = try? await persistence.mutate(body) else { return }
        sites = envelope.sites
        envs = envelope.envs
        applyStatuses()
    }

    private func applyStatuses() {
        for i in sites.indices {
            sites[i].status = statusByID[sites[i].id] ?? .stopped
        }
        for i in envs.indices {
            envs[i].status = statusByID[envs[i].id] ?? .stopped
        }
    }

    private func startWatching() {
        let path = persistence.fileURL.path
        // Ensure the file exists so we have something to watch.
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            Task { @MainActor in
                await self.reload()
                // Atomic replace swaps the inode — re-establish the watch.
                if flags.contains(.rename) || flags.contains(.delete) {
                    self.restartWatching()
                }
            }
        }
        source.setCancelHandler { [watchedFD] in
            if watchedFD >= 0 { close(watchedFD) }
        }
        watcher = source
        source.resume()
    }

    private func restartWatching() {
        watcher?.cancel()
        watcher = nil
        watchedFD = -1
        startWatching()
    }
}
