import Foundation

/// A local WordPress site. `Codable` for persistence; `status` is runtime-derived
/// and deliberately excluded from the coding keys.
public struct Site: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    public var slug: String
    /// Root folder of the site (contains `wordpress/`, `database/`, `.envs/`, `.worktrees/`).
    public var path: URL
    public var port: Int
    /// Full WordPress image reference, e.g. `wordpress:latest` or `wordpress:php8.3-apache`.
    public var imageTag: String
    /// Optional display string for the PHP version chosen at creation.
    public var phpVersion: String?
    public var createdAt: Date
    public var provisioned: Bool

    /// Runtime-derived; NOT persisted.
    public var status: SiteStatus = .stopped

    private enum CodingKeys: String, CodingKey {
        case id, name, slug, path, port, imageTag, phpVersion, createdAt, provisioned
    }

    public init(
        id: UUID = UUID(),
        name: String,
        slug: String,
        path: URL,
        port: Int,
        imageTag: String,
        phpVersion: String? = nil,
        createdAt: Date = Date(),
        provisioned: Bool = false,
        status: SiteStatus = .stopped
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.path = path
        self.port = port
        self.imageTag = imageTag
        self.phpVersion = phpVersion
        self.createdAt = createdAt
        self.provisioned = provisioned
        self.status = status
    }

    // MARK: Derived paths
    public var wordpressFolder: URL { path.appendingPathComponent("wordpress", isDirectory: true) }
    public var databaseFolder: URL { path.appendingPathComponent("database", isDirectory: true) }
    /// Hidden folders for worktree environments — never inside `wordpress/`.
    public var envsFolder: URL { path.appendingPathComponent(".envs", isDirectory: true) }
    public var worktreesFolder: URL { path.appendingPathComponent(".worktrees", isDirectory: true) }

    /// Absolute path of a repo living under this site's `wp-content`.
    public func repoURL(forRelativePath rel: String) -> URL {
        wordpressFolder.appendingPathComponent(rel, isDirectory: true)
    }
}

extension Site: RunnableInstance {
    public var instanceID: UUID { id }
    public var containerSlug: String { slug }
    public var siteSlug: String { slug }
    public var envSlug: String? { nil }
    public var displayName: String { name }
    public var isProvisioned: Bool { provisioned }
    public var extraMounts: [Mount] { [] }
}
