import Foundation
import MCP
import WPContainerKit

/// Behaviors behind the MCP tools declared in `MCPTools`. Every tool returns
/// structured JSON; failures surface as MCP tool errors (isError) rather than
/// crashing the server.
enum MCPToolDispatch {
    static func handle(_ params: CallTool.Parameters, ctx: CLIContext, scopedSlug: String) async -> CallTool.Result {
        let args = params.arguments ?? [:]
        // Any scoped tool call is an agent deliberately working on this instance,
        // and none of it goes through the proxy — so stamp `lastActivityAt` before
        // dispatching (throttled to at most one store write a minute, issue #16).
        // Without this an agent driving an environment entirely over MCP would
        // look completely idle and get parked mid-task.
        await stampActivity(ctx: ctx, slug: scopedSlug)
        do {
            switch params.name {
            case "wp_cli":            return try await wpCLI(args, ctx: ctx, slug: scopedSlug)
            case "read_error_log":    return try await readErrorLog(args, ctx: ctx, slug: scopedSlug)
            case "read_access_log":   return try await readAccessLog(args, ctx: ctx, slug: scopedSlug)
            case "wp_debug_toggle":   return try await wpDebugToggle(args, ctx: ctx, slug: scopedSlug)
            case "read_wp_config":    return try await readWPConfig(ctx: ctx, slug: scopedSlug)
            case "edit_wp_config":    return try await editWPConfig(args, ctx: ctx, slug: scopedSlug)
            case "get_site_info":     return try await getSiteInfo(ctx: ctx, slug: scopedSlug)
            case "login_link":        return try await loginLink(args, ctx: ctx, slug: scopedSlug)
            case "create_user":       return try await createUser(args, ctx: ctx, slug: scopedSlug)
            case "site_health_check": return try await siteHealthCheck(ctx: ctx, slug: scopedSlug)
            case "site_start":        return try await siteStart(args, ctx: ctx, slug: scopedSlug)
            case "site_stop":         return try await siteStop(ctx: ctx, slug: scopedSlug)
            case "site_restart":      return try await siteRestart(ctx: ctx, slug: scopedSlug)
            case "site_status":       return try await siteStatus(ctx: ctx, slug: scopedSlug)
            case "list_sites":        return try await listSites(ctx: ctx)
            case "worktree_create":   return try await worktreeCreate(args, ctx: ctx, slug: scopedSlug)
            case "worktree_list":     return try await worktreeList(args, ctx: ctx, slug: scopedSlug)
            case "worktree_delete":   return try await worktreeDelete(args, ctx: ctx)
            case "xdebug_toggle":     return try await addonToggle(args, ctx: ctx, slug: scopedSlug, kind: .xdebug)
            case "elasticsearch_toggle": return try await addonToggle(args, ctx: ctx, slug: scopedSlug, kind: .elasticsearch)
            case "mailpit_toggle":    return try await mailpitToggle(args, ctx: ctx, slug: scopedSlug)
            case "db_import":         return try await dbImport(args, ctx: ctx, slug: scopedSlug)
            case "set_idle_stop":     return try await setIdleStop(args, ctx: ctx, slug: scopedSlug)
            default:
                return MCPResult.failure("Unknown tool: \(params.name)")
            }
        } catch {
            return MCPResult.failure(humanError(error))
        }
    }

    // MARK: - Activity tracking (issue #16)

    /// Record the scoped slug's `lastActivityAt`. Best-effort and silent: an
    /// unresolvable slug or a store error must never turn into a tool failure.
    /// Accepts a site OR an env slug, since agents work in both.
    private static func stampActivity(ctx: CLIContext, slug: String) async {
        guard let envelope = try? await ctx.load() else { return }
        guard let resolved = resolveTarget(slug, in: envelope) else { return }
        await ctx.persistence.recordActivity(instanceID: resolved.instance.instanceID)
    }

    // MARK: - Idle stop (issue #16)

