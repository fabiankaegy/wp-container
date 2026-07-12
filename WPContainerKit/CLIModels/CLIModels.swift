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

    public init(from site: Site) {
        self.id = site.id.uuidString
        self.name = site.name
        self.slug = site.slug
        self.status = site.status.token
        self.url = site.localURL.absoluteString
        self.port = site.port
        self.path = site.path.path
        self.image = site.imageTag
        self.provisioned = site.provisioned
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

    public init(from env: WorktreeEnv) {
        self.url = env.localURL.absoluteString
        self.port = env.port
        self.path = env.envPath.path
        self.worktreePath = env.worktreePath.path
        self.branch = env.branch
        self.envSlug = env.envSlug
        self.containers = [env.wpContainerName, env.dbContainerName]
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
