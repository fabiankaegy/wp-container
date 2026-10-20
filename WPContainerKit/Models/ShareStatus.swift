import Foundation

/// Runtime state of one shared instance, published by the proxy owner in
/// `proxy-shares.json` so the CLI, MCP server and app can read it.
public struct ShareStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case starting, live, down
    }

    public var instanceID: UUID
    public var slug: String
    public var state: State
    public var url: String?
    public var provider: String
    /// The effective public hostname, including a provider-assigned domain.
    public var hostname: String?
    public var temporary: Bool
    public var listenerPort: UInt16?
    public var pid: Int32?
    public var providerExecutable: String?
    public var error: String?
    public var updatedAt: Date

    public init(instanceID: UUID, slug: String, state: State, url: String? = nil,
                provider: String, hostname: String? = nil, temporary: Bool = false,
                listenerPort: UInt16? = nil, pid: Int32? = nil,
                providerExecutable: String? = nil, error: String? = nil,
                updatedAt: Date = Date()) {
        self.instanceID = instanceID
        self.slug = slug
        self.state = state
        self.url = url
        self.provider = provider
        self.hostname = hostname
        self.temporary = temporary
        self.listenerPort = listenerPort
        self.pid = pid
        self.providerExecutable = providerExecutable
        self.error = error
        self.updatedAt = updatedAt
    }
}
