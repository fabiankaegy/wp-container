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

    /// Clear `id`'s archive mark and restart the purge window of its settled
    /// envs: they sat out the archive, so a site archived for longer than the
    /// window doesn't lose them on the first purge after it comes back.
    /// Returns false when the site is gone or wasn't archived.
    public mutating func unarchiveSite(id: UUID, now: Date = Date()) -> Bool {
        guard let i = sites.firstIndex(where: { $0.id == id }), sites[i].isArchived else { return false }
        sites[i].archivedAt = nil
        for j in envs.indices where envs[j].parentSiteID == id && envs[j].isSettled {
            envs[j].settledAt = now
        }
        return true
    }
}
