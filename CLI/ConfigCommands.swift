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

// MARK: - elasticsearch (§2c)

struct ElasticsearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "elasticsearch", abstract: "Enable or disable Elasticsearch for a site: elasticsearch on|off <slug>.")
    @Argument(help: "on | off") var state: String
    @Argument(help: "Site slug.") var slug: String
    @OptionGroup var output: JSONOptions

    func run() async throws {
        guard let onOff = OnOff(rawValue: state.lowercased()) else { throw CLIErrorJSON("bad_args", detail: "state must be on|off") }
        let ctx = CLIContext()
        do {
            try await toggleAndRestart(slug: slug, output: output, ctx: ctx,
                                       label: onOff.enabled ? "Enabled Elasticsearch" : "Disabled Elasticsearch") { $0.elasticsearchEnabled = onOff.enabled }
        } catch { throw failCommand(error, json: output.json) }
    }
}

// MARK: - mailpit (issue #10)

struct MailpitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mailpit",
        abstract: "Enable or disable the Mailpit email catcher for a site: mailpit on|off <slug>.",
        discussion: """
        On enable, writes the wpc-mailpit mu-plugin, reserves a localhost port for \
        the mailbox web UI, and (for a running site) restarts to launch the mail \
        container. Outgoing WordPress mail is then caught by Mailpit instead of \
        being sent. The mailbox is browsable at the printed URL.
        """
    )
    @Argument(help: "on | off") var state: String
    @Argument(help: "Site slug.") var slug: String
    @OptionGroup var output: JSONOptions

    func run() async throws {
        guard let onOff = OnOff(rawValue: state.lowercased()) else {
            throw CLIErrorJSON("bad_args", detail: "state must be on|off")
        }
        let ctx = CLIContext()
        do {
            let envelope = try await ctx.load()
            guard let site = envelope.sites.first(where: { $0.slug == slug }) else {
                throw CLIErrorJSON("site_not_found", detail: slug)
            }
            let updated: Site
            if onOff.enabled {
                try MailpitService.writeMuPlugin(wordpressFolder: site.wordpressFolder)
                if site.mailpitPort == nil {
                    guard let (_, reservedSite, _) = try await ctx.persistence.allocatePort(reserve: { port, env -> Site? in
                        guard let i = env.sites.firstIndex(where: { $0.id == site.id }) else { return nil }
                        env.sites[i].mailpitPort = port
                        env.sites[i].mailpitEnabled = true
                        return env.sites[i]
                    }), let s = reservedSite else { throw CLIErrorJSON("no_free_port") }
                    updated = s
                } else {
                    let env2 = try await ctx.persistence.mutate { e in
                        if let i = e.sites.firstIndex(where: { $0.id == site.id }) { e.sites[i].mailpitEnabled = true }
                    }
                    updated = env2.sites.first { $0.id == site.id } ?? site
                }
            } else {
                try? MailpitService.removeMuPlugin(wordpressFolder: site.wordpressFolder)
                let env2 = try await ctx.persistence.mutate { e in
                    if let i = e.sites.firstIndex(where: { $0.id == site.id }) { e.sites[i].mailpitEnabled = false }
                }
                updated = env2.sites.first { $0.id == site.id } ?? site
            }
            let running = await ctx.runningContainerNames().contains(site.wpContainerName)
            var restarted = false
            if running {
                await ctx.lifecycle.stop(updated)
                _ = try await ctx.lifecycle.startSite(updated)
                await ctx.lifecycle.markRunning(updated.id)
                restarted = true
            }
            let mailbox = updated.mailboxURL?.absoluteString
            if output.json {
                emitLine(MCPJSON.string(["ok": true, "slug": slug, "enabled": onOff.enabled,
                                         "restarted": restarted,
                                         "mailboxUrl": mailbox as Any? ?? NSNull()]))
            } else {
                var line = (onOff.enabled ? "Enabled Mailpit" : "Disabled Mailpit") + " for \(slug)."
                if onOff.enabled, let mailbox { line += " Mailbox: \(mailbox)." }
                line += restarted ? " Restarted to apply." : " Restart the site to apply."
                emitLine(line)
            }
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

// MARK: - domain (§2i)

struct DomainCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "domain",
        abstract: "Manage a site's custom domain (updates /etc/hosts — prompts for admin).",
        subcommands: [DomainSet.self, DomainClear.self]
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
            let all = updated.sites.compactMap(\.customDomain)
            try await DomainService(cli: ctx.cli).apply(site: newSite, allCustomDomains: all)
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
            let all = updated.sites.compactMap(\.customDomain)
            try await DomainService(cli: ctx.cli).apply(site: newSite, allCustomDomains: all)
            if output.json { emitLine(MCPJSON.string(["ok": true, "url": newSite.url.absoluteString])) }
            else { emitLine("Cleared \(slug) custom domain → \(newSite.url.absoluteString).") }
        } catch { throw failCommand(error, json: output.json) }
    }
}

// MARK: - resolve-site (§2e follow-up: powers the global `wp` router)

struct ResolveSiteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resolve-site", abstract: "Resolve a filesystem path to the site/env whose wordpress/ tree contains it.")
    @Option(name: .long, help: "Absolute path to resolve (default: cwd).") var path: String?
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        let target = path ?? FileManager.default.currentDirectoryPath
        do {
            let envelope = try await ctx.load()
            if let match = SiteResolver.resolve(path: target, in: envelope) {
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
