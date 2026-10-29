import ArgumentParser
import Foundation
import WPContainerKit

// MARK: - Shared add-on toggle helper

private enum OnOff: String, ExpressibleByArgument {
    case on, off
    var enabled: Bool { self == .on }
}

private func toggleAndRestart(slug: String, output: JSONOptions, ctx: CLIContext,
                              label: String,
                              apply: @escaping @Sendable (inout Site) -> Void) async throws {
    let envelope = try await ctx.load()
    guard let site = envelope.sites.first(where: { $0.slug == slug }) else {
        throw CLIErrorJSON("site_not_found", detail: slug)
    }
    let updated = try await ctx.persistence.mutate { env in
        if let i = env.sites.firstIndex(where: { $0.id == site.id }) { apply(&env.sites[i]) }
    }
    let newSite = updated.sites.first { $0.id == site.id } ?? site
    // Re-apply by restarting when the site is currently running.
    let running = await ctx.runningContainerNames()
    var restarted = false
    if running.contains(site.wpContainerName) {
        await ctx.lifecycle.stop(newSite)
        _ = try await ctx.lifecycle.startSite(newSite)
        await ctx.lifecycle.markRunning(newSite.id)
        restarted = true
    }
    if output.json {
        emitLine(MCPJSON.string(["ok": true, "slug": slug, "restarted": restarted]))
    } else {
        emitLine("\(label) for \(slug).\(restarted ? " Restarted to apply." : " Restart the site to apply.")")
    }
}

// MARK: - xdebug (§2c)

struct XdebugCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "xdebug", abstract: "Enable or disable Xdebug for a site: xdebug on|off <slug>.")
    @Argument(help: "on | off") var state: String
    @Argument(help: "Site slug.") var slug: String
    @OptionGroup var output: JSONOptions

    func run() async throws {
        guard let onOff = OnOff(rawValue: state.lowercased()) else { throw CLIErrorJSON("bad_args", detail: "state must be on|off") }
        let ctx = CLIContext()
        do {
            try await toggleAndRestart(slug: slug, output: output, ctx: ctx,
                                       label: onOff.enabled ? "Enabled Xdebug" : "Disabled Xdebug") { $0.xdebugEnabled = onOff.enabled }
        } catch { throw failCommand(error, json: output.json) }
    }
}

// MARK: - web-server

struct WebServerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "web-server", abstract: "Switch a site's web server: web-server apache|nginx <slug>.")
    @Argument(help: "apache | nginx") var server: String
    @Argument(help: "Site slug.") var slug: String
    @OptionGroup var output: JSONOptions

    func run() async throws {
        guard let webServer = WebServer(rawValue: server.lowercased()) else { throw CLIErrorJSON("bad_args", detail: "server must be apache|nginx") }
        let ctx = CLIContext()
        do {
            let envelope = try await ctx.load()
            guard let site = envelope.sites.first(where: { $0.slug == slug }) else {
                throw CLIErrorJSON("site_not_found", detail: slug)
            }
            guard webServer.supports(imageTag: site.imageTag) else {
                throw CLIErrorJSON("bad_args", detail: "nginx needs an official wordpress image with a PHP-FPM variant; \(site.imageTag) has none")
            }
            try await toggleAndRestart(slug: slug, output: output, ctx: ctx,
                                       label: "Switched to \(webServer.label)") { $0.webServer = webServer }
        } catch { throw failCommand(error, json: output.json) }
    }
}

