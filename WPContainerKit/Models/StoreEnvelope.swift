import Foundation

/// Versioned on-disk envelope for `sites.json`.
/// v1 held only `sites`; v2 adds `envs` for worktree environments.
public struct StoreEnvelope: Codable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var sites: [Site]
    public var envs: [WorktreeEnv]

    public init(version: Int = StoreEnvelope.currentVersion, sites: [Site] = [], envs: [WorktreeEnv] = []) {
        self.version = version
        self.sites = sites
        self.envs = envs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        self.sites = (try? c.decode([Site].self, forKey: .sites)) ?? []
        // `envs` absent in v1 files.
        self.envs = (try? c.decode([WorktreeEnv].self, forKey: .envs)) ?? []
    }
}