    /// Set (or clear) the auto-stop-when-idle timeout for a site or env.
    ///
    /// Exists so an agent that just created an environment can opt it in without
    /// shelling out to `wp-container idle` — the whole point of the feature is
    /// reclaiming memory from fleets of agent-created envs, and the agent is the
    /// one who knows whether its env is finished with.
    ///
    /// `minutes` omitted ⇒ back to the built-in default; `0` ⇒ never.
    private static func setIdleStop(_ args: [String: Value], ctx: CLIContext, slug: String) async throws -> CallTool.Result {
        let target = args["slug"]?.stringValue ?? slug
        let envelope = try await ctx.load()
        guard let resolved = resolveTarget(target, in: envelope) else {
            throw ToolError("not_found", "No site or environment with slug \(target).")
        }
        let isEnv = resolved.instance.envLabel != nil
        // Absent `minutes` is a deliberate "back to default", which is why this
        // reads the key's presence rather than defaulting the value.
        var configured: Int?
        if let raw = args["minutes"] {
            guard let value = raw.intValue else {
                throw ToolError("bad_args", "minutes must be an integer (omit it for the default, 0 for never).")
            }
            configured = value > 0 ? value : 0
        }
        let newValue = configured
        _ = try await ctx.persistence.mutate { store in
            switch resolved {
            case .site(let site):
                if let i = store.sites.firstIndex(where: { $0.id == site.id }) {
                    store.sites[i].idleStopMinutes = newValue
                }
            case .env(let env):
                if let i = store.envs.firstIndex(where: { $0.id == env.id }) {
                    store.envs[i].idleStopMinutes = newValue
                }
            }
        }
        let effective = IdlePolicy.effectiveMinutes(configured: newValue, isEnv: isEnv)
        return MCPResult.json([
            "slug": target,
            "kind": isEnv ? "env" : "site",
            "idleStopMinutes": newValue as Any? ?? NSNull(),
            "effectiveIdleStopMinutes": effective,
            "enforced": ProxyControl.current() != nil,
            "note": IdlePolicy.activityNote(isEnv: isEnv),
        ])
    }

    // MARK: - Resolution helpers

    private static func resolveSite(_ slug: String, ctx: CLIContext) async throws -> Site {
        let envelope = try await ctx.load()
        guard let site = envelope.sites.first(where: { $0.slug == slug }) else {
            throw ToolError("site_not_found", "No site with slug \(slug).")
        }
        return site
    }

