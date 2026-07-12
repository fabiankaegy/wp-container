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

    /// Runtime-derived; NOT persisted.
    public var status: SiteStatus = .stopped

    private enum CodingKeys: String, CodingKey {
        case id, parentSiteID, parentSlug, envSlug, repoRelPath, branch,
             worktreePath, envPath, port, imageTag, createdAt, provisioned
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
        self.status = status
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
