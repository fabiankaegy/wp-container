import Foundation

/// Everything the share listener needs to authorize and rewrite traffic for one shared instance.
public struct ShareGateConfig: Sendable {
    /// Public origin of the share, e.g. `https://abc.example.com`.
    public var publicOrigin: String
    /// Host header sent to the site's own proxy route.
    public var upstreamHost: String
    /// Origins the site emits in redirects and links, rewritten to `publicOrigin` on the way out.
    public var localOrigins: [String]
    public var username: String
    public var password: String
    public var authDisabled: Bool
    /// Requests that skip the password check.
    public var allow: [ShareException]

    public init(
        publicOrigin: String,
        upstreamHost: String,
        localOrigins: [String],
        username: String,
        password: String,
        authDisabled: Bool,
        allow: [ShareException]
    ) {
        self.publicOrigin = publicOrigin
        self.upstreamHost = upstreamHost
        self.localOrigins = localOrigins
        self.username = username
        self.password = password
        self.authDisabled = authDisabled
        self.allow = allow
    }
}

public enum ShareGateDecision: Equatable, Sendable {
    /// Valid credentials, or a share with the password gate turned off.
    case pass
    /// No valid credentials, but the request matches a gate exception. It is relayed
    /// without cookies and with `X-WPC-Share-Exempt: 1`.
    case exempt
    case challenge
    case throttled
}

/// Request and response handling for a share listener. All functions are pure.
public enum ShareGate {
    private static let shareHeaderPrefix = "x-wpc-share-"
    private static let robotsHeader = "X-Robots-Tag: noindex, nofollow"

    /// Decides whether a request may reach the site.
    public static func authorize(requestLine: String, headerLines: [String], config: ShareGateConfig) -> ShareGateDecision {
        if config.authDisabled { return .pass }
        if hasValidCredentials(headerLines, config: config) { return .pass }

        let target = requestLine.split(separator: " ", omittingEmptySubsequences: true).dropFirst().first.map(String.init) ?? "/"
        let withoutFragment = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        let parts = withoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = parts.first.map(String.init) ?? "/"
        let query = parts.count > 1 ? String(parts[1]) : nil
        if reachesLoginEndpoint(path) { return .challenge }
        // WordPress serves `rest_route` from the query string whatever the path, so a
        // path-prefix exception cannot cover a request that carries it.
        let overridesRoute = hasRestRoute(query)
        let exempt = config.allow.contains { exception in
            if overridesRoute && exception.description.hasPrefix("/") { return false }
            return exception.matches(path: path, query: query)
        }
        return exempt ? .exempt : .challenge
    }

    /// Builds the upstream request header block, ending in a blank line. An `exempt`
    /// request loses its cookies, so it reaches the site as a logged-out visitor, and
    /// carries `X-WPC-Share-Exempt: 1` for the PHP handler.
    public static func rewriteRequest(requestLine: String, headerLines: [String], config: ShareGateConfig,
                                      exempt: Bool = false) -> String {
        var dropped: Set<String> = [
            "host", "authorization", "x-forwarded-proto", "x-forwarded-host",
            "connection", "keep-alive", "proxy-connection", "upgrade",
        ]
        if exempt { dropped.insert("cookie") }
        var kept: [String] = []
        for line in stripShareHeaders(headerLines) {
            if line.isEmpty { continue }
            if let name = headerName(line), dropped.contains(name) { continue }
            kept.append(line)
        }
        let publicHost = URL(string: config.publicOrigin)?.host ?? config.upstreamHost
        kept.append("Host: \(config.upstreamHost)")
        kept.append("X-Forwarded-Host: \(publicHost)")
        kept.append("X-Forwarded-Proto: https")
        kept.append("X-WPC-Share-Origin: \(config.publicOrigin)")
        if exempt { kept.append("X-WPC-Share-Exempt: 1") }
        kept.append("Connection: close")
        return requestLine + "\r\n" + kept.joined(separator: "\r\n") + "\r\n\r\n"
    }

    /// Points redirect and link headers at the public origin and marks the response non-indexable.
    public static func rewriteResponseHeader(_ header: String, config: ShareGateConfig) -> String {
        let origins = config.localOrigins.sorted { $0.count > $1.count }
        let rewritten: Set<String> = ["location", "link", "content-location", "refresh"]
        var lines = header.components(separatedBy: "\r\n")
        while lines.last?.isEmpty == true { lines.removeLast() }

        var out: [String] = []
        for line in lines {
            guard let name = headerName(line) else { out.append(line); continue }
            if name == "x-robots-tag" { continue }
            if rewritten.contains(name) {
                var updated = line
                for origin in origins {
                    updated = replaceOrigin(origin, with: config.publicOrigin, in: updated)
                }
                out.append(updated)
            } else {
                out.append(line)
            }
        }
        out.append(robotsHeader)
        return out.joined(separator: "\r\n") + "\r\n\r\n"
    }