/// Turn a sidecar on or off for a site and restart it when running. JSON:
/// `{ok, slug, addon, enabled, restarted}`, plus the addon's endpoint under its
/// `endpointKey` (`mailboxUrl` for Mailpit).
private func toggleSidecarAndRestart(_ addon: any SidecarAddon, enabled: Bool, slug: String,
                                     output: JSONOptions, ctx: CLIContext) async throws {
    let envelope = try await ctx.load()
    guard let site = envelope.sites.first(where: { $0.slug == slug }) else {
        throw CLIErrorJSON("site_not_found", detail: slug)
    }
    guard let updated = try await ctx.persistence.setSidecar(addon, enabled: enabled, siteID: site.id)?.site else {
        throw CLIErrorJSON("no_free_port")
    }
    var restarted = false
    if await ctx.runningContainerNames().contains(site.wpContainerName) {
        await ctx.lifecycle.stop(updated)
        _ = try await ctx.lifecycle.startSite(updated)
        await ctx.lifecycle.markRunning(updated.id)
        restarted = true
    }
    let endpoint = addon.endpointURL(for: updated)?.absoluteString
    if output.json {
        var payload: [String: Any] = ["ok": true, "slug": slug, "addon": addon.id, "enabled": enabled, "restarted": restarted]
        if let key = addon.endpointKey { payload[key] = endpoint as Any? ?? NSNull() }
        emitLine(MCPJSON.string(payload))
    } else {
        var line = "\(enabled ? "Enabled" : "Disabled") \(addon.displayName) for \(slug)."
        if let endpoint { line += " Open it at \(endpoint)." }
        line += restarted ? " Restarted to apply." : " Restart the site to apply."
        emitLine(line)
    }
}

// MARK: - elasticsearch (§2c)

struct ElasticsearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "elasticsearch", abstract: "Enable or disable Elasticsearch for a site: elasticsearch on|off <slug>.")
    @Argument(help: "on | off") var state: String
    @Argument(help: "Site slug.") var slug: String
    @OptionGroup var output: JSONOptions

    func run() async throws {
        guard let onOff = OnOff(rawValue: state.lowercased()) else { throw CLIErrorJSON("bad_args", detail: "state must be on|off") }
        do {
            try await toggleSidecarAndRestart(SidecarAddons.elasticsearch, enabled: onOff.enabled, slug: slug,
                                              output: output, ctx: CLIContext())
        } catch { throw failCommand(error, json: output.json) }
    }
}

// MARK: - mailpit (issue #10)

struct MailpitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mailpit",
        abstract: "Enable or disable the Mailpit email catcher for a site: mailpit on|off <slug>.",
        discussion: """
        On enable, writes the Mailpit mail-routing handler, reserves a localhost \
        port for the mailbox web UI, and (for a running site) restarts to launch \
        the mail container. Outgoing WordPress mail is then caught by Mailpit \
        instead of being sent. The mailbox is browsable at the printed URL.
        """
    )
    @Argument(help: "on | off") var state: String
    @Argument(help: "Site slug.") var slug: String
    @OptionGroup var output: JSONOptions

    func run() async throws {
        guard let onOff = OnOff(rawValue: state.lowercased()) else {
            throw CLIErrorJSON("bad_args", detail: "state must be on|off")
        }
        do {
            try await toggleSidecarAndRestart(SidecarAddons.mailpit, enabled: onOff.enabled, slug: slug,
                                              output: output, ctx: CLIContext())
        } catch { throw failCommand(error, json: output.json) }
    }
}

// MARK: - redis

struct RedisCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "redis",
        abstract: "Enable or disable the Redis object cache for a site: redis on|off <slug>.",
        discussion: """
        On enable, (for a running site) restarts to launch a Redis container and \
        defines WP_REDIS_HOST and WP_REDIS_PORT for object-cache drop-ins. Install \
        and enable a drop-in plugin such as Redis Object Cache in the site to use \
        it. The cache is empty after every restart.
        """
    )
    @Argument(help: "on | off") var state: String
    @Argument(help: "Site slug.") var slug: String
    @OptionGroup var output: JSONOptions

    func run() async throws {
        guard let onOff = OnOff(rawValue: state.lowercased()) else {
            throw CLIErrorJSON("bad_args", detail: "state must be on|off")
        }
        do {
            try await toggleSidecarAndRestart(SidecarAddons.redis, enabled: onOff.enabled, slug: slug,
                                              output: output, ctx: CLIContext())
        } catch { throw failCommand(error, json: output.json) }
    }
}

// MARK: - limits (issue #11)

