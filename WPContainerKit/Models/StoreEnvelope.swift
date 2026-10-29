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

    public init(version: Int = StoreEnvelope.currentVersion, sites: [Site] = [], envs: [WorktreeEnv] = [], groups: [SiteGroup] = []) {
        self.version = version
        self.sites = sites
        self.envs = envs
        self.groups = groups
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        self.sites = (try? c.decode([Site].self, forKey: .sites)) ?? []
        // `envs` absent in v1 files.
        self.envs = (try? c.decode([WorktreeEnv].self, forKey: .envs)) ?? []
        // `groups` absent in v1/v2 files.
        self.groups = (try? c.decode([SiteGroup].self, forKey: .groups)) ?? []
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
