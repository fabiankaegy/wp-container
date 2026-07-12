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
}

public extension RunnableInstance {
    var wpContainerName: String { "wpc-\(containerSlug)-wp" }
    var dbContainerName: String { "wpc-\(containerSlug)-db" }
    var localURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var adminURL: URL { URL(string: "http://127.0.0.1:\(port)/wp-admin")! }
    var extraMounts: [Mount] { [] }
}