struct LimitsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "limits",
        abstract: "Show or set a site's per-container CPU/memory caps: limits <slug> [--cpus N] [--memory MB].",
        discussion: """
        Caps are passed to `container run` for the db/WordPress/Elasticsearch/Mailpit \
        containers and take effect on the next start (restart a running site to \
        apply). Pass 0 to reset a cap to the container default (4 CPUs / 1024 MB). \
        Worktree environments inherit the parent's caps at creation.
        """
    )
    @Argument(help: "Site slug.") var slug: String
    @Option(name: .long, help: "CPU cap (1–8), or 0 to reset to the default (4).") var cpus: Int?
    @Option(name: .long, help: "Memory cap in MB (e.g. 512), or 0 to reset to the default (1024).") var memory: Int?
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let envelope = try await ctx.load()
            guard let site = envelope.sites.first(where: { $0.slug == slug }) else {
                throw CLIErrorJSON("site_not_found", detail: slug)
            }
            // No options → report the current caps.
            if cpus == nil && memory == nil {
                if output.json {
                    emitLine(MCPJSON.string(["slug": slug,
                                             "cpus": site.cpuLimit as Any? ?? NSNull(),
                                             "memoryMB": site.memoryLimitMB as Any? ?? NSNull()]))
                } else {
                    emitLine("\(slug): CPU \(site.cpuLimit.map(String.init) ?? "default (4)"), memory \(site.memoryLimitMB.map { "\($0) MB" } ?? "default (1024 MB)").")
                }
                return
            }
            let newCPU = cpus
            let newMem = memory
            let updated = try await ctx.persistence.mutate { env in
                if let i = env.sites.firstIndex(where: { $0.id == site.id }) {
                    if let c = newCPU { env.sites[i].cpuLimit = c == 0 ? nil : c }
                    if let m = newMem { env.sites[i].memoryLimitMB = m == 0 ? nil : m }
                }
            }
            let s = updated.sites.first { $0.id == site.id } ?? site
            let running = await ctx.runningContainerNames().contains(site.wpContainerName)
            if output.json {
                emitLine(MCPJSON.string(["ok": true, "slug": slug,
                                         "cpus": s.cpuLimit as Any? ?? NSNull(),
                                         "memoryMB": s.memoryLimitMB as Any? ?? NSNull(),
                                         "restartNeeded": running]))
            } else {
                emitLine("\(slug): CPU \(s.cpuLimit.map(String.init) ?? "default (4)"), memory \(s.memoryLimitMB.map { "\($0) MB" } ?? "default (1024 MB)").\(running ? " Restart the site to apply." : "")")
            }
        } catch { throw failCommand(error, json: output.json) }
    }
}

// MARK: - idle (issue #16)

