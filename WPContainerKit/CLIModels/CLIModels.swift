import Foundation

/// Stable, documented `--json` output structures for the `wp-container` CLI.
/// These are a public contract: field names here are what agents parse, so they
/// should only be extended additively.
public enum CLIJSON {
    /// A shared JSON encoder for CLI output (stable key ordering, ISO-8601 dates).
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func string<T: Encodable>(_ value: T) -> String {
        (try? String(data: encoder().encode(value), encoding: .utf8)) ?? "{}"
    }
}

/// One site in `wp-container list --json`.
public struct SiteJSON: Codable, Sendable {
    public let id: String
    public let name: String
    public let slug: String
    public let status: String       // stopped|starting|running|stopping|error
    public let url: String
    public let port: Int
    public let path: String
    public let image: String
    public let provisioned: Bool
    /// Sidebar group name, or nil when ungrouped (PLAN.md §2g).
    public let group: String?
    /// Mailbox (Mailpit web UI) URL when enabled, else nil (issue #10).
    public let mailboxUrl: String?

    public init(from site: Site, group: String? = nil) {
        self.id = site.id.uuidString
        self.name = site.name
        self.slug = site.slug
        self.status = site.status.token
        self.url = site.url.absoluteString   // effective URL via SiteURL (§2f/§2i)
        self.port = site.port
        self.path = site.path.path
        self.image = site.imageTag
        self.provisioned = site.provisioned
        self.group = group
        self.mailboxUrl = site.mailboxURL?.absoluteString
    }
}

/// One worktree env in `wp-container list --json` / `worktree list --json`.
public struct EnvJSON: Codable, Sendable {
    public let id: String
    public let envSlug: String
    public let parentSlug: String
    public let branch: String
    public let repoRelPath: String
    public let status: String
    public let url: String
    public let port: Int
    public let path: String
    public let worktreePath: String
    /// The persisted auto-stop-when-idle setting (issue #16): null = follow the
    /// built-in default, 0 = never, > 0 = minutes.
    public let idleStopMinutes: Int?
    /// The timeout actually in force with the default resolved; 0 = never. Agents
    /// should read THIS to know whether an env can be parked under them, and use
    /// the `set_idle_stop` MCP tool (or `wp-container idle`) to change it.
    public let effectiveIdleStopMinutes: Int
    /// Last recorded deliberate use — wp-cli, an MCP tool call, magic-login or an
    /// explicit start — from any process. null when never observed.
    public let lastActivityAt: Date?

    public init(from env: WorktreeEnv) {
        self.id = env.id.uuidString
        self.envSlug = env.envSlug
        self.parentSlug = env.parentSlug
        self.branch = env.branch
        self.repoRelPath = env.repoRelPath
        self.status = env.status.token
        self.url = env.localURL.absoluteString
        self.port = env.port
        self.path = env.envPath.path
        self.worktreePath = env.worktreePath.path
        self.idleStopMinutes = env.idleStopMinutes
        self.effectiveIdleStopMinutes = env.effectiveIdleStopMinutes
        self.lastActivityAt = env.lastActivityAt
    }
}

/// `wp-container list --json`.
public struct ListJSON: Codable, Sendable {
    public let sites: [SiteJSON]
    public let envs: [EnvJSON]
    public init(sites: [SiteJSON], envs: [EnvJSON]) {
        self.sites = sites
        self.envs = envs
    }
}

/// Descriptor emitted by `wp-container worktree create --json` (PLAN.md §2b.6).
public struct WorktreeDescriptor: Codable, Sendable {
    public let url: String
    public let port: Int
    public let path: String
    public let worktreePath: String
    public let branch: String
    public let envSlug: String
    public let containers: [String]
    /// The MySQL schema this env's WordPress uses. `wordpress` on its own server,
    /// or a `wpc_*` schema on the parent site's server when the database is
    /// shared (issue #17) — in which case `containers` lists the PARENT's db
    /// container, because that is genuinely the one it talks to.
    public let databaseName: String
    public let sharedDatabase: Bool
    /// Auto-stop-when-idle for the new env (issue #16): the persisted setting
    /// (null = default) and the timeout actually in force (0 = never). Reported at
    /// creation so an agent knows up front whether its environment can be parked.
    public let idleStopMinutes: Int?
    public let effectiveIdleStopMinutes: Int

    public init(from env: WorktreeEnv) {
        self.url = env.localURL.absoluteString
        self.port = env.port
        self.path = env.envPath.path
        self.worktreePath = env.worktreePath.path
        self.branch = env.branch
        self.envSlug = env.envSlug
        self.containers = [env.wpContainerName, env.dbContainerName]
        self.databaseName = env.databaseName
        self.sharedDatabase = env.sharedDatabase
        self.idleStopMinutes = env.idleStopMinutes
        self.effectiveIdleStopMinutes = env.effectiveIdleStopMinutes
    }
}

/// Error object printed to stderr (nonzero exit) when `--json` is set.
public struct CLIErrorJSON: Codable, Sendable, Error {
    public let error: String
    public let detail: String?
    public init(_ error: String, detail: String? = nil) {
        self.error = error
        self.detail = detail
    }
}
