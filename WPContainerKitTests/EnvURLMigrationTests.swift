import XCTest
@testable import WPContainerKit

/// Coverage for the pure half of the worktree-env URL migration: authority
/// normalization, the ordered search-replace variants, stale-origin candidate
/// filtering, the wp-config constant rewrite, and the replacement-count parser
/// shared with the database importer.
final class EnvURLMigrationTests: XCTestCase {

    // MARK: - Authority normalization

    func testAuthorityStripsSchemePathAndQuery() {
        XCTAssertEqual(EnvURLMigration.authority(from: "https://mysite.test/wp-admin/?x=1"), "mysite.test")
        XCTAssertEqual(EnvURLMigration.authority(from: "http://mysite.test"), "mysite.test")
        XCTAssertEqual(EnvURLMigration.authority(from: "//mysite.test/foo"), "mysite.test")
        XCTAssertEqual(EnvURLMigration.authority(from: "mysite.test"), "mysite.test")
    }

    func testAuthorityKeepsThePort() {
        // WordPress only strips :80/:443 from HTTP_HOST, so a non-standard port
        // is part of the host identity in wp_blogs.domain and DOMAIN_CURRENT_SITE.
        XCTAssertEqual(EnvURLMigration.authority(from: "http://127.0.0.1:8901"), "127.0.0.1:8901")
        XCTAssertEqual(EnvURLMigration.authority(from: "localhost:8901/wp-admin"), "localhost:8901")
        XCTAssertEqual(EnvURLMigration.authority(from: "192.168.64.242"), "192.168.64.242")
    }

    func testAuthorityNormalizesCaseWhitespaceAndUserInfo() {
        XCTAssertEqual(EnvURLMigration.authority(from: "  HTTPS://Mysite.TEST/  "), "mysite.test")
        XCTAssertEqual(EnvURLMigration.authority(from: "https://user:pw@mysite.test"), "mysite.test")
    }

    func testAuthorityRejectsUnusableValues() {
        XCTAssertNil(EnvURLMigration.authority(from: ""))
        XCTAssertNil(EnvURLMigration.authority(from: "   "))
        XCTAssertNil(EnvURLMigration.authority(from: "https://"))
        XCTAssertNil(EnvURLMigration.authority(from: ":8901"))
        XCTAssertNil(EnvURLMigration.authority(from: "some option value"))
        XCTAssertNil(EnvURLMigration.authority(from: "a:b'c"))
    }

    // MARK: - Variant derivation

    func testPassesCoverEveryFormAndPutFullURLsFirst() {
        let passes = EnvURLMigration.passes(from: "https://mysite.test", to: "127.0.0.1:8901")
        XCTAssertEqual(passes, [
            EnvURLMigration.Pass(source: "https://mysite.test", target: "http://127.0.0.1:8901"),
            EnvURLMigration.Pass(source: "http://mysite.test", target: "http://127.0.0.1:8901"),
            EnvURLMigration.Pass(source: "//mysite.test", target: "//127.0.0.1:8901"),
            EnvURLMigration.Pass(source: "mysite.test", target: "127.0.0.1:8901"),
        ])
    }

    func testPassesAreIdenticalWhicheverSchemeTheOriginArrivesIn() {
        XCTAssertEqual(EnvURLMigration.passes(from: "http://mysite.test", to: "127.0.0.1:8901"),
                       EnvURLMigration.passes(from: "mysite.test", to: "127.0.0.1:8901"))
    }

    func testPassesCarryPortsThrough() {
        let passes = EnvURLMigration.passes(from: "http://127.0.0.1:8880", to: "127.0.0.1:8901")
        XCTAssertEqual(passes.first?.source, "https://127.0.0.1:8880")
        XCTAssertEqual(passes.last, EnvURLMigration.Pass(source: "127.0.0.1:8880", target: "127.0.0.1:8901"))
    }

    func testNoPassesWhenTheOriginIsAlreadyTheTarget() {
        XCTAssertTrue(EnvURLMigration.passes(from: "http://127.0.0.1:8901", to: "127.0.0.1:8901").isEmpty)
        XCTAssertTrue(EnvURLMigration.passes(from: "", to: "127.0.0.1:8901").isEmpty)
    }

    func testTargetAuthorityIsTheLoopbackPort() {
        XCTAssertEqual(EnvURLMigration.targetAuthority(port: 8901), "127.0.0.1:8901")
    }

    // MARK: - Stale-origin filtering

    func testStaleOriginsDedupeAcrossFormsAndDropTheTarget() {
        let origins = EnvURLMigration.staleOrigins(
            candidates: ["https://mysite.test", "http://mysite.test/", "mysite.test",
                         "http://127.0.0.1:8901", "127.0.0.1:8901", "192.168.64.242"],
            target: "127.0.0.1:8901")
        XCTAssertEqual(origins, ["mysite.test", "192.168.64.242"])
    }

    func testStaleOriginsPreserveFirstSeenOrderAndSkipJunk() {
        let origins = EnvURLMigration.staleOrigins(
            candidates: ["localhost:8901", "", "not a url", "https://mysite.test"],
            target: "127.0.0.1:8901")
        XCTAssertEqual(origins, ["localhost:8901", "mysite.test"])
    }

