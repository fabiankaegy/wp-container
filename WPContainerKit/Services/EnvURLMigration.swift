import Foundation

/// Pure URL-migration logic shared by worktree-env creation and the
/// `worktree fix-urls` repair command.
///
/// A worktree env is a byte-for-byte clone of its parent site's database and
/// `wordpress/` folder, so EVERY url in it still points at the parent:
/// `home`/`siteurl`, `wp_blogs.domain`, `wp_site.domain`, `wp_sitemeta`,
/// per-subsite `wp_N_options`, and serialized content. A shallow
/// `wp option update home/siteurl` (the only fix that used to run) touches two
/// rows of one table and leaves all of that behind — on multisite the env then
/// redirects every request back to the parent's domain and is unreachable.
///
/// Nothing here executes a process; `EnvURLMigrator` does that.
public enum EnvURLMigration {
    /// One `wp search-replace` invocation.
    public struct Pass: Sendable, Equatable {
        public let source: String
        public let target: String
        public init(source: String, target: String) {
            self.source = source
            self.target = target
        }
    }

    /// A wp-config.php constant that has to change, as `name` → string value.
    public struct ConstantUpdate: Sendable, Equatable {
        public let name: String
        public let value: String
        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    /// The authority (`host[:port]`) every url in a migrated env points at.
    /// Always the env's own loopback port — an env publishes no hostname of its
    /// own beyond `<envSlug>.localhost`, which the proxy maps to this same port.
    public static func targetAuthority(port: Int) -> String { "127.0.0.1:\(port)" }

    /// Normalize an arbitrary origin — `https://host/path`, `//host`,
    /// `host:port`, a bare `host`, a `wp_blogs.domain` column value — down to its
    /// `host[:port]` authority. nil when there is nothing usable in it.
    ///
    /// The port is deliberately KEPT: WordPress only strips `:80`/`:443` from
    /// `HTTP_HOST`, so `127.0.0.1:8901` is a legitimate `wp_blogs.domain` and a
    /// legitimate `DOMAIN_CURRENT_SITE`.
    public static func authority(from raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let scheme = s.range(of: "://") {
            s = String(s[scheme.upperBound...])
        } else if s.hasPrefix("//") {
            s = String(s.dropFirst(2))
        }
        if let stop = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            s = String(s[..<stop])
        }
        if let at = s.lastIndex(of: "@") {
            s = String(s[s.index(after: at)...])
        }
        s = s.lowercased()
        guard !s.isEmpty, !s.hasPrefix(":"), s != "." else { return nil }
        // Anything that couldn't be a host[:port] is a value we must not feed to
        // search-replace — a stray quote or space there would rewrite content at
        // random rather than migrate a url.
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-_:[]")
        guard s.allSatisfy({ allowed.contains($0) }) else { return nil }
        return s
    }

    /// The ordered `wp search-replace` passes migrating one origin authority onto
    /// another. Empty when the two are the same (or either is unusable).
    ///
    /// Order is load-bearing: the full-url forms run FIRST so scheme-specific
    /// occurrences are consumed before the bare-host pass, which would otherwise
    /// rewrite the host inside `https://old` and leave a dead `https://` scheme
    /// on an env that only ever answers plain HTTP. The bare-host pass is what
    /// reaches the multisite domain columns (`wp_blogs.domain`, `wp_site.domain`),
    /// which hold no scheme at all.
    public static func passes(from source: String, to target: String) -> [Pass] {
        guard let s = authority(from: source), let t = authority(from: target), s != t else { return [] }
        return [
            Pass(source: "https://\(s)", target: "http://\(t)"),
            Pass(source: "http://\(s)", target: "http://\(t)"),
            Pass(source: "//\(s)", target: "//\(t)"),
            Pass(source: s, target: t),
        ]
    }

    /// Normalize, dedupe and order the origins to migrate: everything that isn't
    /// already the target, in first-seen order.
    ///
    /// `networkDomain` (the value the multisite bootstrap keys off —
    /// `DOMAIN_CURRENT_SITE`, else `wp_site.domain`) is moved LAST. Until that
    /// one is rewritten, `wp` can still find its network, so every earlier pass
    /// bootstraps; rewriting it last means only the wp-config rewrite that
    /// immediately follows has to restore agreement.
    public static func staleOrigins(candidates: [String], target: String,
                                    networkDomain: String? = nil) -> [String] {
        guard let t = authority(from: target) else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for candidate in candidates {
            guard let a = authority(from: candidate), a != t, seen.insert(a).inserted else { continue }
            out.append(a)
        }
        if let network = networkDomain.flatMap({ authority(from: $0) }),
           let i = out.firstIndex(of: network) {
            out.append(out.remove(at: i))
        }
        return out
    }

    /// Whether this clone is a multisite network — the parent site's recorded
    /// network type OR a live `MULTISITE` constant in the clone's wp-config.php
    /// (a network that arrived through a database import never set the former).
    public static func isMultisite(networkType: NetworkType, constants: [String: String]) -> Bool {
        if networkType.isMultisite { return true }
        guard let raw = constants["MULTISITE"]?.lowercased() else { return false }
        return raw == "true" || raw == "1"
    }

