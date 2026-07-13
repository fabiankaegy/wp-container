import ArgumentParser
import Foundation
import WPContainerKit

// MARK: - Root command

@main
struct WPContainerCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wp-container",
        abstract: "Manage local WordPress dev sites and git worktree environments running on Apple containers.",
        version: "0.1.0",
        subcommands: [
            ListCommand.self,
            CreateCommand.self,
            StartCommand.self,
            StopCommand.self,
            DeleteCommand.self,
            WorktreeCommand.self,
            WPCommand.self,
            MCPCommand.self,
            AgentToolsCommand.self,
            ShimCommand.self,
            HTTPSCommand.self,
            ProxyCommand.self,
            XdebugCommand.self,
            ElasticsearchCommand.self,
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

    func load() async throws -> StoreEnvelope { try await persistence.load() }

    /// Names of currently-running containers.
    func runningContainerNames() async -> Set<String> {
        guard let records = try? await cli.list(all: true) else { return [] }
        return Set(records.filter { $0.isRunning }.map { $0.name })
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
    let cliError = (error as? CLIErrorJSON) ?? CLIErrorJSON(humanText(error))
    if json {
        FileHandle.standardError.write(Data((CLIJSON.string(cliError) + "\n").utf8))
    } else {
        var line = cliError.error
        if let d = cliError.detail { line += ": \(d)" }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
    return ExitCode.failure
}

private func humanText(_ error: Error) -> String {
    if let e = error as? ContainerCLIError { return e.description }
    if let e = error as? LifecycleError { return e.description }
    if let e = error as? GitError { return e.description }
    if let e = error as? WorktreeError { return e.description }
    return "\(error)"
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
                    emitLine("\(e.status.token.padding(toLength: 8, withPad: " ", startingAt: 0))  \(e.envSlug) [env]  \(e.localURL.absoluteString)")
                }
            }
        } catch {
            throw failCommand(error, json: output.json)
        }
    }
}

// MARK: - create

struct CreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a new site (does not start it).")
    @Argument(help: "Site name.") var name: String
    @Option(name: .long, help: "Parent folder (default: ~/WP Container Sites).") var path: String?
    @Option(name: .long, help: "Full WordPress image tag override (e.g. wordpress:php8.3-apache).") var php: String?
    @Option(name: .long, help: "WordPress version: latest, 6.8, 6.7, 6.6.") var wp: String?
    @Option(name: .long, help: "PHP version: 8.4, 8.3, 8.2, 8.1.") var phpVersion: String?
    @Option(name: .long, help: "Multisite network: subdirectory | subdomain.") var multisite: String?
    @Option(name: .long, help: "Custom domain, e.g. mysite.local.") var domain: String?
    @Option(name: .long, help: "Sidebar group name (created if it doesn't exist).") var group: String?
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
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
            let siteDomain = customDomain
            let siteNetwork = networkType
            guard let (_, created, updated) = try await ctx.persistence.allocatePort(reserve: { port, env in
                var s = Site(name: siteName, slug: slug, path: sitePath,
                             port: port, imageTag: siteImageTag, phpVersion: sitePHPLabel,
                             customDomain: siteDomain, networkType: siteNetwork)
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
            try SiteFolders.ensure(for: created)
            // Write the per-site wp-cli shim at <site>/wp (§2e).
            try? WPCLIShim.writeShim(slug: created.slug, siteRoot: created.path,
                                     cliImage: WordPressImageCatalog.cliImage(for: created.imageTag))
            let resolvedGroupName = created.groupID.flatMap { id in updated.groups.first { $0.id == id }?.name }
            if output.json { emitLine(CLIJSON.string(SiteJSON(from: created, group: resolvedGroupName))) }
            else { emitLine("Created \(created.slug) at \(created.path.path) (port \(created.port))\(resolvedGroupName.map { " in group \"\($0)\"" } ?? "").") }
        } catch {
            throw failCommand(error, json: output.json)
        }
    }
}

// MARK: - start / stop / delete

