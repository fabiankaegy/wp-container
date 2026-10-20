import Foundation
import Security

/// Public-sharing configuration for a site or worktree env.
public struct ShareSettings: Codable, Sendable, Hashable {
    /// Provider used when neither the instance nor the store names one.
    public static let defaultProvider = "ngrok"

    /// Provider name (`ngrok`, `cloudflared`, or a custom provider); nil follows the store default.
    public var provider: String?
    /// Fixed public hostname, when the provider supports one.
    public var hostname: String?
    public var username: String
    public var password: String
    /// Requests that bypass the password gate.
    public var allow: [ShareException]
    /// Whether the share is currently running.
    public var active: Bool
    /// Whether the password gate is turned off for this share.
    public var authDisabled: Bool
    /// Changes on every share request, so re-requesting a share that went down retries it.
    public var requestID: UUID?

    public init(
        provider: String? = nil,
        hostname: String? = nil,
        username: String,
        password: String,
        allow: [ShareException] = [],
        active: Bool = false,
        authDisabled: Bool = false,
        requestID: UUID? = nil
    ) {
        self.provider = provider
        self.hostname = hostname
        self.username = username
        self.password = password
        self.allow = allow
        self.active = active
        self.authDisabled = authDisabled
        self.requestID = requestID
    }

    /// Settings with the username `share` and a random 20-character alphanumeric password.
    public static func generated() -> ShareSettings {
        ShareSettings(username: "share", password: randomPassword(length: 20))
    }

    private static func randomPassword(length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        // Bytes at or above this limit are discarded so every character is equally likely.
        let limit = UInt8(256 - 256 % alphabet.count)
        var result = ""
        while result.count < length {
            var bytes = [UInt8](repeating: 0, count: length)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
            for byte in bytes where byte < limit && result.count < length {
                result.append(alphabet[Int(byte) % alphabet.count])
            }
        }
        return result
    }
}

/// A request pattern that skips the share password gate. The string form is
/// `/path-prefix` or `?query-key[=value]`.
public struct ShareException: Codable, Sendable, Hashable, CustomStringConvertible {
    private enum Rule: Sendable, Hashable {
        case pathPrefix(String)
        case query(key: String, value: String?)
    }

    public let description: String
    private let rule: Rule

