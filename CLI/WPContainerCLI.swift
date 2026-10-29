import ArgumentParser
import Foundation
import WPContainerKit

// MARK: - Root command

@main
struct WPContainerCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wp-container",
        abstract: "Manage local WordPress dev sites and git worktree environments running on Apple containers.",
        version: WPContainerVersion.current,
        subcommands: [
            ListCommand.self,
            CreateCommand.self,
            StartCommand.self,
            StopCommand.self,
            DeleteCommand.self,
            WorktreeCommand.self,
            WPCommand.self,
            RunCommand.self,
            TestCommand.self,
            LoginCommand.self,
            MCPCommand.self,
            AgentToolsCommand.self,
            ShimCommand.self,
            HTTPSCommand.self,
            MountCommand.self,
            ProxyCommand.self,
            XdebugCommand.self,
            WebServerCommand.self,
            ElasticsearchCommand.self,
            MailpitCommand.self,
            RedisCommand.self,
            DBCommand.self,
            ExportCommand.self,
            ImportCommand.self,
            LimitsCommand.self,
            IdleCommand.self,
            DomainCommand.self,
            ResolveSiteCommand.self,
            SetupCommand.self,
        ]
    )
}

// MARK: - Shared options / helpers

struct JSONOptions: ParsableArguments {
    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json = false
}

/// Bundle of services + persistence for a single CLI invocation.
struct CLIContext {
    let persistence = StorePersistence()
    let cli = ContainerCLI()
    let git = GitService()
    let lifecycle: SiteLifecycle
    let worktrees: WorktreeEnvService

    init() {
        let c = cli
        let g = git
        let lc = SiteLifecycle(cli: c)
        self.lifecycle = lc
        self.worktrees = WorktreeEnvService(cli: c, git: g, lifecycle: lc)
    }

    var settler: EnvSettler {
        EnvSettler(persistence: persistence, lifecycle: lifecycle, worktrees: worktrees, cli: cli)
    }

    func load() async throws -> StoreEnvelope { try await persistence.load() }

    /// Restore a settled env (new port if its old one was taken, URLs migrated
    /// when needed) and start it, printing a notice and any warnings to stderr.
    @discardableResult
    func restore(_ env: WorktreeEnv, envelope: StoreEnvelope) async throws -> WorktreeEnv {
        FileHandle.standardError.write(Data("\(env.envSlug) was settled — restoring it…\n".utf8))
        try await unarchiveIfNeeded(siteID: env.parentSiteID)
        let parent = envelope.sites.first { $0.id == env.parentSiteID }
        do {
            let (restored, warnings) = try await settler.restore(env, parent: parent)
            for warning in warnings {
                FileHandle.standardError.write(Data(("warning: \(warning)\n").utf8))
            }
            return restored
        } catch let error as EnvSettlementError {
            throw CLIErrorJSON("restore_failed", detail: error.description)
        }
    }

    /// Names of currently-running containers.
    func runningContainerNames() async -> Set<String> {
        guard let records = try? await cli.list(all: true) else { return [] }
        return Set(records.filter { $0.isRunning }.map { $0.name })
    }

    /// Starting an archived site, or one of its branch environments, brings the
    /// site back: clear the archive mark so the app lists it again and the
    /// proxy routes it (it skips archived sites' envs too). Takes the site's ID
    /// and reads the store, so env paths can pass their parent's.
    func unarchiveIfNeeded(siteID: UUID) async throws {
        let envelope = try await persistence.load()
        guard let site = envelope.sites.first(where: { $0.id == siteID }), site.isArchived else { return }
        _ = try await persistence.mutate { store in _ = store.unarchiveSite(id: siteID) }
        FileHandle.standardError.write(Data("\(site.slug) was archived — unarchiving it.\n".utf8))
    }

    /// Wake a stopped target before a one-shot command (`wp`, `db import`,
    /// `login`) touches it. Before this, only HTTP through the proxy woke an
    /// idle-stopped instance — these commands talk to the container directly
    /// and used to hard-fail instead ("container not found"-style errors).
    /// No-op when already running, or when `noStart` opts out (the caller's
    /// own not-running check then fires exactly as it did before this fix).
    /// Reuses `SiteLifecycle.startSite`/`startInstance` — never reimplements
    /// start. Prints a one-line notice to stderr (stdout is reserved for wp-
    /// cli/MCP output) when it actually starts something.
    func ensureRunning(_ resolved: ResolvedTarget, envelope: StoreEnvelope, noStart: Bool = false) async throws {
        guard !noStart, await !lifecycle.isWPContainerRunning(resolved.instance) else { return }
        if case .env(let env) = resolved, env.isSettled {
            try await restore(env, envelope: envelope)
            return
        }
        let label: String
        switch resolved {
        case .site(let s): label = s.slug
        case .env(let e): label = e.envSlug
        }
        FileHandle.standardError.write(Data("\(label) was stopped — starting it first…\n".utf8))
        switch resolved {
        case .site(let site):
            try await unarchiveIfNeeded(siteID: site.id)
            let provisioned = try await lifecycle.startSite(site)
            if provisioned != site.provisioned {
                _ = try await persistence.mutate { store in
                    if let i = store.sites.firstIndex(where: { $0.id == site.id }) { store.sites[i].provisioned = provisioned }
                }
            }
        case .env(let env):
            // The parent goes along as `dbProvider` so a shared-database env
            // can boot the server it borrows when the parent site is down
            // (issue #17) — same as the `start` command's env branch.
            try await unarchiveIfNeeded(siteID: env.parentSiteID)
            let parent = envelope.sites.first { $0.id == env.parentSiteID }
            _ = try await lifecycle.startInstance(env, dbProvider: parent)
        }
    }
}

enum ResolvedTarget {
    case site(Site)
    case env(WorktreeEnv)

    var instance: any RunnableInstance {
        switch self {
        case .site(let s): return s
        case .env(let e): return e
        }
    }
}

func resolveTarget(_ identifier: String, in envelope: StoreEnvelope) -> ResolvedTarget? {
    if let s = envelope.sites.first(where: { $0.slug == identifier }) { return .site(s) }
    if let e = envelope.envs.first(where: { $0.envSlug == identifier }) { return .env(e) }
    return nil
}

