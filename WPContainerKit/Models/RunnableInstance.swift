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
    /// The container that hosts this instance's MariaDB server. Defaults to the
    /// instance's own `wpc-<containerSlug>-db`; a shared-database worktree env
    /// (issue #17) overrides it to the PARENT site's container.
    ///
    /// A protocol REQUIREMENT (with a default implementation) rather than an
    /// extension-only member on purpose: extension-only members dispatch
    /// STATICALLY, so an override on `WorktreeEnv` would be invisible to the
    /// lifecycle's `any RunnableInstance` call sites.
    var dbContainerName: String { get }
    /// The MySQL schema WordPress connects to (`WORDPRESS_DB_NAME`). Defaults to
    /// the shared `wordpress` constant; a shared-database env overrides it with
    /// its own persisted `wpc_*` schema on the parent's server (issue #17).
    var databaseName: String { get }
    /// Whether this instance OWNS its database container — i.e. may create it on
    /// start and stop/delete it on stop/delete. False for a shared-database env,
    /// whose DB container belongs to its parent site (issue #17).
    var ownsDatabaseContainer: Bool { get }
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
    /// Public hostnames (no wildcards) that must resolve to the HOST from
    /// inside the wp container, so WordPress loopback requests (wp-cron spawn,
    /// Site Health checks, REST self-calls) reach the host proxy exactly like a
    /// browser does. Injected into the container's /etc/hosts on every start.
    var loopbackHosts: [String] { get }
}

public extension RunnableInstance {
    var wpContainerName: String { "wpc-\(containerSlug)-wp" }
    var dbContainerName: String { "wpc-\(containerSlug)-db" }
    /// Default: the single `wordpress` schema on the instance's own server.
    var databaseName: String { SiteRecipe.dbName }
    /// Default: the instance runs (and therefore owns) its own DB container.
    var ownsDatabaseContainer: Bool { true }
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
    /// Per-instance PHP overrides folder, bind-mounted into the wp container
    /// and scanned via `PHP_INI_SCAN_DIR` (upload limits — see
    /// `PHPConfService`). Sits alongside `wordpress/`, never inside it.
    var phpConfFolder: URL {
        wordpressFolder.deletingLastPathComponent().appendingPathComponent("php", isDirectory: true)
    }
    /// The Mailpit web-UI URL on its published localhost port, if enabled and a
    /// port is assigned (issue #10). The reliable, proxy-independent mailbox URL.
    var mailboxURL: URL? {
        guard mailpitEnabled, let port = mailpitPort else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }
    /// The proxy hostname for the mailbox (`<slug>-mail.localhost`, issue #10).
    var mailboxHost: String { "\(containerSlug)-mail.localhost" }
    /// Default loopback set: the `<containerSlug>.localhost` proxy hostname.
    /// Site overrides this to add its custom domain.
    var loopbackHosts: [String] { ["\(containerSlug).localhost"] }
}
