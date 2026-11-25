import ArgumentParser
import Foundation
import WPContainerKit

// MARK: - move

struct MoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move a site's folder into another folder.",
        discussion: """
        The site folder keeps its name: `wpc move example ~/Sites` moves it to \
        ~/Sites/example. Running containers of the site and its worktree envs \
        stop before the move and start again after it. The stored paths, the \
        wp shim, the agent-tools files and the git worktree links are updated.
        """
    )
    @Argument(help: "Site slug.") var slug: String
    @Argument(help: "Folder to move the site into, e.g. ~/Sites.") var parentFolder: String
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let envelope = try await ctx.load()
            guard let site = envelope.sites.first(where: { $0.slug == slug }) else {
                throw CLIErrorJSON("site_not_found", detail: slug)
            }
            let envs = envelope.envs.filter { $0.parentSiteID == site.id }
            let expanded = (parentFolder as NSString).expandingTildeInPath
            let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let parent = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded, isDirectory: true)
                : base.appendingPathComponent(expanded, isDirectory: true)
            let mover = SiteMover(cli: ctx.cli, lifecycle: ctx.lifecycle, git: ctx.git, persistence: ctx.persistence)
            let jsonMode = output.json
            let outcome = try await mover.move(site, envs: envs, toParent: parent) { phase in
                guard !jsonMode else { return }
                writeStderr("→ \(Self.progressLine(for: phase))")
            }
            if output.json {
                struct MoveJSON: Codable {
                    let ok: Bool
                    let slug: String
                    let from: String
                    let path: String
                    let restarted: [String]
                    let warnings: [String]
                }
                emitLine(CLIJSON.string(MoveJSON(ok: true, slug: outcome.site.slug, from: outcome.from.path,
                                                 path: outcome.site.path.path, restarted: outcome.restarted,
                                                 warnings: outcome.warnings)))
            } else {
                emitLine("Moved \(outcome.site.slug) to \(outcome.site.path.path)")
                if !outcome.restarted.isEmpty {
                    emitLine("Started again: \(outcome.restarted.joined(separator: ", "))")
                }
                for warning in outcome.warnings { emitLine("! \(warning)") }
            }
        } catch { throw failCommand(error, json: output.json) }
    }

    private static func progressLine(for phase: SiteMovePhase) -> String {
        switch phase {
        case .stopping: return "Stopping containers…"
        case .moving: return "Moving the folder…"
        case .updating: return "Updating paths and git links…"
        case .starting: return "Starting again…"
        }
    }
}

extension SiteMover.Failure {
    var cliError: CLIErrorJSON { CLIErrorJSON(code, detail: description) }
}