func emitLine(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

/// Print an error (JSON on stderr when `--json`) and exit non-zero.
func failCommand(_ error: Error, json: Bool) -> ExitCode {
    let cliError = (error as? CLIErrorJSON)
        ?? (error as? SiteMounts.Failure)?.cliError
        ?? errorCode(error).map { CLIErrorJSON($0, detail: humanText(error)) }
        ?? CLIErrorJSON(humanText(error))
    if json {
        FileHandle.standardError.write(Data((CLIJSON.string(cliError) + "\n").utf8))
    } else {
        var line = cliError.error
        if let d = cliError.detail { line += ": \(d)" }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
    return ExitCode.failure
}

func humanText(_ error: Error) -> String {
    if let e = error as? ContainerCLIError { return e.description }
    if let e = error as? LifecycleError { return e.description }
    if let e = error as? GitError { return e.description }
    if let e = error as? WorktreeError { return e.description }
    if let e = error as? MagicLoginError { return e.description }
    if let e = error as? ImageUnavailableError { return e.description }
    if let e = error as? SiteArchiveError { return e.description }
    return "\(error)"
}

/// The stable `error` code for typed errors that carry one.
func errorCode(_ error: Error) -> String? {
    guard let archiveError = error as? SiteArchiveError else { return nil }
    switch archiveError {
    case .unsupportedSchema: return "unsupported_schema"
    case .notAWPCExport: return "not_a_wpc_export"
    case .unsafeEntry: return "unsafe_entry"
    case .insufficientDiskSpace: return "insufficient_disk_space"
    case .siteNotRunning: return "not_running"
    case .outputExists: return "output_exists"
    case .toolFailed: return "tool_failed"
    case .domainInUse: return "domain_in_use"
    case .invalidDomain: return "invalid_domain"
    case .noFreePort: return "no_free_port"
    }
}

// MARK: - list

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List sites and worktree envs with status/url/port.")
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            var envelope = try await ctx.load()
            let running = await ctx.runningContainerNames()
            // Apply live status.
            for i in envelope.sites.indices {
                envelope.sites[i].status = running.contains(envelope.sites[i].wpContainerName) ? .running : .stopped
            }
            for i in envelope.envs.indices {
                envelope.envs[i].status = running.contains(envelope.envs[i].wpContainerName) ? .running : .stopped
            }
            if output.json {
                let groupNames = Dictionary(uniqueKeysWithValues: envelope.groups.map { ($0.id, $0.name) })
                let payload = ListJSON(sites: envelope.sites.map { SiteJSON(from: $0, group: $0.groupID.flatMap { groupNames[$0] }) },
                                       envs: envelope.envs.map(EnvJSON.init))
                emitLine(CLIJSON.string(payload))
            } else {
                if envelope.sites.isEmpty && envelope.envs.isEmpty {
                    emitLine("No sites.")
                }
                for s in envelope.sites {
                    emitLine("\(s.status.token.padding(toLength: 8, withPad: " ", startingAt: 0))  \(s.slug)  \(s.url.absoluteString)")
                }
                for e in envelope.envs {
                    emitLine("\(e.status.token.padding(toLength: 8, withPad: " ", startingAt: 0))  \(e.envSlug) [env]  \(e.url.absoluteString)")
                }
            }
        } catch {
            throw failCommand(error, json: output.json)
        }
    }
}

// MARK: - create

