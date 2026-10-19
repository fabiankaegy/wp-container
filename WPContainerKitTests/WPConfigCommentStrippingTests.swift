import XCTest
@testable import WPContainerKit

/// Coverage for the wp-config comment stripper behind the shared-database
/// preflight: line endings, comment forms, and the DB_NAME check on top.
final class WPConfigCommentStrippingTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpc-wpconfig-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Stripping

    func testLineCommentsEndAtCRLF() {
        let stripped = WPConfigService.strippingPHPComments("<?php\r\n// a comment\r\ndefine( 'A', 1 );\r\n")
        XCTAssertTrue(stripped.contains("define( 'A', 1 );"))
        XCTAssertFalse(stripped.contains("a comment"))
    }

    func testLineCommentsEndAtLFAndCR() {
        XCTAssertTrue(WPConfigService.strippingPHPComments("# note\ndefine( 'A', 1 );").contains("define"))
        XCTAssertTrue(WPConfigService.strippingPHPComments("// note\rdefine( 'A', 1 );").contains("define"))
    }

    func testBlockCommentsKeepTheirLineBreaks() {
        let stripped = WPConfigService.strippingPHPComments("/**\r\n * Docs\r\n */\r\ndefine( 'A', 1 );")
        XCTAssertFalse(stripped.contains("Docs"))
        XCTAssertEqual(stripped.filter(\.isNewline).count, 3)
    }

    func testCommentMarkersInsideStringsAreKept() {
        let stripped = WPConfigService.strippingPHPComments("define( 'DB_NAME', 'shop#1' ); // x\r\n")
        XCTAssertTrue(stripped.contains("'shop#1'"))
    }

    // MARK: - DB_NAME follows the environment

    func testStockDockerConfigWithCRLFFollowsTheEnvironment() throws {
        try writeConfig("""
        <?php\r
        define( 'WP_ENVIRONMENT_TYPE', 'local' );
        /**\r
         * The base configuration for WordPress\r
         */\r
        \r
        // IMPORTANT: this file needs to stay in-sync with wp-config-sample.php\r
        // (it gets parsed by the upstream wizard in setup-config.php#L356-L392)\r
        \r
        // a helper function to lookup "env_FILE", "env", then fallback\r
        if (!function_exists('getenv_docker')) {\r
        \tfunction getenv_docker($env, $default) {\r
        \t\treturn getenv($env) ?: $default;\r
        \t}\r
        }\r
        \r
        /** The name of the database for WordPress */\r
        define( 'DB_NAME', getenv_docker('WORDPRESS_DB_NAME', 'wordpress') );\r
        """)
        XCTAssertTrue(WPConfigService.dbNameFollowsEnvironment(wordpressFolder: tempRoot))
    }

    func testHardcodedDBNameWithCRLFStillRefuses() throws {
        try writeConfig("<?php\r\n// define('DB_NAME', getenv_docker('WORDPRESS_DB_NAME', 'wordpress'));\r\ndefine('DB_NAME', 'wordpress');\r\n")
        XCTAssertFalse(WPConfigService.dbNameFollowsEnvironment(wordpressFolder: tempRoot))
    }

    // MARK: - Helpers

    private func writeConfig(_ contents: String) throws {
        try contents.write(to: tempRoot.appendingPathComponent("wp-config.php"), atomically: true, encoding: .utf8)
    }
}
