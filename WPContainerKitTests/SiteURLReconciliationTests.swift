import XCTest
@testable import WPContainerKit

/// Covers how a site's stored `home`/`siteurl` values are compared with the
/// URL it is served at: full migration for a main site on another host, a
/// scheme flip per host otherwise.
final class SiteURLReconciliationTests: XCTestCase {

    private func rows(_ pairs: [(String, String)]) -> [SiteURLReconciliation.Row] {
        pairs.map { SiteURLReconciliation.Row(table: $0.0, value: $0.1) }
    }

    func testMatchingURLsNeedNothing() {
        let plan = SiteURLReconciliation.plan(
            rows: rows([("wp_options", "https://net.test"), ("wp_options", "https://net.test/wp"),
                        ("wp_2_options", "https://net.test/shop")]),
            mainTable: "wp_options", target: URL(string: "https://net.test")!)
        XCTAssertTrue(plan.isEmpty)
    }

    func testHTTPSEnabledWhileStoppedFlipsEveryHost() {
        let plan = SiteURLReconciliation.plan(
            rows: rows([("wp_options", "http://net.test"), ("wp_2_options", "http://blog.net.test"),
                        ("wp_3_options", "http://other.test"), ("wp_4_options", "https://shop.net.test")]),
            mainTable: "wp_options", target: URL(string: "https://net.test")!)
        XCTAssertEqual(plan.staleOrigins, [])
        XCTAssertEqual(plan.schemeFixes, ["net.test", "blog.net.test", "other.test"])
    }

    func testMainSiteOnAnotherHostNeedsMigration() {
        let plan = SiteURLReconciliation.plan(
            rows: rows([("wp_options", "http://127.0.0.1:8900"), ("wp_options", "http://127.0.0.1:8900"),
                        ("wp_2_options", "http://127.0.0.1:8900/shop")]),
            mainTable: "wp_options", target: URL(string: "https://net.localhost")!)
        XCTAssertEqual(plan.staleOrigins, ["127.0.0.1:8900"])
        XCTAssertEqual(plan.schemeFixes, [])
    }

    func testStaleNetworkDomainMigratesItsSubsitesInsteadOfFlippingThem() {
        let plan = SiteURLReconciliation.plan(
            rows: rows([("wp_options", "https://net.localhost"), ("wp_2_options", "http://127.0.0.1:8900/shop")]),
            mainTable: "wp_options", networkDomain: "127.0.0.1:8900", target: URL(string: "https://net.localhost")!)
        XCTAssertEqual(plan.staleOrigins, ["127.0.0.1:8900"])
        XCTAssertEqual(plan.schemeFixes, [])
    }

    func testHTTPSDisabledFlipsBack() {
        let plan = SiteURLReconciliation.plan(
            rows: rows([("wp_options", "https://net.test")]),
            mainTable: "wp_options", target: URL(string: "http://net.test")!)
        XCTAssertEqual(plan.schemeFixes, ["net.test"])
        XCTAssertEqual(SiteURLReconciliation.schemePass(authority: "net.test", scheme: "http"),
                       EnvURLMigration.Pass(source: "https://net.test", target: "http://net.test"))
    }

    func testRowsParseFromQueryOutput() {
        let output = "wp_options\thome\thttps://net.test\nwp_2_options\tsiteurl\thttp://blog.net.test\n\nbad line\n"
        XCTAssertEqual(SiteURLReconciliation.parseRows(output),
                       rows([("wp_options", "https://net.test"), ("wp_2_options", "http://blog.net.test")]))
    }

    func testQueryMatchesOnlyOptionsTablesOfThePrefix() {
        let sql = SiteURLReconciliation.readURLsSQL(prefix: "wpx_")
        XCTAssertTrue(sql.contains("REGEXP '^wpx_([0-9]+_)?options$'"))
    }

    func testStoresWithoutWordPressURLDecodeNil() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"net","slug":"net","path":"file:///tmp/net","port":8900,
         "imageTag":"wordpress:latest","createdAt":0}
        """
        XCTAssertNil(try JSONDecoder().decode(Site.self, from: Data(json.utf8)).wordpressURL)
    }
}
