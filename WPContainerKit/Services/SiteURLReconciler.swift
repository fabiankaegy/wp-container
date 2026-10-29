import Foundation

/// Pure planning for `SiteURLReconciler`: compares the `home`/`siteurl` values
/// of every blog in a site's database with the URL the site is served at.
///
/// Two kinds of drift are told apart. The main site or the network on another
/// authority (the domain or HTTPS changed while the site was stopped) needs a
/// full origin migration, the one worktree envs get. A blog on the right host but the
/// wrong scheme (HTTPS toggled, subsites left behind) only needs its scheme
/// flipped; doing that per authority keeps subdomain and mapped subsites on
/// their own hosts.
public enum SiteURLReconciliation {
    /// One `home` or `siteurl` value and the options table it was read from.
    public struct Row: Sendable, Equatable {
        public let table: String
        public let value: String
        public init(table: String, value: String) {
            self.table = table
            self.value = value
        }
    }

    public struct Plan: Sendable, Equatable {
        /// Authorities of the main site or the network other than the target.
        /// Non-empty means a full origin migration first.
        public var staleOrigins: [String] = []
        /// Other authorities whose URLs use the wrong scheme, in first-seen order.
        public var schemeFixes: [String] = []
        public var isEmpty: Bool { staleOrigins.isEmpty && schemeFixes.isEmpty }
    }

    /// One `wp db query` that lists `home` and `siteurl` from the main options
    /// table and every subsite's (`<prefix><N>_options`), as `table`, `option`,
    /// `value` rows. A single wp-cli run however many subsites there are.
    public static func readURLsSQL(prefix: String) -> String {
        """
        SET SESSION group_concat_max_len = 1048576; \
        SET @q = (SELECT GROUP_CONCAT(CONCAT('SELECT ''', table_name, ''', option_name, option_value FROM `', \
        table_name, '` WHERE option_name IN (''home'', ''siteurl'')') SEPARATOR ' UNION ALL ') \
        FROM information_schema.tables WHERE table_schema = DATABASE() \
        AND table_name REGEXP '^\(prefix)([0-9]+_)?options$'); \
        PREPARE wpc_urls FROM @q; EXECUTE wpc_urls; DEALLOCATE PREPARE wpc_urls;
        """
    }

    /// The rows of `readURLsSQL` output (`--skip-column-names`, tab-separated).
    public static func parseRows(_ output: String) -> [Row] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { return nil }
            let value = String(fields[2]).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : Row(table: String(fields[0]), value: value)
        }
    }

    /// What has to change for every row to agree with `target`.
    /// `networkDomain` is a multisite's `DOMAIN_CURRENT_SITE`: subdirectory
    /// subsites live on it, so a stale one moves with the main site.
    public static func plan(rows: [Row], mainTable: String, networkDomain: String? = nil,
                            target: URL) -> Plan {
        var plan = Plan()
        guard let targetAuthority = EnvURLMigration.authority(from: target.absoluteString),
              let targetScheme = target.scheme?.lowercased() else { return plan }
        let origins = rows.filter { $0.table == mainTable }.map(\.value) + [networkDomain].compactMap { $0 }
        for origin in origins {
            guard let authority = EnvURLMigration.authority(from: origin), authority != targetAuthority,
                  !plan.staleOrigins.contains(authority) else { continue }
            plan.staleOrigins.append(authority)
        }
        for row in rows {
            guard let scheme = scheme(of: row.value), scheme != targetScheme,
                  let authority = EnvURLMigration.authority(from: row.value),
                  !plan.staleOrigins.contains(authority),
                  !plan.schemeFixes.contains(authority) else { continue }
            plan.schemeFixes.append(authority)
        }
        return plan
    }

    /// The `wp search-replace` pass moving `authority`'s URLs onto `scheme`.
    public static func schemePass(authority: String, scheme: String) -> EnvURLMigration.Pass {
        let other = scheme == "https" ? "http" : "https"
        return EnvURLMigration.Pass(source: "\(other)://\(authority)", target: "\(scheme)://\(authority)")
    }

    private static func scheme(of value: String) -> String? {
        let lower = value.lowercased()
        if lower.hasPrefix("https://") { return "https" }
        if lower.hasPrefix("http://") { return "http" }
        return nil
    }
}

