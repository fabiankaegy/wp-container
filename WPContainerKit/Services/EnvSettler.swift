import Foundation

public enum EnvSettlementError: Error, CustomStringConvertible, Sendable {
    case notFound(String)
    case busy(String)
    case noFreePort(String)

    public var description: String {
        switch self {
        case .notFound(let slug): return "No environment \(slug)."
        case .busy(let slug): return "\(slug) is starting or stopping; try again in a moment."
        case .noFreePort(let slug): return "No free port to restore \(slug) on."
        }
    }
}

/// Settles and restores worktree envs (see `EnvSettlement`) for the app, the
/// CLI and MCP, so every surface parks and revives them the same way.
public struct EnvSettler: Sendable {
    private let persistence: StorePersistence
    private let lifecycle: SiteLifecycle
    private let worktrees: WorktreeEnvService
    private let cli: ContainerCLI

    public init(persistence: StorePersistence, lifecycle: SiteLifecycle,
                worktrees: WorktreeEnvService, cli: ContainerCLI) {
        self.persistence = persistence
        self.lifecycle = lifecycle
        self.worktrees = worktrees
        self.cli = cli
    }

    /// Stop `env`, retire the parent's shared DB container when nothing else
    /// needs it, and mark the env settled. Its files, checkout and database are
    /// kept. Returns the settled record.
    @discardableResult
    public func settle(_ env: WorktreeEnv, parent: Site?) async throws -> WorktreeEnv {
        guard await lifecycle.stop(env) else { throw EnvSettlementError.busy(env.envSlug) }
        if let parent { await lifecycle.stopSharedDatabaseIfUnused(parent: parent) }
        guard let settled = try await persistence.settleEnv(id: env.id) else {
            throw EnvSettlementError.notFound(env.envSlug)
        }
        return settled
    }

    /// Clear `env`'s settled mark, re-acquire its ports and start it. An env
    /// that came back on a different port while its database still holds its
    /// loopback URL is migrated onto its domain, which doesn't depend on the
    /// port. Returns the env as persisted and any migration warnings.
    public func restore(_ env: WorktreeEnv, parent: Site?) async throws -> (env: WorktreeEnv, warnings: [String]) {
        guard let (restored, portChanged) = try await persistence.restoreEnv(id: env.id) else {
            throw EnvSettlementError.noFreePort(env.envSlug)
        }
        await persistence.recordActivity(instanceID: restored.id)
        try await lifecycle.startInstance(restored, dbProvider: parent)
        guard portChanged, !restored.usesDomainURL else { return (restored, []) }

        guard let dbHost = try await cli.ipAddress(of: restored.dbContainerName) else {
            return (restored, ["\(restored.envSlug) moved to port \(restored.port); run `wp-container worktree fix-urls \(restored.envSlug)` to update its URLs."])
        }
        let repair = try await worktrees.fixURLs(env: restored, parent: parent, dbHost: dbHost, dryRun: false,
                                                 extraCandidates: [env.localURL.absoluteString])
        let id = restored.id
        let https = repair.https
        let store = try await persistence.mutate { store in
            guard let i = store.envs.firstIndex(where: { $0.id == id }) else { return }
            store.envs[i].httpsEnabled = https
            store.envs[i].usesDomainURL = true
        }
        return (store.envs.first { $0.id == id } ?? restored, repair.warnings)
    }
}
