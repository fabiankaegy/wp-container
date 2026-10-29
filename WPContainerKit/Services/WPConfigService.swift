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
        case invalidName(String)

        public var description: String {
            switch self {
            case .notFound(let p):   return "wp-config.php not found at \(p)"
            case .unreadable(let p): return "wp-config.php unreadable at \(p)"
            case .invalidName(let n): return "\"\(n)\" is not a valid PHP constant name (expected [A-Za-z_][A-Za-z0-9_]*)."
            }
        }
    }

    /// A syntactically valid PHP constant identifier. Enforced before any write
    /// so an untrusted `edit_wp_config` name (MCP) cannot inject arbitrary PHP
    /// into wp-config.php or corrupt it (a stray quote/paren/newline would
    /// otherwise white-screen the site).
    static func isValidConstantName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        let isNameStart: (Unicode.Scalar) -> Bool = { $0 == "_" || ($0.isASCII && (($0 >= "A" && $0 <= "Z") || ($0 >= "a" && $0 <= "z"))) }
        guard isNameStart(first) else { return false }
        return name.unicodeScalars.allSatisfy { isNameStart($0) || ($0 >= "0" && $0 <= "9") }
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

    /// The table prefix: the last string literal assigned to `$table_prefix`,
    /// which covers both `'wp_'` and the official image's
    /// `getenv_docker('WORDPRESS_TABLE_PREFIX', 'wp_')`. nil when absent or not
    /// `[A-Za-z0-9_]+`, so callers can inline a non-nil prefix into SQL.
    static func parseTablePrefix(_ text: String) -> String? {
        // Drop `/* … */` blocks first, so a line inside a multi-line one is
        // never read as code.
        let uncommented = text.replacing(#/(?s)\/\*.*?\*\//#, with: "")
        // Split on any line ending: in Swift "\r\n" is ONE character, so a
        // CRLF wp-config.php never splits on "\n" alone.
        // Skip commented-out assignments, so `// $table_prefix = 'old_';` above
        // the real one doesn't win.
        guard let line = uncommented.split(whereSeparator: \.isNewline).first(where: { line in
                  let code = line.drop(while: \.isWhitespace)
                  return !code.hasPrefix("//") && !code.hasPrefix("#")
                      && code.contains("$table_prefix") && code.contains("=")
              }),
              let assignment = line.split(separator: "=", maxSplits: 1).last else { return nil }
        // Only the statement itself: a trailing comment can quote another prefix.
        let statement = assignment.prefix(while: { $0 != ";" })
        let literals = statement.matches(of: #/['"]([A-Za-z0-9_]*)['"]/#).map { String($0.output.1) }
        return literals.last.flatMap { $0.isEmpty ? nil : $0 }
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
        guard isValidConstantName(name) else { throw ConfigError.invalidName(name) }
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

    // MARK: - Shared-database safety preflight (issue #17)

    /// The env var the `wordpress` image's `wp-config.php` template reads
    /// `DB_NAME` from — and the hinge the whole shared-database feature turns on.
    public static let dbNameEnvironmentVariable = "WORDPRESS_DB_NAME"

    /// Whether pointing a container at a different schema via
    /// `WORDPRESS_DB_NAME` will actually be honored by this site's
    /// `wp-config.php`.
    ///
    /// This is the guard in front of issue #17's one genuinely dangerous failure
    /// mode: a project that ships its own config with a hardcoded
    /// `define('DB_NAME', 'wordpress')` would ignore the env var entirely and a
    /// "shared" env would silently read and WRITE the parent site's database.
    /// Anything we can't positively confirm reads as false, so the caller falls
    /// back to a dedicated DB container.
    ///
    /// A missing `wp-config.php` is safe: the image's entrypoint generates one
    /// from the `WORDPRESS_DB_*` environment on first boot.
    ///
    /// Comments are stripped before matching, and EVERY surviving `DB_NAME` define
    /// must follow the environment. Looking at only the first match is how you get
    /// fooled by the shape that matters most — a commented-out env-following
    /// define sitting above the live hardcoded one:
    /// ```php
    /// // define('DB_NAME', getenv_docker('WORDPRESS_DB_NAME', 'wordpress'));
    /// define('DB_NAME', 'wordpress');
    /// ```
    public static func dbNameFollowsEnvironment(wordpressFolder: URL) -> Bool {
        defineFollowsEnvironment(constant: "DB_NAME", variable: dbNameEnvironmentVariable, wordpressFolder: wordpressFolder)
    }

    /// The env var the image's `wp-config.php` template reads `DB_HOST` from.
    public static let dbHostEnvironmentVariable = "WORDPRESS_DB_HOST"

    /// Whether this site's `wp-config.php` takes `DB_HOST` from
    /// `WORDPRESS_DB_HOST`, so the database can be reached at a different host.
    /// Same rules as `dbNameFollowsEnvironment`: a missing file is safe, any
    /// other case that can't be confirmed reads as false.
    public static func dbHostFollowsEnvironment(wordpressFolder: URL) -> Bool {
        defineFollowsEnvironment(constant: "DB_HOST", variable: dbHostEnvironmentVariable, wordpressFolder: wordpressFolder)
    }

    /// Remove PHP comments (`//`, `#`, `/* … */`) while leaving string literals
    /// intact, so a `define('DB_NAME', 'shop#1')` isn't truncated and a
    /// commented-out define can't be mistaken for live code.
    ///
    /// A character scanner rather than a regex, because the two constructs are
    /// mutually nesting: `'a // b'` is a string, `// 'a` is a comment. Heredocs
    /// and Nowdocs are NOT modelled — a heredoc containing `/*` would over-strip.
    /// That direction is safe here: over-stripping can only remove `define`s, and
    /// removing them all makes `dbNameFollowsEnvironment` return false (isolated
    /// fallback), never true.
    static func strippingPHPComments(_ text: String) -> String {
        enum State { case code, singleQuoted, doubleQuoted, lineComment, blockComment }
        var state = State.code
        var out = String()
        out.reserveCapacity(text.count)
        var escaped = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            switch state {
            case .code:
                if ch == "/", next == "/" { state = .lineComment; i += 2; continue }
                if ch == "#" { state = .lineComment; i += 1; continue }
                if ch == "/", next == "*" { state = .blockComment; i += 2; continue }
                if ch == "'" { state = .singleQuoted }
                if ch == "\"" { state = .doubleQuoted }
                out.append(ch)
            case .singleQuoted, .doubleQuoted:
                out.append(ch)
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if (state == .singleQuoted && ch == "'") || (state == .doubleQuoted && ch == "\"") {
                    state = .code
                }
            case .lineComment:
                // Keep the newline so line numbers and statement boundaries hold.
                // `isNewline` because a CRLF pair is one Character, and the
                // `wordpress` image's wp-config.php uses CRLF line endings.
                if ch.isNewline { out.append(ch); state = .code }
            case .blockComment:
                if ch == "*", next == "/" { state = .code; i += 2; continue }
                if ch.isNewline { out.append(ch) }
            }
            i += 1
        }
        return out
    }

    // MARK: - Development constants (§2c-bis)

    /// Debug switches surfaced in Settings → Development (all boolean).
    public static let debugConstants = ["WP_DEBUG", "WP_DEBUG_LOG", "WP_DEBUG_DISPLAY", "SCRIPT_DEBUG", "SAVEQUERIES"]
    public static let developmentModeConstant = "WP_DEVELOPMENT_MODE"
    public static let environmentTypeConstant = "WP_ENVIRONMENT_TYPE"

    /// Set a constant only when it is absent (never overwrite a user value).
    /// Returns true if it was written.
    @discardableResult
    public static func setConstantIfAbsent(_ name: String, value: String, rawValue: Bool, wordpressFolder: URL) throws -> Bool {
        let parsed = try? read(wordpressFolder: wordpressFolder)
        if parsed?.constants[name] != nil { return false }
        try setConstant(name, value: value, rawValue: rawValue, wordpressFolder: wordpressFolder)
        return true
    }

    /// Inject the tool's default dev constants (`WP_DEVELOPMENT_MODE=all`,
    /// `WP_ENVIRONMENT_TYPE=local`) if absent — idempotent (§2c-bis).
    public static func ensureDevelopmentConstants(wordpressFolder: URL) throws {
        guard FileManager.default.fileExists(atPath: configURL(for: wordpressFolder).path) else { return }
        try setConstantIfAbsent(developmentModeConstant, value: "all", rawValue: false, wordpressFolder: wordpressFolder)
        try setConstantIfAbsent(environmentTypeConstant, value: "local", rawValue: false, wordpressFolder: wordpressFolder)
    }

    /// Read a boolean constant (a missing constant reads as false).
    public static func boolConstant(_ name: String, wordpressFolder: URL) -> Bool {
        guard let parsed = try? read(wordpressFolder: wordpressFolder),
              let raw = parsed.constants[name] else { return false }
        return raw.lowercased() == "true" || raw == "1"
    }

    /// Set a boolean constant verbatim (`true`/`false`).
    public static func setBoolConstant(_ name: String, _ value: Bool, wordpressFolder: URL) throws {
        try setConstant(name, value: value ? "true" : "false", rawValue: true, wordpressFolder: wordpressFolder)
    }

    // MARK: - HTTPS proxy snippet (§2f)

    private static let forwardedProtoMarker = "// WP Container: honor X-Forwarded-Proto from the local HTTPS proxy"
    private static let forwardedProtoSnippet = """
    // WP Container: honor X-Forwarded-Proto from the local HTTPS proxy
    if ( isset( $_SERVER['HTTP_X_FORWARDED_PROTO'] ) && 'https' === $_SERVER['HTTP_X_FORWARDED_PROTO'] ) {
        $_SERVER['HTTPS'] = 'on';
    }
    """

    /// True when `text` already contains a functionally-equivalent
    /// X-Forwarded-Proto handler — an `if` guarded by
    /// `$_SERVER['HTTP_X_FORWARDED_PROTO']` that sets `$_SERVER['HTTPS'] = 'on'`.
    /// The official WordPress Docker image ships exactly such a block in its
    /// wp-config template, so injecting ours next to it duplicates the same
    /// idempotent check (#7). Matches both our snippet and the image's
    /// (`'https' === …` vs `strpos(…, 'https') !== false` guard styles).
    static func hasForwardedProtoHandler(_ text: String) -> Bool {
        let pattern = #"isset\s*\(\s*\$_SERVER\s*\[\s*['\"]HTTP_X_FORWARDED_PROTO['\"]\s*\][\s\S]{0,300}?\$_SERVER\s*\[\s*['\"]HTTPS['\"]\s*\]\s*=\s*['\"]on['\"]"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Inject the X-Forwarded-Proto snippet right after the opening `<?php`.
    /// Idempotent, and a no-op when the file already handles
    /// X-Forwarded-Proto — either our marked snippet or the Docker image's own
    /// equivalent block (#7).
    @discardableResult
    public static func enableForwardedProto(wordpressFolder: URL) throws -> String? {
        let url = configURL(for: wordpressFolder)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ConfigError.notFound(url.path) }
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { throw ConfigError.unreadable(url.path) }
        if text.contains(forwardedProtoMarker) { return nil }
        if hasForwardedProtoHandler(text) { return nil }
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

    private static func defineFollowsEnvironment(constant: String, variable: String, wordpressFolder: URL) -> Bool {
        let url = configURL(for: wordpressFolder)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let text = strippingPHPComments(raw)
        // The define's value expression, whatever shape it has.
        let pattern = #"define\s*\(\s*['\"]"# + constant + #"['\"]\s*,\s*(.*?)\s*\)\s*;"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return false }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        // No define we can reason about — assume unsafe.
        guard !matches.isEmpty else { return false }
        return matches.allSatisfy {
            ns.substring(with: $0.range(at: 1)).contains(variable)
        }
    }

    private static func phpEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }
}
