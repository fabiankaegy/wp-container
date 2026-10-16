import Foundation

/// Moves an existing site from its legacy `<slug>.localhost` default host into
/// the owned loopback zone (`<slug>.wpc.test`, PLAN.md §2f-ter).
///
/// Explicit, never automatic (`wp-container zone migrate`): it rewrites the
/// site's database, and until it runs the site keeps working through the
/// proxy's legacy alias + the helper's temporary 127.0.0.1 redirect
/// (`HTTPSProxy.needsLegacyLoopback`), which disappears once nothing needs it.
public struct LoopbackZoneMigrator: Sendable {
    public enum MigrationError: Error, Sendable, CustomStringConvertible {
        case zoneNotInstalled
        case notRunning(String)
        case searchReplaceFailed(String)

        public var description: String {
            switch self {
            case .zoneNotInstalled:
                return "The \(LoopbackZone.zone) zone isn't set up on this Mac — it needs the privileged helper (Settings › General) and a running proxy."
            case .notRunning(let slug):
                return "\(slug) must be running to rewrite its database."
            case .searchReplaceFailed(let detail):
                return "wp search-replace failed: \(detail)"
            }
        }
    }

    public struct Outcome: Sendable {
        public let slug: String
        public let url: String
        /// nil when the database was not touched (nothing in it used the host).
        public let replacements: Int?
        public let dryRun: Bool
    }

    private let cli: ContainerCLI
    private let persistence: StorePersistence

    public init(cli: ContainerCLI = ContainerCLI(), persistence: StorePersistence = StorePersistence()) {
        self.cli = cli
        self.persistence = persistence
    }

    /// The `--regex` search-replace moving `<slug>.localhost` onto the zone:
    /// matches it in urls, bare multisite domain columns and as the parent of
    /// subdomains, but never inside a longer label (`my-blog.localhost` for
    /// slug `blog`) or a longer name (`blog.localhost.example.com`).
    /// Slugs are `[a-z0-9-]`, so only the dot needs escaping; no `/` (wp-cli's
    /// regex delimiter) can appear.
    public static func replacement(slug: String) -> (pattern: String, target: String) {
        ("(?<![a-z0-9-])\(slug)\\.localhost(?![a-z0-9-]|\\.[a-z0-9])", LoopbackZone.host(slug))
    }

    /// Whether the site's database can reference the legacy host at all: only
    /// an HTTPS site without a custom domain was ever served at it. Others just
    /// flip the flag — their database holds `127.0.0.1:<port>` or the domain.
    public static func needsDatabaseRewrite(_ site: Site) -> Bool {
        site.httpsEnabled && (site.customDomain ?? "").isEmpty
    }

    /// Migrate one site. A site whose database needs rewriting must be running
    /// (the caller starts it). Idempotent: an already-zoned site is a no-op.
    public func migrate(_ site: Site, dryRun: Bool = false) async throws -> Outcome {
        guard LoopbackZone.isInstalled else { throw MigrationError.zoneNotInstalled }
        var target = site
        target.usesLoopbackZone = true
        guard !site.usesLoopbackZone else {
            return Outcome(slug: site.slug, url: site.url.absoluteString, replacements: nil, dryRun: dryRun)
        }

        var replacements: Int?
        let dbHost = (try? await cli.ipAddress(of: site.dbContainerName)) ?? nil
        if let dbHost, !dbHost.isEmpty {
            replacements = try await rewriteDatabase(site, dbHost: dbHost, dryRun: dryRun)
        } else if Self.needsDatabaseRewrite(site) {
            throw MigrationError.notRunning(site.slug)
        }
        guard !dryRun else {
            return Outcome(slug: site.slug, url: target.url.absoluteString, replacements: replacements, dryRun: true)
        }

        let id = site.id
        _ = try await persistence.mutate { env in
            if let i = env.sites.firstIndex(where: { $0.id == id }) { env.sites[i].usesLoopbackZone = true }
        }
        // Make the new name resolve inside the running container too (its
        // /etc/hosts maps site names to the gateway; rebuilt on every start).
        if let gateway = (try? await cli.gatewayAddress(of: site.wpContainerName)) ?? nil,
           let args = SiteRecipe.injectLoopbackHostsArgs(target, gateway: gateway) {
            _ = try? await cli.runCapturing(args)
        }
        return Outcome(slug: site.slug, url: target.url.absoluteString, replacements: replacements, dryRun: false)
    }

    /// Search-replace the host everywhere, then fix `DOMAIN_CURRENT_SITE`,
    /// which multisite reads before the database. Returns the replacement count.
    private func rewriteDatabase(_ site: Site, dbHost: String, dryRun: Bool) async throws -> Int? {
        let (pattern, host) = Self.replacement(slug: site.slug)
        let parsed = try? WPConfigService.read(wordpressFolder: site.wordpressFolder)
        let constants = parsed?.constants ?? [:]
        let multisite = EnvURLMigration.isMultisite(networkType: site.networkType, constants: constants)
        let args = SiteRecipe.wpSearchReplaceArgs(site, dbHost: dbHost, source: pattern, target: host,
                                                  network: multisite, dryRun: dryRun, regex: true)
        let result = try await cli.runCapturing(args)
        guard result.succeeded else {
            throw MigrationError.searchReplaceFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        let count = EnvURLMigration.parseReplacementCount(result.stdout)
        guard !dryRun else { return count }

        if constants["DOMAIN_CURRENT_SITE"] == site.legacyLocalhostHost {
            try WPConfigService.setConstant("DOMAIN_CURRENT_SITE", value: host, rawValue: false,
                                            wordpressFolder: site.wordpressFolder)
        }
        _ = try? await cli.runCapturing(SiteRecipe.wpCacheFlushArgs(site, dbHost: dbHost))
        return count
    }
}
