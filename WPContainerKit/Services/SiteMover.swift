import Foundation

/// Steps of `SiteMover.move`, reported at the start of each. `stopping` and
/// `starting` happen only when a container of the site or its envs runs.
public enum SiteMovePhase: String, Sendable {
    case stopping, moving, updating, starting
}

/// Moves a site's folder into another parent folder and updates every stored
/// path that points into it: the site record, its worktree envs, the mounts,
/// the agent-tools root, the `wp` shims and the git worktree links.
///
/// Containers bind-mount the site folder, so the running containers of the
/// site and its envs stop before the move and start again after it. A start
/// re-runs each container with the paths from the store.
public struct SiteMover: Sendable {
    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        /// The site is archived.
        case archived(String)
        /// A start or stop of the site or one of its envs is in progress.
        case busy(String)
        /// The site folder doesn't exist.
        case sourceMissing(String)
        /// The destination is the folder the site is already in.
        case sameFolder(String)
        /// Something already exists at the destination.
        case destinationExists(String)
        /// The destination is inside the site folder.
        case destinationInsideSite(String)
        /// The destination path contains `:`, which splits a `-v host:container` mount.
        case invalidDestination(String)
        /// A container of the site or one of its envs is still running after the stop.
        case stillRunning(String)
        /// The store kept the old path, so the folder moved back.
        case storeNotUpdated(String)

        /// Machine-readable error code for CLI and MCP JSON output.
        public var code: String {
            switch self {
            case .archived: return "site_archived"
            case .busy: return "site_busy"
            case .sourceMissing: return "site_folder_missing"
            case .sameFolder: return "same_folder"
            case .destinationExists: return "destination_exists"
            case .destinationInsideSite: return "destination_inside_site"
            case .invalidDestination: return "invalid_destination"
            case .stillRunning: return "still_running"
            case .storeNotUpdated: return "store_not_updated"
            }
        }