struct CreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new site (does not start it).",
        discussion: """
        `--wp-env <project-dir>` builds the site from the project's .wp-env.json \
        (with .wp-env.override.json and env.development applied): WordPress and \
        PHP version, multisite, and config constants. Local plugins, themes, and \
        mappings are bind-mounted live into the site; remote plugins and themes \
        (GitHub owner/repo#ref, zip URLs) are installed, and plugins activated. \
        The site is started to apply them. --wp, --php-version, --php, and \
        --multisite override the project's values.

        `--mount <host-folder>:<path>` bind-mounts a host folder at a path in \
        the WordPress folder, such as wp-content/plugins/example. It replaces a \
        project mount at the same path. Manage mounts later with `mount`.
        """
    )
    @Argument(help: "Site name.") var name: String
    @Option(name: .long, help: "Parent folder (default: ~/WP Container Sites).") var path: String?
    @Option(name: .long, help: "Full WordPress image tag override (e.g. wordpress:php8.3-apache).") var php: String?
    @Option(name: .long, help: "WordPress version: latest, 6.8, 6.7, 6.6.") var wp: String?
    @Option(name: .long, help: "PHP version: 8.4, 8.3, 8.2, 8.1.") var phpVersion: String?
    @Option(name: .long, help: "Web server: apache (default) | nginx.") var webServer: String?
    @Option(name: .long, help: "Multisite network: subdirectory | subdomain.") var multisite: String?
    @Option(name: .long, help: "Custom domain, e.g. mysite.local.") var domain: String?
    @Option(name: .long, help: "Sidebar group name (created if it doesn't exist).") var group: String?
    @Option(name: .long, help: "CPU cap per container (1–8; default: container default of 4).") var cpus: Int?
    @Option(name: .long, help: "Memory cap per container in MB (e.g. 512; default: container default of 1024).") var memory: Int?
    @Option(name: .customLong("wp-env"), help: "Build the site from this project's .wp-env.json, and start it.") var wpEnv: String?
    @Option(name: .customLong("mount"), help: ArgumentHelp("Bind-mount a host folder into the site, e.g. ~/code/example:wp-content/plugins/example. Repeatable.", valueName: "host-folder:path"))
    var mounts: [String] = []
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let plan = try wpEnv.map { try WPEnvPlan(project: WPEnvProject.load(directory: Self.expand($0))) }
            let siteMounts = try Self.mounts(mounts, plan: plan)
            let wp = self.wp ?? plan?.wordpressVersion
            let phpVersion = self.phpVersion ?? plan?.phpVersion
            let multisite = self.multisite ?? ((plan?.multisite ?? false) ? NetworkType.subdirectory.rawValue : nil)
            let envelope = try await ctx.load()
            let slug = Slug.unique(name, existing: Set(envelope.sites.map(\.slug)))
            // Resolve the image tag: explicit --php override wins; else map the
            // WP × PHP matrix (§2k); else default.
            let imageTag: String
            let phpLabel: String?
            if let php {
                imageTag = php; phpLabel = php
            } else if wp != nil || phpVersion != nil {
                let wpVer = wp ?? "latest"
                let phpVer = phpVersion ?? WordPressImageCatalog.defaultPHP
                imageTag = WordPressImageCatalog.imageTag(wordpress: wpVer, php: phpVer)
                phpLabel = "PHP \(phpVer)"
            } else {
                imageTag = SiteRecipe.defaultWordPressImage; phpLabel = nil
            }
            var siteWebServer = WebServer.apache
            if let webServer {
                guard let server = WebServer(rawValue: webServer.lowercased()) else {
                    throw CLIErrorJSON("bad_args", detail: "--web-server must be apache|nginx")
                }
                guard server.supports(imageTag: imageTag) else {
                    throw CLIErrorJSON("bad_args", detail: "nginx needs an official wordpress image with a PHP-FPM variant; \(imageTag) has none")
                }
                siteWebServer = server
            }
            // Network type.
            var networkType: NetworkType = .none
            if let multisite {
                guard let t = NetworkType(rawValue: multisite.lowercased()), t.isMultisite else {
                    throw CLIErrorJSON("bad_args", detail: "--multisite must be subdirectory|subdomain")
                }
                networkType = t
            }
            // Custom domain (validated).
            var customDomain: String? = nil
            if let domain {
                guard let normalized = DomainService.normalize(domain) else { throw CLIErrorJSON("invalid_domain", detail: domain) }
                if envelope.sites.contains(where: { $0.customDomain == normalized }) { throw CLIErrorJSON("domain_in_use", detail: normalized) }
                customDomain = normalized
            }
            let root = path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? SiteFolders.defaultSitesRoot
            let sitePath = root.appendingPathComponent(slug, isDirectory: true)
            // Allocate the port INSIDE the locked store mutation (#3): the port
            // is picked from the store's current taken set AND the new site is
            // appended in the same critical section, so a concurrent creator
            // (app or another CLI) can never observe the same port as free.
            let groupName = group
            let siteName = name
            let siteImageTag = imageTag
            let sitePHPLabel = phpLabel
            let siteServer = siteWebServer
            let siteDomain = customDomain
            let siteNetwork = networkType
            let siteCPU = cpus
            let siteMemory = memory
            guard let (_, created, updated) = try await ctx.persistence.allocatePort(reserve: { port, env in
                var s = Site(name: siteName, slug: slug, path: sitePath,
                             port: port, imageTag: siteImageTag, phpVersion: sitePHPLabel,
                             webServer: siteServer, cpuLimit: siteCPU, memoryLimitMB: siteMemory,
                             customDomain: siteDomain, networkType: siteNetwork)
                s.mounts = siteMounts
                if let groupName, !groupName.trimmingCharacters(in: .whitespaces).isEmpty {
                    if let existing = env.groups.first(where: { $0.name.caseInsensitiveCompare(groupName) == .orderedSame }) {
                        s.groupID = existing.id
                    } else {
                        let g = SiteGroup(name: groupName, sortOrder: (env.groups.map(\.sortOrder).max() ?? -1) + 1)
                        env.groups.append(g)
                        s.groupID = g.id
                    }
                }
                env.sites.append(s)
                return s
            }) else {
                throw CLIErrorJSON("no_free_port")
            }
            let folderExisted = FileManager.default.fileExists(atPath: created.path.path)
            try SiteFolders.ensure(for: created)
            // Write the per-site wp-cli shim at <site>/wp (§2e).
            try? WPCLIShim.writeShim(for: created, siteRoot: created.path, slug: created.slug)
            let resolvedGroupName = created.groupID.flatMap { id in updated.groups.first { $0.id == id }?.name }
            guard let plan else {
                if output.json { emitLine(CLIJSON.string(SiteJSON(from: created, group: resolvedGroupName))) }
                else { emitLine("Created \(created.slug) at \(created.path.path) (port \(created.port))\(resolvedGroupName.map { " in group \"\($0)\"" } ?? "").") }
                return
            }
            if !output.json { emitLine("Created \(created.slug) at \(created.path.path) (port \(created.port)). Starting it to apply .wp-env.json…") }
            // A site that doesn't start is removed, so re-running `create`
            // reuses its name.
            let dbHost: String
            do {
                try await ctx.ensureRunning(.site(created), envelope: updated)
                guard let host = try await ctx.cli.ipAddress(of: created.dbContainerName) else {
                    throw CLIErrorJSON("not_running", detail: "\(created.slug)'s database didn't come up")
                }
                dbHost = host
            } catch {
                await SiteDiscard.discard(created, keepFolder: folderExisted, lifecycle: ctx.lifecycle, persistence: ctx.persistence)
                if !output.json {
                    FileHandle.standardError.write(Data("Removed \(created.slug): it didn't start, so .wp-env.json wasn't applied.\n".utf8))
                }
                throw error
            }
            let report = await WPEnvApplier.apply(plan, to: created, dbHost: dbHost, cli: ctx.cli)
            if output.json {
                struct CreateFromWPEnvJSON: Codable {
                    let site: SiteJSON; let mounts: [Mount]; let applied: [String]; let failures: [String]; let warnings: [String]
                }
                emitLine(CLIJSON.string(CreateFromWPEnvJSON(site: SiteJSON(from: created, group: resolvedGroupName),
                                                            mounts: created.mounts, applied: report.done,
                                                            failures: report.failures, warnings: plan.warnings)))
            } else {
                for mount in created.mounts { emitLine("  Mounted \(mount.hostPath) → \(mount.containerPath)") }
                for line in report.done { emitLine("  \(line)") }
                for line in report.failures { emitLine("  ✗ \(line)") }
                for line in plan.warnings { emitLine("  ! \(line)") }
                emitLine("Ready at \(created.url.absoluteString)")
            }
            if !report.failures.isEmpty { throw ExitCode.failure }
        } catch let code as ExitCode {
            throw code
        } catch {
            throw failCommand(error, json: output.json)
        }
    }

    /// The `--mount` folders, plus the project's mounts that don't share a
    /// container path with one of them.
    private static func mounts(_ specs: [String], plan: WPEnvPlan?) throws -> [Mount] {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let explicit = try specs.map { try SiteMounts.parse($0, relativeTo: base) }
        let paths = Set(explicit.map(\.containerPath))
        var mounts = (plan?.mounts ?? []).filter { !paths.contains($0.containerPath) }
        for mount in explicit { mounts = try SiteMounts.adding(mount, to: mounts) }
        return mounts
    }

    private static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }
}