    /// Whether `name` is an options table for `prefix` — `wp_options` or a
    /// subsite's `wp_<N>_options`.
    public static func isOptionsTable(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let rest = name.dropFirst(prefix.count)
        if rest == "options" { return true }
        guard rest.hasSuffix("_options") else { return false }
        let digits = rest.dropLast("_options".count)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    /// A MySQL identifier we are willing to interpolate into SQL. Table names
    /// come from `SHOW TABLES` and the prefix from wp-config.php, so neither is
    /// attacker-supplied — but neither is validated by anything upstream either.
    public static func isSafeIdentifier(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// The wp-config constants that must change for the clone to stop pointing
    /// at its parent. `DOMAIN_CURRENT_SITE` for a multisite clone (WordPress
    /// reads the network's domain from the CONSTANT, so a stale one redirects
    /// away regardless of what the database says), plus any hardcoded
    /// `WP_HOME`/`WP_SITEURL` — those override the database options entirely.
    ///
    /// `WP_HOME`/`WP_SITEURL` are only ever REWRITTEN, never added: a clone that
    /// didn't pin them should keep reading its options.
    public static func configConstantUpdates(existing: [String: String], targetAuthority: String,
                                             multisite: Bool) -> [ConstantUpdate] {
        var out: [ConstantUpdate] = []
        if multisite || existing["DOMAIN_CURRENT_SITE"] != nil,
           existing["DOMAIN_CURRENT_SITE"] != targetAuthority {
            out.append(ConstantUpdate(name: "DOMAIN_CURRENT_SITE", value: targetAuthority))
        }
        let url = "http://\(targetAuthority)"
        for name in ["WP_HOME", "WP_SITEURL"] {
            guard let current = existing[name], current != url else { continue }
            out.append(ConstantUpdate(name: name, value: url))
        }
        return out
    }

    /// The replacement count from a `wp search-replace` summary line. Handles
    /// both wordings: "Made 12 replacements" for a real run, "12 replacements to
    /// be made" for `--dry-run`.
    public static func parseReplacementCount(_ output: String) -> Int? {
        let patterns = [#"Made\s+(\d+)\s+replacements?"#, #"(\d+)\s+replacements?\s+to\s+be\s+made"#]
        let ns = output as NSString
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: output, range: NSRange(location: 0, length: ns.length)),
                  let value = Int(ns.substring(with: m.range(at: 1))) else { continue }
            return value
        }
        return nil
    }
}

// MARK: - Report

/// One `wp search-replace` invocation's outcome.
public struct URLMigrationPassResult: Sendable {
    public let source: String
    public let target: String
    /// nil when the count couldn't be parsed (or the pass failed).
    public let replacements: Int?
    public let failed: Bool
}

/// Every pass run for one stale origin.
public struct URLOriginMigration: Sendable {
    public let origin: String
    public let passes: [URLMigrationPassResult]
    public var replacements: Int { passes.compactMap(\.replacements).reduce(0, +) }
}

/// What a migration did (or, for a dry run, would do).
public struct URLMigrationReport: Sendable {
    public let target: String
    public let dryRun: Bool
    public var origins: [URLOriginMigration] = []
    public var configUpdates: [EnvURLMigration.ConstantUpdate] = []
    /// Non-fatal problems: a failed search-replace pass, an unwritable
    /// wp-config.php. The migration continues past all of them.
    public var warnings: [String] = []
    public var replacements: Int { origins.map(\.replacements).reduce(0, +) }
}

/// What the database and wp-config.php currently claim this instance's urls are.
public struct URLOriginDiscovery: Sendable {
    public var candidates: [String] = []
    /// The origin the multisite bootstrap keys off, when there is one.
    public var networkDomain: String?
    /// Parsed wp-config.php constants (empty when there is no readable config).
    public var constants: [String: String] = [:]
    public var warnings: [String] = []
}

// MARK: - Executor

/// Runs `EnvURLMigration`'s passes against a live instance.
public struct EnvURLMigrator: Sendable {
    private let cli: ContainerCLI

    public init(cli: ContainerCLI) {
        self.cli = cli
    }