struct IdleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "idle",
        abstract: "Show or set when a site or environment is auto-stopped while idle: idle <slug> [--minutes N | --off | --default].",
        discussion: """
        A stopped container is the only way to give its memory back to macOS \
        (Apple `container` never releases guest memory), and VM boot is ~1s — so \
        an idle instance can be parked and woken again on the next request by \
        whichever process hosts the HTTPS proxy (the app, or \
        `wp-container proxy serve`). Hitting a parked URL in the browser serves a \
        "waking up" page that refreshes into the live site.

        ENVIRONMENTS: on by default, 3 hours (180 minutes). A freshly created \
        environment still on that default is never auto-stopped for its first \
        6 hours regardless of use — pass --minutes or --off to opt out of the \
        grace period too, since an explicit value always wins immediately. An \
        environment's container publishes no port of its own — the \
        proxy serves both its <envSlug>.localhost domain and its \
        http://127.0.0.1:<port> — so every request to either counts as \
        activity, and a parked environment wakes at that same URL. \
        So do wp-cli, MCP tool calls and magic-login links.

        SITES: off by default, opt-in. A site publishes its own \
        http://127.0.0.1:<port>, and requests to that address bypass the proxy: \
        they neither count as activity nor wake it. Its proxied URLs \
        (<slug>.localhost, a custom domain) do both. A parent site is also never \
        auto-stopped while any of its environments are running.

        Accepts a site slug or an env slug.
        """
    )
    @Argument(help: "Site slug or env slug.") var slug: String
    @Option(name: .long, help: "Auto-stop after this many idle minutes.") var minutes: Int?
    @Flag(name: .long, help: "Never auto-stop this instance.") var off = false
    @Flag(name: .long, help: "Follow the built-in default (environments 3 hours, sites off).") var `default` = false
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            // Exactly one intent, or none (which means "report").
            let intents = [minutes != nil, off, `default`].filter { $0 }.count
            guard intents <= 1 else {
                throw CLIErrorJSON("bad_args", detail: "--minutes, --off and --default are mutually exclusive")
            }
            if let minutes, minutes <= 0 {
                throw CLIErrorJSON("bad_args", detail: "--minutes must be greater than 0 (use --off to disable)")
            }
            let envelope = try await ctx.load()
            guard let resolved = resolveTarget(slug, in: envelope) else {
                throw CLIErrorJSON("not_found", detail: slug)
            }
            let isEnv = resolved.instance.envLabel != nil
            // nil = follow the default, 0 = off, N = N minutes. `--default` is
            // spelled as an explicit erase so it can't be confused with "0".
            let newValue: Int?? = {
                if let minutes { return .some(.some(minutes)) }
                if off { return .some(.some(0)) }
                if `default` { return .some(.none) }
                return .none // no intent: report only
            }()

            var configured = resolved.instance.idleStopMinutes
            if let newValue {
                let updated = try await ctx.persistence.mutate { env in
                    switch resolved {
                    case .site(let site):
                        if let i = env.sites.firstIndex(where: { $0.id == site.id }) {
                            env.sites[i].idleStopMinutes = newValue
                        }
                    case .env(let wtEnv):
                        if let i = env.envs.firstIndex(where: { $0.id == wtEnv.id }) {
                            env.envs[i].idleStopMinutes = newValue
                        }
                    }
                }
                switch resolved {
                case .site(let site):
                    configured = updated.sites.first { $0.id == site.id }?.idleStopMinutes
                case .env(let wtEnv):
                    configured = updated.envs.first { $0.id == wtEnv.id }?.idleStopMinutes
                }
            }
            let effective = IdlePolicy.effectiveMinutes(configured: configured, isEnv: isEnv)
            let proxyRunning = ProxyControl.current() != nil
            if output.json {
                emitLine(MCPJSON.string([
                    "ok": true,
                    "slug": slug,
                    "kind": isEnv ? "env" : "site",
                    "idleStopMinutes": configured as Any? ?? NSNull(),
                    "effectiveIdleStopMinutes": effective,
                    "enforced": proxyRunning,
                    "note": IdlePolicy.activityNote(isEnv: isEnv),
                ]))
            } else {
                var line = "\(slug): auto-stop when idle \(IdlePolicy.label(configured: configured, isEnv: isEnv))."
                if effective > 0 && !proxyRunning {
                    line += " The proxy isn’t running, so nothing is enforcing it — start the app or run `wp-container proxy serve`."
                }
                emitLine(line)
                // Print the caveat only when the setting is actually on: it is the
                // difference between "works" and "parks an env you're browsing".
                if effective > 0 { emitLine(IdlePolicy.activityNote(isEnv: isEnv)) }
            }
        } catch { throw failCommand(error, json: output.json) }
    }
}

// MARK: - domain (§2i)

struct DomainCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "domain",
        abstract: "Manage a site's custom domain (updates /etc/hosts — prompts for admin).",
        subcommands: [DomainSet.self, DomainClear.self, DomainSync.self]
    )
}

