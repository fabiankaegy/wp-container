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
    /// Whether a per-site Mailpit email-catcher container runs for this site
    /// (issue #10). When on, outgoing WordPress mail is routed to Mailpit's SMTP
    /// and browsable in its web UI.
    public var mailpitEnabled: Bool
    /// Auto-allocated localhost port the Mailpit web UI is published on (issue
    /// #10). Assigned on first enable and kept (stable mailbox URL, reserved
    /// against other sites); nil until Mailpit has ever been enabled.
    public var mailpitPort: Int?
    /// Whether a per-site Redis container runs for the object cache.
    public var redisEnabled: Bool
    /// Optional per-site CPU cap passed to `container run --cpus` (issue #11).
    /// nil = the `container` default (4).
    public var cpuLimit: Int?
    /// Optional per-site memory cap in MB passed to `container run --memory`
    /// (issue #11). nil = the `container` default (1024 MB).
    public var memoryLimitMB: Int?
    /// Optional per-site auto-stop-when-idle timeout in minutes (issue #16).
    /// nil = the built-in default (`IdlePolicy.defaultSiteMinutes`, i.e. OFF —
    /// a site publishes its own port, so a direct `127.0.0.1:<port>` hit is
    /// invisible to the idle clock and auto-stopping a site stays opt-in;
    /// worktree envs, whose port the proxy owns, default to ON); 0 = explicitly off;
    /// > 0 = stop after that many idle minutes. Enforced by the HTTPS proxy,
    /// which also wakes the site on the next request.
    public var idleStopMinutes: Int?
    /// Last time any process observed deliberate use of this site (issue #16) —
    /// wp-cli, an MCP tool call, a magic-login link, or an explicit start. Feeds
    /// the idle sweep alongside the proxy's in-memory request tracking, so work
    /// that never goes through the proxy still counts as activity. Written
    /// throttled by `StorePersistence.recordActivity`.
    public var lastActivityAt: Date?
    /// Optional custom domain (e.g. `mysite.local`), routed via /etc/hosts + the
    /// host proxy (PLAN.md §2i). nil = the zero-config `<slug>.localhost` name.
    public var customDomain: String?
    /// WordPress network type — single site or a multisite network (PLAN.md §2j).
    public var networkType: NetworkType
    /// Where the agent-tools artifacts (MCP configs + doc) were written, so
    /// disable/regenerate targets the same place (PLAN.md §2d rework). nil = the
    /// site folder default. Absolute path.
    public var agentToolsRoot: String?
    /// The doc filename the agent-tools block was written into (AGENTS.md or
    /// CLAUDE.md).
    public var agentToolsDoc: String?
    /// The source URL detected (or overridden) during the last Database
    /// Importer run (PLAN.md §2m) — the `home` option value read from the
    /// imported dump right after `wp db import`, or the caller's override. Powers
    /// the "Load from source site" remote-media mu-plugin (`RemoteMediaService`),
    /// which needs a known source host to rewrite missing upload URLs against.
    /// nil until a database has ever been imported into this site.
    public var lastImportSourceURL: String?
    /// TOMBSTONES: schemas on this site's MariaDB server that belonged to a
    /// deleted shared-database worktree env but could not be dropped at deletion
    /// time because the server was down (issue #17).
    ///
    /// An explicit list, deliberately: the alternative — listing `wpc\_%` on the
    /// server and dropping whatever no live env record claims — races any
    /// concurrent env creation, whose schema exists before its record does, and
    /// the loser's fresh database gets DROPped. We only ever drop names we
    /// recorded ourselves. Consequence: a schema orphaned by a hard crash
    /// mid-create is never reaped. Leaking beats destroying.
    ///
    /// Reaped by `WorktreeEnvService.create` on the shared path, where the server
    /// is guaranteed up; entries are cleared once their DROP actually succeeds.
    public var pendingSchemaDrops: [String] = []
    /// Host folders bind-mounted into the site's WordPress tree, such as a
    /// project mounted as a plugin by `create --wp-env` (`.wp-env.json`'s local
    /// plugins, themes, and mappings). Edits in those folders reach the site
    /// live.
    public var mounts: [Mount] = []

    /// Runtime-derived; NOT persisted.
    public var status: SiteStatus = .stopped

    private enum CodingKeys: String, CodingKey {
        case id, name, slug, path, port, imageTag, phpVersion, createdAt, provisioned, groupID, httpsEnabled
        case xdebugEnabled, elasticsearchEnabled, customDomain, networkType
        case agentToolsRoot, agentToolsDoc
        case cpuLimit, memoryLimitMB
        case idleStopMinutes, lastActivityAt
        case mailpitEnabled, mailpitPort
        case redisEnabled
        case lastImportSourceURL
        case pendingSchemaDrops
        case mounts
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
        mailpitEnabled: Bool = false,
        mailpitPort: Int? = nil,
        redisEnabled: Bool = false,
        cpuLimit: Int? = nil,
        memoryLimitMB: Int? = nil,
        idleStopMinutes: Int? = nil,
        lastActivityAt: Date? = nil,
        customDomain: String? = nil,
        networkType: NetworkType = .none,
        agentToolsRoot: String? = nil,
        agentToolsDoc: String? = nil,
        lastImportSourceURL: String? = nil,
        pendingSchemaDrops: [String] = [],
        mounts: [Mount] = [],
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
        self.mailpitEnabled = mailpitEnabled
        self.mailpitPort = mailpitPort
        self.redisEnabled = redisEnabled
        self.cpuLimit = cpuLimit
        self.memoryLimitMB = memoryLimitMB
        self.idleStopMinutes = idleStopMinutes
        self.lastActivityAt = lastActivityAt
        self.customDomain = customDomain
        self.networkType = networkType
        self.agentToolsRoot = agentToolsRoot
        self.agentToolsDoc = agentToolsDoc
        self.lastImportSourceURL = lastImportSourceURL
        self.pendingSchemaDrops = pendingSchemaDrops
        self.mounts = mounts
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
        // Absent in stores written before issue #10.
        self.mailpitEnabled = (try? c.decode(Bool.self, forKey: .mailpitEnabled)) ?? false
        self.mailpitPort = try? c.decodeIfPresent(Int.self, forKey: .mailpitPort)
        self.redisEnabled = (try? c.decode(Bool.self, forKey: .redisEnabled)) ?? false
        // Absent in stores written before issue #11.
        self.cpuLimit = try? c.decodeIfPresent(Int.self, forKey: .cpuLimit)
        self.memoryLimitMB = try? c.decodeIfPresent(Int.self, forKey: .memoryLimitMB)
        // Absent in stores written before issue #16 — decodes to nil, which means
        // "use the default", which for a SITE is off. Old stores therefore keep
        // exactly today's behaviour (nothing is ever auto-stopped).
        self.idleStopMinutes = try? c.decodeIfPresent(Int.self, forKey: .idleStopMinutes)
        // Also absent before issue #16. nil reads as "never observed", which the
        // sweep treats as no evidence rather than as ancient — see
        // `HTTPSProxy.idleMinutes`.
        self.lastActivityAt = try? c.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        self.customDomain = try? c.decodeIfPresent(String.self, forKey: .customDomain)
        self.networkType = (try? c.decodeIfPresent(NetworkType.self, forKey: .networkType)) ?? .none
        self.agentToolsRoot = try? c.decodeIfPresent(String.self, forKey: .agentToolsRoot)
        self.agentToolsDoc = try? c.decodeIfPresent(String.self, forKey: .agentToolsDoc)
        // Absent in stores written before the Database Importer (§2m).
        self.lastImportSourceURL = try? c.decodeIfPresent(String.self, forKey: .lastImportSourceURL)
        // Absent in stores written before issue #17. Only ever holds env and test
        // schema names (`WorktreeEnvService.isReapableSchemaName`); a hand-edited
        // store can't widen the blast radius because every drop re-checks.
        self.pendingSchemaDrops = ((try? c.decodeIfPresent([String].self, forKey: .pendingSchemaDrops)) ?? [])
            ?? []
        // Absent in stores written before `create --wp-env`.
        self.mounts = ((try? c.decodeIfPresent([Mount].self, forKey: .mounts)) ?? []) ?? []
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
    /// Compact host label for lists/menus, derived from the effective URL — the
    /// single source of truth (§2f/§2i): `localhost:<port>` for a plain local
    /// site, else the proxy hostname.
    public var displayHost: String {
        if (customDomain?.isEmpty ?? true) && !httpsEnabled { return "localhost:\(port)" }
        return primaryHost
    }
}

extension Site: RunnableInstance {
    public var instanceID: UUID { id }
    public var containerSlug: String { slug }
    public var siteSlug: String { slug }
    public var envLabel: String? { nil }
    public var displayName: String { name }
    public var isProvisioned: Bool { provisioned }
    public var extraMounts: [Mount] { mounts }
    /// `<slug>.localhost` plus any custom domain. Subdomain-multisite wildcards
    /// are omitted — /etc/hosts can't express them; subsite loopbacks would
    /// need per-subsite entries (acceptable gap, matches the proxy SAN story).
    public var loopbackHosts: [String] {
        var hosts = [localhostHost]
        if let d = customDomain, !d.isEmpty { hosts.append(d.lowercased()) }
        return hosts
    }
}
