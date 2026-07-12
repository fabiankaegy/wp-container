import Foundation
import MCP
import WPContainerKit

/// Behaviors behind the MCP tools declared in `MCPTools`. Every tool returns
/// structured JSON; failures surface as MCP tool errors (isError) rather than
/// crashing the server.
enum MCPToolDispatch {
    static func handle(_ params: CallTool.Parameters, ctx: CLIContext, scopedSlug: String) async -> CallTool.Result {
        let args = params.arguments ?? [:]
        do {
            switch params.name {
            case "wp_cli":            return try await wpCLI(args, ctx: ctx, slug: scopedSlug)
            case "read_error_log":    return try await readErrorLog(args, ctx: ctx, slug: scopedSlug)
            case "read_access_log":   return try await readAccessLog(args, ctx: ctx, slug: scopedSlug)
            case "wp_debug_toggle":   return try await wpDebugToggle(args, ctx: ctx, slug: scopedSlug)
            case "read_wp_config":    return try await readWPConfig(ctx: ctx, slug: scopedSlug)
            case "edit_wp_config":    return try await editWPConfig(args, ctx: ctx, slug: scopedSlug)
            case "get_site_info":     return try await getSiteInfo(ctx: ctx, slug: scopedSlug)
            case "site_health_check": return try await siteHealthCheck(ctx: ctx, slug: scopedSlug)
            case "site_start":        return try await siteStart(ctx: ctx, slug: scopedSlug)
            case "site_stop":         return try await siteStop(ctx: ctx, slug: scopedSlug)
            case "site_restart":      return try await siteRestart(ctx: ctx, slug: scopedSlug)
            case "site_status":       return try await siteStatus(ctx: ctx, slug: scopedSlug)
            case "list_sites":        return try await listSites(ctx: ctx)
            case "worktree_create":   return try await worktreeCreate(args, ctx: ctx, slug: scopedSlug)
            case "worktree_list":     return try await worktreeList(args, ctx: ctx, slug: scopedSlug)
            case "worktree_delete":   return try await worktreeDelete(args, ctx: ctx)
            default:
                return MCPResult.failure("Unknown tool: \(params.name)")
            }
        } catch {
            return MCPResult.failure(humanError(error))
        }
    }

    // MARK: - Resolution helpers

    private static func resolveSite(_ slug: String, ctx: CLIContext) async throws -> Site {
        let envelope = try await ctx.load()
        guard let site = envelope.sites.first(where: { $0.slug == slug }) else {
            throw ToolError("site_not_found", "No site with slug \(slug).")
        }
        return site
    }

    private static func dbHost(for inst: any RunnableInstance, ctx: CLIContext) async throws -> String {
        guard let ip = try await ctx.cli.ipAddress(of: inst.dbContainerName), !ip.isEmpty else {
            throw ToolError("not_running", "Site is not running — start it first.")
        }
        return ip
    }

    // MARK: - wp_cli

    private static func wpArgs(from args: [String: Value]) -> [String] {
        if let arr = args["args"]?.arrayValue {
            return arr.compactMap { $0.stringValue }
        }
        if let cmd = args["command"]?.stringValue {
            return cmd.split(whereSeparator: { $0 == " " }).map(String.init)
        }
        return []
    }

    private static func wpCLI(_ args: [String: Value], ctx: CLIContext, slug: String) async throws -> CallTool.Result {
        let site = try await resolveSite(slug, ctx: ctx)
        let host = try await dbHost(for: site, ctx: ctx)
        let wp = wpArgs(from: args)
        guard !wp.isEmpty else { throw ToolError("bad_args", "Provide `args` (array) or `command` (string).") }
        let result = try await ctx.cli.runCapturing(SiteRecipe.wpProxyArgs(site, dbHost: host, wpArgs: wp))
        return MCPResult.json([
            "stdout": result.stdout,
            "stderr": result.stderr,
            "exitCode": Int(result.exitCode),
        ], isError: result.exitCode != 0)
    }

    // MARK: - Logs

