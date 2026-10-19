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
    public private(set) var groups: [SiteGroup] = []

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
        groups = envelope.groups
        applyStatuses()
    }

    // MARK: - Derived sets

    public var takenPorts: Set<Int> {
        PortAllocator.reservedPorts(sites: sites, envs: envs)
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

    // MARK: - Groups (PLAN.md §2g)

    /// Groups sorted by their `sortOrder` (then name) for stable display.
    public var sortedGroups: [SiteGroup] {
        groups.sorted { ($0.sortOrder, $0.name.lowercased()) < ($1.sortOrder, $1.name.lowercased()) }
    }

    public func group(id: UUID) -> SiteGroup? { groups.first { $0.id == id } }
    public func group(named name: String) -> SiteGroup? {
        groups.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
    /// Sites belonging to a group (nil = the ungrouped section), preserving store order.
    public func sites(inGroup groupID: UUID?) -> [Site] {
        sites.filter { $0.groupID == groupID }
    }

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

    /// Stamp an instance's `lastActivityAt` (issue #16) — throttled and
    /// best-effort, see `StorePersistence.recordActivity`. Called for explicit
    /// user-driven starts so the idle sweep counts them as activity; NOT called
    /// for wake-triggered starts, which are the sweep undoing itself and must not
    /// extend their own deadline.
    ///
    /// Updates the in-memory record too rather than reloading: the whole point is
    /// to be cheap enough to call on every interaction.
    public func recordActivity(id: UUID, now: Date = Date()) async {
        await persistence.recordActivity(instanceID: id, now: now)
        if let i = sites.firstIndex(where: { $0.id == id }) { sites[i].lastActivityAt = now }
        if let i = envs.firstIndex(where: { $0.id == id }) { envs[i].lastActivityAt = now }
    }

    /// Set an instance's idle-stop timeout by ID inside the locked
    /// read-modify-write (issue #16). NOT `upsertSite(_:)` with a caller's
    /// snapshot: that writes back every field the view happened to be holding and
    /// would clobber a concurrent `pendingSchemaDrops` tombstone (#17) or provisioned
    /// flip. Matches `wp-container idle`'s mutate-by-id shape.
    public func setIdleStopMinutes(_ minutes: Int?, siteID: UUID) async {
        await apply { env in
            if let i = env.sites.firstIndex(where: { $0.id == siteID }) {
                env.sites[i].idleStopMinutes = minutes
            }
        }
    }

    public func setIdleStopMinutes(_ minutes: Int?, envID: UUID) async {
        await apply { store in
            if let i = store.envs.firstIndex(where: { $0.id == envID }) {
                store.envs[i].idleStopMinutes = minutes
            }
        }
    }

    /// Record and/or clear a site's shared-schema tombstones in one locked write
    /// (issue #17). `adding` is a schema a deletion could not drop because the DB
    /// server was down; `removing` are the ones a create just dropped for real.
    /// Read-modify-write on the LIVE record, never a caller's snapshot, so two
    /// concurrent env operations can't clobber each other's list.
    public func updatePendingSchemaDrops(siteID: UUID, adding: String? = nil, removing: [String] = []) async {
        guard adding != nil || !removing.isEmpty else { return }
        await apply { env in
            guard let i = env.sites.firstIndex(where: { $0.id == siteID }) else { return }
            if !removing.isEmpty {
                env.sites[i].pendingSchemaDrops.removeAll { removing.contains($0) }
            }
            if let adding, !env.sites[i].pendingSchemaDrops.contains(adding) {
                env.sites[i].pendingSchemaDrops.append(adding)
            }
        }
    }

    /// Allocate a free port and reserve it in ONE cross-process-locked
    /// read-modify-write, matching the CLI (#3 follow-up). `reserve` MUST record
    /// the port in the envelope (append the new site/env, or a placeholder a
    /// follow-up upsert replaces) so it is visible as taken to the next locked
    /// reader; its return value is handed back. Returns nil — with nothing
    /// written — only when no free port exists. The store adopts the updated
    /// envelope so the reservation is visible in-memory immediately.
    public func allocatePort<T: Sendable>(
        reserve: @Sendable @escaping (Int, inout StoreEnvelope) -> T
    ) async -> (port: Int, value: T)? {
        guard let result = try? await persistence.allocatePort(reserve: reserve) else { return nil }
        sites = result.envelope.sites
        envs = result.envelope.envs
        groups = result.envelope.groups
        applyStatuses()
        return (result.port, result.value)
    }

    /// Turn a sidecar on or off for a site (see `StorePersistence.setSidecar`).
    /// Returns the updated site, or nil when the site is gone or no port is free.
    public func setSidecar(_ addon: any SidecarAddon, enabled: Bool, siteID: UUID) async throws -> Site? {
        guard let result = try await persistence.setSidecar(addon, enabled: enabled, siteID: siteID) else { return nil }
        sites = result.envelope.sites
        envs = result.envelope.envs
        groups = result.envelope.groups
        applyStatuses()
        return result.site
    }

    // MARK: - Group mutations (write-through to disk under lock)

    /// Create a group (appended after existing ones) and return its id.
    @discardableResult
    public func addGroup(name: String) async -> UUID {
        let id = UUID()
        await apply { env in
            let nextOrder = (env.groups.map(\.sortOrder).max() ?? -1) + 1
            env.groups.append(SiteGroup(id: id, name: name, sortOrder: nextOrder))
        }
        return id
    }

    public func renameGroup(id: UUID, to name: String) async {
        await apply { env in
            if let i = env.groups.firstIndex(where: { $0.id == id }) { env.groups[i].name = name }
        }
    }

    /// Delete a group; its sites fall back to ungrouped (never deleted).
    public func deleteGroup(id: UUID) async {
        await apply { env in
            env.groups.removeAll { $0.id == id }
            for i in env.sites.indices where env.sites[i].groupID == id {
                env.sites[i].groupID = nil
            }
        }
    }

    /// Move a site into a group (nil = ungrouped).
    public func moveSite(_ siteID: UUID, toGroup groupID: UUID?) async {
        await apply { env in
            if let i = env.sites.firstIndex(where: { $0.id == siteID }) { env.sites[i].groupID = groupID }
        }
    }

    /// Persist a new group ordering (assigns ascending `sortOrder` in the given order).
    public func reorderGroups(_ orderedIDs: [UUID]) async {
        await apply { env in
            for (order, id) in orderedIDs.enumerated() {
                if let i = env.groups.firstIndex(where: { $0.id == id }) { env.groups[i].sortOrder = order }
            }
        }
    }

    /// The last-known runtime status for an instance id (nil if never tracked).
    public func status(for id: UUID) -> SiteStatus? { statusByID[id] }

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
        groups = envelope.groups
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
        // Re-entrancy guard: never stack a second watcher on the first (a
        // repeated `start()` would otherwise leak the old source + fd).
        if watcher != nil { return }
        let path = persistence.fileURL.path
        // Ensure the file exists so we have something to watch.
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // `open()` failing here (e.g. a transient race with an external
            // atomic-replace write) used to leave the watcher permanently dead —
            // nothing ever retried, so external edits (like a deleted group)
            // would silently stop reaching the UI until the app relaunched.
            // Retry shortly instead of giving up forever; `AppViewModel`'s 5s
            // reconcile loop also now reloads the store directly as a second,
            // independent backstop against this whole class of watcher misses.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.startWatching()
            }
            return
        }
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
