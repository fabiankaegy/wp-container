import XCTest
@testable import WPContainerKit

/// Coverage for the archive manifest and the portable subset of site settings.
final class SiteArchiveManifestTests: XCTestCase {

    func testSettingsRoundTripCarriesEnvironmentOnly() {
        var site = Site(name: "Shop", slug: "shop", path: URL(fileURLWithPath: "/tmp/shop"), port: 8123,
                        imageTag: "wordpress:php8.3-apache", phpVersion: "PHP 8.3",
                        httpsEnabled: true, xdebugEnabled: true, elasticsearchEnabled: true,
                        mailpitEnabled: true, mailpitPort: 9100, redisEnabled: true,
                        cpuLimit: 2, memoryLimitMB: 2048, idleStopMinutes: 30,
                        customDomain: "shop.test", networkType: .subdirectory,
                        agentToolsRoot: "/x", lastImportSourceURL: "https://example.com",
                        pendingSchemaDrops: ["wpc_a"],
                        mounts: [Mount(hostPath: "/p", containerPath: "/var/www/html/wp-content/plugins/p")])
        site.groupID = UUID()
        let settings = SiteArchiveSettings(site: site)
        var target = Site(name: "B", slug: "b", path: URL(fileURLWithPath: "/tmp/b"), port: 8200, imageTag: "wordpress:latest")
        settings.apply(to: &target)
        XCTAssertEqual(target.imageTag, "wordpress:php8.3-apache")
        XCTAssertEqual(target.phpVersion, "PHP 8.3")
        XCTAssertEqual(target.networkType, .subdirectory)
        XCTAssertTrue(target.httpsEnabled && target.xdebugEnabled && target.redisEnabled && target.elasticsearchEnabled)
        XCTAssertFalse(target.mailpitEnabled)
        XCTAssertNil(target.mailpitPort)
        XCTAssertEqual(target.port, 8200)
        XCTAssertEqual(target.cpuLimit, 2)
        XCTAssertEqual(target.memoryLimitMB, 2048)
        XCTAssertEqual(target.customDomain, "shop.test")
        XCTAssertEqual(target.idleStopMinutes, 30)
        XCTAssertEqual(target.lastImportSourceURL, "https://example.com")
        XCTAssertTrue(target.provisioned)
        XCTAssertTrue(target.mounts.isEmpty)
        XCTAssertNil(target.groupID)
        XCTAssertNil(target.agentToolsRoot)
        XCTAssertTrue(target.pendingSchemaDrops.isEmpty)
        XCTAssertTrue(settings.mailpitEnabled)
    }

    func testManifestRoundTrip() throws {
        let manifest = makeManifest(schemaVersion: SiteArchiveLayout.schemaVersion)
        let decoded = try SiteArchiveManifest.decode(try manifest.encoded())
        XCTAssertEqual(decoded, manifest)
    }

    func testDecodeRejectsFutureSchema() throws {
        let data = try makeManifest(schemaVersion: 2).encoded()
        XCTAssertThrowsError(try SiteArchiveManifest.decode(data)) { error in
            XCTAssertEqual(error as? SiteArchiveError, .unsupportedSchema(2))
        }
    }

    // MARK: - Helpers

    private func makeManifest(schemaVersion: Int) -> SiteArchiveManifest {
        let site = Site(name: "Shop", slug: "shop", path: URL(fileURLWithPath: "/tmp/shop"), port: 8123,
                        imageTag: "wordpress:latest", networkType: .subdomain)
        return SiteArchiveManifest(
            schemaVersion: schemaVersion,
            wpcVersion: "0.0.0",
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: .init(name: "Shop", slug: "shop", url: "https://shop.localhost", localURL: "http://localhost:8123"),
            wordpressVersion: "6.5",
            tablePrefix: "wp_",
            database: SiteArchiveLayout.databaseName,
            excludes: ["wp-content/cache"],
            mountsInlined: ["plugins/example"],
            settings: SiteArchiveSettings(site: site)
        )
    }
}
