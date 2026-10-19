import XCTest
@testable import WPContainerKit

/// Coverage for the in-container readiness checks the lifecycle falls back to
/// when the host can't reach a container IP (no Local Network permission).
final class ReadinessProbeTests: XCTestCase {

    private let site = Site(name: "Example", slug: "example",
                            path: URL(fileURLWithPath: "/tmp/wpc-probe-tests/example", isDirectory: true),
                            port: 8881, imageTag: SiteRecipe.defaultWordPressImage)

    func testHTTPProbeAsksTheWebServerInsideItsContainer() {
        XCTAssertEqual(SiteRecipe.wpHTTPProbeArgs(site),
                       ["exec", "wpc-example-wp", "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                        "--max-time", "5", "http://127.0.0.1/"])
    }

    func testAnyHTTPStatusMeansTheServerAnswers() {
        XCTAssertTrue(SiteRecipe.isHTTPStatus("200"))
        XCTAssertTrue(SiteRecipe.isHTTPStatus("302\n"))
        XCTAssertTrue(SiteRecipe.isHTTPStatus("500"))
        XCTAssertFalse(SiteRecipe.isHTTPStatus("000"))
        XCTAssertFalse(SiteRecipe.isHTTPStatus(""))
        XCTAssertFalse(SiteRecipe.isHTTPStatus("curl: not found"))
    }

    func testDatabaseHealthcheckRunsInTheDatabaseContainer() {
        XCTAssertEqual(SiteRecipe.databaseHealthcheckArgs(site),
                       ["exec", "wpc-example-db", "healthcheck.sh", "--connect", "--innodb_initialized"])
    }
}
