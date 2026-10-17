import Foundation

/// An environment variable a sidecar passes to WordPress and wp-cli. Its value
/// is `prefix + <sidecar IP> + suffix`, e.g. `EP_HOST=http://<ip>:9200`.
public struct SidecarEnvVar: Sendable, Equatable, Codable {
    public let key: String
    public let prefix: String
    public let suffix: String

    public init(_ key: String, prefix: String = "", suffix: String = "") {
        self.key = key
        self.prefix = prefix
        self.suffix = suffix
    }

    public func value(ip: String) -> String { prefix + ip + suffix }

    /// `KEY=value`, the form `container run -e` takes.
    public func assignment(ip: String) -> String { "\(key)=\(value(ip: ip))" }
}

/// A sidecar as the shell surfaces (shim, router, Terminal command) see it: the
/// container to look up and the env vars built from its IP.
public struct SidecarRef: Sendable, Equatable, Codable {
    public let container: String
    public let environment: [SidecarEnvVar]

    public init(container: String, environment: [SidecarEnvVar]) {
        self.container = container
        self.environment = environment
    }
}

/// A managed PHP handler in an instance's `php/prepend.d/` (see `PrependService`).
public struct PrependHandler: Sendable {
    public let fileName: String
    /// Unique header marker that tells our file apart from a user's own.
    public let marker: String
    public let contents: String
    /// Whether the handler loads at prepend time, before wp-config.php, rather
    /// than at `muplugins_loaded`.
    public let isEarly: Bool

    public init(fileName: String, marker: String, contents: String, isEarly: Bool = false) {
        self.fileName = fileName
        self.marker = marker
        self.contents = contents
        self.isEarly = isEarly
    }

    /// The path below `prepend.d/`.
    var relativePath: String { isEarly ? "\(PrependService.earlyDirName)/\(fileName)" : fileName }

    public func isPresent(phpConfFolder: URL) -> Bool {
        PrependService.isHandlerPresent(phpConfFolder: phpConfFolder, name: relativePath, marker: marker)
    }

    public func write(phpConfFolder: URL) throws {
        try PrependService.writeHandler(phpConfFolder: phpConfFolder, name: relativePath, contents: contents)
    }

    /// Removes the handler only when it is ours (marker match).
    public func remove(phpConfFolder: URL) {
        PrependService.removeHandler(phpConfFolder: phpConfFolder, name: relativePath, marker: marker)
    }
}

/// A service container that runs beside an instance's WordPress container as
/// `wpc-<containerSlug>-<containerSuffix>`. The lifecycle starts every enabled
/// sidecar alongside the database, injects its `environment` into the wp
/// container and one-shot wp-cli, keeps its PHP `handler` in sync with the
/// toggle, and stops and deletes it with the instance.
///
/// Enabling or disabling a sidecar takes effect on the next start.
public protocol SidecarAddon: Sendable {
    /// Stable identifier, e.g. `elasticsearch`.
    var id: String { get }
    var displayName: String { get }
    /// Container name suffix: `wpc-<containerSlug>-<containerSuffix>`.
    var containerSuffix: String { get }
    var image: String { get }
    /// Env vars passed to the wp container and wp-cli, built from the sidecar's IP.
    var environment: [SidecarEnvVar] { get }
    /// The managed PHP handler that wires WordPress to the sidecar, if any.
    var handler: PrependHandler? { get }
    /// Whether the sidecar publishes a host port, reserved on first enable and
    /// kept reserved afterwards.
    var publishesHostPort: Bool { get }

    func isEnabled(for inst: any RunnableInstance) -> Bool
    func setEnabled(_ enabled: Bool, on site: inout Site)
    func setEnabled(_ enabled: Bool, on env: inout WorktreeEnv)
    func hostPort(of inst: any RunnableInstance) -> Int?
    func setHostPort(_ port: Int, on site: inout Site)
    func setHostPort(_ port: Int, on env: inout WorktreeEnv)
    /// The `container run` args, or nil when the instance cannot run it yet.
    func runArgs(for inst: any RunnableInstance) -> [String]?
    /// Host folders the container bind-mounts, created before it runs.
    func dataFolders(for inst: any RunnableInstance) -> [URL]
    /// A URL the user opens for this sidecar (Mailpit's mailbox), if any.
    func endpointURL(for inst: any RunnableInstance) -> URL?
    /// The JSON key toggles report `endpointURL` under, if the addon has one.
    var endpointKey: String? { get }
}

public extension SidecarAddon {
    var handler: PrependHandler? { nil }
    var publishesHostPort: Bool { false }
    func hostPort(of inst: any RunnableInstance) -> Int? { nil }
    func setHostPort(_ port: Int, on site: inout Site) {}
    func setHostPort(_ port: Int, on env: inout WorktreeEnv) {}
    func dataFolders(for inst: any RunnableInstance) -> [URL] { [] }
    func endpointURL(for inst: any RunnableInstance) -> URL? { nil }
    var endpointKey: String? { nil }

    func containerName(for inst: any RunnableInstance) -> String {
        "wpc-\(inst.containerSlug)-\(containerSuffix)"
    }

    /// The `container run -e` assignments for this sidecar at `ip`.
    func assignments(ip: String) -> [String] {
        environment.map { $0.assignment(ip: ip) }
    }
}

/// The sidecar registry. Order is significant: env vars are passed in this order.
public enum SidecarAddons {
    public static let elasticsearch = ElasticsearchAddon()
    public static let mailpit = MailpitAddon()
    public static let redis = RedisAddon()

    public static let all: [any SidecarAddon] = [elasticsearch, mailpit, redis]

    public static func enabled(for inst: any RunnableInstance) -> [any SidecarAddon] {
        all.filter { $0.isEnabled(for: inst) }
    }