    /// Resolve `inst`'s db-container IP, waking it first if its wp container
    /// isn't running. Before this, only HTTP through the proxy woke an idle-
    /// stopped instance — `wp_cli`/`login_link`/`create_user` talk to the
    /// container directly and used to hard-fail with "not running" instead.
    /// Reuses `SiteLifecycle.startSite`/`startInstance` — never reimplements
    /// start. Prints a one-line notice to stderr (stdout is reserved for the
    /// MCP JSON-RPC stream) when it actually starts something.
    private static func dbHost(for inst: any RunnableInstance, ctx: CLIContext) async throws -> String {
        if await !ctx.lifecycle.isWPContainerRunning(inst) {
            FileHandle.standardError.write(Data("\(inst.siteSlug) was stopped — starting it first…\n".utf8))
            if let site = inst as? Site {
                let provisioned = try await ctx.lifecycle.startSite(site)
                if provisioned != site.provisioned {
                    _ = try await ctx.persistence.mutate { env in
                        if let i = env.sites.firstIndex(where: { $0.id == site.id }) { env.sites[i].provisioned = provisioned }
                    }
                }
            } else {
                _ = try await ctx.lifecycle.startInstance(inst)
            }
        }
        guard let ip = try await ctx.cli.ipAddress(of: inst.dbContainerName), !ip.isEmpty else {
            throw ToolError("not_running", "Site could not be started.")
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
        // Inject the Mailpit host so wp_mail from wp-cli is caught too (issue #10).
        var mailHost: String? = nil
        if site.mailpitEnabled { mailHost = (try? await ctx.cli.ipAddress(of: site.mailContainerName)) ?? nil }
        // Point ElasticPress at the sidecar so `wp elasticpress …` works.
        var esURL: String? = nil
        if site.elasticsearchEnabled, let esIP = (try? await ctx.cli.ipAddress(of: site.esContainerName)) ?? nil {
            esURL = SiteRecipe.elasticsearchURL(esHost: esIP)
        }
        let result = try await ctx.cli.runCapturing(SiteRecipe.wpProxyArgs(site, dbHost: host, wpArgs: wp,
                                                                           mailpitHost: mailHost, elasticsearchURL: esURL))
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
        let enabled = args["enabled"]?.boolValue ?? true
        let wpDebug = args["wpDebug"]?.boolValue ?? enabled
        let wpDebugLog = args["wpDebugLog"]?.boolValue ?? enabled
        let scriptDebug = args["scriptDebug"]?.boolValue ?? enabled
        // Single file-based write path (WPConfigService) — works whether or not
        // the site is running; constants take effect per-request, no restart.
        let folder = site.wordpressFolder
        try WPConfigService.setBoolConstant("WP_DEBUG", wpDebug, wordpressFolder: folder)
        try WPConfigService.setBoolConstant("WP_DEBUG_LOG", wpDebugLog, wordpressFolder: folder)
        try WPConfigService.setBoolConstant("SCRIPT_DEBUG", scriptDebug, wordpressFolder: folder)
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
            "mailpitEnabled": site.mailpitEnabled,
            "mailboxUrl": site.mailboxURL?.absoluteString as Any? ?? NSNull(),
            // Auto-stop-when-idle (issue #16). `idleStopMinutes` is the persisted
            // setting (null = follow the default), `effectiveIdleStopMinutes` the
            // timeout actually in force with the default resolved — 0 means the
            // site is never auto-stopped. Sites default to off; envs to 180 min.
            "idleStopMinutes": site.idleStopMinutes as Any? ?? NSNull(),
            "effectiveIdleStopMinutes": site.effectiveIdleStopMinutes,
            // Read off the instance rather than the `SiteRecipe` constants (#17).
            // `resolveSite` only ever returns a SITE, which always owns its
            // `wordpress` schema — going through the instance just means this
            // can't drift if envs ever become addressable here. Worktree envs
            // report their own schema via `worktree_create`/`worktree_list`.
            "db": ["name": site.databaseName, "container": site.dbContainerName,
                   "user": SiteRecipe.dbUser, "password": SiteRecipe.dbPassword],
            "admin": ["user": SiteRecipe.adminUser, "password": SiteRecipe.adminPassword],
            "loginHint": "Use the login_link tool for a one-time browser login URL instead of the wp-login form.",
        ]
        if isUp, let host = try? await dbHost(for: site, ctx: ctx) {
            let plugins = try? await ctx.cli.runCapturing(SiteRecipe.wpProxyArgs(site, dbHost: host, wpArgs: ["plugin", "list", "--status=active", "--field=name"]))
            let theme = try? await ctx.cli.runCapturing(SiteRecipe.wpProxyArgs(site, dbHost: host, wpArgs: ["theme", "list", "--status=active", "--field=name"]))
            payload["activePlugins"] = (plugins?.stdout ?? "").split(separator: "\n").map(String.init)
            payload["activeTheme"] = (theme?.stdout ?? "").split(separator: "\n").map(String.init).first ?? NSNull()
        }
        return MCPResult.json(payload)
    }

    // MARK: - Login / users (issue #13)

    private static func loginLink(_ args: [String: Value], ctx: CLIContext, slug: String) async throws -> CallTool.Result {
        let site = try await resolveSite(slug, ctx: ctx)
        let host = try await dbHost(for: site, ctx: ctx)
        let user = args["user"]?.stringValue ?? SiteRecipe.adminUser
        var mailHost: String? = nil
        if site.mailpitEnabled { mailHost = (try? await ctx.cli.ipAddress(of: site.mailContainerName)) ?? nil }
        // The site is running (dbHost resolved). If the handler wasn't already
        // active this container predates it and must be restarted.
        let alreadyActive = MagicLoginService.isLoginActive(for: site)
        try PrependService.ensure(for: site)
        try MagicLoginService.ensureLoginHandler(for: site)
        do {
            let link = try await MagicLoginService.issueLoginLink(for: site, publicURL: site.url, dbHost: host,
                                                                 cli: ctx.cli, user: user, mailpitHost: mailHost)
            let iso = ISO8601DateFormatter().string(from: link.expiresAt)
            var payload: [String: Any] = [
                "url": link.url.absoluteString,
                "user": link.user,
                "expiresAt": iso,
                "note": "One-time link, expires in 15 minutes. Open in a browser to get a logged-in wp-admin session.",
            ]
            if !alreadyActive {
                payload["warning"] = "This site was started before magic-login support; restart it (site_restart) for the link to work."
            }
            return MCPResult.json(payload)
        } catch let e as MagicLoginError {
            throw ToolError("user_not_found", e.description)
        }
    }