    func testNetworkDomainIsMigratedLast() {
        // Until the bootstrap origin is rewritten, every earlier wp-cli call can
        // still find its network — so it has to go last.
        let origins = EnvURLMigration.staleOrigins(
            candidates: ["mysite.test", "192.168.64.242", "localhost:8901"],
            target: "127.0.0.1:8901", networkDomain: "mysite.test")
        XCTAssertEqual(origins, ["192.168.64.242", "localhost:8901", "mysite.test"])
    }

    func testNetworkDomainAbsentFromCandidatesChangesNothing() {
        let origins = EnvURLMigration.staleOrigins(
            candidates: ["192.168.64.242"], target: "127.0.0.1:8901", networkDomain: "mysite.test")
        XCTAssertEqual(origins, ["192.168.64.242"])
    }

    func testStaleOriginsIsEmptyForAnUnusableTarget() {
        XCTAssertTrue(EnvURLMigration.staleOrigins(candidates: ["mysite.test"], target: "").isEmpty)
    }

    // MARK: - Multisite detection

    func testMultisiteFromTheParentsRecordedNetworkType() {
        XCTAssertTrue(EnvURLMigration.isMultisite(networkType: .subdirectory, constants: [:]))
        XCTAssertTrue(EnvURLMigration.isMultisite(networkType: .subdomain, constants: [:]))
        XCTAssertFalse(EnvURLMigration.isMultisite(networkType: .none, constants: [:]))
    }

    func testMultisiteFromTheClonesConfigWhenTheParentNeverRecordedIt() {
        // A network that arrived through a database import leaves networkType none.
        XCTAssertTrue(EnvURLMigration.isMultisite(networkType: .none, constants: ["MULTISITE": "true"]))
        XCTAssertTrue(EnvURLMigration.isMultisite(networkType: .none, constants: ["MULTISITE": "1"]))
        XCTAssertFalse(EnvURLMigration.isMultisite(networkType: .none, constants: ["MULTISITE": "false"]))
    }

    // MARK: - Table classification

    func testOptionsTableMatchesTheMainSiteAndSubsites() {
        XCTAssertTrue(EnvURLMigration.isOptionsTable("wp_options", prefix: "wp_"))
        XCTAssertTrue(EnvURLMigration.isOptionsTable("wp_2_options", prefix: "wp_"))
        XCTAssertTrue(EnvURLMigration.isOptionsTable("ig_17_options", prefix: "ig_"))
    }

    func testOptionsTableRejectsEverythingElse() {
        XCTAssertFalse(EnvURLMigration.isOptionsTable("wp_posts", prefix: "wp_"))
        XCTAssertFalse(EnvURLMigration.isOptionsTable("wp_sitemeta", prefix: "wp_"))
        XCTAssertFalse(EnvURLMigration.isOptionsTable("wp_x_options", prefix: "wp_"))
        XCTAssertFalse(EnvURLMigration.isOptionsTable("wp__options", prefix: "wp_"))
        XCTAssertFalse(EnvURLMigration.isOptionsTable("other_options", prefix: "wp_"))
    }

    func testSafeIdentifierGuardsSQLInterpolation() {
        XCTAssertTrue(EnvURLMigration.isSafeIdentifier("wp_2_options"))
        XCTAssertFalse(EnvURLMigration.isSafeIdentifier(""))
        XCTAssertFalse(EnvURLMigration.isSafeIdentifier("wp`; DROP"))
        XCTAssertFalse(EnvURLMigration.isSafeIdentifier("wp options"))
    }

    // MARK: - wp-config constants

    func testMultisiteCloneGetsDomainCurrentSite() {
        let updates = EnvURLMigration.configConstantUpdates(
            existing: ["DOMAIN_CURRENT_SITE": "mysite.test"], targetAuthority: "127.0.0.1:8901", multisite: true)
        XCTAssertEqual(updates, [EnvURLMigration.ConstantUpdate(name: "DOMAIN_CURRENT_SITE", value: "127.0.0.1:8901")])
    }

    func testDomainCurrentSiteAlreadyCorrectIsLeftAlone() {
        let updates = EnvURLMigration.configConstantUpdates(
            existing: ["DOMAIN_CURRENT_SITE": "127.0.0.1:8901"], targetAuthority: "127.0.0.1:8901", multisite: true)
        XCTAssertTrue(updates.isEmpty)
    }

    func testSingleSiteCloneGetsNoDomainCurrentSite() {
        let updates = EnvURLMigration.configConstantUpdates(
            existing: [:], targetAuthority: "127.0.0.1:8901", multisite: false)
        XCTAssertTrue(updates.isEmpty)
    }

    func testAStaleDomainCurrentSiteIsFixedEvenOnAnUndetectedNetwork() {
        let updates = EnvURLMigration.configConstantUpdates(
            existing: ["DOMAIN_CURRENT_SITE": "mysite.test"], targetAuthority: "127.0.0.1:8901", multisite: false)
        XCTAssertEqual(updates.map(\.name), ["DOMAIN_CURRENT_SITE"])
    }

