import Foundation

/// A single host→container bind mount.
public struct Mount: Sendable, Equatable, Hashable {
    public let hostPath: String
    public let containerPath: String
    public init(hostPath: String, containerPath: String) {
        self.hostPath = hostPath
        self.containerPath = containerPath
    }
}

/// Anything the lifecycle can start/stop as a pair of `wpc-<slug>-{wp,db}`
/// containers. Both `Site` and `WorktreeEnv` conform so that a single start/stop
/// code path in `SiteLifecycle` serves both.
public protocol RunnableInstance: Sendable {
    /// Stable identity used to key status events.
    var instanceID: UUID { get }
    /// Basis for the container names `wpc-<containerSlug>-wp` / `-db`.
    var containerSlug: String { get }
    /// Value for the `dev.wpcontainer.site` label (parent site slug).
    var siteSlug: String { get }
    /// Value for the `dev.wpcontainer.env` label, or nil for a plain site.
    var envLabel: String? { get }
    /// Name used in provisioning (site title / display).
    var displayName: String { get }
    var port: Int { get }
    var imageTag: String { get }
    var wordpressFolder: URL { get }
    var databaseFolder: URL { get }
    /// Additional mounts beyond the base `wordpress/`→`/var/www/html` mount
    /// (e.g. a worktree checkout that shadows the primary one).
    var extraMounts: [Mount] { get }
    var isProvisioned: Bool { get }
    /// Whether this instance runs from the Xdebug-enabled derived image (§2c).
    var xdebugEnabled: Bool { get }
    /// Whether this instance runs a per-instance Elasticsearch sidecar (§2c).
    var elasticsearchEnabled: Bool { get }
    /// WordPress network type — governs multisite provisioning (§2j).
    var networkType: NetworkType { get }
    /// Per-instance CPU cap for `container run --cpus` (issue #11); nil = default.
    var cpuLimit: Int? { get }
    /// Per-instance memory cap in MB for `container run --memory` (issue #11);
    /// nil = default.
    var memoryLimitMB: Int? { get }
    /// Whether a per-instance Mailpit email-catcher container runs (issue #10).
    var mailpitEnabled: Bool { get }
    /// The localhost port the Mailpit web UI is published on (issue #10).
    var mailpitPort: Int? { get }
}

public extension RunnableInstance {
    var wpContainerName: String { "wpc-\(containerSlug)-wp" }
    var dbContainerName: String { "wpc-\(containerSlug)-db" }
    /// Per-instance Elasticsearch sidecar container name (§2c).
    var esContainerName: String { "wpc-\(containerSlug)-es" }
    /// Per-instance Mailpit container name (issue #10).
    var mailContainerName: String { "wpc-\(containerSlug)-mail" }
    var localURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var adminURL: URL { URL(string: "http://127.0.0.1:\(port)/wp-admin")! }
    var extraMounts: [Mount] { [] }
    // Defaults so instances predating the add-ons still conform.
    var xdebugEnabled: Bool { false }
    var elasticsearchEnabled: Bool { false }
    var networkType: NetworkType { .none }
    var cpuLimit: Int? { nil }
    var memoryLimitMB: Int? { nil }
    var mailpitEnabled: Bool { false }
    var mailpitPort: Int? { nil }
    /// Per-instance Elasticsearch data directory bind mount host path.
    var elasticsearchFolder: URL {
        wordpressFolder.deletingLastPathComponent().appendingPathComponent("elasticsearch", isDirectory: true)
    }
    /// Per-instance Mailpit persistent data directory bind mount host path
    /// (issue #10). Sits alongside `wordpress/`, never inside it.
    var mailpitFolder: URL {
        wordpressFolder.deletingLastPathComponent().appendingPathComponent("mailpit", isDirectory: true)
    }
    /// The Mailpit web-UI URL on its published localhost port, if enabled and a
    /// port is assigned (issue #10). The reliable, proxy-independent mailbox URL.
    var mailboxURL: URL? {
        guard mailpitEnabled, let port = mailpitPort else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }
    /// The proxy hostname for the mailbox (`<slug>-mail.localhost`, issue #10).
    var mailboxHost: String { "\(containerSlug)-mail.localhost" }
}
