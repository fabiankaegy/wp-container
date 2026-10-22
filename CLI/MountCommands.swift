import ArgumentParser
import Foundation
import WPContainerKit

// MARK: - mount

struct MountCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mount",
        abstract: "List, add, or remove host folders bind-mounted into a site.",
        discussion: """
        A mounted folder appears inside the site's WordPress folder, and edits \
        in it reach the site live. Container paths are relative to the \
        WordPress folder (wp-content/plugins/example) or absolute under \
        /var/www/html. A running site restarts to apply a change. Worktree envs \
        created afterwards inherit the site's mounts; existing envs keep theirs.
        """,
        subcommands: [MountList.self, MountAdd.self, MountRemove.self]
    )
}

struct MountList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List a site's mounts.")
    @Argument(help: "Site slug.") var slug: String
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let site = try await mountSite(slug, ctx: ctx)
            if output.json {
                struct MountListJSON: Codable { let slug: String; let mounts: [Mount] }
                emitLine(CLIJSON.string(MountListJSON(slug: site.slug, mounts: site.mounts)))
            } else if site.mounts.isEmpty {
                emitLine("\(site.slug) has no mounts.")
            } else {
                for mount in site.mounts { emitLine("\(mount.hostPath) → \(mount.containerPath)") }
            }
        } catch { throw failCommand(error, json: output.json) }
    }
}

struct MountAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Mount a host folder into a site.")
    @Argument(help: "Site slug.") var slug: String
    @Argument(help: "Host folder to mount.") var hostFolder: String
    @Argument(help: "Where it appears, e.g. wp-content/plugins/example.") var containerPath: String
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let mount = try SiteMounts.mount(hostPath: hostFolder, containerPath: containerPath, relativeTo: base)
            let site = try await mountSite(slug, ctx: ctx)
            let mounts = try SiteMounts.adding(mount, to: site.mounts)
            try await applyMounts(mounts, to: site, ctx: ctx, output: output,
                                  label: "Mounted \(mount.hostPath) → \(mount.containerPath)")
        } catch { throw failCommand(error, json: output.json) }
    }
}

struct MountRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove a mount from a site.")
    @Argument(help: "Site slug.") var slug: String
    @Argument(help: "Container path of the mount, e.g. wp-content/plugins/example.") var containerPath: String
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let site = try await mountSite(slug, ctx: ctx)
            let mounts = try SiteMounts.removing(containerPath: containerPath, from: site.mounts)
            let path = try SiteMounts.containerPath(containerPath)
            try await applyMounts(mounts, to: site, ctx: ctx, output: output,
                                  label: "Removed the mount at \(path)")
            SiteMounts.removeEmptyMountpoint(path, in: site.wordpressFolder)
        } catch { throw failCommand(error, json: output.json) }
    }
}

private func mountSite(_ slug: String, ctx: CLIContext) async throws -> Site {
    let envelope = try await ctx.load()
    guard let site = envelope.sites.first(where: { $0.slug == slug }) else {
        throw CLIErrorJSON("site_not_found", detail: slug)
    }
    return site
}

/// Saves `mounts` on the site, rewrites its `wp` shim, and restarts the site
/// when it is running. JSON: `{ok, slug, mounts, restarted}`.
private func applyMounts(_ mounts: [Mount], to site: Site, ctx: CLIContext,
                         output: JSONOptions, label: String) async throws {
    let updated = try await ctx.persistence.mutate { env in
        if let i = env.sites.firstIndex(where: { $0.id == site.id }) { env.sites[i].mounts = mounts }
    }
    let newSite = updated.sites.first { $0.id == site.id } ?? site
    try? WPCLIShim.writeShim(for: newSite, siteRoot: newSite.path, slug: newSite.slug)
    var restarted = false
    if await ctx.runningContainerNames().contains(site.wpContainerName) {
        await ctx.lifecycle.stop(newSite)
        _ = try await ctx.lifecycle.startSite(newSite)
        await ctx.lifecycle.markRunning(newSite.id)
        restarted = true
    }
    if output.json {
        struct MountChangeJSON: Codable { let ok: Bool; let slug: String; let mounts: [Mount]; let restarted: Bool }
        emitLine(CLIJSON.string(MountChangeJSON(ok: true, slug: newSite.slug, mounts: newSite.mounts, restarted: restarted)))
    } else {
        emitLine("\(label) for \(newSite.slug).\(restarted ? " Restarted to apply." : " Applies on the next start.")")
    }
}

extension SiteMounts.Failure {
    var cliError: CLIErrorJSON { CLIErrorJSON(code, detail: description) }
}
