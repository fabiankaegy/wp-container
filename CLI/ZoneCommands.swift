import ArgumentParser
import Foundation
import WPContainerKit

// MARK: - zone (PLAN.md §2f-ter)

struct ZoneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "zone",
        abstract: "Inspect the owned *.\(LoopbackZone.zone) loopback zone and move sites into it.",
        subcommands: [ZoneStatus.self, ZoneMigrate.self]
    )
}

struct ZoneStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status",
                                                    abstract: "Show whether the zone is set up and which sites still use <slug>.localhost.")
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let envelope = try await ctx.load()
            let legacy = envelope.sites.filter { !$0.usesLoopbackZone }.map(\.slug)
            let legacyRedirect = HTTPSProxy.needsLegacyLoopback(envelope)
            if output.json {
                emitLine(MCPJSON.string([
                    "installed": LoopbackZone.isInstalled,
                    "zone": LoopbackZone.zone,
                    "address": LoopbackZone.ipv4,
                    "legacySites": legacy,
                    "legacyLoopbackRedirect": legacyRedirect,
                ]))
            } else {
                emitLine(LoopbackZone.isInstalled
                         ? "Zone *.\(LoopbackZone.zone) is set up (→ \(LoopbackZone.ipv4))."
                         : "Zone *.\(LoopbackZone.zone) is NOT set up — sites use <slug>.localhost and the proxy binds *:80/*:443. It needs the privileged helper (Developer-ID build, Settings › General).")
                emitLine(legacy.isEmpty ? "All sites use the zone." : "Sites still on <slug>.localhost: \(legacy.joined(separator: ", "))")
                if LoopbackZone.isInstalled, legacyRedirect {
                    emitLine("127.0.0.1:80/443 is still redirected to WP Container for them (and for worktree envs); run `wp-container zone migrate --all` to release it.")
                }
            }
        } catch { throw failCommand(error, json: output.json) }
    }
}

struct ZoneMigrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate",
        abstract: "Move sites from <slug>.localhost to <slug>.\(LoopbackZone.zone).",
        discussion: """
        Rewrites every occurrence of the site's <slug>.localhost host in its \
        database (`wp search-replace --all-tables --precise --regex`, multisite \
        domains included) and DOMAIN_CURRENT_SITE, then switches the site's \
        default host. Sites that never used the .localhost URL (HTTP-only or \
        custom-domain sites) just switch. A stopped site whose database needs \
        rewriting is started first unless --no-start is given. The old name \
        keeps routing as an alias.
        """
    )
    @Argument(help: "Site slugs (omit with --all).") var slugs: [String] = []
    @Flag(name: .long, help: "Migrate every site still on <slug>.localhost.") var all = false
    @Flag(name: .long, help: "Report the replacement counts without writing anything.") var dryRun = false
    @Flag(name: .long, help: "Don't auto-start a stopped site; fail instead.") var noStart = false
    @OptionGroup var output: JSONOptions

    func validate() throws {
        if all == !slugs.isEmpty { throw ValidationError("Pass site slugs or --all (not both).") }
    }

    func run() async throws {
        let ctx = CLIContext()
        do {
            let envelope = try await ctx.load()
            let sites: [Site]
            if all {
                sites = envelope.sites.filter { !$0.usesLoopbackZone }
            } else {
                sites = try slugs.map { slug in
                    guard let s = envelope.sites.first(where: { $0.slug == slug }) else {
                        throw CLIErrorJSON("site_not_found", detail: slug)
                    }
                    return s
                }
            }
            let migrator = LoopbackZoneMigrator(cli: ctx.cli, persistence: ctx.persistence)
            var results: [[String: Any]] = []
            for site in sites {
                if LoopbackZoneMigrator.needsDatabaseRewrite(site), !site.usesLoopbackZone {
                    try await ctx.ensureRunning(.site(site), envelope: envelope, noStart: noStart)
                }
                let outcome = try await migrator.migrate(site, dryRun: dryRun)
                results.append(["slug": outcome.slug, "url": outcome.url,
                                "replacements": outcome.replacements as Any? ?? NSNull(), "dryRun": outcome.dryRun])
                if !output.json {
                    let count = outcome.replacements.map { " (\($0) replacement\($0 == 1 ? "" : "s"))" } ?? ""
                    emitLine("\(dryRun ? "Would migrate" : "Migrated") \(outcome.slug) → \(outcome.url)\(count)")
                }
            }
            if output.json { emitLine(MCPJSON.string(["ok": true, "sites": results])) }
            else if sites.isEmpty { emitLine("Nothing to migrate.") }
        } catch { throw failCommand(error, json: output.json) }
    }
}