    private static func createUser(_ args: [String: Value], ctx: CLIContext, slug: String) async throws -> CallTool.Result {
        guard let user = args["user"]?.stringValue, let email = args["email"]?.stringValue else {
            throw ToolError("bad_args", "`user` and `email` are required.")
        }
        let role = args["role"]?.stringValue ?? "administrator"
        let password = args["password"]?.stringValue ?? randomPassword()
        let site = try await resolveSite(slug, ctx: ctx)
        let host = try await dbHost(for: site, ctx: ctx)
        // Detect an existing login up front for a clear, actionable error.
        let existing = try await ctx.cli.runCapturing(SiteRecipe.wpProxyArgs(site, dbHost: host, wpArgs: ["user", "get", user, "--field=user_login"]))
        if existing.exitCode == 0 {
            throw ToolError("user_exists", "A user '\(user)' already exists. Use login_link to log in as them, or pick another login.")
        }
        let result = try await ctx.cli.runCapturing(SiteRecipe.wpProxyArgs(site, dbHost: host, wpArgs: [
            "user", "create", user, email, "--role=\(role)", "--user_pass=\(password)",
        ]))
        guard result.exitCode == 0 else {
            throw ToolError("create_failed", result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return MCPResult.json([
            "user": user,
            "email": email,
            "role": role,
            "password": password,
        ])
    }

    /// 20-char URL-safe random password for `create_user` when none is supplied.
    private static func randomPassword() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<20).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
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

    /// Coupled lifecycle (§2b): starting a site also starts its worktree envs
    /// (parent first, then envs; env failures reported but non-fatal).
    private static func siteStart(_ args: [String: Value], ctx: CLIContext, slug: String) async throws -> CallTool.Result {
        let site = try await resolveSite(slug, ctx: ctx)
        // Env fan-out is opt-in (issue #18) — defaults to starting only the site.
        let withEnvs = args["with_envs"]?.boolValue ?? false
        let envs = withEnvs ? try await ctx.load().envs.filter { $0.parentSiteID == site.id } : []
        let noPull = args["no_pull"]?.boolValue ?? false
        let refreshImages = args["refresh_images"]?.boolValue ?? false
        guard !(noPull && refreshImages) else {
            throw ToolError("bad_args", "no_pull and refresh_images are mutually exclusive")
        }
        let policy: PullPolicy = noPull ? .never : (refreshImages ? .refresh : .ifMissing)
        let outcome = await ctx.lifecycle.startSiteWithEnvs(site, envs: envs, pullPolicy: policy)
        if outcome.provisioned != site.provisioned {
            _ = try await ctx.persistence.mutate { env in
                if let i = env.sites.firstIndex(where: { $0.id == site.id }) { env.sites[i].provisioned = outcome.provisioned }
            }
        }
        if let parentError = outcome.parentErrorMessage {
            throw ToolError("start_failed", parentError)
        }
        // Envs in the fan-out are served by the proxy, not by a published port
        // (issue #16 follow-through), so an absent proxy is worth saying out loud.
        var warnings = outcome.warnings
        // Per-env: one port may be served while another collides with a
        // pre-upgrade container still publishing it.
        warnings.append(contentsOf: Set(envs.compactMap { ProxyControl.envProxyWarning(port: $0.port) }))
        if !outcome.envErrorMessages.isEmpty || !warnings.isEmpty {
            var payload: [String: Any] = ["slug": site.slug, "status": "running"]
            if !outcome.envErrorMessages.isEmpty { payload["envWarnings"] = outcome.envErrorMessages }
            if !warnings.isEmpty { payload["warnings"] = warnings }
            return MCPResult.json(payload)
        }
        return try await siteStatus(ctx: ctx, slug: slug)
    }

    /// Coupled lifecycle (§2b): stopping a site also stops its worktree envs.
    private static func siteStop(ctx: CLIContext, slug: String) async throws -> CallTool.Result {
        let site = try await resolveSite(slug, ctx: ctx)
        let envs = try await ctx.load().envs.filter { $0.parentSiteID == site.id }
        await ctx.lifecycle.stopSiteWithEnvs(site, envs: envs)
        // Teardown problems recorded by the stop path (issue #16) — a container
        // that outlived both `stop` and `delete` is still holding VM memory.
        var warnings: [String] = []
        for id in [site.id] + envs.map(\.id) {
            warnings.append(contentsOf: await ctx.lifecycle.drainWarnings(for: id))
        }
        var payload: [String: Any] = ["slug": slug, "status": "stopped"]
        if !warnings.isEmpty { payload["warnings"] = warnings }
        return MCPResult.json(payload)
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
        let provision = args["provision"]?.boolValue ?? true
        let isolatedDB = args["isolated_db"]?.boolValue ?? false
        let envelope = try await ctx.load()
        guard let parent = envelope.sites.first(where: { $0.slug == parentSlug }) else {
            throw ToolError("site_not_found", "No site with slug \(parentSlug).")
        }
        guard WorktreeEnvService.isValidRepoRelPath(repo) else {
            throw ToolError("invalid_repo_path", WorktreeError.invalidRepoPath(repo).description)
        }
        let running = await ctx.runningContainerNames()
        // Port allocation + env reservation happen in ONE locked store mutation
        // (#3) so a concurrent creator can't observe the same port as free.
        guard let (_, reserved, _) = try await ctx.persistence.allocatePort(reserve: { port, store in
            WorktreeEnvService.reservedDescriptor(parent: parent, repoRelPath: repo, branch: branch, port: port, into: &store)
        }) else {
            throw ToolError("no_free_port", "No free port available.")
        }
        let env: WorktreeEnv
        do {
            let outcome = try await ctx.worktrees.create(parent: parent, parentIsRunning: running.contains(parent.wpContainerName),
                                                        repoRelPath: repo, branch: branch, from: from,
                                                        port: reserved.port, reserved: reserved, provision: provision,
                                                        isolatedDB: isolatedDB)
            env = outcome.env
            let reaped = outcome.reapedSchemas
            _ = try await ctx.persistence.mutate { store in
                store.envs.removeAll { $0.id == env.id }
                store.envs.append(env)
                // Clear exactly the tombstones whose DROP succeeded (#17).
                if !reaped.isEmpty, let i = store.sites.firstIndex(where: { $0.id == parent.id }) {
                    store.sites[i].pendingSchemaDrops.removeAll { reaped.contains($0) }
                }
            }
        } catch {
            _ = try? await ctx.persistence.mutate { store in store.envs.removeAll { $0.id == reserved.id } }
            throw error
        }
        let d = WorktreeDescriptor(from: env)
        var payload: [String: Any] = [
            "url": d.url, "port": d.port, "path": d.path, "worktreePath": d.worktreePath,
            "branch": d.branch, "envSlug": d.envSlug, "containers": d.containers,
            // So an agent can see WHERE this env's data actually lives (#17).
            "database": ["name": env.databaseName, "container": env.dbContainerName,
                         "shared": env.sharedDatabase],
        ]
        var warnings = await ctx.lifecycle.drainWarnings(for: env.id)
        // The returned `url` is the proxy's to serve (issue #16 follow-through) —
        // tell the caller now rather than letting it discover a refused connection.
        if let warning = ProxyControl.envProxyWarning(port: env.port) { warnings.append(warning) }
        if !warnings.isEmpty { payload["warnings"] = warnings }
        return MCPResult.json(payload)
    }

    private static func worktreeList(_ args: [String: Value], ctx: CLIContext, slug: String) async throws -> CallTool.Result {
        let envelope = try await ctx.load()
        let running = await ctx.runningContainerNames()
        let filter = args["site"]?.stringValue ?? slug
        let envs = envelope.envs.filter { filter == "*" || $0.parentSlug == filter }.map { e -> [String: Any] in
            ["envSlug": e.envSlug, "parentSlug": e.parentSlug, "branch": e.branch, "repoRelPath": e.repoRelPath,
             "status": running.contains(e.wpContainerName) ? "running" : "stopped",
             "url": e.localURL.absoluteString, "port": e.port, "worktreePath": e.worktreePath.path,
             // Auto-stop-when-idle (issue #16), so an agent can see whether an env
             // may be parked under it and opt in/out via `set_idle_stop`.
             "idleStopMinutes": e.idleStopMinutes as Any? ?? NSNull(),
             "effectiveIdleStopMinutes": e.effectiveIdleStopMinutes]
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
        let outcome = await ctx.worktrees.delete(env, parent: parent, keepBranch: keepBranch, keepWorktree: keepWorktree)
        _ = try await ctx.persistence.mutate { store in
            store.envs.removeAll { $0.id == env.id }
            // The DB server was down, so the env's schema is still there (#17).
            // Tombstone it for the next shared-env create to reap.
            if let orphan = outcome.tombstonedSchema, let parent,
               let i = store.sites.firstIndex(where: { $0.id == parent.id }),
               !store.sites[i].pendingSchemaDrops.contains(orphan) {
                store.sites[i].pendingSchemaDrops.append(orphan)
            }
        }
        if let parent { await ctx.lifecycle.stopSharedDatabaseIfUnused(parent: parent) }
        return MCPResult.json(["ok": true, "envSlug": envSlug])
    }

    // MARK: - Add-on toggles (§2c)

    private enum Addon { case xdebug, elasticsearch }

    private static func addonToggle(_ args: [String: Value], ctx: CLIContext, slug: String, kind: Addon) async throws -> CallTool.Result {
        guard let enabled = args["enabled"]?.boolValue else { throw ToolError("bad_args", "`enabled` is required.") }
        let site = try await resolveSite(slug, ctx: ctx)
        let updated = try await ctx.persistence.mutate { env in
            if let i = env.sites.firstIndex(where: { $0.id == site.id }) {
                switch kind {
                case .xdebug:        env.sites[i].xdebugEnabled = enabled
                case .elasticsearch: env.sites[i].elasticsearchEnabled = enabled
                }
            }
        }
        let newSite = updated.sites.first { $0.id == site.id } ?? site
        let running = await ctx.runningContainerNames()
        var restarted = false
        if running.contains(site.wpContainerName) {
            await ctx.lifecycle.stop(newSite)
            _ = try await ctx.lifecycle.startSite(newSite)
            await ctx.lifecycle.markRunning(newSite.id)
            restarted = true
        }
        return MCPResult.json([
            "ok": true,
            "addon": kind == .xdebug ? "xdebug" : "elasticsearch",
            "enabled": enabled,
            "restarted": restarted,
        ])
    }

    // MARK: - Mailpit toggle (issue #10)

    private static func mailpitToggle(_ args: [String: Value], ctx: CLIContext, slug: String) async throws -> CallTool.Result {
        guard let enabled = args["enabled"]?.boolValue else { throw ToolError("bad_args", "`enabled` is required.") }
        let site = try await resolveSite(slug, ctx: ctx)
        let updated: Site
        if enabled {
            try MailpitService.writeHandler(phpConfFolder: site.phpConfFolder)
            if site.mailpitPort == nil {
                guard let (_, reservedSite, _) = try await ctx.persistence.allocatePort(reserve: { port, env -> Site? in
                    guard let i = env.sites.firstIndex(where: { $0.id == site.id }) else { return nil }
                    env.sites[i].mailpitPort = port
                    env.sites[i].mailpitEnabled = true
                    return env.sites[i]
                }), let s = reservedSite else { throw ToolError("no_free_port", "No free port available for the mailbox.") }
                updated = s
            } else {
                let env = try await ctx.persistence.mutate { e in
                    if let i = e.sites.firstIndex(where: { $0.id == site.id }) { e.sites[i].mailpitEnabled = true }
                }
                updated = env.sites.first { $0.id == site.id } ?? site
            }
        } else {
            MailpitService.removeHandler(phpConfFolder: site.phpConfFolder)
            let env = try await ctx.persistence.mutate { e in
                if let i = e.sites.firstIndex(where: { $0.id == site.id }) { e.sites[i].mailpitEnabled = false }
            }
            updated = env.sites.first { $0.id == site.id } ?? site
        }
        let running = await ctx.runningContainerNames()
        var restarted = false
        if running.contains(site.wpContainerName) {
            await ctx.lifecycle.stop(updated)
            _ = try await ctx.lifecycle.startSite(updated)
            await ctx.lifecycle.markRunning(updated.id)
            restarted = true
        }
        return MCPResult.json([
            "ok": true,
            "enabled": enabled,
            "restarted": restarted,
            "mailboxUrl": updated.mailboxURL?.absoluteString as Any? ?? NSNull(),
        ])
    }

    // MARK: - db_import (PLAN.md §2m)

    /// Imports a `.sql`/`.sql.gz` dump into a site's database. Sites only (not
    /// worktree environments) in v1. Auto-starts a stopped site (the kit never
    /// starts containers itself) and persists the detected/overridden source
    /// URL into `lastImportSourceURL` afterward (the kit doesn't write it).
    /// No streaming progress over MCP — the progress callback is a no-op and
    /// only the final summary (or a structured phaseFailed error) is returned.
    private static func dbImport(_ args: [String: Value], ctx: CLIContext, slug: String) async throws -> CallTool.Result {
        guard let file = args["file"]?.stringValue else {
            throw ToolError("bad_args", "`file` is required (absolute path to a .sql/.sql.gz dump).")
        }
        let targetSlug = args["site"]?.stringValue ?? slug
        let envelope = try await ctx.load()
        guard let site = envelope.sites.first(where: { $0.slug == targetSlug }) else {
            if envelope.envs.contains(where: { $0.envSlug == targetSlug }) {
                throw ToolError("unsupported_target", "db_import targets sites only (not worktree environments) in this version.")
            }
            throw ToolError("site_not_found", "No site with slug \(targetSlug).")
        }

        let mediaArg = args["media"]?.stringValue ?? "remote"
        let media: DBImportMediaOption
        switch mediaArg {
        case "remote": media = .remote
        case "skip": media = .skip
        case "copy":
            guard let mediaPath = args["media_path"]?.stringValue else {
                throw ToolError("bad_args", "media=\"copy\" requires media_path.")
            }
            media = .copy(from: URL(fileURLWithPath: (mediaPath as NSString).expandingTildeInPath))
        default:
            throw ToolError("bad_args", "media must be \"remote\", \"skip\", or \"copy\".")
        }

        let options = DBImportOptions(
            scrub: args["scrub"]?.boolValue ?? true,
            allowedEmails: args["allowed_emails"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
            allowedDomains: args["allowed_domains"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
            media: media,
            createAdmin: args["create_admin"]?.boolValue ?? true,
            sourceURLOverride: args["source_url"]?.stringValue
        )

        // Auto-start (mirrors the CLI surface): the kit throws .siteNotRunning
        // rather than starting containers itself.
        let running = await ctx.runningContainerNames()
        if !running.contains(site.wpContainerName) {
            let provisioned = try await ctx.lifecycle.startSite(site)
            if provisioned != site.provisioned {
                _ = try await ctx.persistence.mutate { env in
                    if let i = env.sites.firstIndex(where: { $0.id == site.id }) { env.sites[i].provisioned = provisioned }
                }
            }
        }

        let dumpURL = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        let importer = DatabaseImportService(cli: ctx.cli, lifecycle: ctx.lifecycle)
        do {
            let summary = try await importer.importDatabase(into: site, dump: dumpURL, options: options) { _ in
                // No streaming progress over MCP — final result only.
            }
            if let detectedSource = summary.sourceURL {
                _ = try? await ctx.persistence.mutate { env in
                    if let i = env.sites.firstIndex(where: { $0.id == site.id }) { env.sites[i].lastImportSourceURL = detectedSource }
                }
            }
            return MCPResult.json([
                "site": site.slug,
                "sourceURL": summary.sourceURL as Any? ?? NSNull(),
                "localURL": summary.localURL,
                "backupPath": summary.backupPath,
                "usersScrubbed": summary.usersScrubbed,
                "usersPreserved": summary.usersPreserved,
                "commentsRemoved": summary.commentsRemoved,
                "replacementsMade": summary.replacementsMade as Any? ?? NSNull(),
                "mediaMode": summary.mediaMode,
                "adminUser": summary.adminUser as Any? ?? NSNull(),
                "adminPassword": summary.adminPassword as Any? ?? NSNull(),
                "dumpSizeBytes": summary.dumpSizeBytes,
            ])
        } catch let dbError as DatabaseImportError {
            if case .phaseFailed(let phase, let short, let full, let rolledBack) = dbError {
                return MCPResult.json([
                    "error": "import_failed",
                    "phase": phase.rawValue,
                    "short": short,
                    "full": full,
                    "rolledBack": rolledBack,
                ], isError: true)
            }
            throw ToolError("import_failed", dbError.description)
        }
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