    /// Read the origins this instance's database and wp-config.php actually
    /// contain, rather than assuming the parent's domain: envs repaired by hand
    /// carry stale vmnet IPs, dead `localhost:<port>` forwarders and mixed
    /// schemes as well.
    ///
    /// Every read goes through `wp db query`, which runs at wp-cli's
    /// `after_wp_config_load` stage — so a multisite whose bootstrap is already
    /// broken (the exact case this repairs) cannot block detection.
    public func discoverOrigins(instance: any RunnableInstance, dbHost: String,
                                wordpressFolder: URL) async -> URLOriginDiscovery {
        var discovery = URLOriginDiscovery()
        let parsed = try? WPConfigService.read(wordpressFolder: wordpressFolder)
        discovery.constants = parsed?.constants ?? [:]

        var prefix = "wp_"
        if let candidate = parsed?.tablePrefix, EnvURLMigration.isSafeIdentifier(candidate) {
            prefix = candidate
        }

        let tables = await queryColumn(instance: instance, dbHost: dbHost, sql: "SHOW TABLES")
            .filter(EnvURLMigration.isSafeIdentifier)
        if tables.isEmpty {
            discovery.warnings.append("Could not list the database tables of \(instance.containerSlug); detection fell back to the parent site's url only.")
        }

        for table in tables where EnvURLMigration.isOptionsTable(table, prefix: prefix) {
            discovery.candidates += await queryColumn(
                instance: instance, dbHost: dbHost,
                sql: "SELECT option_value FROM `\(table)` WHERE option_name IN ('home', 'siteurl')")
        }
        if tables.contains("\(prefix)blogs") {
            discovery.candidates += await queryColumn(
                instance: instance, dbHost: dbHost, sql: "SELECT domain FROM `\(prefix)blogs`")
        }
        if tables.contains("\(prefix)site") {
            let domains = await queryColumn(instance: instance, dbHost: dbHost,
                                            sql: "SELECT domain FROM `\(prefix)site`")
            discovery.candidates += domains
            discovery.networkDomain = domains.first
        }
        // The constant wins as the bootstrap key: WordPress reads the network's
        // domain from it before it ever looks at wp_site.
        if let configured = discovery.constants["DOMAIN_CURRENT_SITE"], !configured.isEmpty {
            discovery.candidates.append(configured)
            discovery.networkDomain = configured
        }
        return discovery
    }

    /// Migrate every `origins` entry onto `targetAuthority`, then rewrite the
    /// wp-config constants that override the database, then finish with the
    /// belt-and-braces `wp option update home/siteurl` + `wp cache flush`.
    ///
    /// Only the finisher throws. A failed search-replace pass is recorded as a
    /// warning and the migration carries on, so this can never brick an env
    /// creation — the env still ends up with the old shallow behavior.
    public func migrate(instance: any RunnableInstance, dbHost: String, wordpressFolder: URL,
                        origins: [String], targetAuthority: String,
                        multisite: Bool, dryRun: Bool) async throws -> URLMigrationReport {
        var report = URLMigrationReport(target: targetAuthority, dryRun: dryRun)
        for origin in origins {
            var results: [URLMigrationPassResult] = []
            for pass in EnvURLMigration.passes(from: origin, to: targetAuthority) {
                let args = SiteRecipe.wpSearchReplaceArgs(instance, dbHost: dbHost,
                                                          source: pass.source, target: pass.target,
                                                          network: multisite, dryRun: dryRun)
                let result = try? await cli.runCapturing(args)
                guard let result, result.succeeded else {
                    let detail = (result?.stderr.isEmpty == false ? result!.stderr : result?.stdout) ?? ""
                    report.warnings.append("Could not replace \(pass.source) with \(pass.target): \(Self.firstLine(detail))")
                    results.append(URLMigrationPassResult(source: pass.source, target: pass.target,
                                                          replacements: nil, failed: true))
                    continue
                }
                results.append(URLMigrationPassResult(
                    source: pass.source, target: pass.target,
                    replacements: EnvURLMigration.parseReplacementCount(result.stdout), failed: false))
            }
            report.origins.append(URLOriginMigration(origin: origin, passes: results))
        }

        let parsed = try? WPConfigService.read(wordpressFolder: wordpressFolder)
        report.configUpdates = EnvURLMigration.configConstantUpdates(
            existing: parsed?.constants ?? [:], targetAuthority: targetAuthority, multisite: multisite)
        guard !dryRun else { return report }

        if !report.configUpdates.isEmpty {
            if parsed == nil {
                report.warnings.append("No readable wp-config.php at \(WPConfigService.configURL(for: wordpressFolder).path); DOMAIN_CURRENT_SITE / WP_HOME were left alone.")
                report.configUpdates = []
            } else {
                for update in report.configUpdates {
                    do {
                        try WPConfigService.setConstant(update.name, value: update.value,
                                                        rawValue: false, wordpressFolder: wordpressFolder)
                    } catch {
                        report.warnings.append("Could not set \(update.name) in wp-config.php: \(error)")
                    }
                }
            }
        }
        try await cli.run(SiteRecipe.wpUpdateURLsArgs(instance, dbHost: dbHost))
        return report
    }

    // MARK: - Helpers

    /// A single column of a `wp db query` result, one row per line.
    private func queryColumn(instance: any RunnableInstance, dbHost: String, sql: String) async -> [String] {
        let args = SiteRecipe.wpDBQueryArgs(instance, dbHost: dbHost, sql: sql, skipColumnNames: true)
        guard let result = try? await cli.runCapturing(args), result.succeeded else { return [] }
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func firstLine(_ text: String) -> String {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return line }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
