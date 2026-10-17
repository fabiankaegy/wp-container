import XCTest
@testable import WPContainerKit

/// Coverage for `wp-container run`: working-directory mapping, the `exec` and
/// one-shot `run` argument shapes, and the in-container time limit.
final class RunCommandTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/tmp/wpc-run-tests/example", isDirectory: true)

    private var site: Site {
        Site(name: "Example", slug: "example", path: root, port: 8881, imageTag: SiteRecipe.defaultWordPressImage)
    }

    private var env: WorktreeEnv {
        WorktreeEnv(parentSiteID: UUID(), parentSlug: "example", envSlug: "example-wt-feature",
                    repoRelPath: "wp-content/plugins/demo", branch: "feature",
                    worktreePath: URL(fileURLWithPath: "/tmp/wpc-run-tests/checkouts/demo-feature", isDirectory: true),
                    envPath: URL(fileURLWithPath: "/tmp/wpc-run-tests/example-wt-feature", isDirectory: true),
                    port: 8882, imageTag: SiteRecipe.defaultWordPressImage)
    }

    // MARK: - Working directory

    func testWordPressFolderMapsToDocumentRoot() {
        XCTAssertEqual(SiteRecipe.containerPath(forHostPath: site.wordpressFolder, in: site), "/var/www/html")
    }

    func testSubfolderMapsBelowDocumentRoot() {
        let plugins = site.wordpressFolder.appendingPathComponent("wp-content/plugins", isDirectory: true)
        XCTAssertEqual(SiteRecipe.containerPath(forHostPath: plugins, in: site), "/var/www/html/wp-content/plugins")
    }

    func testSiblingWithSharedPrefixDoesNotMap() {
        let sibling = root.appendingPathComponent("wordpress-backup", isDirectory: true)
        XCTAssertNil(SiteRecipe.containerPath(forHostPath: sibling, in: site))
    }

    func testWorktreeCheckoutMapsToItsShadowMount() {
        let src = env.worktreePath.appendingPathComponent("src", isDirectory: true)
        XCTAssertEqual(SiteRecipe.containerPath(forHostPath: src, in: env),
                       "/var/www/html/wp-content/plugins/demo/src")
    }

    func testWorkdirDefaultsToDocumentRootOutsideTheInstance() {
        let elsewhere = URL(fileURLWithPath: "/tmp/elsewhere", isDirectory: true)
        XCTAssertEqual(SiteRecipe.runWorkdir(requested: nil, hostCWD: elsewhere, in: site), "/var/www/html")
    }

    func testRequestedWorkdirIsRelativeToDocumentRoot() {
        XCTAssertEqual(SiteRecipe.runWorkdir(requested: "wp-content", hostCWD: site.wordpressFolder, in: site),
                       "/var/www/html/wp-content")
        XCTAssertEqual(SiteRecipe.runWorkdir(requested: "/tmp", hostCWD: site.wordpressFolder, in: site), "/tmp")
    }

    // MARK: - Arguments

    func testExecTargetsTheWordPressContainer() {
        let args = SiteRecipe.execArgs(site, command: ["php", "-v"], workdir: "/var/www/html",
                                       env: ["FOO=bar"], interactive: true, tty: true)
        XCTAssertEqual(args, ["exec", "-i", "-t", "-w", "/var/www/html", "-e", "FOO=bar",
                              site.wpContainerName, "php", "-v"])
    }

    func testRunImageCarriesMountsAndEnvironment() throws {
        let args = SiteRecipe.runImageArgs(env, image: "composer:2", dbHost: "10.0.0.2", command: ["composer", "install"],
                                           workdir: "/var/www/html", env: ["FOO=bar"],
                                           mailpitHost: "10.0.0.3", elasticsearchURL: "http://10.0.0.4:9200")
        XCTAssertEqual(Array(args.prefix(2)), ["run", "--rm"])
        XCTAssertTrue(containsPair(args, "-v", "\(env.wordpressFolder.path):/var/www/html"))
        XCTAssertTrue(containsPair(args, "-v", "\(env.worktreePath.path):/var/www/html/wp-content/plugins/demo"))
        XCTAssertTrue(containsPair(args, "-e", "WORDPRESS_DB_HOST=10.0.0.2"))
        XCTAssertTrue(containsPair(args, "-e", "WPC_MAILPIT_HOST=10.0.0.3"))
        XCTAssertTrue(containsPair(args, "-e", "EP_HOST=http://10.0.0.4:9200"))
        let imageIndex = try XCTUnwrap(args.firstIndex(of: "composer:2"))
        XCTAssertEqual(Array(args[imageIndex...]), ["composer:2", "composer", "install"])
        let userEnvIndex = try XCTUnwrap(args.firstIndex(of: "FOO=bar"))
        let dbEnvIndex = try XCTUnwrap(args.firstIndex(of: "WORDPRESS_DB_HOST=10.0.0.2"))
        XCTAssertGreaterThan(userEnvIndex, dbEnvIndex, "user env must follow the defaults so it overrides them")
    }

    // MARK: - Time limit

    func testTimeLimitedPassesArgumentsThrough() throws {
        let output = try runShell(SiteRecipe.timeLimited(["sh", "-c", #"printf '%s|' "$0" "$@""#, "a b", "c"], seconds: 5))
        XCTAssertEqual(output.stdout, "a b|c|")
        XCTAssertEqual(output.status, 0)
    }

    func testTimeLimitedKeepsTheExitStatus() throws {
        let output = try runShell(SiteRecipe.timeLimited(["sh", "-c", "exit 3"], seconds: 5))
        XCTAssertEqual(output.status, 3)
    }

    // MARK: - Helpers

    private func containsPair(_ args: [String], _ flag: String, _ value: String) -> Bool {
        zip(args, args.dropFirst()).contains { $0 == flag && $1 == value }
    }

    /// Runs `command` on the host with `/usr/bin/env` resolving the program.
    private func runShell(_ command: [String]) throws -> (stdout: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }
}
