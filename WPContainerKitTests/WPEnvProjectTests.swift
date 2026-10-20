import XCTest
@testable import WPContainerKit

/// Coverage for `create --wp-env`: source parsing, the override/env merge, the
/// plan (versions, mounts, installs, constants, warnings), and site mounts
/// reaching envs and the shell surfaces.
final class WPEnvProjectTests: XCTestCase {

    private var project: URL!

    override func setUpWithError() throws {
        project = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpc-wpenv-tests-\(UUID().uuidString)/example-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("mu-plugins"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: project.deletingLastPathComponent())
    }

    // MARK: - Sources

    func testParsesLocalPaths() {
        XCTAssertEqual(WPEnvSource.parse(".", relativeTo: project), .local(project.standardizedFileURL))
        XCTAssertEqual(WPEnvSource.parse("../sibling", relativeTo: project),
                       .local(project.deletingLastPathComponent().appendingPathComponent("sibling").standardizedFileURL))
        XCTAssertEqual(WPEnvSource.parse("/opt/example", relativeTo: project), .local(URL(fileURLWithPath: "/opt/example")))
        guard case .local(let home) = WPEnvSource.parse("~/example", relativeTo: project) else { return XCTFail("not local") }
        XCTAssertTrue(home.path.hasSuffix("/example") && !home.path.contains("~"))
    }

    func testParsesGitHubAndArchives() {
        XCTAssertEqual(WPEnvSource.parse("WordPress/gutenberg#trunk", relativeTo: project),
                       .github(owner: "WordPress", repo: "gutenberg", path: nil, ref: "trunk"))
        XCTAssertEqual(WPEnvSource.parse("example/themes/my-theme#v2", relativeTo: project),
                       .github(owner: "example", repo: "themes", path: "my-theme", ref: "v2"))
        XCTAssertEqual(WPEnvSource.parse("https://example.com/plugin.zip", relativeTo: project),
                       .zip(URL(string: "https://example.com/plugin.zip")!))
        XCTAssertEqual(WPEnvSource.parse("ssh://git@github.com/example/repo.git", relativeTo: project),
                       .unsupported("ssh://git@github.com/example/repo.git"))
        XCTAssertEqual(WPEnvSource.parse("https://example.com/page", relativeTo: project),
                       .unsupported("https://example.com/page"))
    }

    func testArchiveURLs() {
        XCTAssertEqual(WPEnvSource.github(owner: "example", repo: "plugin", path: nil, ref: nil).archiveURL?.absoluteString,
                       "https://github.com/example/plugin/archive/HEAD.zip")
        XCTAssertEqual(WPEnvSource.github(owner: "example", repo: "plugin", path: nil, ref: "v1.2").archiveURL?.absoluteString,
                       "https://github.com/example/plugin/archive/v1.2.zip")
        XCTAssertNil(WPEnvSource.github(owner: "example", repo: "mono", path: "plugins/one", ref: nil).archiveURL)
    }

    // MARK: - Merge

