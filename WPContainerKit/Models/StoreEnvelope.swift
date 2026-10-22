import Foundation

/// Versioned on-disk envelope for `sites.json`.
/// v1 held only `sites`; v2 adds `envs` for worktree environments;
/// v3 adds `groups` for sidebar site groups (PLAN.md §2g).
public struct StoreEnvelope: Codable, Sendable {
    public static let currentVersion = 3

    public var version: Int
    public var sites: [Site]
    public var envs: [WorktreeEnv]
    public var groups: [SiteGroup]
    /// Share provider used by instances that do not name one; nil means `ShareSettings.defaultProvider`.
    public var shareDefaultProvider: String?

    public init(version: Int = StoreEnvelope.currentVersion, sites: [Site] = [], envs: [WorktreeEnv] = [], groups: [SiteGroup] = [], shareDefaultProvider: String? = nil) {
        self.version = version
        self.sites = sites
        self.envs = envs
        self.groups = groups
        self.shareDefaultProvider = shareDefaultProvider
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        self.sites = (try? c.decode([Site].self, forKey: .sites)) ?? []
        // `envs` absent in v1 files.
        self.envs = (try? c.decode([WorktreeEnv].self, forKey: .envs)) ?? []
        // `groups` absent in v1/v2 files.
        self.groups = (try? c.decode([SiteGroup].self, forKey: .groups)) ?? []
        // Absent in stores written before site sharing.
        self.shareDefaultProvider = try? c.decodeIfPresent(String.self, forKey: .shareDefaultProvider)
    }

    /// The provider that serves `share`: its own choice, else the store default, else ngrok.
    public func effectiveProvider(for share: ShareSettings?) -> String {
        if let provider = share?.provider { return provider }
        return shareDefaultProvider ?? ShareSettings.defaultProvider
    }
}
