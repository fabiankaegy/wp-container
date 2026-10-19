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
    /// Per-instance auto-stop-when-idle timeout in MINUTES (issue #16).
    ///
    /// `nil` = follow the built-in default for this kind of instance, resolved by
    /// `IdlePolicy.effectiveMinutes(configured:isEnv:)` (180 minutes for an env,
    /// OFF for a site — see `IdlePolicy` for why they differ); `0` =
    /// explicitly disabled; `> 0` = stop the instance after that many idle
    /// minutes. Enforced by whichever process hosts the HTTPS proxy, which is
    /// also what wakes the instance back up on the next request — so this MUST be
    /// a persisted per-instance field rather than a `UserDefaults` setting
    /// (UserDefaults is per-process and invisible to a headless
    /// `wp-container proxy serve`).
    var idleStopMinutes: Int? { get }
    /// Last time ANY process observed deliberate use of this instance (issue #16):
    /// a wp-cli invocation, an MCP tool call, a magic-login link, or an explicit
    /// start. Persisted precisely because the proxy's own in-memory last-access
    /// map only sees traffic it routed — an agent driving an env entirely through
    /// wp-cli and MCP would otherwise look idle. Written throttled (see
    /// `StorePersistence.recordActivity`) so it never turns a hot loop of tool
    /// calls into a hot loop of store writes.
    var lastActivityAt: Date? { get }
    /// Whether a per-instance Mailpit email-catcher container runs (issue #10).
    var mailpitEnabled: Bool { get }
    /// The localhost port the Mailpit web UI is published on (issue #10).
    var mailpitPort: Int? { get }
    /// Public hostnames (no wildcards) that must resolve to the HOST from
    /// inside the wp container, so WordPress loopback requests (wp-cron spawn,
    /// Site Health checks, REST self-calls) reach the host proxy exactly like a
    /// browser does. Injected into the container's /etc/hosts on every start.
    var loopbackHosts: [String] { get }
    /// Whether the wp container publishes `127.0.0.1:<port>:80` itself via Apple
    /// `container`'s port forwarder (issue #16 follow-through).
    ///
    /// True for sites, FALSE for worktree envs: the HTTPS proxy binds each env's
    /// `127.0.0.1:<port>` socket itself (and serves its domain URL by Host on
    /// 443/80), relaying to the container's vmnet IP. Two things fall out of
    /// that, both the point of the exercise — every request to either env URL
    /// becomes visible to the idle clock, and a parked env wakes at the exact
    /// URL users already hold — plus a third that is pure
    /// gain: env traffic stops crossing the lossy forwarder (see
    /// `HTTPSProxy.Route.containerName` for what "lossy" means here).
    ///
    /// A protocol REQUIREMENT (with an extension default) rather than an
    /// extension-only member: extension-only members dispatch STATICALLY, so an
    /// override on `WorktreeEnv` would be invisible to `SiteRecipe`'s and
    /// `SiteLifecycle`'s `any RunnableInstance` call sites.
    var publishesPort: Bool { get }
}

public extension RunnableInstance {
    var wpContainerName: String { "wpc-\(containerSlug)-wp" }
    var dbContainerName: String { "wpc-\(containerSlug)-db" }
    /// Default: the single `wordpress` schema on the instance's own server.
    var databaseName: String { SiteRecipe.dbName }
    /// Default: the instance runs (and therefore owns) its own DB container.
    var ownsDatabaseContainer: Bool { true }
    /// Per-instance Elasticsearch sidecar container name (§2c).
    var esContainerName: String { SidecarAddons.elasticsearch.containerName(for: self) }
    /// Per-instance Mailpit container name (issue #10).
    var mailContainerName: String { SidecarAddons.mailpit.containerName(for: self) }
    var localURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var adminURL: URL { URL(string: "http://127.0.0.1:\(port)/wp-admin")! }
    var extraMounts: [Mount] { [] }
    // Defaults so instances predating the add-ons still conform.
    var xdebugEnabled: Bool { false }
    var elasticsearchEnabled: Bool { false }
    var networkType: NetworkType { .none }
    var cpuLimit: Int? { nil }
    var memoryLimitMB: Int? { nil }
    var idleStopMinutes: Int? { nil }
    var lastActivityAt: Date? { nil }
    /// The idle timeout actually in force for this instance (issue #16), with the
    /// kind-specific default already resolved. `0` ⇒ auto-stop is off.
    ///
    /// Lives here rather than in the proxy so the idle sweep can treat sites and
    /// envs uniformly — `envLabel != nil` is the one bit that distinguishes them.
    var effectiveIdleStopMinutes: Int {
        IdlePolicy.effectiveMinutes(configured: idleStopMinutes, isEnv: envLabel != nil)
    }
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
    /// Site overrides this to add its custom domain; `WorktreeEnv` to use its
    /// `domainHost`.
    var loopbackHosts: [String] { ["\(containerSlug).localhost"] }
    /// Default: the container publishes its own host port. `WorktreeEnv` opts out.
    var publishesPort: Bool { true }
}
