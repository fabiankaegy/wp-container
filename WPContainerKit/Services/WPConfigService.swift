import Foundation

/// Reads and edits a site's `wordpress/wp-config.php` (PLAN.md §2d/§2f).
///
/// Parsing is line/regex based rather than a full PHP parse — enough to surface
/// `define()` constants and `$table_prefix`, and to set/add constants or inject
/// the standard HTTPS-behind-proxy snippet. Every write makes a timestamped
/// `.bak` copy first.
public enum WPConfigService {
    public enum ConfigError: Error, Sendable, CustomStringConvertible {
        case notFound(String)
        case unreadable(String)

        public var description: String {
            switch self {
            case .notFound(let p):   return "wp-config.php not found at \(p)"
            case .unreadable(let p): return "wp-config.php unreadable at \(p)"
            }
        }
    }

    /// A parsed view of wp-config.php.
    public struct Parsed: Sendable, Codable {
        public var path: String
        public var constants: [String: String]
        public var tablePrefix: String?
    }

    public static func configURL(for wordpressFolder: URL) -> URL {
        wordpressFolder.appendingPathComponent("wp-config.php")
    }

    // MARK: - Read

    public static func read(wordpressFolder: URL) throws -> Parsed {
        let url = configURL(for: wordpressFolder)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigError.notFound(url.path)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ConfigError.unreadable(url.path)
        }
        return Parsed(path: url.path,
                      constants: parseConstants(text),
                      tablePrefix: parseTablePrefix(text))
    }

    /// Parse `define('NAME', value)` pairs. String values are unquoted; booleans
    /// and numbers are kept as their literal token.
    static func parseConstants(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        // define( 'NAME' , VALUE )  — VALUE may be 'str', "str", true/false, number.
        let pattern = #"define\s*\(\s*['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]\s*,\s*(.*?)\s*\)\s*;"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return out }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            var value = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            value = unquote(value)
            out[name] = value
        }
        return out
    }

    static func parseTablePrefix(_ text: String) -> String? {
        let pattern = #"\$table_prefix\s*=\s*['\"]([^'\"]*)['\"]\s*;"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func unquote(_ value: String) -> String {
        if value.count >= 2, (value.hasPrefix("'") && value.hasSuffix("'")) || (value.hasPrefix("\"") && value.hasSuffix("\"")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    // MARK: - Edit

    /// Set (or add) a constant. `rawValue: true` writes the value verbatim (e.g.
    /// `true`, `false`, an integer); otherwise it is emitted as a single-quoted
    /// PHP string. Makes a timestamped `.bak` first. Returns the backup path.
    @discardableResult
    public static func setConstant(_ name: String, value: String, rawValue: Bool,
                                   wordpressFolder: URL) throws -> String {
        let url = configURL(for: wordpressFolder)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ConfigError.notFound(url.path) }
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { throw ConfigError.unreadable(url.path) }

        let backup = try makeBackup(url)
        let literal = rawValue ? value : "'\(phpEscape(value))'"
        let defineLine = "define( '\(name)', \(literal) );"

        let existing = #"define\s*\(\s*['\"]"# + NSRegularExpression.escapedPattern(for: name) + #"['\"]\s*,\s*.*?\)\s*;"#
        if let re = try? NSRegularExpression(pattern: existing, options: [.dotMatchesLineSeparators]),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(m.range, in: text) {
            text.replaceSubrange(range, with: defineLine)
        } else {
            text = insertAfterOpeningTag(text, snippet: defineLine)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return backup
    }

    // MARK: - HTTPS proxy snippet (§2f)

    private static let forwardedProtoMarker = "// WP Container: honor X-Forwarded-Proto from the local HTTPS proxy"
    private static let forwardedProtoSnippet = """
    // WP Container: honor X-Forwarded-Proto from the local HTTPS proxy
    if ( isset( $_SERVER['HTTP_X_FORWARDED_PROTO'] ) && 'https' === $_SERVER['HTTP_X_FORWARDED_PROTO'] ) {
        $_SERVER['HTTPS'] = 'on';
    }
    """

    /// Inject the X-Forwarded-Proto snippet right after the opening `<?php` (idempotent).
    @discardableResult
    public static func enableForwardedProto(wordpressFolder: URL) throws -> String? {
        let url = configURL(for: wordpressFolder)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ConfigError.notFound(url.path) }
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { throw ConfigError.unreadable(url.path) }
        if text.contains(forwardedProtoMarker) { return nil }
        let backup = try makeBackup(url)
        text = insertAfterOpeningTag(text, snippet: forwardedProtoSnippet)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return backup
    }

    /// Remove the injected snippet (idempotent).
    @discardableResult
    public static func disableForwardedProto(wordpressFolder: URL) throws -> String? {
        let url = configURL(for: wordpressFolder)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard var text = try? String(contentsOf: url, encoding: .utf8), text.contains(forwardedProtoMarker) else { return nil }
        let backup = try makeBackup(url)
        // Remove the marker block (marker line through the closing brace line).
        let pattern = NSRegularExpression.escapedPattern(for: forwardedProtoMarker) + #"[\s\S]*?\}\s*\n?"#
        if let re = try? NSRegularExpression(pattern: pattern),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(m.range, in: text) {
            text.replaceSubrange(range, with: "")
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return backup
    }

    // MARK: - Helpers

    /// Copy `<file>` to `<file>.<timestamp>.bak`, returning the backup path.
    private static func makeBackup(_ url: URL) throws -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let stamp = fmt.string(from: Date())
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).\(stamp).bak")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: url, to: backup)
        return backup.path
    }

    /// Insert `snippet` on its own line immediately after the opening `<?php`.
    private static func insertAfterOpeningTag(_ text: String, snippet: String) -> String {
        if let range = text.range(of: "<?php") {
            var copy = text
            copy.insert(contentsOf: "\n\(snippet)\n", at: range.upperBound)
            return copy
        }
        // No opening tag (unusual): prepend one.
        return "<?php\n\(snippet)\n?>\n" + text
    }

    private static func phpEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }
}