struct StartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start a site (and all of its worktree envs) or a single env.",
        discussion: """
        Lifecycle is coupled (PLAN.md §2b): starting a SITE also starts every \
        worktree environment created from it — concurrently (they share nothing \
        at runtime); a failure in one does not abort the others (env failures \
        print as warnings). Starting an ENV slug starts just that environment.
        """
    )
    @Argument(help: "Site slug or env slug.") var target: String
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let envelope = try await ctx.load()
            guard let resolved = resolveTarget(target, in: envelope) else { throw CLIErrorJSON("not_found", detail: target) }
            switch resolved {
            case .site(let site):
                let envs = envelope.envs.filter { $0.parentSiteID == site.id }
                let outcome = await ctx.lifecycle.startSiteWithEnvs(site, envs: envs)
                if outcome.provisioned != site.provisioned {
                    _ = try await ctx.persistence.mutate { env in
                        if let i = env.sites.firstIndex(where: { $0.id == site.id }) { env.sites[i].provisioned = outcome.provisioned }
                    }
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
                // action for the same env in THIS process.
                _ = try await ctx.lifecycle.startInstance(env)
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
            switch resolved {
            case .site(let site):
                let envs = envelope.envs.filter { $0.parentSiteID == site.id }
                await ctx.lifecycle.stopSiteWithEnvs(site, envs: envs)
            case .env(let env):
                await ctx.lifecycle.stop(env)
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
                let staleHosts = site.proxyHosts + childEnvs.map { "\($0.envSlug).localhost" }
                try? await CertificateAuthority().removeLeafCoverage(staleHosts)
            case .env(let env):
                let parent = envelope.sites.first { $0.id == env.parentSiteID }
                await ctx.worktrees.delete(env, parent: parent, keepBranch: true, keepWorktree: false)
                _ = try await ctx.persistence.mutate { store in store.envs.removeAll { $0.id == env.id } }
                try? await CertificateAuthority().removeLeafCoverage(["\(env.envSlug).localhost"])
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
        subcommands: [WorktreeCreate.self, WorktreeList.self, WorktreeDelete.self]
    )
}

struct WorktreeCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a branch environment for a repo under a site's wp-content.")
    @Option(name: .long, help: "Parent site slug.") var site: String
    @Option(name: .long, help: "Repo path relative to wordpress/ (e.g. wp-content/plugins/my-plugin).") var repo: String
    @Option(name: .long, help: "Branch name.") var branch: String
    @Option(name: .long, help: "Base ref for a new branch.") var from: String?
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let envelope = try await ctx.load()
            guard let parent = envelope.sites.first(where: { $0.slug == site }) else { throw CLIErrorJSON("site_not_found", detail: site) }
            guard WorktreeEnvService.isValidRepoRelPath(repo) else {
                throw CLIErrorJSON("invalid_repo_path", detail: WorktreeError.invalidRepoPath(repo).description)
            }
            let running = await ctx.runningContainerNames()
            let parentRunning = running.contains(parent.wpContainerName)

            // Allocate the port AND reserve the env record in one locked store
            // mutation (#3), so a concurrent creator can't pick the same port
            // during the (long) creation flow below.
            let repoArg = repo
            let branchArg = branch
            guard let (_, reserved, _) = try await ctx.persistence.allocatePort(reserve: { port, store in
                let d = WorktreeEnvService.descriptor(parent: parent, repoRelPath: repoArg,
                                                      branch: branchArg, port: port)
                store.envs.append(d)
                return d
            }) else { throw CLIErrorJSON("no_free_port") }

            do {
                let env = try await ctx.worktrees.create(parent: parent, parentIsRunning: parentRunning,
                                                         repoRelPath: repo, branch: branch, from: from,
                                                         port: reserved.port, reserved: reserved)
                _ = try await ctx.persistence.mutate { store in
                    store.envs.removeAll { $0.id == env.id }
                    store.envs.append(env)
                }
                if output.json { emitLine(CLIJSON.string(WorktreeDescriptor(from: env))) }
                else { emitLine("Created env \(env.envSlug) at \(env.localURL.absoluteString) (worktree: \(env.worktreePath.path)).") }
            } catch {
                // Creation rolled back its containers/folders; also release the
                // reserved store record (and with it, the port).
                _ = try? await ctx.persistence.mutate { store in
                    store.envs.removeAll { $0.id == reserved.id }
                }
                throw error
            }
        } catch {
            throw failCommand(error, json: output.json)
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
                for e in envs { emitLine("\(e.status.token)  \(e.envSlug)  \(e.branch)  \(e.localURL.absoluteString)") }
            }
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
            await ctx.worktrees.delete(env, parent: parent, keepBranch: keepBranch, keepWorktree: keepWorktree)
            _ = try await ctx.persistence.mutate { store in store.envs.removeAll { $0.id == env.id } }
            try? await CertificateAuthority().removeLeafCoverage(["\(env.envSlug).localhost"])
            if output.json { emitLine(CLIJSON.string(CLIErrorJSON("ok", detail: "\(envSlug) deleted"))) }
            else { emitLine("Deleted env \(envSlug).") }
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
        Note: --json is captured as part of <wp args> (passthrough) if it appears \
        after <target>, so place it BEFORE <target> if you want JSON output for the \
        wp-container invocation itself: `wp-container wp --json <target> -- <wp args>`.
        """
    )
    @Argument(help: "Site slug or env slug.") var target: String
    @Argument(parsing: .captureForPassthrough, help: "wp-cli arguments (after --).") var wpArgs: [String] = []
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let envelope = try await ctx.load()
            guard let resolved = resolveTarget(target, in: envelope) else { throw CLIErrorJSON("not_found", detail: target) }
            let inst = resolved.instance
            guard let dbHost = try await ctx.cli.ipAddress(of: inst.dbContainerName) else {
                throw CLIErrorJSON("not_running", detail: "start \(target) first")
            }
            // `.captureForPassthrough` retains a literal "--" separator when the
            // caller uses the documented `wp-container wp <target> -- <wp args>`
            // form (e.g. `wp itest-alpha -- core version`); wp-cli itself treats
            // "--" as an unknown command, so strip a single leading occurrence.
            var passthroughArgs = wpArgs
            if passthroughArgs.first == "--" { passthroughArgs.removeFirst() }
            let result = try await ctx.cli.runCapturing(SiteRecipe.wpProxyArgs(inst, dbHost: dbHost, wpArgs: passthroughArgs))
            if output.json {
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
            throw failCommand(error, json: output.json)
        }
    }
}
