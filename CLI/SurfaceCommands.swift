import ArgumentParser
import Foundation
import WPContainerKit

// MARK: - agent-tools (§2d)

struct AgentToolsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-tools",
        abstract: "Manage per-site AI agent integration files (MCP configs, CLAUDE.md, wp shim).",
        subcommands: [AgentToolsEnable.self, AgentToolsDisable.self]
    )
}

private func loadSite(_ slug: String, _ ctx: CLIContext) async throws -> Site {
    let envelope = try await ctx.load()
    guard let site = envelope.sites.first(where: { $0.slug == slug }) else {
        throw CLIErrorJSON("site_not_found", detail: slug)
    }
    return site
}

/// Relative path of `root` under the site's `wordpress/` (for prefilled worktree
/// commands), or nil when it isn't inside wordpress/.
private func repoRelPath(root: URL, site: Site) -> String? {
    let wp = site.wordpressFolder.resolvingSymlinksInPath().path
    let r = root.resolvingSymlinksInPath().path
    guard r != wp, r.hasPrefix(wp + "/") else { return nil }
    return String(r.dropFirst(wp.count + 1))
}

struct AgentToolsEnable: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Write MCP configs, an AGENTS.md block, .gitignore entries and the wp shim into a chosen root (default: the site folder).")
    @Argument(help: "Site slug.") var slug: String
    @Option(name: .long, help: "Placement root for the generated files (default: site folder). Use your wp-content repo root for IDE discovery.") var root: String?
    @Option(name: .long, help: "Doc filename: AGENTS.md (default) or CLAUDE.md.") var doc: String?
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let site = try await loadSite(slug, ctx)
            let rootURL = root.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? site.path
            let result = try AgentToolsService.enable(site: site, root: rootURL, docName: doc,
                                                      repoRelPath: repoRelPath(root: rootURL, site: site))
            _ = try await ctx.persistence.mutate { env in
                if let i = env.sites.firstIndex(where: { $0.id == site.id }) {
                    env.sites[i].agentToolsRoot = result.root
                    env.sites[i].agentToolsDoc = result.docName
                }
            }
            if output.json { emitLine(MCPJSON.string(["ok": true, "root": result.root, "doc": result.docName, "written": result.written])) }
            else { emitLine("Enabled agent tools for \(slug) at \(result.root): \(result.written.joined(separator: ", ")).") }
        } catch { throw failCommand(error, json: output.json) }
    }
}

struct AgentToolsDisable: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Remove the generated MCP configs and doc block from the recorded root.")
    @Argument(help: "Site slug.") var slug: String
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let site = try await loadSite(slug, ctx)
            let rootURL = site.agentToolsRoot.map { URL(fileURLWithPath: $0) } ?? site.path
            try AgentToolsService.disable(site: site, root: rootURL, docName: site.agentToolsDoc)
            _ = try await ctx.persistence.mutate { env in
                if let i = env.sites.firstIndex(where: { $0.id == site.id }) {
                    env.sites[i].agentToolsRoot = nil
                    env.sites[i].agentToolsDoc = nil
                }
            }
            if output.json { emitLine(CLIJSON.string(CLIErrorJSON("ok", detail: "agent tools disabled for \(slug)"))) }
            else { emitLine("Disabled agent tools for \(slug).") }
        } catch { throw failCommand(error, json: output.json) }
    }
}

// MARK: - shim (§2e)

struct ShimCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "shim", abstract: "Write the per-site `wp` shim for an existing site.")
    @Argument(help: "Site slug.") var slug: String
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let site = try await loadSite(slug, ctx)
            let url = try WPCLIShim.writeShim(for: site, siteRoot: site.path, slug: site.slug)
            if output.json { emitLine(MCPJSON.string(["ok": true, "path": url.path])) }
            else { emitLine("Wrote wp shim to \(url.path).") }
        } catch { throw failCommand(error, json: output.json) }
    }
}

// MARK: - https (§2f)

struct HTTPSCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "https",
        abstract: "Manage trusted HTTPS for a site and the local certificate authority.",
        subcommands: [HTTPSEnable.self, HTTPSDisable.self, HTTPSTrust.self, HTTPSStatus.self]
    )
}

struct HTTPSEnable: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Enable HTTPS for a site (https://<slug>.localhost).")
    @Argument(help: "Site slug.") var slug: String
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let site = try await loadSite(slug, ctx)
            try await HTTPSIntegration(cli: ctx.cli).enable(site)
            _ = try await ctx.persistence.mutate { env in
                if let i = env.sites.firstIndex(where: { $0.id == site.id }) { env.sites[i].httpsEnabled = true }
            }
            if output.json { emitLine(MCPJSON.string(["ok": true, "url": site.secureURL.absoluteString])) }
            else { emitLine("Enabled HTTPS for \(slug): \(site.secureURL.absoluteString) (needs the proxy running + CA trusted).") }
        } catch { throw failCommand(error, json: output.json) }
    }
}

