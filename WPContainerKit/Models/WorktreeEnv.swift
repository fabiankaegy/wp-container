import Foundation

/// A disposable clone of a parent site bound to a git worktree of one repo
/// inside it. See PLAN.md §2b.
public struct WorktreeEnv: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var parentSiteID: UUID
    /// Parent site slug (used for the `dev.wpcontainer.site` reconciliation label).
    public var parentSlug: String
    /// `<site-slug>-wt-<branch-slug>` — basis for container names and the
    /// `dev.wpcontainer.env` label.
    public var envSlug: String
    /// Repo path relative to `wordpress/`, e.g. `wp-content/plugins/my-plugin`.
    public var repoRelPath: String
    public var branch: String
    /// Git worktree checkout: `<site>/.worktrees/<branch-slug>/`.
    public var worktreePath: URL
    /// Cloned site+db root: `<site>/.envs/<branch-slug>/`.
    public var envPath: URL
    public var port: Int
    public var imageTag: String
    public var createdAt: Date
    public var provisioned: Bool
    /// Inherited from the parent site at creation (PLAN.md §2c): the env runs its
    /// own Xdebug image / Elasticsearch sidecar when the parent has them enabled.
    public var xdebugEnabled: Bool
    public var elasticsearchEnabled: Bool

    /// Runtime-derived; NOT persisted.
    public var status: SiteStatus = .stopped

    private enum CodingKeys: String, CodingKey {
        case id, parentSiteID, parentSlug, envSlug, repoRelPath, branch,
             worktreePath, envPath, port, imageTag, createdAt, provisioned,
             xdebugEnabled, elasticsearchEnabled
    }

    public init(
        id: UUID = UUID(),
        parentSiteID: UUID,
        parentSlug: String,
        envSlug: String,
        repoRelPath: String,
        branch: String,
        worktreePath: URL,
        envPath: URL,
        port: Int,
        imageTag: String,
        createdAt: Date = Date(),
        provisioned: Bool = false,
        xdebugEnabled: Bool = false,
        elasticsearchEnabled: Bool = false,
        status: SiteStatus = .stopped
    ) {
        self.id = id
        self.parentSiteID = parentSiteID
        self.parentSlug = parentSlug
        self.envSlug = envSlug
        self.repoRelPath = repoRelPath
        self.branch = branch
        self.worktreePath = worktreePath
        self.envPath = envPath
        self.port = port
        self.imageTag = imageTag
        self.createdAt = createdAt
        self.provisioned = provisioned
        self.xdebugEnabled = xdebugEnabled
        self.elasticsearchEnabled = elasticsearchEnabled
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.parentSiteID = try c.decode(UUID.self, forKey: .parentSiteID)
        self.parentSlug = try c.decode(String.self, forKey: .parentSlug)
        self.envSlug = try c.decode(String.self, forKey: .envSlug)
        self.repoRelPath = try c.decode(String.self, forKey: .repoRelPath)
        self.branch = try c.decode(String.self, forKey: .branch)
        self.worktreePath = try c.decode(URL.self, forKey: .worktreePath)
        self.envPath = try c.decode(URL.self, forKey: .envPath)
        self.port = try c.decode(Int.self, forKey: .port)
        self.imageTag = try c.decode(String.self, forKey: .imageTag)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.provisioned = (try? c.decode(Bool.self, forKey: .provisioned)) ?? false
        // Absent in envs written before §2c.
        self.xdebugEnabled = (try? c.decode(Bool.self, forKey: .xdebugEnabled)) ?? false
        self.elasticsearchEnabled = (try? c.decode(Bool.self, forKey: .elasticsearchEnabled)) ?? false
    }

    public var wordpressFolder: URL { envPath.appendingPathComponent("wordpress", isDirectory: true) }
    public var databaseFolder: URL { envPath.appendingPathComponent("database", isDirectory: true) }

    /// Compose the env slug from a parent slug + branch slug.
    public static func makeSlug(parentSlug: String, branch: String) -> String {
        "\(parentSlug)-wt-\(Slug.make(branch))"
    }
}

extension WorktreeEnv: RunnableInstance {
    public var instanceID: UUID { id }
    public var containerSlug: String { envSlug }
    public var siteSlug: String { parentSlug }
    public var envLabel: String? { envSlug }
    public var displayName: String { branch }
    public var isProvisioned: Bool { provisioned }
    /// The worktree checkout shadows the primary checkout inside the env container.
    /// Mount construction is isolated in `SiteRecipe` so integration can adjust it.
    public var extraMounts: [Mount] {
        [SiteRecipe.shadowMount(worktreePath: worktreePath, repoRelPath: repoRelPath)]
    }
}
