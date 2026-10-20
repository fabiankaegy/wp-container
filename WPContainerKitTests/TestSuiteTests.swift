import XCTest
@testable import WPContainerKit

/// Coverage for `wp-container test`: test schema naming, WordPress version
/// detection, the generated test config, the PHPUnit run args, the project
/// check, and the summary parser.
final class TestSuiteTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpc-testsuite-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Schema

    func testSchemaIsPerInstanceAndOutsideManagedEnvSchemas() {
        let name = TestSuite.databaseName(for: makeSite())
        XCTAssertEqual(name, "wpctests_example")
        XCTAssertFalse(WorktreeEnv.isManagedSchemaName(name))
        XCTAssertEqual(TestSuite.databaseName(for: makeEnv()), "wpctests_example_wt_feature")
    }

    func testLongSchemaNamesAreCappedAndStable() {
        let slug = String(repeating: "long-site-name-", count: 6)
        let site = Site(name: "Long", slug: slug, path: tempRoot.appendingPathComponent("long"), port: 8881,
                        imageTag: SiteRecipe.defaultWordPressImage)
        let name = TestSuite.databaseName(for: site)
        XCTAssertLessThanOrEqual(name.count, WorktreeEnv.maxSchemaNameLength)
        XCTAssertEqual(name, TestSuite.databaseName(for: site))
        XCTAssertTrue(name.hasPrefix(TestSuite.schemaPrefix))
    }

    func testTestSchemaNamesAreRecognized() {
        XCTAssertTrue(TestSuite.isTestSchemaName(TestSuite.databaseName(for: makeEnv())))
        XCTAssertFalse(TestSuite.isTestSchemaName("wpctests_"))
        XCTAssertFalse(TestSuite.isTestSchemaName("wpc_example_wt_feature"))
        XCTAssertFalse(TestSuite.isTestSchemaName("wpctests_x; DROP DATABASE wordpress"))
        XCTAssertFalse(TestSuite.isTestSchemaName("wpctests_" + String(repeating: "a", count: 60)))
    }

    func testOnlyEnvAndTestSchemasAreReapable() {
        XCTAssertTrue(WorktreeEnvService.isReapableSchemaName("wpc_example_wt_feature"))
        XCTAssertTrue(WorktreeEnvService.isReapableSchemaName("wpctests_example_wt_feature"))
        XCTAssertFalse(WorktreeEnvService.isReapableSchemaName(SiteRecipe.dbName))
        XCTAssertFalse(WorktreeEnvService.isReapableSchemaName("mysql"))
        XCTAssertFalse(WorktreeEnvService.isReapableSchemaName("wpctests"))
    }

    func testCreateTestDatabaseRunsInTheDatabaseContainer() {
        let args = SiteRecipe.createTestDatabaseArgs(makeEnv(), schema: "wpctests_example_wt_feature")
        XCTAssertEqual(Array(args.prefix(3)), ["exec", "wpc-example-wt-feature-db", "mariadb"])
        XCTAssertTrue(args.last!.contains("CREATE DATABASE IF NOT EXISTS `wpctests_example_wt_feature`"))
    }

    // MARK: - Version and library

    func testReadsTheWordPressVersion() throws {
        let wordpress = tempRoot.appendingPathComponent("wordpress", isDirectory: true)
        let includes = wordpress.appendingPathComponent("wp-includes", isDirectory: true)
        try FileManager.default.createDirectory(at: includes, withIntermediateDirectories: true)
        try "<?php\n$wp_version = '6.9.1';\n$wp_db_version = 60000;\n"
            .write(to: includes.appendingPathComponent("version.php"), atomically: true, encoding: .utf8)
        XCTAssertEqual(TestSuite.wordPressVersion(wordpressFolder: wordpress), "6.9.1")
        XCTAssertNil(TestSuite.wordPressVersion(wordpressFolder: tempRoot))
    }

    func testLibraryLivesBesideWordPress() {
        let site = makeSite()
        XCTAssertEqual(TestSuite.libraryFolder(for: site, version: "6.9.1").path,
                       site.path.appendingPathComponent("phpunit/wp-phpunit-6.9.1").path)
    }

    func testConfigRequiresATestSchema() {
        let config = TestSuite.configContents
        XCTAssertTrue(config.contains("$wpc_tests_db = getenv( 'WPC_TESTS_DB_NAME' );"))
        XCTAssertTrue(config.contains("exit( 1 );"))
        XCTAssertTrue(config.contains("define( 'ABSPATH', '/var/www/html/' );"))
        XCTAssertTrue(config.contains("$table_prefix = 'wptests_';"))
    }

    // MARK: - Run args

    func testRunArgsTargetTheTestSchemaOnTheSiteImage() throws {
        let site = makeSite()
        let library = tempRoot.appendingPathComponent("phpunit/wp-phpunit-6.9.1", isDirectory: true)
        let args = SiteRecipe.runTestsArgs(site, dbHost: "10.0.0.2", library: library, schema: "wpctests_example",
                                           workdir: "/var/www/html/wp-content/plugins/demo",
                                           phpunitArgs: ["--filter", "test_one"],
                                           polyfillsPath: "/var/www/html/wp-content/plugins/demo/vendor/yoast/phpunit-polyfills")
        XCTAssertTrue(containsPair(args, "-v", "\(library.path):\(TestSuite.libraryContainerPath)"))
        XCTAssertTrue(containsPair(args, "-e", "WP_TESTS_DIR=\(TestSuite.libraryContainerPath)"))
        XCTAssertTrue(containsPair(args, "-e", "WPC_TESTS_DB_NAME=wpctests_example"))
        let siteSchema = try XCTUnwrap(args.firstIndex(of: "WORDPRESS_DB_NAME=\(site.databaseName)"))
        let testSchema = try XCTUnwrap(args.firstIndex(of: "WORDPRESS_DB_NAME=wpctests_example"))
        XCTAssertGreaterThan(testSchema, siteSchema, "the test schema must override the site's")
        XCTAssertFalse(args.contains { $0.hasPrefix("PHP_INI_SCAN_DIR=") }, "tests run on stock PHP")
        let image = try XCTUnwrap(args.lastIndex(of: site.imageTag))
        XCTAssertEqual(Array(args[(image + 1)...]), ["vendor/bin/phpunit", "--filter", "test_one"])
    }

    func testRunArgsApplyTheTimeLimit() throws {
        let site = makeSite()
        let args = SiteRecipe.runTestsArgs(site, dbHost: "10.0.0.2", library: tempRoot, schema: "wpctests_example",
                                           workdir: "/var/www/html", phpunitArgs: [], timeLimit: 60)
        let image = try XCTUnwrap(args.lastIndex(of: site.imageTag))
        XCTAssertEqual(Array(args[(image + 1)...]), SiteRecipe.timeLimited(["vendor/bin/phpunit"], seconds: 60))
    }

    // MARK: - Project check

    func testHostPathIsTheInverseOfTheContainerPath() {
        let env = makeEnv()
        XCTAssertEqual(SiteRecipe.hostPath(forContainerPath: "/var/www/html/wp-content/plugins/demo/src", in: env)?.path,
                       env.worktreePath.appendingPathComponent("src").path)
        XCTAssertEqual(SiteRecipe.hostPath(forContainerPath: "/var/www/html/wp-content", in: env)?.path,
                       env.wordpressFolder.appendingPathComponent("wp-content").path)
        XCTAssertNil(SiteRecipe.hostPath(forContainerPath: "/tmp", in: env))
    }

    func testProjectCheckFindsPHPUnitAndPolyfills() throws {
        let site = makeSite()
        let project = site.wordpressFolder.appendingPathComponent("wp-content/plugins/demo", isDirectory: true)
        let workdir = "/var/www/html/wp-content/plugins/demo"
        XCTAssertThrowsError(try TestSuite.checkProject(workdir: workdir, in: site, slug: "example"))

        let bin = project.appendingPathComponent("vendor/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let phpunit = bin.appendingPathComponent("phpunit")
        try "#!/bin/sh\n".write(to: phpunit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: phpunit.path)
        XCTAssertNil(try TestSuite.checkProject(workdir: workdir, in: site, slug: "example"))

        try FileManager.default.createDirectory(at: project.appendingPathComponent("vendor/yoast/phpunit-polyfills"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(try TestSuite.checkProject(workdir: workdir, in: site, slug: "example"),
                       "\(workdir)/vendor/yoast/phpunit-polyfills")
    }

    // MARK: - Summary

    func testSummaryOfAPassingRun() {
        XCTAssertEqual(TestSuite.summary(fromOutput: "...\n\nOK (12 tests, 34 assertions)\n"),
                       TestSuite.Summary(passed: true, tests: 12, assertions: 34))
        XCTAssertEqual(TestSuite.summary(fromOutput: "OK (1 test, 1 assertion)")?.tests, 1)
    }

    func testSummaryOfAFailingRun() throws {
        let output = "FAILURES!\nTests: 5, Assertions: 9, Failures: 1, Errors: 2, Skipped: 1.\n"
        let summary = try XCTUnwrap(TestSuite.summary(fromOutput: output))
        XCTAssertFalse(summary.passed)
        XCTAssertEqual([summary.tests, summary.assertions, summary.failures, summary.errors, summary.skipped],
                       [5, 9, 1, 2, 1])
    }

    func testSummaryOfARunWithOnlySkips() throws {
        let output = "OK, but incomplete, skipped, or risky tests!\nTests: 3, Assertions: 2, Skipped: 1.\n"
        let summary = try XCTUnwrap(TestSuite.summary(fromOutput: output))
        XCTAssertTrue(summary.passed)
        XCTAssertEqual(summary.skipped, 1)
    }

    func testNoSummaryWithoutAResultLine() {
        XCTAssertNil(TestSuite.summary(fromOutput: "No tests executed!\n"))
    }

    // MARK: - Helpers

    private func makeSite() -> Site {
        Site(name: "Example", slug: "example", path: tempRoot.appendingPathComponent("example", isDirectory: true),
             port: 8881, imageTag: SiteRecipe.defaultWordPressImage)
    }

    private func makeEnv() -> WorktreeEnv {
        WorktreeEnv(parentSiteID: UUID(), parentSlug: "example", envSlug: "example-wt-feature",
                    repoRelPath: "wp-content/plugins/demo", branch: "feature",
                    worktreePath: tempRoot.appendingPathComponent("checkouts/feature", isDirectory: true),
                    envPath: tempRoot.appendingPathComponent("example/.envs/feature", isDirectory: true),
                    port: 8882, imageTag: SiteRecipe.defaultWordPressImage)
    }

    private func containsPair(_ args: [String], _ flag: String, _ value: String) -> Bool {
        zip(args, args.dropFirst()).contains { $0 == flag && $1 == value }
    }
}