// MARK: - start / stop / delete

struct StartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start a site or a single env.",
        discussion: """
        Starting a SITE starts ONLY that site by default (issue #18) — pass \
        --with-envs to also start every worktree environment created from it, \
        concurrently (they share nothing at runtime); a failure in one does not \
        abort the others (env failures print as warnings). Starting an ENV slug \
        always starts just that environment.

        Images are pulled only when missing locally by default. Use --no-pull \
        for a strictly offline start (fails clearly if an image isn't already \
        local), or --refresh-images to force a registry revalidation (falls \
        back to the local image with a warning if the pull fails, e.g. rate \
        limited).
        """
    )
    @Argument(help: "Site slug or env slug.") var target: String
    @Flag(name: .long, help: "Also start all worktree environments of the site.") var withEnvs = false
    @Flag(name: .long, help: "Never contact the registry; fail clearly if an image isn't already local.") var noPull = false
    @Flag(name: .long, help: "Force a registry pull even for images that already exist locally.") var refreshImages = false
    @OptionGroup var output: JSONOptions

    private func resolvedPullPolicy() throws -> PullPolicy {
        guard !(noPull && refreshImages) else {
            throw CLIErrorJSON("bad_args", detail: "--no-pull and --refresh-images are mutually exclusive")
        }
        if noPull { return .never }
        if refreshImages { return .refresh }
        return .ifMissing
    }

    func run() async throws {
        let ctx = CLIContext()
        do {
            let policy = try resolvedPullPolicy()
            let envelope = try await ctx.load()
            guard let resolved = resolveTarget(target, in: envelope) else { throw CLIErrorJSON("not_found", detail: target) }
            switch resolved {
            case .site(let site):
                try await ctx.unarchiveIfNeeded(siteID: site.id)
                // An explicit start is the clearest possible activity signal, so
                // the idle sweep can't park what somebody just asked for (issue
                // #16). Wake-triggered starts deliberately do NOT stamp — that
                // would let the sweep extend its own deadline.
                await ctx.persistence.recordActivity(instanceID: site.id)
                // A plain `start` (no fan-out) on an already-running site used to
                // fall through to `container run` and surface its raw "already
                // exists" error; make it the no-op it should be instead. With
                // --with-envs there may still be envs to start, so let the
                // (now idempotent) coupled start run regardless.
                if !withEnvs, await ctx.lifecycle.isWPContainerRunning(site) {
                    if output.json { emitLine(CLIJSON.string(CLIErrorJSON("ok", detail: "\(target) already running"))) }
                    else { emitLine("\(target) is already running.") }
                    return
                }
                // Env fan-out is opt-in (issue #18) — an empty envs list makes
                // `startSiteWithEnvs` start only the parent, reusing the same
                // claim/warning/image-prefetch plumbing.
                // Settled envs stay parked; `start <env>` restores one.
                let envs = withEnvs ? envelope.envs.filter { $0.parentSiteID == site.id && !$0.isSettled } : []
                let outcome = await ctx.lifecycle.startSiteWithEnvs(site, envs: envs, pullPolicy: policy)
                if outcome.provisioned != site.provisioned {
                    _ = try await ctx.persistence.mutate { env in
                        if let i = env.sites.firstIndex(where: { $0.id == site.id }) { env.sites[i].provisioned = outcome.provisioned }
                    }
                }
                for warning in outcome.warnings {
                    FileHandle.standardError.write(Data(("warning: \(warning)\n").utf8))
                }
                if outcome.parentErrorMessage == nil,
                   let warning = await NetworkHostsService.hostsWarningAfterStart(site, cli: ctx.cli, persistence: ctx.persistence) {
                    FileHandle.standardError.write(Data(("warning: \(warning)\n").utf8))
                }
                // Any env in the fan-out is served by the proxy, not by a
                // published port (issue #16 follow-through). Per-env, because the
                // answer differs per port: one may be served while another collides
                // with a pre-upgrade container still publishing it.
                for warning in Set(envs.compactMap { ProxyControl.envProxyWarning(port: $0.port) }) {
                    FileHandle.standardError.write(Data(("warning: \(warning)\n").utf8))
                }
                // Env failures are non-fatal warnings; a parent failure fails
                // the command (envs were still attempted first, per §2b).
                for message in outcome.envErrorMessages {
                    FileHandle.standardError.write(Data(("warning: env start failed — \(message)\n").utf8))
                }
                if let parentError = outcome.parentErrorMessage {
                    throw CLIErrorJSON("start_failed", detail: parentError)
                }
            case .env(let env):
                // Guarded start (issue #5): dedupes against a concurrent
                // action for the same env in THIS process. The parent goes along
                // as `dbProvider` so a shared-database env can boot the server it
                // borrows when the parent site is down (issue #17).
                try await ctx.unarchiveIfNeeded(siteID: env.parentSiteID)
                let parent = envelope.sites.first { $0.id == env.parentSiteID }
                await ctx.persistence.recordActivity(instanceID: env.id)
                // Same no-op as the site branch above: `start` on an env that's
                // already up must succeed quietly, not surface `container run`'s
                // "already exists" error.
                if await ctx.lifecycle.isWPContainerRunning(env) {
                    if output.json { emitLine(CLIJSON.string(CLIErrorJSON("ok", detail: "\(target) already running"))) }
                    else { emitLine("\(target) is already running.") }
                    return
                }
                if env.isSettled {
                    let restored = try await ctx.restore(env, envelope: envelope)
                    if output.json { emitLine(CLIJSON.string(CLIErrorJSON("ok", detail: "\(target) restored at \(restored.url.absoluteString)"))) }
                    else { emitLine("Restored \(target) at \(restored.url.absoluteString).") }
                    return
                }
                _ = try await ctx.lifecycle.startInstance(env, pullPolicy: policy, dbProvider: parent)
                for warning in await ctx.lifecycle.drainWarnings(for: env.id) {
                    FileHandle.standardError.write(Data(("warning: \(warning)\n").utf8))
                }
                // The env is up either way — but its URL only answers when a
                // proxy owns THIS port (issue #16 follow-through).
                if let warning = ProxyControl.envProxyWarning(port: env.port) {
                    FileHandle.standardError.write(Data(("warning: \(warning)\n").utf8))
                }
            }
            if output.json { emitLine(CLIJSON.string(CLIErrorJSON("ok", detail: "\(target) started"))) }
            else { emitLine("Started \(target).") }
        } catch {
            throw failCommand(error, json: output.json)
        }
    }
}

struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop a site (and all of its worktree envs) or a single env.",
        discussion: """
        Lifecycle is coupled (PLAN.md §2b): stopping a SITE also stops every \
        worktree environment created from it. Stopping an ENV slug stops just \
        that environment.
        """
    )
    @Argument(help: "Site slug or env slug.") var target: String
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let envelope = try await ctx.load()
            guard let resolved = resolveTarget(target, in: envelope) else { throw CLIErrorJSON("not_found", detail: target) }
            // Teardown problems the stop path recorded (issue #16): a container
            // that survived both `container stop` and `container delete` is
            // still holding its VM's memory, so it must not stay invisible.
            var ids: [UUID] = []
            switch resolved {
            case .site(let site):
                let envs = envelope.envs.filter { $0.parentSiteID == site.id }
                await ctx.lifecycle.stopSiteWithEnvs(site, envs: envs)
                ids = [site.id] + envs.map(\.id)
            case .env(let env):
                await ctx.lifecycle.stop(env)
                ids = [env.id]
                // A shared DB container would otherwise linger after its last
                // user stopped (issue #17) — that memory is the whole point.
                if let parent = envelope.sites.first(where: { $0.id == env.parentSiteID }) {
                    await ctx.lifecycle.stopSharedDatabaseIfUnused(parent: parent)
                    ids.append(parent.id)
                }
            }
            for id in ids {
                for warning in await ctx.lifecycle.drainWarnings(for: id) {
                    FileHandle.standardError.write(Data(("warning: \(warning)\n").utf8))
                }
            }
            if output.json { emitLine(CLIJSON.string(CLIErrorJSON("ok", detail: "\(target) stopped"))) }
            else { emitLine("Stopped \(target).") }
        } catch {
            throw failCommand(error, json: output.json)
        }
    }
}

struct DeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a site (and its envs) or a single env.")
    @Argument(help: "Site slug or env slug.") var target: String
    @Flag(name: .long, help: "Do not trash the site folder on disk.") var keepFolder = false
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let envelope = try await ctx.load()
            guard let resolved = resolveTarget(target, in: envelope) else { throw CLIErrorJSON("not_found", detail: target) }
            switch resolved {
            case .site(let site):
                let childEnvs = envelope.envs.filter { $0.parentSiteID == site.id }
                for env in childEnvs {
                    await ctx.worktrees.delete(env, parent: site, keepBranch: true, keepWorktree: false)
                }
                await ctx.lifecycle.deleteContainers(site)
                if !keepFolder { try? FileManager.default.trashItem(at: site.path, resultingItemURL: nil) }
                _ = try await ctx.persistence.mutate { env in
                    env.sites.removeAll { $0.id == site.id }
                    env.envs.removeAll { $0.parentSiteID == site.id }
                }
                // Drop this site's (and its envs') hostnames from the trusted
                // leaf's SAN set now that they're gone — otherwise sans.json
                // only ever grows (never wired up anywhere previously).
                let staleHosts = site.proxyHosts + childEnvs.map { $0.domainHost }
                try? await CertificateAuthority().removeLeafCoverage(staleHosts)
            case .env(let env):
                let parent = envelope.sites.first { $0.id == env.parentSiteID }
                let outcome = await ctx.worktrees.delete(env, parent: parent, keepBranch: true, keepWorktree: false)
                _ = try await ctx.persistence.mutate { store in
                    store.envs.removeAll { $0.id == env.id }
                    // The DB server was down, so the env's schemas are still there
                    // (issue #17). Tombstone them for the next shared-env create.
                    if let parent, let i = store.sites.firstIndex(where: { $0.id == parent.id }) {
                        for orphan in outcome.tombstonedSchemas where !store.sites[i].pendingSchemaDrops.contains(orphan) {
                            store.sites[i].pendingSchemaDrops.append(orphan)
                        }
                    }
                }
                if let parent { await ctx.lifecycle.stopSharedDatabaseIfUnused(parent: parent) }
                try? await CertificateAuthority().removeLeafCoverage([env.domainHost])
            }
            if output.json { emitLine(CLIJSON.string(CLIErrorJSON("ok", detail: "\(target) deleted"))) }
            else { emitLine("Deleted \(target).") }
        } catch {
            throw failCommand(error, json: output.json)
        }
    }
}

// MARK: - worktree

struct WorktreeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "worktree",
        abstract: "Manage git worktree environments.",
        subcommands: [WorktreeCreate.self, WorktreeList.self, WorktreeSettle.self, WorktreeRestore.self,
                      WorktreeDelete.self, WorktreeFixURLs.self]
    )
}

