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
    /// Sidebar group this site belongs to (nil = ungrouped). See PLAN.md §2g.
    public var groupID: UUID?
    /// Whether trusted HTTPS is enabled for this site (PLAN.md §2f). When true the
    /// site's public URL is `https://<slug>.localhost` served by the host proxy.
    public var httpsEnabled: Bool
    /// Whether the Xdebug-enabled derived image is used for this site (PLAN.md §2c).
    public var xdebugEnabled: Bool
    /// Whether a per-site Elasticsearch sidecar container runs for this site (§2c).
    public var elasticsearchEnabled: Bool
    /// Optional custom domain (e.g. `mysite.local`), routed via /etc/hosts + the
    /// host proxy (PLAN.md §2i). nil = the zero-config `<slug>.localhost` name.
    public var customDomain: String?
    /// WordPress network type — single site or a multisite network (PLAN.md §2j).
    public var networkType: NetworkType

    /// Runtime-derived; NOT persisted.
    public var status: SiteStatus = .stopped

    private enum CodingKeys: String, CodingKey {
        case id, name, slug, path, port, imageTag, phpVersion, createdAt, provisioned, groupID, httpsEnabled
        case xdebugEnabled, elasticsearchEnabled, customDomain, networkType
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
        groupID: UUID? = nil,
        httpsEnabled: Bool = false,
        xdebugEnabled: Bool = false,
        elasticsearchEnabled: Bool = false,
        customDomain: String? = nil,
        networkType: NetworkType = .none,
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
        self.groupID = groupID
        self.httpsEnabled = httpsEnabled
        self.xdebugEnabled = xdebugEnabled
        self.elasticsearchEnabled = elasticsearchEnabled
        self.customDomain = customDomain
        self.networkType = networkType
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.slug = try c.decode(String.self, forKey: .slug)
        self.path = try c.decode(URL.self, forKey: .path)
        self.port = try c.decode(Int.self, forKey: .port)
        self.imageTag = try c.decode(String.self, forKey: .imageTag)
        self.phpVersion = try c.decodeIfPresent(String.self, forKey: .phpVersion)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.provisioned = (try? c.decode(Bool.self, forKey: .provisioned)) ?? false
        self.groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        // `httpsEnabled` absent in stores written before §2f.
        self.httpsEnabled = (try? c.decode(Bool.self, forKey: .httpsEnabled)) ?? false
        // The following are absent in stores written before §2c/§2i/§2j.
        self.xdebugEnabled = (try? c.decode(Bool.self, forKey: .xdebugEnabled)) ?? false
        self.elasticsearchEnabled = (try? c.decode(Bool.self, forKey: .elasticsearchEnabled)) ?? false
        self.customDomain = try? c.decodeIfPresent(String.self, forKey: .customDomain)
        self.networkType = (try? c.decodeIfPresent(NetworkType.self, forKey: .networkType)) ?? .none
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

    // MARK: HTTPS / domains (URL logic delegated to `SiteURL` — see §2f/§2i)
    /// The `<slug>.localhost` hostname served by the host HTTPS proxy.
    public var localhostHost: String { "\(slug).localhost" }
    /// Legacy alias retained for callers written before custom domains.
    public var httpsHost: String { primaryHost }
    /// The site's canonical hostname: a custom domain when set, else `<slug>.localhost`.
    public var primaryHost: String { (customDomain?.isEmpty == false ? customDomain! : localhostHost) }
    /// All hostnames the proxy/cert must cover for this site (§2i/§2j):
    /// `<slug>.localhost`, any custom domain, and a subdomain-multisite wildcard.
    public var proxyHosts: [String] {
        var hosts = [localhostHost]
        if let d = customDomain, !d.isEmpty { hosts.append(d) }
        if networkType.isSubdomain {
            hosts.append("*.\(localhostHost)")
            if let d = customDomain, !d.isEmpty { hosts.append("*.\(d)") }
        }
        return hosts
    }
    /// `https://<primary host>` — valid only while HTTPS is enabled and the proxy runs.
    public var secureURL: URL { SiteURL.secure(host: primaryHost) }
    /// The site's effective public URL: proxy host name when HTTPS or a custom
    /// domain is in play, else the local port.
    public var url: URL {
        SiteURL.effective(httpsEnabled: httpsEnabled, customDomain: customDomain, slug: slug, port: port)
    }
    /// The effective WP Admin URL, honoring HTTPS + custom domains.
    public var wpAdminURL: URL { url.appendingPathComponent("wp-admin") }
}

extension Site: RunnableInstance {
    public var instanceID: UUID { id }
    public var containerSlug: String { slug }
    public var siteSlug: String { slug }
    public var envLabel: String? { nil }
    public var displayName: String { name }
    public var isProvisioned: Bool { provisioned }
    public var extraMounts: [Mount] { [] }
}