    private static func containerLogTail(_ name: String, lines: Int, ctx: CLIContext) async -> String {
        guard let result = try? await ctx.cli.runCapturing(SiteRecipe.logsArgs(name)) else { return "" }
        let combined = result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr)
        return tail(combined, lines: lines)
    }

    private static func readErrorLog(_ args: [String: Value], ctx: CLIContext, slug: String) async throws -> CallTool.Result {
        let site = try await resolveSite(slug, ctx: ctx)
        let lines = args["lines"]?.intValue ?? 100
        let containerLog = await containerLogTail(site.wpContainerName, lines: lines, ctx: ctx)
        var payload: [String: Any] = ["containerLog": containerLog]
        let debugLog = site.wordpressFolder.appendingPathComponent("wp-content/debug.log")
        if let text = try? String(contentsOf: debugLog, encoding: .utf8) {
            payload["debugLog"] = tail(text, lines: lines)
        } else {
            payload["debugLog"] = NSNull()
        }
        return MCPResult.json(payload)
    }

    private static func readAccessLog(_ args: [String: Value], ctx: CLIContext, slug: String) async throws -> CallTool.Result {
        let site = try await resolveSite(slug, ctx: ctx)
        let lines = args["lines"]?.intValue ?? 100
        let log = await containerLogTail(site.wpContainerName, lines: lines, ctx: ctx)
        return MCPResult.json(["accessLog": log])
    }

    // MARK: - wp_debug_toggle

    private static func wpDebugToggle(_ args: [String: Value], ctx: CLIContext, slug: String) async throws -> CallTool.Result {
        let site = try await resolveSite(slug, ctx: ctx)
        let host = try await dbHost(for: site, ctx: ctx)
        let enabled = args["enabled"]?.boolValue ?? true
        let wpDebug = args["wpDebug"]?.boolValue ?? enabled
        let wpDebugLog = args["wpDebugLog"]?.boolValue ?? enabled
        let scriptDebug = args["scriptDebug"]?.boolValue ?? enabled

        func setConst(_ name: String, _ value: Bool) async throws {
            _ = try await ctx.cli.runCapturing(SiteRecipe.wpProxyArgs(
                site, dbHost: host, wpArgs: ["config", "set", name, value ? "true" : "false", "--raw", "--type=constant"]))
        }
        try await setConst("WP_DEBUG", wpDebug)
        try await setConst("WP_DEBUG_LOG", wpDebugLog)
        try await setConst("SCRIPT_DEBUG", scriptDebug)
        return MCPResult.json([
            "WP_DEBUG": wpDebug, "WP_DEBUG_LOG": wpDebugLog, "SCRIPT_DEBUG": scriptDebug,
        ])
    }

    // MARK: - wp-config

    private static func readWPConfig(ctx: CLIContext, slug: String) async throws -> CallTool.Result {
        let site = try await resolveSite(slug, ctx: ctx)
        let parsed = try WPConfigService.read(wordpressFolder: site.wordpressFolder)
        return MCPResult.json([
            "path": parsed.path,
            "constants": parsed.constants,
            "tablePrefix": parsed.tablePrefix ?? NSNull(),
        ])
    }

    private static func editWPConfig(_ args: [String: Value], ctx: CLIContext, slug: String) async throws -> CallTool.Result {
        let site = try await resolveSite(slug, ctx: ctx)
        guard let name = args["name"]?.stringValue, let value = args["value"]?.stringValue else {
            throw ToolError("bad_args", "`name` and `value` are required.")
        }
        let raw = args["raw"]?.boolValue ?? false
        let backup = try WPConfigService.setConstant(name, value: value, rawValue: raw, wordpressFolder: site.wordpressFolder)
        return MCPResult.json(["ok": true, "constant": name, "backup": backup])
    }

    // MARK: - Info / health

    private static func getSiteInfo(ctx: CLIContext, slug: String) async throws -> CallTool.Result {
        let site = try await resolveSite(slug, ctx: ctx)
        let running = await ctx.runningContainerNames()
        let isUp = running.contains(site.wpContainerName)
        var payload: [String: Any] = [
            "slug": site.slug,
            "name": site.name,
            "status": isUp ? "running" : "stopped",
            "url": site.url.absoluteString,
            "localUrl": site.localURL.absoluteString,
            "httpsEnabled": site.httpsEnabled,
            "port": site.port,
            "path": site.path.path,
            "wordpressPath": site.wordpressFolder.path,
            "databasePath": site.databaseFolder.path,
            "image": site.imageTag,
            "provisioned": site.provisioned,
            "db": ["name": SiteRecipe.dbName, "user": SiteRecipe.dbUser, "password": SiteRecipe.dbPassword],
            "admin": ["user": SiteRecipe.adminUser, "password": SiteRecipe.adminPassword],
        ]
        if isUp, let host = try? await dbHost(for: site, ctx: ctx) {
            let plugins = try? await ctx.cli.runCapturing(SiteRecipe.wpProxyArgs(site, dbHost: host, wpArgs: ["plugin", "list", "--status=active", "--field=name"]))
            let theme = try? await ctx.cli.runCapturing(SiteRecipe.wpProxyArgs(site, dbHost: host, wpArgs: ["theme", "list", "--status=active", "--field=name"]))
            payload["activePlugins"] = (plugins?.stdout ?? "").split(separator: "\n").map(String.init)
            payload["activeTheme"] = (theme?.stdout ?? "").split(separator: "\n").map(String.init).first ?? NSNull()
        }
        return MCPResult.json(payload)
    }

    private static func siteHealthCheck(ctx: CLIContext, slug: String) async throws -> CallTool.Result {
        let site = try await resolveSite(slug, ctx: ctx)
        let running = await ctx.runningContainerNames()
        let wpUp = running.contains(site.wpContainerName)
        let dbUp = running.contains(site.dbContainerName)

        var dbHealthy = false
        if dbUp {
            let hc = try? await ctx.cli.runCapturing(SiteRecipe.databaseHealthcheckArgs(site))
            dbHealthy = (hc?.exitCode == 0)
        }
        let httpStatus = await httpProbe(site.localURL)
        let wpDebug = (try? WPConfigService.read(wordpressFolder: site.wordpressFolder).constants["WP_DEBUG"]) ?? nil

        return MCPResult.json([
            "wpContainer": wpUp ? "running" : "stopped",
            "dbContainer": dbUp ? "running" : "stopped",
            "dbHealthy": dbHealthy,
            "httpStatus": httpStatus.map { $0 as Any } ?? NSNull(),
            "wpDebug": wpDebug ?? "unset",
            "folderSizes": [
                "wordpress": folderSize(site.wordpressFolder),
                "database": folderSize(site.databaseFolder),
            ],
        ])
    }

    // MARK: - Lifecycle

    private static func siteStart(ctx: CLIContext, slug: String) async throws -> CallTool.Result {
        let site = try await resolveSite(slug, ctx: ctx)
        let provisioned = try await ctx.lifecycle.startSite(site)
        if provisioned != site.provisioned {
            _ = try await ctx.persistence.mutate { env in
                if let i = env.sites.firstIndex(where: { $0.id == site.id }) { env.sites[i].provisioned = provisioned }
            }
        }
        return try await siteStatus(ctx: ctx, slug: slug)
    }

    private static func siteStop(ctx: CLIContext, slug: String) async throws -> CallTool.Result {
        let site = try await resolveSite(slug, ctx: ctx)
        await ctx.lifecycle.stop(site)
        return MCPResult.json(["slug": slug, "status": "stopped"])
    }

    private static func siteRestart(ctx: CLIContext, slug: String) async throws -> CallTool.Result {
        let site = try await resolveSite(slug, ctx: ctx)
        await ctx.lifecycle.stop(site)
        _ = try await ctx.lifecycle.startSite(site)
        return try await siteStatus(ctx: ctx, slug: slug)
    }

    private static func siteStatus(ctx: CLIContext, slug: String) async throws -> CallTool.Result {
        let site = try await resolveSite(slug, ctx: ctx)
        let running = await ctx.runningContainerNames()
        let isUp = running.contains(site.wpContainerName)
        return MCPResult.json([
            "slug": site.slug,
            "status": isUp ? "running" : "stopped",
            "url": site.url.absoluteString,
            "port": site.port,
        ])
    }

    private static func listSites(ctx: CLIContext) async throws -> CallTool.Result {
        var envelope = try await ctx.load()
        let running = await ctx.runningContainerNames()
        let sites = envelope.sites.map { s -> [String: Any] in
            ["slug": s.slug, "name": s.name,
             "status": running.contains(s.wpContainerName) ? "running" : "stopped",
             "url": s.url.absoluteString, "port": s.port, "path": s.path.path]
        }
        let envs = envelope.envs.map { e -> [String: Any] in
            ["envSlug": e.envSlug, "parentSlug": e.parentSlug, "branch": e.branch,
             "status": running.contains(e.wpContainerName) ? "running" : "stopped",
             "url": e.localURL.absoluteString, "port": e.port]
        }
        return MCPResult.json(["sites": sites, "envs": envs])
    }

    // MARK: - Worktrees

    private static func worktreeCreate(_ args: [String: Value], ctx: CLIContext, slug: String) async throws -> CallTool.Result {
        guard let repo = args["repo"]?.stringValue, let branch = args["branch"]?.stringValue else {
            throw ToolError("bad_args", "`repo` and `branch` are required.")
        }
        let parentSlug = args["site"]?.stringValue ?? slug
        let from = args["from"]?.stringValue
        let envelope = try await ctx.load()
        guard let parent = envelope.sites.first(where: { $0.slug == parentSlug }) else {
            throw ToolError("site_not_found", "No site with slug \(parentSlug).")
        }
        let taken = Set(envelope.sites.map(\.port)).union(envelope.envs.map(\.port))
        guard let port = PortAllocator.firstFreePort(excluding: taken) else {
            throw ToolError("no_free_port", "No free port available.")
        }
        let running = await ctx.runningContainerNames()
        let env = try await ctx.worktrees.create(parent: parent, parentIsRunning: running.contains(parent.wpContainerName),
                                                 repoRelPath: repo, branch: branch, from: from, port: port)
        _ = try await ctx.persistence.mutate { $0.envs.append(env) }
        let d = WorktreeDescriptor(from: env)
        return MCPResult.json([
            "url": d.url, "port": d.port, "path": d.path, "worktreePath": d.worktreePath,
            "branch": d.branch, "envSlug": d.envSlug, "containers": d.containers,
        ])
    }

    private static func worktreeList(_ args: [String: Value], ctx: CLIContext, slug: String) async throws -> CallTool.Result {
        let envelope = try await ctx.load()
        let running = await ctx.runningContainerNames()
        let filter = args["site"]?.stringValue ?? slug
        let envs = envelope.envs.filter { filter == "*" || $0.parentSlug == filter }.map { e -> [String: Any] in
            ["envSlug": e.envSlug, "parentSlug": e.parentSlug, "branch": e.branch, "repoRelPath": e.repoRelPath,
             "status": running.contains(e.wpContainerName) ? "running" : "stopped",
             "url": e.localURL.absoluteString, "port": e.port, "worktreePath": e.worktreePath.path]
        }
        return MCPResult.json(["envs": envs])
    }

    private static func worktreeDelete(_ args: [String: Value], ctx: CLIContext) async throws -> CallTool.Result {
        guard let envSlug = args["envSlug"]?.stringValue else { throw ToolError("bad_args", "`envSlug` is required.") }
        let envelope = try await ctx.load()
        guard let env = envelope.envs.first(where: { $0.envSlug == envSlug }) else {
            throw ToolError("env_not_found", "No environment with slug \(envSlug).")
        }
        let keepBranch = args["keepBranch"]?.boolValue ?? true
        let keepWorktree = args["keepWorktree"]?.boolValue ?? false
        let parent = envelope.sites.first { $0.id == env.parentSiteID }
        await ctx.worktrees.delete(env, parent: parent, keepBranch: keepBranch, keepWorktree: keepWorktree)
        _ = try await ctx.persistence.mutate { store in store.envs.removeAll { $0.id == env.id } }
        return MCPResult.json(["ok": true, "envSlug": envSlug])
    }

    // MARK: - Small utilities

    private static func tail(_ text: String, lines: Int) -> String {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard all.count > lines else { return text }
        return all.suffix(lines).joined(separator: "\n")
    }

    private static func httpProbe(_ url: URL) async -> Int? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 4
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return http.statusCode
    }

    private static func folderSize(_ url: URL) -> String {
        guard let result = try? runSync("/usr/bin/du", ["-sh", url.path]) else { return "n/a" }
        return result.split(separator: "\t").first.map(String.init) ?? "n/a"
    }

    /// Synchronous helper for quick shell reads (du). Blocks briefly; only used
    /// off the MCP dispatch path where a short block is acceptable.
    private static func runSync(_ exe: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func humanError(_ error: Error) -> String {
        if let e = error as? ToolError { return MCPJSON.string(["error": e.code, "detail": e.detail]) }
        if let e = error as? ContainerCLIError { return MCPJSON.string(["error": "container_error", "detail": e.description]) }
        if let e = error as? WPConfigService.ConfigError { return MCPJSON.string(["error": "wp_config_error", "detail": e.description]) }
        return MCPJSON.string(["error": "internal", "detail": "\(error)"])
    }
}

/// Structured tool-level error carried to the MCP client as an isError result.
struct ToolError: Error {
    let code: String
    let detail: String
    init(_ code: String, _ detail: String) { self.code = code; self.detail = detail }
}
