import ArgumentParser
import Foundation
import WPContainerKit

// MARK: - `wp-container run <target> -- <command>`

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a command inside a site or env: wp-container run <target> -- <command>",
        discussion: """
        The command runs in the target's WordPress container, with its database, \
        Mailpit, Elasticsearch, and PHP override environment. `--image` runs it \
        in a one-shot container of that image with the same mounts and \
        environment, for tools the WordPress image lacks: \
        `wp-container run mysite --image composer:2 -- composer install`.

        The working directory follows your current directory when it is inside \
        the target's wordpress/ folder or worktree checkout, and is /var/www/html \
        otherwise. `--workdir` sets it explicitly.

        A stopped target is started first (a notice is printed to stderr); pass \
        --no-start to fail instead of waking it.
        """
    )
    @Argument(help: "Site slug or env slug.") var target: String
    @Option(name: .shortAndLong, help: "Working directory in the container (absolute, or relative to /var/www/html).")
    var workdir: String?
    @Option(name: .shortAndLong, help: "Set an environment variable, KEY=VALUE (repeatable).") var env: [String] = []
    @Option(name: .long, help: "Run in a one-shot container of this image.") var image: String?
    @Flag(name: .long, help: "Don't auto-start the target if it's stopped; fail instead.") var noStart = false
    @OptionGroup var output: JSONOptions
    @Argument(parsing: .postTerminator, help: "The command and its arguments (after --).") var command: [String] = []

    func run() async throws {
        let ctx = CLIContext()
        let jsonOut = output.json
        do {
            guard !command.isEmpty else { throw CLIErrorJSON("bad_args", detail: "pass the command after --") }
            let envelope = try await ctx.load()
            guard let resolved = resolveTarget(target, in: envelope) else { throw CLIErrorJSON("not_found", detail: target) }
            let inst = resolved.instance
            await ctx.persistence.recordActivity(instanceID: inst.instanceID)
            try await ctx.ensureRunning(resolved, envelope: envelope, noStart: noStart)
            guard await ctx.lifecycle.isWPContainerRunning(inst) else {
                throw CLIErrorJSON("not_running", detail: "start \(target) first")
            }

            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let dir = SiteRecipe.runWorkdir(requested: workdir, hostCWD: cwd, in: inst)
            // JSON output is captured, so the command gets no stdin or TTY.
            let interactive = !jsonOut
            let tty = interactive && isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
            let args: [String]
            if let image {
                guard let dbHost = try await ctx.cli.ipAddress(of: inst.dbContainerName) else {
                    throw CLIErrorJSON("not_running", detail: "start \(target) first")
                }
                let sidecars = await ctx.sidecarAddresses(for: inst)
                args = SiteRecipe.runImageArgs(inst, image: image, dbHost: dbHost, command: command, workdir: dir,
                                               env: env, interactive: interactive, tty: tty,
                                               mailpitHost: sidecars.mailpitHost,
                                               elasticsearchURL: sidecars.elasticsearchURL)
            } else {
                args = SiteRecipe.execArgs(inst, command: command, workdir: dir, env: env,
                                           interactive: interactive, tty: tty)
            }

            if jsonOut {
                let result = try await ctx.cli.runCapturing(args)
                struct RunResult: Codable { let stdout: String; let stderr: String; let exitCode: Int32 }
                emitLine(CLIJSON.string(RunResult(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)))
                if result.exitCode != 0 { throw ExitCode(result.exitCode) }
            } else {
                try replaceProcess(executable: await ctx.cli.binaryPath, args: args)
            }
        } catch let code as ExitCode {
            throw code
        } catch {
            throw failCommand(error, json: jsonOut)
        }
    }
}

/// Replace this process with `executable`, so the command owns the terminal,
/// receives signals directly, and its exit status becomes this command's.
private func replaceProcess(executable: String, args: [String]) throws -> Never {
    let argv = ([executable] + args).map { strdup($0) } + [nil]
    execv(executable, argv)
    throw CLIErrorJSON("exec_failed", detail: String(cString: strerror(errno)))
}