struct HTTPSDisable: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Disable HTTPS for a site (revert to http://127.0.0.1:<port>).")
    @Argument(help: "Site slug.") var slug: String
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let site = try await loadSite(slug, ctx)
            try await HTTPSIntegration(cli: ctx.cli).disable(site)
            _ = try await ctx.persistence.mutate { env in
                if let i = env.sites.firstIndex(where: { $0.id == site.id }) { env.sites[i].httpsEnabled = false }
            }
            // Drop this site's hostname(s) from the trusted leaf's SAN set now
            // that HTTPS is off — otherwise sans.json only ever grows.
            try? await CertificateAuthority().removeLeafCoverage(site.proxyHosts)
            if output.json { emitLine(MCPJSON.string(["ok": true, "url": site.localURL.absoluteString])) }
            else { emitLine("Disabled HTTPS for \(slug).") }
        } catch { throw failCommand(error, json: output.json) }
    }
}

struct HTTPSTrust: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "trust", abstract: "Install the WP Container local CA as a trusted root (prompts for admin).")
    @OptionGroup var output: JSONOptions

    func run() async throws {
        do {
            try await CertificateAuthority().trustCA()
            if output.json { emitLine(CLIJSON.string(CLIErrorJSON("ok", detail: "CA trusted"))) }
            else { emitLine("WP Container CA installed as a trusted root.") }
        } catch { throw failCommand(error, json: output.json) }
    }
}

struct HTTPSStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show CA + proxy status.")
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ca = CertificateAuthority()
        try? await ca.ensureGenerated()
        let generated = await ca.isGenerated
        let trusted = await ca.isCATrusted()
        let proxy = ProxyControl.current()
        // Which env ports the live proxy actually holds (issue #16
        // follow-through). Envs have no published port of their own, so this is
        // the difference between "the environment's URL works" and "it silently
        // doesn't" — and there is nowhere else to see it.
        let envPorts = proxy != nil ? ProxyControl.envPorts() : nil
        var payload: [String: Any] = [
            "caGenerated": generated,
            "caTrusted": trusted,
            "caPath": await ca.caCertURL.path,
            "proxyRunning": proxy != nil,
            "proxyPort": proxy?.port.map { Int($0) } as Any? ?? NSNull(),
        ]
        if let envPorts {
            payload["envPortsServed"] = envPorts.ownedPorts
            payload["envPortsUnavailable"] = envPorts.conflictedPorts
        }
        if output.json { emitLine(MCPJSON.string(payload)) }
        else {
            emitLine("CA generated: \(generated)  trusted: \(trusted)")
            emitLine("Proxy running: \(proxy != nil)\(proxy?.port.map { " on port \($0)" } ?? "")")
            if let envPorts {
                let served = envPorts.ownedPorts.map(String.init).joined(separator: ", ")
                emitLine("Environment ports served: \(served.isEmpty ? "none" : served)")
                if !envPorts.conflictedPorts.isEmpty {
                    let stuck = envPorts.conflictedPorts.map(String.init).joined(separator: ", ")
                    emitLine("Environment ports NOT served: \(stuck) — those URLs and their "
                             + "idle-stop are dead. An environment started by an older build still "
                             + "publishes its own port (stop and start it once); otherwise check "
                             + "`lsof -nP -iTCP:<port> -sTCP:LISTEN`.")
                }
            }
        }
    }
}

// MARK: - proxy (§2f)

struct ProxyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "proxy",
        abstract: "Run the host HTTPS reverse proxy.",
        subcommands: [ProxyServe.self]
    )
}

struct ProxyServe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Start the TLS-terminating reverse proxy (headless; runs until interrupted).",
        discussion: """
        The proxy also enforces auto-stop-when-idle and wakes stopped \
        sites/environments on the next request (issue #16), so running it \
        headlessly gives the same behaviour as running the app — see \
        `wp-container idle`.
        """
    )
    @OptionGroup var output: JSONOptions

    func run() async throws {
        if let existing = ProxyControl.current() {
            let msg = "proxy already running (pid \(existing.pid)\(existing.port.map { ", port \($0)" } ?? ""))"
            if output.json { emitLine(CLIJSON.string(CLIErrorJSON("already_running", detail: msg))) }
            else { emitLine(msg) }
            return
        }
        // Its own lifecycle: there is no IPC between app/CLI/MCP — every process
        // drives `container` directly and coordinates through the flock'd
        // sites.json plus container-runtime ground truth. Without this the
        // headless proxy could route but never idle-stop or wake (issue #16).
        let proxy = HTTPSProxy(lifecycle: SiteLifecycle(cli: ContainerCLI()))
        do {
            let port = try await proxy.start()
            try ProxyControl.claim(port: port)
            // Release the pidfile on termination (#4). Ownership-checked so a
            // racing claimer's record is never deleted by mistake.
            let cleanup: @convention(c) (Int32) -> Void = { _ in ProxyControl.releaseIfOwned(); Darwin.exit(0) }
            signal(SIGINT, cleanup)
            signal(SIGTERM, cleanup)
            if output.json { emitLine(MCPJSON.string(["ok": true, "port": Int(port)])) }
            else { emitLine("HTTPS proxy listening on port \(port). Ctrl-C to stop.") }
            // Stay alive.
            while true { try await Task.sleep(for: .seconds(3600)) }
        } catch {
            // Only tear down a record THIS process wrote — between the
            // stale-check above and a failed claim, another owner may have
            // legitimately claimed the proxy.
            ProxyControl.releaseIfOwned()
            throw failCommand(error, json: output.json)
        }
    }
}
