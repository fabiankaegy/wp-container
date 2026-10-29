import XCTest
@testable import WPContainerKit

/// The connection details shown for desktop database clients.
final class DatabaseConnectionTests: XCTestCase {

    func testDatabaseURLCarriesAppUserPortAndSchema() {
        XCTAssertEqual(SiteRecipe.databaseURL(dbHost: "10.0.0.5", database: "wpc_feature"),
                       "mysql://wordpress:wordpress@10.0.0.5:3306/wpc_feature")
    }
}
