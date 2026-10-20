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

    public init(
        provider: String? = nil,
        hostname: String? = nil,
        username: String,
        password: String,
        allow: [ShareException] = [],
        active: Bool = false,
        authDisabled: Bool = false
    ) {
        self.provider = provider
        self.hostname = hostname
        self.username = username
        self.password = password
        self.allow = allow
        self.active = active
        self.authDisabled = authDisabled
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

    public var description: String {
        switch self {
        case .invalidException(let text):
            return "Invalid share exception \"\(text)\": use /path-prefix or ?query-key[=value]."
        }
    }
}