    public init(parsing text: String) throws(ShareError) {
        if text.hasPrefix("/") {
            self.rule = .pathPrefix(text)
        } else if text.hasPrefix("?") {
            let pair = Self.splitPair(String(text.dropFirst()))
            guard !pair.key.isEmpty else { throw .invalidException(text) }
            self.rule = .query(key: pair.key, value: pair.value)
        } else {
            throw .invalidException(text)
        }
        self.description = text
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        do {
            try self.init(parsing: text)
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "\(error)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    /// Whether a request with this path and raw query string is exempt from the gate.
    /// The path is percent-decoded once and never matches when it contains a `..` segment.
    public func matches(path: String, query: String?) -> Bool {
        switch rule {
        case .pathPrefix(let prefix):
            guard let decoded = path.removingPercentEncoding else { return false }
            let hasDotDot = decoded.split(separator: "/", omittingEmptySubsequences: false).contains("..")
            return !hasDotDot && decoded.hasPrefix(prefix)
        case .query(let key, let value):
            guard let query else { return false }
            return query.split(separator: "&").contains { part in
                let pair = Self.splitPair(String(part))
                guard pair.key == key else { return false }
                return value == nil || pair.value == value
            }
        }
    }

    private static func splitPair(_ text: String) -> (key: String, value: String?) {
        guard let eq = text.firstIndex(of: "=") else { return (text, nil) }
        return (String(text[..<eq]), String(text[text.index(after: eq)...]))
    }
}

/// Failures raised by share configuration and lifecycle.
public enum ShareError: Error, Sendable, CustomStringConvertible {
    case invalidException(String)
    /// A share origin or upstream host carrying a line break, which would inject request headers.
    case invalidGateConfig(String)
    /// No built-in or custom provider has this name.
    case providerNotFound(String)
    /// The provider's executable is not installed; `install` is the command that installs it.
    case providerMissingBinary(name: String, install: String)
    case ngrokNotAuthenticated
    /// A fixed cloudflared hostname needs a named tunnel to route it.
    case cloudflaredTunnelNameRequired
    case invalidShareHostname(String)
    case invalidTunnelName(String)
    /// The provider reported a public hostname other than the requested one.
    case hostnameMismatch(expected: String, got: String)
    /// The provider did not report a public URL before the start timeout.
    case providerTimedOut(stderrTail: [String])
    /// The provider exited before reporting a public URL.
    case providerExited(status: Int32, stderrTail: [String])
    /// cloudflared has no origin certificate, so it cannot manage tunnels or DNS.
    case cloudflaredNotLoggedIn
    /// The hostname already has a DNS record that WP Container did not create.
    case dnsRecordExists(String)
    /// A cloudflared tunnel command failed; `output` is its trimmed error text.
    case cloudflaredFailed(command: String, output: String)
    /// The tunnel is already routed to another hostname; clean it up before routing a new one.
    case cloudflaredHostnameChanged(tunnel: String, recorded: String, requested: String)
    /// The tunnel registry could not be written.
    case cloudflaredRegistryWriteFailed(String)
    /// Subdomain multisite networks need one public hostname per subsite.
    case subdomainMultisite
    /// Another share already serves `hostname`. `providerAssigned` is true when that
    /// share's hostname came from the provider (a free ngrok domain).
    case hostnameInUse(hostname: String, by: String, providerAssigned: Bool)
    /// The provider exited after its share went live.
    case providerStopped(status: Int32, stderrTail: [String])
    /// No proxy host is running to serve the share.
    case proxyNotRunning
    /// The share did not reach `live` or `down` before the wait timeout.
    case timedOut
    /// The share was stopped before it reached `live` or `down`.
    case cancelled
    /// No site or worktree env has this id.
    case instanceNotFound(UUID)
    /// The instance stopped before its share could start.
    case instanceNotRunning
    /// The running proxy host was built without sharing support.
    case proxyTooOld

    public var description: String {
        switch self {
        case .invalidException(let text):
            return "Invalid share exception \"\(text)\": use /path-prefix or ?query-key[=value]."
        case .invalidGateConfig(let field):
            return "Invalid share configuration: \(field) must not contain line breaks."
        case .providerNotFound(let name):
            return "Unknown share provider \"\(name)\": use ngrok, cloudflared, or an executable in the share-providers directory."
        case .providerMissingBinary(let name, let install):
            return "The share provider \(name) is not installed. Install it with: \(install)"
        case .ngrokNotAuthenticated:
            return "ngrok has no authtoken. Run: ngrok config add-authtoken <token>"
        case .cloudflaredTunnelNameRequired:
            return "A fixed cloudflared hostname needs a tunnel name: create the named tunnel first."
        case .invalidShareHostname(let value):
            return "Invalid share hostname \"\(value)\": use a bare DNS host name such as share.example.com."
        case .invalidTunnelName(let value):
            return "Invalid tunnel name \"\(value)\": use letters, digits, dots, underscores and hyphens, not starting with a hyphen."
        case .cloudflaredNotLoggedIn:
            return "cloudflared is not logged in. Run: cloudflared tunnel login"
        case .dnsRecordExists(let hostname):
            return "\(hostname) already has a DNS record. Remove it in the Cloudflare dashboard or choose another hostname."
        case .cloudflaredFailed(let command, let output):
            return "cloudflared \(command) failed: \(output)"
        case .cloudflaredHostnameChanged(let tunnel, let recorded, let requested):
            return "The tunnel \(tunnel) is routed to \(recorded), not \(requested). Stop sharing to clean it up before using a new hostname."
        case .cloudflaredRegistryWriteFailed(let detail):
            return "Could not save the Cloudflare tunnel registry: \(detail)"
        case .subdomainMultisite:
            return "A subdomain multisite network cannot be shared: every subsite needs its own public hostname, and a share has one."
        case .hostnameInUse(let hostname, let slug, let providerAssigned):
            let message = "\(hostname) is already used by the share of \(slug). Stop that share first: wp-container share stop \(slug)"
            guard providerAssigned else { return message }
            return message + "\nA free ngrok account serves one share at a time; use --provider cloudflared or a paid ngrok plan to share more."
        case .proxyNotRunning:
            return "Sharing needs the proxy running. Start the WP Container app or run: wp-container proxy serve"
        case .timedOut:
            return "The share did not report a status in time. Check its state with: wp-container share list"
        case .cancelled:
            return "Sharing was stopped."
        case .instanceNotFound(let id):
            return "No site or environment with id \(id.uuidString) exists."
        case .instanceNotRunning:
            return "The site isn't running."
        case .proxyTooOld:
            return "The running WP Container proxy doesn't support sharing; update or quit the app, or run `wp-container proxy serve` from this build."
        case .providerStopped(let status, let tail):
            return "The share provider exited with status \(status)." + Self.formatTail(tail)
        case .hostnameMismatch(let expected, let got):
            return "The share provider returned the hostname \(got) instead of the requested \(expected)."
        case .providerTimedOut(let tail):
            return "The share provider did not report a public URL in time." + Self.formatTail(tail)
        case .providerExited(let status, let tail):
            return "The share provider exited with status \(status) before reporting a public URL." + Self.formatTail(tail)
        }
    }

    private static func formatTail(_ tail: [String]) -> String {
        tail.isEmpty ? "" : " Last output:\n" + tail.joined(separator: "\n")
    }
}