struct DomainSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set a custom domain for a site (e.g. mysite.local).")
    @Argument(help: "Site slug.") var slug: String
    @Argument(help: "Custom domain, e.g. mysite.local.") var domain: String
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let envelope = try await ctx.load()
            guard let site = envelope.sites.first(where: { $0.slug == slug }) else { throw CLIErrorJSON("site_not_found", detail: slug) }
            guard let normalized = DomainService.normalize(domain) else { throw CLIErrorJSON("invalid_domain", detail: domain) }
            if envelope.sites.contains(where: { $0.id != site.id && $0.customDomain == normalized }) {
                throw CLIErrorJSON("domain_in_use", detail: normalized)
            }
            let updated = try await ctx.persistence.mutate { env in
                if let i = env.sites.firstIndex(where: { $0.id == site.id }) { env.sites[i].customDomain = normalized }
            }
            let newSite = updated.sites.first { $0.id == site.id } ?? site
            let all = HostsFileService.domains(for: updated.sites)
            try await DomainService(cli: ctx.cli).apply(site: newSite, hostsDomains: all)
            if output.json { emitLine(MCPJSON.string(["ok": true, "domain": normalized, "url": newSite.url.absoluteString])) }
            else { emitLine("Set \(slug) domain to \(normalized) → \(newSite.url.absoluteString) (proxy must be running; trust the CA for HTTPS).") }
        } catch { throw failCommand(error, json: output.json) }
    }
}

struct DomainClear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear", abstract: "Remove a site's custom domain (revert to <slug>.localhost / port).")
    @Argument(help: "Site slug.") var slug: String
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let envelope = try await ctx.load()
            guard let site = envelope.sites.first(where: { $0.slug == slug }) else { throw CLIErrorJSON("site_not_found", detail: slug) }
            let updated = try await ctx.persistence.mutate { env in
                if let i = env.sites.firstIndex(where: { $0.id == site.id }) { env.sites[i].customDomain = nil }
            }
            let newSite = updated.sites.first { $0.id == site.id } ?? site
            let all = HostsFileService.domains(for: updated.sites)
            try await DomainService(cli: ctx.cli).apply(site: newSite, hostsDomains: all)
            if output.json { emitLine(MCPJSON.string(["ok": true, "url": newSite.url.absoluteString])) }
            else { emitLine("Cleared \(slug) custom domain → \(newSite.url.absoluteString).") }
        } catch { throw failCommand(error, json: output.json) }
    }
}

struct DomainSync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Rewrite /etc/hosts to every site's custom domain and multisite subsite hosts.",
        discussion: "Reads the subsites of every multisite network whose database is running first, so subsites added in Network Admin are included. Prompts for admin only when /etc/hosts changes."
    )
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            for site in try await ctx.load().sites where site.networkType.isMultisite {
                await NetworkHostsService.refresh(site, cli: ctx.cli, persistence: ctx.persistence)
            }
            let domains = HostsFileService.domains(for: try await ctx.load().sites)
            let changed = !HostsFileService.isUpToDate(domains: domains)
            try await HostsFileService.apply(domains: domains)
            if output.json { emitLine(MCPJSON.string(["ok": true, "changed": changed, "domains": domains])) }
            else if !changed { emitLine("/etc/hosts already lists every site hostname.") }
            else if domains.isEmpty { emitLine("Removed the wp-container block from /etc/hosts.") }
            else { emitLine("Synced /etc/hosts: \(domains.joined(separator: ", ")).") }
        } catch { throw failCommand(error, json: output.json) }
    }
}

// MARK: - resolve-site (§2e follow-up: powers the global `wp` router)

