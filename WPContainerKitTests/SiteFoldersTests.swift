import XCTest
@testable import WPContainerKit

/// Coverage for the default sites root: the Settings override is read from the
/// app's preferences domain by name, so any process sees it, and an empty or
/// missing value falls back to `~/WP Container Sites`.
final class SiteFoldersTests: XCTestCase {
    private let domain = "com.fabiankaegy.wpcontainer.tests.\(UUID().uuidString)"

    override func tearDown() {
        write(nil)
        super.tearDown()
    }

    func testReadsTheOverrideFromTheNamedDomain() {
        write("/tmp/example-sites/")
        XCTAssertEqual(SiteFolders.defaultSitesRoot(preferencesDomain: domain).path, "/tmp/example-sites")
    }

    func testFallsBackWhenTheOverrideIsMissing() {
        XCTAssertEqual(SiteFolders.defaultSitesRoot(preferencesDomain: domain), SiteFolders.builtInDefaultSitesRoot)
    }

    func testFallsBackWhenTheOverrideIsEmpty() {
        write("")
        XCTAssertEqual(SiteFolders.defaultSitesRoot(preferencesDomain: domain), SiteFolders.builtInDefaultSitesRoot)
    }

    private func write(_ value: String?) {
        CFPreferencesSetAppValue("defaultSitesRoot" as CFString, value as CFString?, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
    }
}