struct WorktreeCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a branch environment for a repo under a site's wp-content.",
        discussion: """
        The env starts with a clone of the parent's database. `--import <dump>` then \
        imports a .sql/.sql.gz dump into the env's own database, with the same \
        pipeline and options as `wp-container db import` (backup, URL migration to \
        the env's URL, scrub, media, local admin, rollback on failure). If the \
        import fails, the env is kept, rolled back to the parent's data, and the \
        command exits non-zero.
        """
    )
    @Option(name: .long, help: "Parent site slug.") var site: String
    @Option(name: .long, help: "Repo path relative to wordpress/ (e.g. wp-content/plugins/my-plugin).") var repo: String
    @Option(name: .long, help: "Branch name.") var branch: String
    @Option(name: .long, help: "Base ref for a new branch.") var from: String?
    @Flag(name: .long, help: "Skip seeding the worktree with the parent's gitignored runtime deps (vendor/, built assets, provisioned plugins); leaves a bare checkout.") var noProvision: Bool = false
    @Flag(name: .long, help: "Give the environment its own MariaDB container instead of a schema on the parent site's server. Costs ~470 MB of memory; worth it only for a very large database, where cloning the parent's data directory beats a logical dump+restore.") var isolatedDb: Bool = false
    @Option(name: .customLong("import"), help: "Import this .sql/.sql.gz dump into the new env's database.") var importDump: String?
    @OptionGroup var importFlags: DBImportFlags
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            // Check the dump before creating anything, so a typo can't leave a
            // half-wanted env behind.
            let dumpURL = importDump.map(DBImportFlags.expandPath)
            let importOptions = try dumpURL.map { _ in try importFlags.importOptions() }
            if let dumpURL {
                guard FileManager.default.fileExists(atPath: dumpURL.path) else {
                    throw CLIErrorJSON("dump_not_found", detail: dumpURL.path)
                }
                guard ["sql", "gz"].contains(dumpURL.pathExtension.lowercased()) else {
                    throw CLIErrorJSON("bad_args", detail: DatabaseImportError.invalidDumpExtension(dumpURL.lastPathComponent).description)
                }
            }
            let envelope = try await ctx.load()
            guard let parent = envelope.sites.first(where: { $0.slug == site }) else { throw CLIErrorJSON("site_not_found", detail: site) }
            guard WorktreeEnvService.isValidRepoRelPath(repo) else {
                throw CLIErrorJSON("invalid_repo_path", detail: WorktreeError.invalidRepoPath(repo).description)
            }
            try await ctx.unarchiveIfNeeded(siteID: parent.id)
            let running = await ctx.runningContainerNames()
            let parentRunning = running.contains(parent.wpContainerName)

            // Allocate the port AND reserve the env record in one locked store
            // mutation (#3), so a concurrent creator can't pick the same port
            // during the (long) creation flow below.
            let repoArg = repo
            let branchArg = branch
            guard let (_, reserved, _) = try await ctx.persistence.allocatePort(reserve: { port, store in
                WorktreeEnvService.reservedDescriptor(parent: parent, repoRelPath: repoArg,
                                                      branch: branchArg, port: port, into: &store)
            }) else { throw CLIErrorJSON("no_free_port") }

            let env: WorktreeEnv
            do {
                let outcome = try await ctx.worktrees.create(parent: parent, parentIsRunning: parentRunning,
                                                            repoRelPath: repo, branch: branch, from: from,
                                                            port: reserved.port, reserved: reserved,
                                                            provision: !noProvision, isolatedDB: isolatedDb)
                env = outcome.env
                let reaped = outcome.reapedSchemas
                _ = try await ctx.persistence.mutate { store in
                    store.envs.removeAll { $0.id == env.id }
                    store.envs.append(env)
                    // Clear exactly the tombstones whose DROP succeeded (#17); one
                    // that failed keeps its reminder for the next create.
                    if !reaped.isEmpty, let i = store.sites.firstIndex(where: { $0.id == parent.id }) {
                        store.sites[i].pendingSchemaDrops.removeAll { reaped.contains($0) }
                    }
                }
                for warning in await ctx.lifecycle.drainWarnings(for: env.id) {
                    FileHandle.standardError.write(Data(("warning: \(warning)\n").utf8))
                }
                // The env was created and started; its URL, though, is the
                // proxy's to serve (issue #16 follow-through).
                if let warning = ProxyControl.envProxyWarning(port: env.port) {
                    FileHandle.standardError.write(Data(("warning: \(warning)\n").utf8))
                }
            } catch {
                // Creation rolled back its containers/folders; also release the
                // reserved store record (and with it, the port).
                _ = try? await ctx.persistence.mutate { store in
                    store.envs.removeAll { $0.id == reserved.id }
                }
                throw error
            }
            guard let dumpURL, let importOptions else {
                if output.json { emitLine(CLIJSON.string(WorktreeDescriptor(from: env))) }
                else { emitLine("Created env \(env.envSlug) at \(env.url.absoluteString) (worktree: \(env.worktreePath.path)).") }
                return
            }
            if !output.json {
                emitLine("Created env \(env.envSlug) at \(env.url.absoluteString) (worktree: \(env.worktreePath.path)). Importing \(dumpURL.lastPathComponent)…")
            }
            try await importDump(dumpURL, into: env, options: importOptions, ctx: ctx)
        } catch let code as ExitCode {
            throw code
        } catch {
            throw failCommand(error, json: output.json)
        }
    }

    /// Import into the just-created env. A failed import keeps the env and exits
    /// non-zero; `--json` still prints `{env, import}`, with the import's error.
    private func importDump(_ dump: URL, into env: WorktreeEnv, options: DBImportOptions, ctx: CLIContext) async throws {
        let importer = DatabaseImportService(cli: ctx.cli, lifecycle: ctx.lifecycle)
        let jsonMode = output.json
        do {
            let summary = try await importer.importDatabase(into: env, publicURL: env.url, dump: dump, options: options) { phase in
                guard !jsonMode else { return }
                emitLine("→ \(DBImportCommand.progressLine(for: phase))")
            }
            if jsonMode {
                struct CreatedWithImport: Encodable { let env: WorktreeDescriptor; let `import`: DBImportResultJSON }
                emitLine(CLIJSON.string(CreatedWithImport(env: WorktreeDescriptor(from: env),
                                                          import: DBImportResultJSON(from: summary, site: env.envSlug))))
            } else {
                emitLine(DBImportCommand.summaryText(summary, site: env.envSlug))
            }
        } catch {
            let failure = DBImportFailureJSON(error)
            if jsonMode {
                struct CreatedWithFailedImport: Encodable { let env: WorktreeDescriptor; let `import`: DBImportFailureJSON }
                emitLine(CLIJSON.string(CreatedWithFailedImport(env: WorktreeDescriptor(from: env), import: failure)))
            } else {
                let note = failure.databaseIntact
                    ? "Env \(env.envSlug) was created with the parent's data; the import did not apply."
                    : "Env \(env.envSlug) was created, but its database could not be restored after the failed import."
                FileHandle.standardError.write(Data((note + "\n").utf8))
                DBImportCommand.reportImportError(failure, json: false)
            }
            throw ExitCode.failure
        }
    }
}

