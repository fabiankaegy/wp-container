import ArgumentParser
import Foundation
import WPContainerKit

// MARK: - `wp-container test <target> -- <phpunit args>`

struct TestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Run a plugin or theme's PHPUnit tests against a site or env: wp-container test <target> -- <phpunit args>",
        discussion: """
        Runs `vendor/bin/phpunit` in a one-shot container of the target's own \
        WordPress image, against a dedicated test schema (`wpctests_<slug>`) on \
        its database server, so the suite never touches the site's data. The \
        WordPress test library matching the site's WordPress version is \
        downloaded once into the site's private phpunit/ folder; tests read \
        WP_TESTS_DIR as usual.

        The project directory follows your current directory when it is inside \
        the target's wordpress/ folder or worktree checkout. `--path` sets it \
        explicitly (absolute, or relative to /var/www/html). Install the \
        project's dev dependencies first: \
        `wp-container run <target> --image composer:2 -- composer install`.

        A stopped target is started first (a notice is printed to stderr); pass \
        --no-start to fail instead of waking it.
        """
    )
    @Argument(help: "Site slug or env slug.") var target: String
    @Option(name: .shortAndLong, help: "Project directory in the container (absolute, or relative to /var/www/html).")
    var path: String?
    @Flag(name: .long, help: "Don't auto-start the target if it's stopped; fail instead.") var noStart = false
    @OptionGroup var output: JSONOptions
    @Argument(parsing: .postTerminator, help: "PHPUnit arguments (after --).") var phpunitArgs: [String] = []

    func run() async throws {
        let ctx = CLIContext()
        let jsonOut = output.json
        do {
            let envelope = try await ctx.load()
            guard let resolved = resolveTarget(target, in: envelope) else { throw CLIErrorJSON("not_found", detail: target) }
            let inst = resolved.instance
            await ctx.persistence.recordActivity(instanceID: inst.instanceID)
            try await ctx.ensureRunning(resolved, envelope: envelope, noStart: noStart)
            guard let dbHost = try await ctx.cli.ipAddress(of: inst.dbContainerName) else {
                throw CLIErrorJSON("not_running", detail: "start \(target) first")
            }

            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let workdir = SiteRecipe.runWorkdir(requested: path, hostCWD: cwd, in: inst)
            let polyfills = try TestSuite.checkProject(workdir: workdir, in: inst, slug: target)

            if !jsonOut { FileHandle.standardError.write(Data("Preparing the WordPress test suite…\n".utf8)) }
            let (library, schema) = try await TestSuite.prepare(inst, cli: ctx.cli)
            let sidecarEnvironment = await SidecarAddons.environment(for: inst, cli: ctx.cli)
            let interactive = !jsonOut
            let tty = interactive && isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
            let args = SiteRecipe.runTestsArgs(inst, dbHost: dbHost, library: library, schema: schema,
                                               workdir: workdir, phpunitArgs: phpunitArgs, polyfillsPath: polyfills,
                                               interactive: interactive, tty: tty,
                                               sidecarEnvironment: sidecarEnvironment)
            if jsonOut {
                let result = try await ctx.cli.runCapturing(args)
                struct TestResult: Codable {
                    let stdout: String; let stderr: String; let exitCode: Int32
                    let summary: TestSuite.Summary?; let workdir: String; let schema: String
                }
                emitLine(CLIJSON.string(TestResult(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode,
                                                   summary: TestSuite.summary(fromOutput: result.stdout),
                                                   workdir: workdir, schema: schema)))
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
