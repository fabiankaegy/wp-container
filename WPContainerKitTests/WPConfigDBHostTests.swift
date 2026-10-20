import XCTest
@testable import WPContainerKit

final class WPConfigDBHostTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpc-dbhost-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testDBHostFromEnvironment() throws {
        try writeConfig("<?php\ndefine('DB_HOST', getenv_docker('WORDPRESS_DB_HOST', 'mysql'));\n")
        XCTAssertTrue(WPConfigService.dbHostFollowsEnvironment(wordpressFolder: tempRoot))
    }

    func testHardcodedDBHost() throws {
        try writeConfig("<?php\ndefine('DB_HOST', '127.0.0.1');\n")
        XCTAssertFalse(WPConfigService.dbHostFollowsEnvironment(wordpressFolder: tempRoot))
    }

    func testCommentedEnvAboveHardcoded() throws {
        try writeConfig("""
        <?php
        // define('DB_HOST', getenv_docker('WORDPRESS_DB_HOST', 'mysql'));
        define('DB_HOST', '127.0.0.1');
        """)
        XCTAssertFalse(WPConfigService.dbHostFollowsEnvironment(wordpressFolder: tempRoot))
    }

    func testMissingConfig() {
        XCTAssertTrue(WPConfigService.dbHostFollowsEnvironment(wordpressFolder: tempRoot))
    }

    private func writeConfig(_ text: String) throws {
        try text.write(to: tempRoot.appendingPathComponent("wp-config.php"), atomically: true, encoding: .utf8)
    }
}