    func testHardcodedHomeAndSiteurlAreRewrittenToTheEnvURL() {
        let updates = EnvURLMigration.configConstantUpdates(
            existing: ["WP_HOME": "https://mysite.test", "WP_SITEURL": "https://mysite.test"],
            targetAuthority: "127.0.0.1:8901", multisite: false)
        XCTAssertEqual(updates, [
            EnvURLMigration.ConstantUpdate(name: "WP_HOME", value: "http://127.0.0.1:8901"),
            EnvURLMigration.ConstantUpdate(name: "WP_SITEURL", value: "http://127.0.0.1:8901"),
        ])
    }

    func testHomeAndSiteurlAreNeverAddedWhenAbsent() {
        // A clone that never pinned them must keep reading its options.
        let updates = EnvURLMigration.configConstantUpdates(
            existing: ["WP_DEBUG": "true"], targetAuthority: "127.0.0.1:8901", multisite: false)
        XCTAssertTrue(updates.isEmpty)
    }

    // MARK: - wp-config rewriting against a fixture (WPConfigService)

    func testSetConstantRewritesDomainCurrentSiteInPlace() throws {
        let folder = try makeTempWordPressFolder(config: """
        <?php
        define( 'DB_NAME', getenv_docker('WORDPRESS_DB_NAME', 'wordpress') );
        define( 'MULTISITE', true );
        define( 'SUBDOMAIN_INSTALL', false );
        define( 'DOMAIN_CURRENT_SITE', 'mysite.test' );
        define( 'PATH_CURRENT_SITE', '/' );
        $table_prefix = 'wp_';
        """)
        defer { try? FileManager.default.removeItem(at: folder) }

        let existing = try WPConfigService.read(wordpressFolder: folder).constants
        XCTAssertTrue(EnvURLMigration.isMultisite(networkType: .none, constants: existing))
        for update in EnvURLMigration.configConstantUpdates(existing: existing,
                                                            targetAuthority: "127.0.0.1:8901",
                                                            multisite: true) {
            try WPConfigService.setConstant(update.name, value: update.value, rawValue: false, wordpressFolder: folder)
        }

        let rewritten = try WPConfigService.read(wordpressFolder: folder).constants
        XCTAssertEqual(rewritten["DOMAIN_CURRENT_SITE"], "127.0.0.1:8901")
        // Nothing else moved.
        XCTAssertEqual(rewritten["MULTISITE"], "true")
        XCTAssertEqual(rewritten["SUBDOMAIN_INSTALL"], "false")
        XCTAssertEqual(rewritten["PATH_CURRENT_SITE"], "/")
        XCTAssertEqual(try WPConfigService.read(wordpressFolder: folder).tablePrefix, "wp_")
        // Re-running is a no-op: the constant already matches.
        XCTAssertTrue(EnvURLMigration.configConstantUpdates(existing: rewritten,
                                                            targetAuthority: "127.0.0.1:8901",
                                                            multisite: true).isEmpty)
    }

    func testSetConstantRewritesHardcodedHomeURLs() throws {
        let folder = try makeTempWordPressFolder(config: """
        <?php
        define( 'WP_HOME', 'https://mysite.test' );
        define( 'WP_SITEURL', 'https://mysite.test' );
        $table_prefix = 'ig_';
        """)
        defer { try? FileManager.default.removeItem(at: folder) }

        let existing = try WPConfigService.read(wordpressFolder: folder).constants
        for update in EnvURLMigration.configConstantUpdates(existing: existing,
                                                            targetAuthority: "127.0.0.1:8901",
                                                            multisite: false) {
            try WPConfigService.setConstant(update.name, value: update.value, rawValue: false, wordpressFolder: folder)
        }

        let rewritten = try WPConfigService.read(wordpressFolder: folder).constants
        XCTAssertEqual(rewritten["WP_HOME"], "http://127.0.0.1:8901")
        XCTAssertEqual(rewritten["WP_SITEURL"], "http://127.0.0.1:8901")
        XCTAssertNil(rewritten["DOMAIN_CURRENT_SITE"])
    }

    // MARK: - Replacement counts

    func testParsesTheRealRunSummaryLine() {
        XCTAssertEqual(EnvURLMigration.parseReplacementCount("Success: Made 412 replacements."), 412)
        XCTAssertEqual(EnvURLMigration.parseReplacementCount("Success: Made 1 replacement."), 1)
    }

    func testParsesTheDryRunSummaryLine() {
        XCTAssertEqual(EnvURLMigration.parseReplacementCount("Success: 128 replacements to be made."), 128)
    }

    func testUnparseableOutputIsNil() {
        XCTAssertNil(EnvURLMigration.parseReplacementCount(""))
        XCTAssertNil(EnvURLMigration.parseReplacementCount("Error: no such table"))
    }

    // MARK: - Helpers

    private func makeTempWordPressFolder(config: String) throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wpc-url-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try config.write(to: WPConfigService.configURL(for: folder), atomically: true, encoding: .utf8)
        return folder
    }
}
