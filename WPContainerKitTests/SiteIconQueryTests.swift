import XCTest
@testable import WPContainerKit

/// Reading the table prefix and sanitizing the Site Icon path.
final class SiteIconQueryTests: XCTestCase {

    func testPrefixFromOfficialImageConfig() {
        let config = "<?php\n$table_prefix = getenv_docker('WORDPRESS_TABLE_PREFIX', 'wp_');\n"
        XCTAssertEqual(SiteIconQuery.tablePrefix(fromWPConfig: config), "wp_")
    }

    func testPrefixFromCRLFConfig() {
        let config = "<?php\r\ndefine( 'ABSPATH', __DIR__ );\r\n$table_prefix = getenv_docker('WORDPRESS_TABLE_PREFIX', 'wp_');\r\ndefine( 'WP_DEBUG', false );\r\n"
        XCTAssertEqual(SiteIconQuery.tablePrefix(fromWPConfig: config), "wp_")
    }

    func testPrefixFromPlainAssignment() {
        XCTAssertEqual(SiteIconQuery.tablePrefix(fromWPConfig: "$table_prefix  = \"nw7_\";"), "nw7_")
    }

    func testPrefixDefaultsAndRejectsUnsafeValues() {
        XCTAssertEqual(SiteIconQuery.tablePrefix(fromWPConfig: ""), "wp_")
        XCTAssertEqual(SiteIconQuery.tablePrefix(fromWPConfig: "$table_prefix = 'x; DROP TABLE';"), "wp_")
    }

    func testQueryUsesPrefix() {
        let sql = SiteIconQuery.sql(prefix: "nw7_")
        XCTAssertTrue(sql.contains("FROM nw7_options"))
        XCTAssertTrue(sql.contains("JOIN nw7_postmeta"))
    }

    func testUploadsPath() {
        XCTAssertEqual(SiteIconQuery.uploadsRelativePath("2026/06/cropped-icon.png\n"), "2026/06/cropped-icon.png")
        XCTAssertNil(SiteIconQuery.uploadsRelativePath(""))
        XCTAssertNil(SiteIconQuery.uploadsRelativePath("/etc/passwd"))
        XCTAssertNil(SiteIconQuery.uploadsRelativePath("../../wp-config.php"))
        XCTAssertNil(SiteIconQuery.uploadsRelativePath("a.png\nb.png"))
    }
}