struct WorktreeList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List worktree envs.")
    @Option(name: .long, help: "Filter by parent site slug.") var site: String?
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            var envelope = try await ctx.load()
            let running = await ctx.runningContainerNames()
            for i in envelope.envs.indices {
                envelope.envs[i].status = running.contains(envelope.envs[i].wpContainerName) ? .running : .stopped
            }
            var envs = envelope.envs
            if let site { envs = envs.filter { $0.parentSlug == site } }
            if output.json { emitLine(CLIJSON.string(envs.map(EnvJSON.init))) }
            else {
                if envs.isEmpty { emitLine("No environments.") }
                for e in envs {
                    let state = e.isSettled ? "settled" : e.status.token
                    let days = EnvSettlement.daysUnused(e)
                    let unused = days == 0 ? "used today" : "unused \(days)d"
                    let hint = EnvSettlement.isStale(e) ? "  (consider: worktree settle \(e.envSlug))" : ""
                    emitLine("\(state)  \(e.envSlug)  \(e.branch)  \(e.url.absoluteString)  \(unused)\(hint)")
                }
            }
        } catch {
            throw failCommand(error, json: output.json)
        }
    }
}

struct WorktreeSettle: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settle",
        abstract: "Park an env: stop it and release its port, keeping its checkout, files and database.",
        discussion: """
        A settled environment drops out of the proxy and the app's sidebar, and \
        its port can be handed to a new environment. `worktree restore`, \
        `start`, or any command that needs it running (`wp`, `run`, `login`) \
        brings it back, on a new port if its old one was taken. The app purges \
        environments that stay settled past the window set in Settings \
        (30 days by default); a checkout with uncommitted changes is kept.
        """
    )
    @Argument(help: "Env slug.") var envSlug: String
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let envelope = try await ctx.load()
            guard let env = envelope.envs.first(where: { $0.envSlug == envSlug }) else { throw CLIErrorJSON("env_not_found", detail: envSlug) }
            let parent = envelope.sites.first { $0.id == env.parentSiteID }
            do { try await ctx.settler.settle(env, parent: parent) }
            catch let error as EnvSettlementError { throw CLIErrorJSON("settle_failed", detail: error.description) }
            if output.json { emitLine(CLIJSON.string(CLIErrorJSON("ok", detail: "\(envSlug) settled"))) }
            else { emitLine("Settled \(envSlug). Restore it with: wp-container worktree restore \(envSlug)") }
        } catch {
            throw failCommand(error, json: output.json)
        }
    }
}

struct WorktreeRestore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Bring a settled env back: re-acquire a port and start it."
    )
    @Argument(help: "Env slug.") var envSlug: String
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let envelope = try await ctx.load()
            guard let env = envelope.envs.first(where: { $0.envSlug == envSlug }) else { throw CLIErrorJSON("env_not_found", detail: envSlug) }
            guard env.isSettled else { throw CLIErrorJSON("not_settled", detail: "\(envSlug) is not settled") }
            let restored = try await ctx.restore(env, envelope: envelope)
            if output.json { emitLine(CLIJSON.string(WorktreeDescriptor(from: restored))) }
            else { emitLine("Restored \(envSlug) at \(restored.url.absoluteString).") }
        } catch {
            throw failCommand(error, json: output.json)
        }
    }
}

struct WorktreeDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a worktree env.")
    @Argument(help: "Env slug.") var envSlug: String
    @Flag(name: .long, help: "Keep the git branch.") var keepBranch = false
    @Flag(name: .long, help: "Keep the git worktree checkout on disk.") var keepWorktree = false
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let envelope = try await ctx.load()
            guard let env = envelope.envs.first(where: { $0.envSlug == envSlug }) else { throw CLIErrorJSON("env_not_found", detail: envSlug) }
            let parent = envelope.sites.first { $0.id == env.parentSiteID }
            let outcome = await ctx.worktrees.delete(env, parent: parent, keepBranch: keepBranch, keepWorktree: keepWorktree)
            _ = try await ctx.persistence.mutate { store in
                store.envs.removeAll { $0.id == env.id }
                // The DB server was down, so the env's schemas are still there
                // (issue #17). Tombstone them for the next shared-env create.
                if let parent, let i = store.sites.firstIndex(where: { $0.id == parent.id }) {
                    for orphan in outcome.tombstonedSchemas where !store.sites[i].pendingSchemaDrops.contains(orphan) {
                        store.sites[i].pendingSchemaDrops.append(orphan)
                    }
                }
            }
            if let parent { await ctx.lifecycle.stopSharedDatabaseIfUnused(parent: parent) }
            try? await CertificateAuthority().removeLeafCoverage([env.domainHost])
            if output.json { emitLine(CLIJSON.string(CLIErrorJSON("ok", detail: "\(envSlug) deleted"))) }
            else { emitLine("Deleted env \(envSlug).") }
        } catch {
            throw failCommand(error, json: output.json)
        }
    }
}