        public var description: String {
            switch self {
            case .archived(let slug):
                return "\(slug) is archived. Unarchive it before you move it."
            case .busy(let slug):
                return "\(slug) or one of its branch environments is starting or stopping. Try again when it finishes."
            case .sourceMissing(let path):
                return "The site folder \(path) doesn't exist."
            case .sameFolder(let path):
                return "The site is already at \(path)."
            case .destinationExists(let path):
                return "\(path) already exists."
            case .destinationInsideSite(let path):
                return "\(path) is inside the site folder."
            case .invalidDestination(let path):
                return "\(path) contains \":\", which a container mount can't use."
            case .stillRunning(let slug):
                return "A container of \(slug) is still running after the stop, so the folder was not moved. Run `container list --all` to find it."
            case .storeNotUpdated(let slug):
                return "The stored path of \(slug) did not change, so its folder moved back. Start the site again if it was running."
            }
        }
    }

    public struct Outcome: Sendable {
        /// The site record after the move.
        public var site: Site
        /// The folder the site was in before the move.
        public var from: URL
        /// Slugs of the site and envs that were running and started again.
        /// A start that failed is in `warnings`.
        public var restarted: [String]
        /// Problems after the folder moved. The move itself stands.
        public var warnings: [String]
    }

    let cli: ContainerCLI
    let lifecycle: SiteLifecycle
    let git: GitService
    let persistence: StorePersistence

    public init(cli: ContainerCLI, lifecycle: SiteLifecycle, git: GitService, persistence: StorePersistence) {
        self.cli = cli
        self.lifecycle = lifecycle
        self.git = git
        self.persistence = persistence
    }

    /// Where the site lands: its folder, under the same name, in `parent`.
    public static func destination(for site: Site, inParent parent: URL) -> URL {
        let name = URL(fileURLWithPath: lexicalPath(site.path)).lastPathComponent
        return URL(fileURLWithPath: lexicalPath(parent), isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    /// Throws a `Failure` when the site can't move to `destination`.
    public static func validate(_ site: Site, destination: URL) throws {
        let source = lexicalPath(site.path)
        let target = lexicalPath(destination)
        if site.isArchived { throw Failure.archived(site.slug) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.sourceMissing(source)
        }
        if target == source { throw Failure.sameFolder(source) }
        if target.hasPrefix(source + "/") { throw Failure.destinationInsideSite(target) }
        if target.contains(":") { throw Failure.invalidDestination(target) }
        if FileManager.default.fileExists(atPath: target) { throw Failure.destinationExists(target) }
    }

    /// `path` with its `old` prefix replaced by `new`, or nil when `path` is
    /// not `old` or inside it.
    public static func rebase(_ path: String, from old: String, to new: String) -> String? {
        if path == old { return new }
        guard path.hasPrefix(old + "/") else { return nil }
        return new + path.dropFirst(old.count)
    }

    /// Rewrites every stored path inside `old` to the same place inside `new`:
    /// site folders, agent-tools roots, mounts, and env checkouts and folders.
    public static func rebasePaths(in envelope: inout StoreEnvelope, from old: URL, to new: URL) {
        let oldPath = lexicalPath(old)
        let newPath = lexicalPath(new)
        func folder(_ url: URL) -> URL {
            guard let moved = rebase(lexicalPath(url), from: oldPath, to: newPath) else { return url }
            return URL(fileURLWithPath: moved, isDirectory: true)
        }
        func mounts(_ list: [Mount]) -> [Mount] {
            list.map { mount in
                guard let moved = rebase(mount.hostPath, from: oldPath, to: newPath) else { return mount }
                return Mount(hostPath: moved, containerPath: mount.containerPath)
            }
        }
        for i in envelope.sites.indices {
            envelope.sites[i].path = folder(envelope.sites[i].path)
            if let root = envelope.sites[i].agentToolsRoot, let moved = rebase(root, from: oldPath, to: newPath) {
                envelope.sites[i].agentToolsRoot = moved
            }
            envelope.sites[i].mounts = mounts(envelope.sites[i].mounts)
        }
        for i in envelope.envs.indices {
            envelope.envs[i].worktreePath = folder(envelope.envs[i].worktreePath)
            envelope.envs[i].envPath = folder(envelope.envs[i].envPath)
            envelope.envs[i].inheritedMounts = mounts(envelope.envs[i].inheritedMounts)
        }
    }

    /// `url`'s absolute path without `.` and `..` components. Symlinks stay
    /// as they are, so the result doesn't depend on what exists on disk.
    static func lexicalPath(_ url: URL) -> String {
        var parts: [Substring] = []
        for part in url.path.split(separator: "/") {
            switch part {
            case ".":
                continue
            case "..":
                if !parts.isEmpty { parts.removeLast() }
            default:
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// `url`'s path with every symlink resolved, `/private` included. Falls
    /// back to the path as given when it doesn't exist.
    static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Every container name an instance can run under: WordPress, database
    /// and each sidecar.
    static func containerNames(of inst: any RunnableInstance) -> Set<String> {
        Set([inst.wpContainerName, inst.dbContainerName] + SidecarAddons.all.map { $0.containerName(for: inst) })
    }

    /// Moves `site` (with `envs`, its worktree envs) into `parent`.
    ///
    /// The folder moves back when the store update fails. Problems after the
    /// store update (git links, shims, agent-tools files, restarts) are
    /// returned as warnings.
    public func move(
        _ site: Site,
        envs: [WorktreeEnv],
        toParent parent: URL,
        progress: @escaping @Sendable (SiteMovePhase) -> Void = { _ in }
    ) async throws -> Outcome {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: Self.lexicalPath(site.path), isDirectory: true)
        let destination = Self.destination(for: site, inParent: parent)
        try Self.validate(site, destination: destination)

        let instances: [any RunnableInstance] = [site] + envs
        for inst in instances where await lifecycle.isBusy(inst.instanceID) {
            throw Failure.busy(site.slug)
        }

        var warnings: [String] = []
        let running = try await runningContainerNames()
        let siteWasRunning = running.contains(site.wpContainerName)
        let runningEnvIDs = Set(envs.filter { running.contains($0.wpContainerName) }.map(\.id))
        let envsToStop = envs.filter { !Self.containerNames(of: $0).isDisjoint(with: running) }
        if !Self.containerNames(of: site).isDisjoint(with: running) || !envsToStop.isEmpty {
            progress(.stopping)
            await lifecycle.stopSiteWithEnvs(site, envs: envsToStop)
            for inst in instances { warnings += await lifecycle.drainWarnings(for: inst.instanceID) }
            let left = try await runningContainerNames()
            if instances.contains(where: { !Self.containerNames(of: $0).isDisjoint(with: left) }) {
                throw Failure.stillRunning(site.slug)
            }
        }

        progress(.moving)
        // Git stores real paths, which differ from `source` when it has a symlink.
        let sourceRealPath = Self.realPath(source)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: source, to: destination)
        let updated: StoreEnvelope
        do {
            updated = try await persistence.mutate { envelope in
                Self.rebasePaths(in: &envelope, from: source, to: destination)
            }
        } catch {
            try? fm.moveItem(at: destination, to: source)
            throw error
        }

        // A start with the old path would fill empty folders there with a
        // new install, so nothing starts unless the store has the new path.
        guard let moved = updated.sites.first(where: { $0.id == site.id }),
              Self.lexicalPath(moved.path) == Self.lexicalPath(destination) else {
            try? fm.moveItem(at: destination, to: source)
            throw Failure.storeNotUpdated(site.slug)
        }
        let movedEnvs = updated.envs.filter { $0.parentSiteID == site.id }

        progress(.updating)
        let movedPaths = [(source.path, destination.path), (sourceRealPath, Self.realPath(destination))]
        warnings += await repairWorktrees(of: moved, envs: movedEnvs, movedPaths: movedPaths)
        warnings += rewriteSurfaces(of: moved)

        let envsToStart = movedEnvs.filter { runningEnvIDs.contains($0.id) }
        var started: [any RunnableInstance] = envsToStart
        if siteWasRunning || !envsToStart.isEmpty { progress(.starting) }
        if siteWasRunning {
            started.insert(moved, at: 0)
            let outcome = await lifecycle.startSiteWithEnvs(moved, envs: envsToStart)
            if let summary = outcome.errorSummary { warnings.append(summary) }
            warnings += outcome.warnings
        } else {
            for env in envsToStart {
                do { try await lifecycle.startInstance(env, dbProvider: moved) }
                catch { warnings.append("Could not start \(env.envSlug) again: \(error)") }
            }
        }
        let nowRunning = started.isEmpty ? [] : ((try? await runningContainerNames()) ?? [])
        let restarted = started.filter { nowRunning.contains($0.wpContainerName) }.map(\.containerSlug)
        return Outcome(site: moved, from: source, restarted: restarted, warnings: warnings)
    }

    // MARK: - Steps

    private func runningContainerNames() async throws -> Set<String> {
        Set(try await cli.list(all: true).filter(\.isRunning).map(\.name))
    }

    /// Reconnects each git repo in the moved site with its linked worktrees.
    /// Main worktrees go first: a linked worktree inside the site can only
    /// find its repo again after the repo's own repair.
    ///
    /// `movedPaths` holds the old and new site folder, as given and as real
    /// paths.
    private func repairWorktrees(of site: Site, envs: [WorktreeEnv], movedPaths: [(String, String)]) async -> [String] {
        let fm = FileManager.default
        var candidates = [site.wordpressFolder]
        candidates += await git.repos(under: site.wordpressFolder).map(\.absolutePath)
        candidates += envs.map { site.wordpressFolder.appendingPathComponent($0.repoRelPath, isDirectory: true) }

        var seen = Set<String>()
        var mainRepos: [URL] = []
        var linkedRepos: [URL] = []
        for repo in candidates {
            let path = Self.lexicalPath(repo)
            guard seen.insert(path).inserted else { continue }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: repo.appendingPathComponent(".git").path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue { mainRepos.append(repo) } else { linkedRepos.append(repo) }
        }

        var warnings: [String] = []
        for repo in mainRepos {
            do {
                let moved = try await git.worktreePaths(repo: repo).compactMap { path in
                    movedPaths.lazy.compactMap { Self.rebase(path, from: $0.0, to: $0.1) }.first
                }.filter { fm.fileExists(atPath: $0) }
                try await git.worktreeRepair(repo: repo, paths: moved)
            } catch {
                warnings.append("Could not repair the git worktrees of \(repo.path): \(error)")
            }
        }
        for repo in linkedRepos {
            do { try await git.worktreeRepair(repo: repo, paths: []) }
            catch { warnings.append("Could not repair the git worktree at \(repo.path): \(error)") }
        }
        return warnings
    }

    /// Rewrites the files that contain the site's absolute paths: the `wp`
    /// shim in the site folder and, when agent tools are on, their files.
    private func rewriteSurfaces(of site: Site) -> [String] {
        var warnings: [String] = []
        do { try WPCLIShim.writeShim(for: site, siteRoot: site.path, slug: site.slug) }
        catch { warnings.append("Could not rewrite the wp shim of \(site.slug): \(error)") }

        guard AgentToolsService.isEnabled(site: site) else { return warnings }
        let root = site.agentToolsRoot.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? site.path
        // A root inside `wordpress/` is a repo, whose path the doc block names.
        let wordpress = Self.lexicalPath(site.wordpressFolder)
        let rootPath = Self.lexicalPath(root)
        let repoRelPath = rootPath.hasPrefix(wordpress + "/") ? String(rootPath.dropFirst(wordpress.count + 1)) : nil
        do { try AgentToolsService.enable(site: site, root: root, docName: site.agentToolsDoc, repoRelPath: repoRelPath) }
        catch { warnings.append("Could not rewrite the agent-tools files of \(site.slug): \(error)") }
        return warnings
    }
}