    public static func challengeResponse() -> String {
        let body = "Authentication required.\n"
        return "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"WP Container share\"\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
    }

    public static func throttledResponse() -> String {
        let body = "Too many failed attempts. Try again shortly.\n"
        return "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 30\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
    }

    /// Removes every `X-WPC-Share-*` header so clients cannot forge share state.
    public static func stripShareHeaders(_ lines: [String]) -> [String] {
        lines.filter { line in
            guard let name = headerName(line) else { return true }
            return !name.hasPrefix(shareHeaderPrefix)
        }
    }

    private static func hasValidCredentials(_ headerLines: [String], config: ShareGateConfig) -> Bool {
        guard let value = headerValue("authorization", in: headerLines) else { return false }
        let pieces = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard pieces.count == 2, pieces[0].lowercased() == "basic",
              let decoded = Data(base64Encoded: pieces[1].trimmingCharacters(in: .whitespaces)) else {
            return false
        }
        let expected = Array("\(config.username):\(config.password)".utf8)
        return constantTimeEqual(Array(decoded), expected)
    }

    /// Whether the path reaches `wp-login.php` or `xmlrpc.php`, which no exception covers.
    /// Any segment counts, so a trailing slash, path info, repeated slashes and a
    /// subdirectory-multisite prefix are all caught. A path that does not decode counts too.
    private static func reachesLoginEndpoint(_ path: String) -> Bool {
        guard let decoded = path.removingPercentEncoding else { return true }
        return decoded.split(separator: "/").contains { segment in
            let name = segment.lowercased()
            return name == "wp-login.php" || name == "xmlrpc.php"
        }
    }

    private static func hasRestRoute(_ query: String?) -> Bool {
        guard let query else { return false }
        return query.split(separator: "&").contains { part in
            let key = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return phpVariableName(key) == "rest_route"
        }
    }

    /// The `$_GET` name PHP derives from a raw query key: percent-decoded, leading spaces dropped,
    /// array suffix removed, and spaces, dots and an unmatched `[` turned into `_`.
    private static func phpVariableName(_ rawKey: String) -> String {
        let plusDecoded = rawKey.replacingOccurrences(of: "+", with: " ")
        let decoded = plusDecoded.removingPercentEncoding ?? plusDecoded
        let trimmed = String(decoded.drop { $0 == " " })
        func normalise(_ text: Substring) -> String {
            String(text.map { $0 == " " || $0 == "." ? "_" : $0 })
        }
        guard let open = trimmed.firstIndex(of: "[") else { return normalise(trimmed[...]) }
        let afterOpen = trimmed.index(after: open)
        if trimmed[afterOpen...].contains("]") {
            return normalise(trimmed[..<open])
        }
        return normalise(trimmed[..<open]) + "_" + String(trimmed[afterOpen...])
    }

    /// Replaces `origin` only where it ends at a delimiter, so longer hosts and ports are left alone.
    private static func replaceOrigin(_ origin: String, with replacement: String, in text: String) -> String {
        let delimiters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/?#>\"',;"))
        var result = ""
        var rest = text[...]
        while let range = rest.range(of: origin) {
            result += rest[..<range.lowerBound]
            let next = rest[range.upperBound...].unicodeScalars.first
            if next == nil || delimiters.contains(next!) {
                result += replacement
            } else {
                result += origin
            }
            rest = rest[range.upperBound...]
        }
        return result + rest
    }

    private static func headerName(_ line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        return line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func headerValue(_ name: String, in lines: [String]) -> String? {
        for line in lines where headerName(line) == name {
            guard let colon = line.firstIndex(of: ":") else { continue }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Compares every byte of the longer buffer so timing does not reveal where a mismatch occurs.
    private static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var diff: UInt8 = a.count == b.count ? 0 : 1
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            diff |= x ^ y
        }
        return diff == 0
    }
}

/// Locks a share out for 30 seconds after 10 failed logins within 60 seconds.
public final class ShareAuthThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [Date] = []
    private var lockedUntil: Date?

    public init() {}

    public func recordFailure(now: Date) {
        lock.withLock {
            failures.removeAll { now.timeIntervalSince($0) > 60 }
            failures.append(now)
            if failures.count >= 10 {
                lockedUntil = now.addingTimeInterval(30)
                failures.removeAll()
            }
        }
    }

    public func isLocked(now: Date) -> Bool {
        lock.withLock {
            guard let until = lockedUntil else { return false }
            if now < until { return true }
            lockedUntil = nil
            return false
        }
    }
}