struct WorktreeFixURLs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fix-urls",
        abstract: "Repair a worktree env's URLs so every one of them points at its own domain.",
        discussion: """
        Detects the origins the environment's database ACTUALLY contains — \
        home/siteurl on every (sub)site, wp_blogs.domain, wp_site.domain, \
        DOMAIN_CURRENT_SITE — plus its parent site's URL and its own \
        http://127.0.0.1:<port>, and migrates each of them onto the \
        environment's domain, http(s)://<envSlug>.localhost (https when the \
        parent site uses HTTPS), with a full `wp search-replace \
        --all-tables` in every form a URL is written in (https://, http://, \
        protocol-relative //host, and the bare host that multisite domain \
        columns hold). Finishes by rewriting DOMAIN_CURRENT_SITE and any \
        hardcoded WP_HOME/WP_SITEURL in the environment's wp-config.php, which \
        override the database options entirely. The environment is then \
        advertised at its domain everywhere (an environment created before \
        environment domains keeps its 127.0.0.1 URL until this is run).

        Use --dry-run to see the counts without writing anything.

        A stopped environment is started first (a notice is printed to stderr); \
        pass --no-start to fail instead of waking it.
        """
    )
    @Argument(help: "Env slug.") var envSlug: String
    @Flag(name: .long, help: "Report what would change without writing anything.") var dryRun = false
    @Flag(name: .long, help: "Don't auto-start the environment if it's stopped; fail instead.") var noStart = false
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let envelope = try await ctx.load()
            guard let env = envelope.envs.first(where: { $0.envSlug == envSlug }) else {
                throw CLIErrorJSON("env_not_found", detail: envSlug)
            }
            let parent = envelope.sites.first { $0.id == env.parentSiteID }
            await ctx.persistence.recordActivity(instanceID: env.id)
            try await ctx.ensureRunning(.env(env), envelope: envelope, noStart: noStart)
            guard let dbHost = try await ctx.cli.ipAddress(of: env.dbContainerName) else {
                throw CLIErrorJSON("not_running", detail: "start \(envSlug) first")
            }

            let repair = try await ctx.worktrees.fixURLs(env: env, parent: parent, dbHost: dbHost, dryRun: dryRun)
            let report = repair.report
            let https = repair.https

            // Flip the record onto its domain so every surface advertises it.
            var migrated = env
            migrated.httpsEnabled = https
            migrated.usesDomainURL = true
            if !dryRun {
                let id = env.id
                _ = try await ctx.persistence.mutate { store in
                    guard let i = store.envs.firstIndex(where: { $0.id == id }) else { return }
                    store.envs[i].httpsEnabled = https
                    store.envs[i].usesDomainURL = true
                }
            }

            let warnings = repair.warnings
            if output.json {
                emitLine(CLIJSON.string(FixURLsJSON(envSlug: env.envSlug, url: migrated.url.absoluteString,
                                                    report: report, warnings: warnings)))
            } else {
                emitLine("\(dryRun ? "Would migrate" : "Migrated") \(env.envSlug) to \(migrated.url.absoluteString).")
                if report.origins.isEmpty {
                    emitLine("  No stale origins found.")
                }
                for origin in report.origins {
                    emitLine("  \(origin.origin) — \(origin.replacements) replacement\(origin.replacements == 1 ? "" : "s")")
                    for pass in origin.passes {
                        let count = pass.failed ? "failed" : pass.replacements.map(String.init) ?? "?"
                        emitLine("    \(pass.source) → \(pass.target)  [\(count)]")
                    }
                }
                for change in report.configUpdates {
                    emitLine("  wp-config.php: \(change.name) = \(change.value)")
                }
                emitLine("Total: \(report.replacements) replacement\(report.replacements == 1 ? "" : "s") across \(report.origins.count) origin\(report.origins.count == 1 ? "" : "s").")
                if dryRun { emitLine("Dry run — nothing was written.") }
                for warning in warnings {
                    FileHandle.standardError.write(Data(("warning: \(warning)\n").utf8))
                }
            }
        } catch {
            throw failCommand(error, json: output.json)
        }
    }
}

// MARK: - wp (proxied one-shot wp-cli)

struct WPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wp",
        abstract: "Run a one-shot wp-cli command against a site or env: wp-container wp <target> -- <wp args>",
        discussion: """
        JSON output: `--json` before <target> always works. As a convenience, a \
        `--json` between <target> and the `--` separator (e.g. `wp-container wp \
        mysite --json -- option get home`) is also treated as wp-container's own \
        flag. A --json AFTER `--` is passed through to wp-cli untouched.

        A stopped target is started first (a notice is printed to stderr); pass \
        --no-start to fail instead of waking it.
        """
    )
    @Argument(help: "Site slug or env slug.") var target: String
    @Argument(parsing: .captureForPassthrough, help: "wp-cli arguments (after --).") var wpArgs: [String] = []
    @Flag(name: .long, help: "Don't auto-start the target if it's stopped; fail instead.") var noStart = false
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        // `.captureForPassthrough` swallows everything after <target>, including
        // a `--json` the caller meant for wp-container itself (#8). Reclaim a
        // `--json` that appears BEFORE the literal `--` separator — tokens there
        // cannot be wp-cli arguments (the documented passthrough form puts wp
        // args after `--`). With no separator, only a LEADING `--json` is
        // reclaimed. A `--json` after `--` still reaches wp-cli verbatim.
        var passthroughArgs = wpArgs
        var jsonOut = output.json
        if let sep = passthroughArgs.firstIndex(of: "--") {
            let before = passthroughArgs[..<sep]
            if before.contains("--json") {
                jsonOut = true
                passthroughArgs = before.filter { $0 != "--json" } + passthroughArgs[sep...]
            }
        } else {
            while passthroughArgs.first == "--json" {
                jsonOut = true
                passthroughArgs.removeFirst()
            }
        }
        do {
            let envelope = try await ctx.load()
            guard let resolved = resolveTarget(target, in: envelope) else { throw CLIErrorJSON("not_found", detail: target) }
            let inst = resolved.instance
            // wp-cli against an instance is deliberate use of it, and it is
            // invisible to the proxy — record it so the idle sweep doesn't park
            // an environment somebody is actively scripting against (issue #16).
            await ctx.persistence.recordActivity(instanceID: inst.instanceID)
            // Wake it first (issue: only HTTP through the proxy did this before —
            // a one-shot `wp` against an idle-stopped target used to hard-fail).
            try await ctx.ensureRunning(resolved, envelope: envelope, noStart: noStart)
            guard let dbHost = try await ctx.cli.ipAddress(of: inst.dbContainerName) else {
                throw CLIErrorJSON("not_running", detail: "start \(target) first")
            }
            // `.captureForPassthrough` retains a literal "--" separator when the
            // caller uses the documented `wp-container wp <target> -- <wp args>`
            // form (e.g. `wp itest-alpha -- core version`); wp-cli itself treats
            // "--" as an unknown command, so strip a single leading occurrence.
            if passthroughArgs.first == "--" { passthroughArgs.removeFirst() }
            // Reach the running sidecars: wp_mail lands in Mailpit, ElasticPress finds Elasticsearch.
            let sidecarEnvironment = await SidecarAddons.environment(for: inst, cli: ctx.cli)
            let result = try await ctx.cli.runCapturing(SiteRecipe.wpProxyArgs(inst, dbHost: dbHost, wpArgs: passthroughArgs,
                                                                               sidecarEnvironment: sidecarEnvironment))
            if jsonOut {
                struct WPResult: Codable { let stdout: String; let stderr: String; let exitCode: Int32 }
                emitLine(CLIJSON.string(WPResult(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)))
            } else {
                if !result.stdout.isEmpty { FileHandle.standardOutput.write(Data(result.stdout.utf8)) }
                if !result.stderr.isEmpty { FileHandle.standardError.write(Data(result.stderr.utf8)) }
            }
            if result.exitCode != 0 { throw ExitCode(result.exitCode) }
        } catch let code as ExitCode {
            throw code
        } catch {
            throw failCommand(error, json: jsonOut)
        }
    }
}