struct ResolveSiteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resolve-site", abstract: "Resolve a filesystem path to the site/env whose wordpress/ tree contains it.")
    @Option(name: .long, help: "Absolute path to resolve (default: cwd).") var path: String?
    @Option(name: .long, help: "Body version of the global `wp` router making this call. Set automatically by the router; a version too old to honor the resolved database name is refused for shared-database environments.")
    var routerVersion: Int?
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        let target = path ?? FileManager.default.currentDirectoryPath
        // The global `wp` router calls this on every invocation, which makes it
        // the one reliable place to heal a router left behind by an older build
        // (issue #17: a v1 router ignores the `dbName` below and would run
        // wp-cli against a shared env's PARENT database). Note the staleness
        // BEFORE healing — the process that just called us is still running the
        // OLD body, which the rewrite can't retroactively fix.
        let staleRouterOnDisk = WPCLIShim.routerNeedsRefresh
        WPCLIShim.refreshRouterIfStale()
        // A caller that announced its version is trusted at its word; one that
        // didn't is presumed stale only when a stale router file was actually
        // sitting there (so a human running `resolve-site` by hand, or anyone
        // with no router installed, is never refused).
        let callerIsStaleRouter: Bool
        if let routerVersion { callerIsStaleRouter = routerVersion < WPCLIShim.routerVersion }
        else { callerIsStaleRouter = staleRouterOnDisk }
        do {
            let envelope = try await ctx.load()
            if let match = SiteResolver.resolve(path: target, in: envelope) {
                // Refuse rather than hand a shared env's paths to a router that
                // will pair them with a hardcoded WORDPRESS_DB_NAME=wordpress —
                // that is one silent write into the PARENT site's database. Sites
                // and isolated envs keep working with an old router.
                if callerIsStaleRouter, match.dbName != SiteRecipe.dbName {
                    let message = "the global `wp` router is out of date and would run wp-cli against "
                        + "\(match.slug)'s PARENT database instead of its own schema. It has just been "
                        + "refreshed — rerun your command (or run `wp-container setup wp`)."
                    // The old router pipes our stderr to /dev/null, so also write
                    // straight to the terminal — the one channel it can't swallow.
                    if let tty = FileHandle(forWritingAtPath: "/dev/tty") {
                        tty.write(Data(("wp: " + message + "\n").utf8))
                        try? tty.close()
                    }
                    throw CLIErrorJSON("stale_router", detail: message)
                }
                if output.json { emitLine(CLIJSON.string(match)) }
                else { emitLine("\(match.kind) \(match.slug) — \(match.wordpressPath)\(match.subpath.isEmpty ? "" : "/\(match.subpath)")") }
            } else {
                if output.json { emitLine(#"{"matched":false}"#) }
                else { emitLine("No WP Container site contains \(target).") }
            }
        } catch { throw failCommand(error, json: output.json) }
    }
}

// MARK: - setup wp (global router install)

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "One-time setup helpers.",
        subcommands: [SetupWP.self]
    )
}

struct SetupWP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "wp", abstract: "Install the global `wp` router so plain `wp` inside a site runs containerized wp-cli.")
    @Flag(name: .long, help: "Remove the router and the PATH block from ~/.zshrc.") var remove = false
    @Flag(name: .long, help: "Only write the router binary (no shell edits); used by `make install-cli`.") var installBinary = false
    @OptionGroup var output: JSONOptions

    func run() async throws {
        do {
            if installBinary {
                let url = try WPCLIShim.writeRouter()
                if output.json { emitLine(MCPJSON.string(["ok": true, "router": url.path])) }
                else { emitLine("Installed global wp router at \(url.path).") }
                return
            }
            if remove {
                try ShellPathService.apply(install: false)
                WPCLIShim.removeRouter()
                if output.json { emitLine(MCPJSON.string(["ok": true, "removed": true])) }
                else { emitLine("Removed the global wp router and the ~/.zshrc PATH block. Open a new terminal.") }
                return
            }
            let router = try WPCLIShim.writeRouter()
            let order = await ShellPathService.wpOnPath()
            let routerActive = order.first.map { $0 == WPCLIShim.routerPath } ?? false
            var edited = false
            if !routerActive {
                try ShellPathService.apply(install: true)
                edited = true
            }
            if output.json {
                emitLine(MCPJSON.string(["ok": true, "router": router.path, "pathEdited": edited, "wpOnPath": order]))
            } else if edited {
                emitLine("Installed global wp router at \(router.path) and prepended it in ~/.zshrc. Open a new terminal, then `wp` inside a site runs containerized wp-cli.")
            } else {
                emitLine("Global wp router installed and already first on PATH.")
            }
        } catch { throw failCommand(error, json: output.json) }
    }
}