    /// Every sidecar of `inst`, enabled or not. The shell surfaces look each one
    /// up at run time and pass an empty value for one that isn't running.
    public static func refs(for inst: any RunnableInstance) -> [SidecarRef] {
        all.map { SidecarRef(container: $0.containerName(for: inst), environment: $0.environment) }
    }

    /// `refs(for:)` for the classic per-site container names of `slug`.
    public static func refs(slug: String) -> [SidecarRef] {
        all.map { SidecarRef(container: "wpc-\(slug)-\($0.containerSuffix)", environment: $0.environment) }
    }

    /// Host ports the sidecars of these instances hold.
    public static func reservedHostPorts(sites: [Site], envs: [WorktreeEnv]) -> Set<Int> {
        var ports = Set<Int>()
        for addon in all {
            ports.formUnion(sites.compactMap { addon.hostPort(of: $0) })
            ports.formUnion(envs.compactMap { addon.hostPort(of: $0) })
        }
        return ports
    }

    /// The `container run -e` assignments for the enabled, running sidecars of
    /// `inst`, read from their live IPs. A stopped sidecar contributes nothing.
    public static func environment(for inst: any RunnableInstance, cli: ContainerCLI) async -> [String] {
        var assignments: [String] = []
        for addon in enabled(for: inst) {
            guard let ip = (try? await cli.ipAddress(of: addon.containerName(for: inst))) ?? nil, !ip.isEmpty else { continue }
            assignments += addon.assignments(ip: ip)
        }
        return assignments
    }
}

// MARK: - Elasticsearch (§2c)

/// Elasticsearch for ElasticPress. The handler defines `EP_HOST`, the only
/// source ElasticPress reads its host from; `ELASTICSEARCH_URL` serves other
/// clients.
public struct ElasticsearchAddon: SidecarAddon {
    public let id = "elasticsearch"
    public let displayName = "Elasticsearch"
    public let containerSuffix = "es"
    public var image: String { SiteRecipe.elasticsearchImage }
    public let environment = [
        SidecarEnvVar("ELASTICSEARCH_URL", prefix: "http://", suffix: ":\(SiteRecipe.elasticsearchPort)"),
        SidecarEnvVar("EP_HOST", prefix: "http://", suffix: ":\(SiteRecipe.elasticsearchPort)"),
    ]
    public var handler: PrependHandler? { ElasticsearchService.handler }

    public func isEnabled(for inst: any RunnableInstance) -> Bool { inst.elasticsearchEnabled }
    public func setEnabled(_ enabled: Bool, on site: inout Site) { site.elasticsearchEnabled = enabled }
    public func setEnabled(_ enabled: Bool, on env: inout WorktreeEnv) { env.elasticsearchEnabled = enabled }
    public func runArgs(for inst: any RunnableInstance) -> [String]? { SiteRecipe.runElasticsearchArgs(inst) }
    public func dataFolders(for inst: any RunnableInstance) -> [URL] { [inst.elasticsearchFolder] }
}

// MARK: - Mailpit (issue #10)

/// Mailpit catches all outgoing mail. The handler routes PHPMailer to its SMTP
/// port, and its web UI is published on a reserved localhost port.
public struct MailpitAddon: SidecarAddon {
    public let id = "mailpit"
    public let displayName = "Mailpit"
    public let containerSuffix = "mail"
    public var image: String { SiteRecipe.mailpitImage }
    public let environment = [SidecarEnvVar("WPC_MAILPIT_HOST")]
    public var handler: PrependHandler? { MailpitService.handler }
    public var publishesHostPort: Bool { true }

    public func isEnabled(for inst: any RunnableInstance) -> Bool { inst.mailpitEnabled }
    public func setEnabled(_ enabled: Bool, on site: inout Site) { site.mailpitEnabled = enabled }
    public func setEnabled(_ enabled: Bool, on env: inout WorktreeEnv) { env.mailpitEnabled = enabled }
    public func hostPort(of inst: any RunnableInstance) -> Int? { inst.mailpitPort }
    public func setHostPort(_ port: Int, on site: inout Site) { site.mailpitPort = port }
    public func setHostPort(_ port: Int, on env: inout WorktreeEnv) { env.mailpitPort = port }

    public func runArgs(for inst: any RunnableInstance) -> [String]? {
        guard let webPort = inst.mailpitPort else { return nil }
        return SiteRecipe.runMailpitArgs(inst, webPort: webPort)
    }

    public func dataFolders(for inst: any RunnableInstance) -> [URL] { [inst.mailpitFolder] }
    public func endpointURL(for inst: any RunnableInstance) -> URL? { inst.mailboxURL }
    public var endpointKey: String? { "mailboxUrl" }
}

// MARK: - Redis

/// Redis for a persistent object cache. The handler defines `WP_REDIS_HOST` and
/// `WP_REDIS_PORT` before the object-cache drop-in loads; the drop-in itself
/// comes from a plugin such as Redis Object Cache, installed in the project.
/// The cache is ephemeral: a restart starts it empty.
public struct RedisAddon: SidecarAddon {
    public let id = "redis"
    public let displayName = "Redis"
    public let containerSuffix = "redis"
    public var image: String { SiteRecipe.redisImage }
    public let environment = [SidecarEnvVar("WPC_REDIS_HOST")]
    public var handler: PrependHandler? { RedisService.handler }

    public func isEnabled(for inst: any RunnableInstance) -> Bool { inst.redisEnabled }
    public func setEnabled(_ enabled: Bool, on site: inout Site) { site.redisEnabled = enabled }
    public func setEnabled(_ enabled: Bool, on env: inout WorktreeEnv) { env.redisEnabled = enabled }
    public func runArgs(for inst: any RunnableInstance) -> [String]? { SiteRecipe.runRedisArgs(inst) }
}
