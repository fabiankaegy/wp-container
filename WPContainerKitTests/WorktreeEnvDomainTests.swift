import XCTest
@testable import WPContainerKit

/// An env's hostname and the URLs derived from it: `domainHost` is the single
/// source every surface reads, the DNS-label guard on long slugs, and the
/// `usesDomainURL` / `httpsEnabled` switch between the domain and loopback URL.
final class WorktreeEnvDomainTests: XCTestCase {

    private func makeEnv(slug: String = "my-site-wt-authors", port: Int = 8901,
                         usesDomainURL: Bool = false, httpsEnabled: Bool = false) -> WorktreeEnv {
        WorktreeEnv(parentSiteID: UUID(), parentSlug: "my-site", envSlug: slug,
                    repoRelPath: "wp-content", branch: "authors",
                    worktreePath: URL(fileURLWithPath: "/tmp/wt"),
                    envPath: URL(fileURLWithPath: "/tmp/env"),
                    port: port, imageTag: "wordpress:6.8",
                    usesDomainURL: usesDomainURL, httpsEnabled: httpsEnabled)
    }

    // MARK: - URLs

    func testDomainHostIsTheSlugUnderLocalhost() {
        XCTAssertEqual(makeEnv().domainHost, "my-site-wt-authors.localhost")
    }

    func testNotYetMigratedEnvAdvertisesItsLoopbackURL() {
        let env = makeEnv()
        XCTAssertEqual(env.url.absoluteString, "http://127.0.0.1:8901")
        XCTAssertEqual(env.adminURL.absoluteString, "http://127.0.0.1:8901/wp-admin")
    }

    func testMigratedEnvAdvertisesItsDomainOnItsScheme() {
        let plain = makeEnv(usesDomainURL: true)
        XCTAssertEqual(plain.url.absoluteString, "http://my-site-wt-authors.localhost")
        XCTAssertEqual(plain.adminURL.absoluteString, "http://my-site-wt-authors.localhost/wp-admin")

        let secure = makeEnv(usesDomainURL: true, httpsEnabled: true)
        XCTAssertEqual(secure.url.absoluteString, "https://my-site-wt-authors.localhost")
        // The loopback URL is unchanged either way.
        XCTAssertEqual(secure.localURL.absoluteString, "http://127.0.0.1:8901")
    }

    func testLoopbackHostsAreTheDomainHost() {
        XCTAssertEqual(makeEnv().loopbackHosts, ["my-site-wt-authors.localhost"])
    }

    func testFlagsRoundTripThroughCodable() throws {
        let env = makeEnv(usesDomainURL: true, httpsEnabled: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WorktreeEnv.self, from: encoder.encode(env))
        XCTAssertTrue(decoded.usesDomainURL)
        XCTAssertTrue(decoded.httpsEnabled)
    }

    // MARK: - DNS label length

    func testShortSlugIsUsedVerbatim() {
        let slug = String(repeating: "a", count: SiteURL.maxDNSLabelLength)
        XCTAssertEqual(SiteURL.dnsLabel(slug), slug)
    }

    func testLongSlugIsTruncatedWithAStableHashSuffix() {
        let slug = "client-flagship-site-wt-" + String(repeating: "features", count: 8) + "end"
        let label = SiteURL.dnsLabel(slug)
        XCTAssertEqual(label.count, SiteURL.maxDNSLabelLength)
        XCTAssertTrue(label.hasPrefix("client-flagship-site-wt-featuresfeatures"))
        XCTAssertEqual(label.suffix(7), Substring("-" + WorktreeEnv.shortHash(slug)))
        // Deterministic — derived, never persisted.
        XCTAssertEqual(SiteURL.dnsLabel(slug), label)
        XCTAssertEqual(makeEnv(slug: slug).domainHost, "\(label).localhost")
    }

    func testLongSlugsSharingAPrefixDoNotCollide() {
        let prefix = String(repeating: "x", count: 70)
        XCTAssertNotEqual(SiteURL.dnsLabel(prefix + "-one"), SiteURL.dnsLabel(prefix + "-two"))
    }

    func testTruncationNeverLeavesADoubledHyphen() {
        // The 56 kept chars end in "-", which would otherwise yield "…--<hash>".
        let slug = String(repeating: "a", count: 55) + "-" + String(repeating: "b", count: 20)
        let label = SiteURL.dnsLabel(slug)
        XCTAssertFalse(label.contains("--"))
        XCTAssertLessThanOrEqual(label.count, SiteURL.maxDNSLabelLength)
    }
}