/// Brings a site's WordPress URLs in line with the URL it is served at, across
/// every blog of a network, and records that URL on the site
/// (`Site.wordpressURL`) so later starts can skip the check.
///
/// Runs on start whenever the recorded URL differs from the site's URL, and
/// whenever HTTPS or the custom domain changes on a running site.
public struct SiteURLReconciler: Sendable {
    private let cli: ContainerCLI
    private let persistence: StorePersistence

    public init(cli: ContainerCLI, persistence: StorePersistence = StorePersistence()) {
        self.cli = cli
        self.persistence = persistence
    }

    /// Point every blog of `site` at `url` (its served URL, passed explicitly
    /// because callers toggling HTTPS haven't stored the new flag yet). Returns
    /// non-fatal warnings; throws when the URLs can't be read or set. The URL
    /// is recorded only when every step succeeded.
    @discardableResult
    public func reconcile(_ site: Site, dbHost: String, url: URL) async throws -> [String] {
        let parsed = try? WPConfigService.read(wordpressFolder: site.wordpressFolder)
        var prefix = "wp_"
        if let candidate = parsed?.tablePrefix, EnvURLMigration.isSafeIdentifier(candidate) {
            prefix = candidate
        }
        let mainTable = "\(prefix)options"
        let https = url.scheme?.lowercased() == "https"
        let multisite = EnvURLMigration.isMultisite(networkType: site.networkType,
                                                    constants: parsed?.constants ?? [:])
        var warnings: [String] = []

        let networkDomain = multisite ? parsed?.constants["DOMAIN_CURRENT_SITE"] : nil
        var plan = SiteURLReconciliation.plan(rows: try await readRows(site, dbHost: dbHost, prefix: prefix),
                                              mainTable: mainTable, networkDomain: networkDomain, target: url)
        let changed = !plan.isEmpty
        if !plan.staleOrigins.isEmpty, let targetAuthority = EnvURLMigration.authority(from: url.absoluteString) {
            let migrator = EnvURLMigrator(cli: cli)
            let discovery = await migrator.discoverOrigins(instance: site, dbHost: dbHost,
                                                           wordpressFolder: site.wordpressFolder)
            let origins = EnvURLMigration.staleOrigins(
                candidates: plan.staleOrigins + [discovery.networkDomain].compactMap { $0 },
                target: targetAuthority, networkDomain: discovery.networkDomain)
            let report = try await migrator.migrate(instance: site, dbHost: dbHost,
                                                    wordpressFolder: site.wordpressFolder,
                                                    origins: origins, targetAuthority: targetAuthority,
                                                    https: https, multisite: multisite, dryRun: false)
            warnings += report.warnings
            plan = SiteURLReconciliation.plan(rows: try await readRows(site, dbHost: dbHost, prefix: prefix),
                                              mainTable: mainTable, target: url)
        }

        if https, !plan.schemeFixes.isEmpty {
            do {
                try WPConfigService.enableForwardedProto(wordpressFolder: site.wordpressFolder)
            } catch {
                warnings.append("Could not add the X-Forwarded-Proto handler to wp-config.php: \(error)")
            }
        }
        let scheme = https ? "https" : "http"
        for authority in plan.schemeFixes {
            let pass = SiteURLReconciliation.schemePass(authority: authority, scheme: scheme)
            let args = SiteRecipe.wpSearchReplaceArgs(site, dbHost: dbHost, source: pass.source,
                                                      target: pass.target, network: multisite)
            let result = try? await cli.runCapturing(args)
            if result?.succeeded != true {
                warnings.append("Could not replace \(pass.source) with \(pass.target).")
            }
        }
        if changed {
            _ = try? await cli.runCapturing(SiteRecipe.wpCacheFlushArgs(site, dbHost: dbHost))
            await RedisService.flush(site, cli: cli)
        }
        if warnings.isEmpty { try? await recordApplied(url, for: site.id) }
        return warnings
    }

    private func readRows(_ site: Site, dbHost: String, prefix: String) async throws -> [SiteURLReconciliation.Row] {
        let args = SiteRecipe.wpDBQueryArgs(site, dbHost: dbHost,
                                            sql: SiteURLReconciliation.readURLsSQL(prefix: prefix),
                                            skipColumnNames: true)
        let output = try await cli.run(args)
        return SiteURLReconciliation.parseRows(output)
    }

    private func recordApplied(_ url: URL, for id: UUID) async throws {
        let value = url.absoluteString
        try await persistence.mutateIfChanged { store in
            guard let i = store.sites.firstIndex(where: { $0.id == id }),
                  store.sites[i].wordpressURL != value else { return false }
            store.sites[i].wordpressURL = value
            return true
        }
    }
}