    func testOverrideMergesConfigAndMappingsAndReplacesTheRest() {
        let resolved = WPEnvProject.resolve(
            base: ["plugins": ["."], "config": ["A": true, "B": "x"], "mappings": ["wp-content/a": "./a"]],
            override: ["plugins": ["./other"], "config": ["B": "y", "C": 1], "mappings": ["wp-content/b": "./b"]],
            directory: project)
        XCTAssertEqual(resolved.plugins, ["./other"])
        XCTAssertEqual(resolved.config.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(resolved.config.first { $0.name == "B" }?.value, .string("y"))
        XCTAssertEqual(resolved.mappings.map(\.path), ["wp-content/a", "wp-content/b"])
    }

    func testDevelopmentEnvAppliesOnTop() {
        let resolved = WPEnvProject.resolve(
            base: ["phpVersion": "8.1", "config": ["A": true],
                   "env": ["development": ["phpVersion": "8.3", "config": ["B": false]], "tests": ["phpVersion": "7.4"]]],
            override: [:], directory: project)
        XCTAssertEqual(resolved.phpVersion, "8.3")
        XCTAssertEqual(resolved.config.map(\.name), ["A", "B"])
    }

    func testBooleansStayBooleans() {
        XCTAssertEqual(WPEnvValue(json: true as NSNumber), .bool(true))
        XCTAssertEqual(WPEnvValue(json: 1 as NSNumber), .number("1"))
        XCTAssertEqual(WPEnvValue(json: NSNull()), .null)
    }

    // MARK: - Plan

    func testCoreMapsToAnImageVersion() {
        XCTAssertEqual(plan(["core": "WordPress/WordPress#6.5.2"]).wordpressVersion, "6.5")
        XCTAssertEqual(plan(["core": "https://wordpress.org/wordpress-6.4.1.zip"]).wordpressVersion, "6.4")
        let trunk = plan(["core": "WordPress/WordPress#trunk"])
        XCTAssertNil(trunk.wordpressVersion)
        XCTAssertTrue(trunk.warnings.contains { $0.contains("using the latest WordPress") })
        XCTAssertNil(plan([:]).wordpressVersion)
    }

    func testLocalSourcesBecomeMounts() {
        let result = plan(["plugins": ["."], "themes": ["./mu-plugins"], "mappings": ["wp-content/mu-plugins": "./mu-plugins"]])
        XCTAssertEqual(result.mounts, [
            Mount(hostPath: project.appendingPathComponent("mu-plugins").path, containerPath: "/var/www/html/wp-content/mu-plugins"),
            Mount(hostPath: project.path, containerPath: "/var/www/html/wp-content/plugins/example-plugin"),
            Mount(hostPath: project.appendingPathComponent("mu-plugins").path, containerPath: "/var/www/html/wp-content/themes/mu-plugins"),
        ])
        XCTAssertEqual(result.activatePlugins, ["example-plugin"])
    }

    func testMissingLocalFoldersAndEscapingMappingsAreSkipped() {
        let result = plan(["plugins": ["./missing"],
                           "mappings": ["../../etc": "./mu-plugins", "wp-content/../../etc": "./mu-plugins", "x:ro": "./mu-plugins"]])
        XCTAssertTrue(result.warnings.contains { $0.contains("missing") && $0.contains("doesn't exist") })
        XCTAssertEqual(result.warnings.filter { $0.contains("leaves the WordPress folder") }.count, 3)
        XCTAssertEqual(result.mounts, [])
    }

    func testFoldersWithAColonAreSkipped() throws {
        try FileManager.default.createDirectory(at: project.appendingPathComponent("a:b"), withIntermediateDirectories: true)
        let result = plan(["plugins": ["./a:b"]])
        XCTAssertEqual(result.mounts, [])
        XCTAssertTrue(result.warnings.contains { $0.contains("can't be mounted") })
    }

    func testNestedMountsComeAfterTheirParentAndDuplicatesAreSkipped() throws {
        try FileManager.default.createDirectory(at: project.appendingPathComponent("plugins"), withIntermediateDirectories: true)
        let result = plan(["plugins": ["."],
                           "mappings": ["wp-content/plugins": "./plugins", "wp-content/plugins/example-plugin": "./mu-plugins"]])
        XCTAssertEqual(result.mounts, [
            Mount(hostPath: project.appendingPathComponent("plugins").path, containerPath: "/var/www/html/wp-content/plugins"),
            Mount(hostPath: project.path, containerPath: "/var/www/html/wp-content/plugins/example-plugin"),
        ])
        XCTAssertTrue(result.warnings.contains { $0.contains("already mounted") })
    }

    func testRemoteSourcesAreInstalled() {
        let result = plan(["plugins": ["example/plugin#v1", "https://example.com/two.zip", "example/mono/sub"],
                           "themes": ["https://example.com/theme.zip"]])
        XCTAssertEqual(result.installPlugins.map(\.absoluteString),
                       ["https://github.com/example/plugin/archive/v1.zip", "https://example.com/two.zip"])
        XCTAssertEqual(result.installThemes.map(\.absoluteString), ["https://example.com/theme.zip"])
        XCTAssertTrue(result.warnings.contains { $0.contains("example/mono/sub") })
    }

    func testConstantsKeepTheirTypes() {
        let result = plan(["config": ["FLAG": true, "LEVEL": 3, "NAME": "example", "UNSET": NSNull()]])
        XCTAssertEqual(result.constants.map { "\($0.name)=\($0.value) raw:\($0.raw)" },
                       ["FLAG=true raw:true", "LEVEL=3 raw:true", "NAME=example raw:false"])
        XCTAssertTrue(result.warnings.contains { $0.contains("UNSET") })
    }

    func testURLAndDatabaseConstantsAreIgnored() {
        let result = plan(["config": ["WP_HOME": "http://localhost:8888", "WP_SITEURL": "http://localhost:8888",
                                      "DB_HOST": "mysql", "WP_DEBUG": true]])
        XCTAssertEqual(result.constants.map(\.name), ["WP_DEBUG"])
        XCTAssertEqual(result.warnings.filter { $0.contains("sets the site's URL and database") }.count, 3)
    }

    func testIgnoredKeysAreReported() {
        let result = plan(["port": 8888, "lifecycleScripts": ["afterStart": "echo"]])
        XCTAssertTrue(result.warnings.contains { $0.hasPrefix("port is ignored") })
        XCTAssertTrue(result.warnings.contains { $0.hasPrefix("lifecycleScripts are ignored") })
    }

    // MARK: - Site mounts

    func testSiteMountsAreExtraMountsAndDecodeAsEmpty() throws {
        var site = makeSite()
        XCTAssertEqual(site.extraMounts, [])
        site.mounts = [Mount(hostPath: project.path, containerPath: "/var/www/html/wp-content/plugins/example-plugin")]
        XCTAssertEqual(site.extraMounts, site.mounts)
        let decoded = try JSONDecoder().decode(Site.self, from: JSONEncoder().encode(site))
        XCTAssertEqual(decoded.mounts, site.mounts)
    }

    func testEnvsInheritTheParentsMountsBeforeTheirCheckout() {
        var site = makeSite()
        site.mounts = [Mount(hostPath: project.path, containerPath: "/var/www/html/wp-content/plugins/example-plugin")]
        let env = WorktreeEnvService.descriptor(parent: site, repoRelPath: "wp-content/plugins/repo", branch: "feature", port: 8890)
        XCTAssertEqual(env.extraMounts.first, site.mounts.first)
        XCTAssertEqual(env.extraMounts.last?.containerPath, "/var/www/html/wp-content/plugins/repo")
    }

    func testShellSurfacesMountTheSiteMounts() throws {
        var site = makeSite()
        site.mounts = [Mount(hostPath: "/tmp/Example Project", containerPath: "/var/www/html/wp-content/plugins/example")]
        let flag = "-v '/tmp/Example Project:/var/www/html/wp-content/plugins/example'"
        let url = try WPCLIShim.writeShim(for: site, siteRoot: project, slug: site.slug)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains(flag))
        XCTAssertTrue(WPCLIShim.interactiveTerminalCommand(for: site, slug: site.slug).contains(flag))
    }

    // MARK: - Helpers

    private func plan(_ json: [String: Any]) -> WPEnvPlan {
        WPEnvPlan(project: WPEnvProject.resolve(base: json, override: [:], directory: project))
    }

    private func makeSite() -> Site {
        Site(name: "Example", slug: "example", path: project.deletingLastPathComponent().appendingPathComponent("site"),
             port: 8881, imageTag: SiteRecipe.defaultWordPressImage)
    }
}
