import XCTest
@testable import WPContainerKit

final class ShareSettingsTests: XCTestCase {
    private func site(customDomain: String? = nil) -> Site {
        Site(name: "My Site", slug: "my-site", path: URL(fileURLWithPath: "/tmp/my-site"),
             port: 8881, imageTag: "wordpress:6.8", customDomain: customDomain)
    }

    private func env(share: ShareSettings? = nil, lastUsedDaysAgo days: Int = 0) -> WorktreeEnv {
        WorktreeEnv(parentSiteID: UUID(), parentSlug: "my-site", envSlug: "my-site-wt-feature",
                    repoRelPath: "wp-content", branch: "feature/x",
                    worktreePath: URL(fileURLWithPath: "/tmp/e/worktree"),
                    envPath: URL(fileURLWithPath: "/tmp/e"), port: 8906, imageTag: "wordpress:6.8",
                    createdAt: Date().addingTimeInterval(-86_400 * 30),
                    lastActivityAt: Date().addingTimeInterval(-86_400 * Double(days)),
                    share: share)
    }

    private func exception(_ text: String) throws -> ShareException {
        try ShareException(parsing: text)
    }

    func testOldStoreDecodesWithoutShare() throws {
        let siteData = try JSONEncoder().encode(site())
        var siteJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: siteData) as? [String: Any])
        siteJSON.removeValue(forKey: "share")
        let decodedSite = try JSONDecoder().decode(Site.self, from: JSONSerialization.data(withJSONObject: siteJSON))
        XCTAssertNil(decodedSite.share)

        let envData = try JSONEncoder().encode(env())
        var envJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: envData) as? [String: Any])
        envJSON.removeValue(forKey: "share")
        let decodedEnv = try JSONDecoder().decode(WorktreeEnv.self, from: JSONSerialization.data(withJSONObject: envJSON))
        XCTAssertNil(decodedEnv.share)
    }

    func testShareRoundTrips() throws {
        var settings = ShareSettings.generated()
        settings.provider = "cloudflared"
        settings.allow = [try exception("/wp-json/wc/v3/webhooks"), try exception("?wc-api=wc_stripe")]
        settings.active = true
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(ShareSettings.self, from: data), settings)

        let withShare = site()
        var shared = withShare
        shared.share = settings
        let decoded = try JSONDecoder().decode(Site.self, from: JSONEncoder().encode(shared))
        XCTAssertEqual(decoded.share, settings)
    }

    func testGeneratedCredentials() {
        let first = ShareSettings.generated()
        let second = ShareSettings.generated()
        XCTAssertEqual(first.username, "share")
        XCTAssertEqual(first.password.count, 20)
        XCTAssertTrue(first.password.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        XCTAssertNotEqual(first.password, second.password)
        XCTAssertFalse(first.active)
        XCTAssertTrue(first.allow.isEmpty)
    }

    func testPathPrefixException() throws {
        let rule = try exception("/wp-json/wc/v3/webhooks")
        XCTAssertTrue(rule.matches(path: "/wp-json/wc/v3/webhooks/1", query: nil))
        XCTAssertFalse(rule.matches(path: "/wp-json/wc/v3/orders", query: nil))
    }

    func testQueryExceptionWithAndWithoutValue() throws {
        XCTAssertTrue(try exception("?wc-api").matches(path: "/", query: "wc-api=wc_stripe&x=1"))
        let valued = try exception("?wc-api=wc_stripe")
        XCTAssertTrue(valued.matches(path: "/", query: "x=1&wc-api=wc_stripe"))
        XCTAssertFalse(valued.matches(path: "/", query: "wc-api=paypal"))
        XCTAssertFalse(valued.matches(path: "/", query: nil))
    }

    func testExceptionCannotBeWidenedByEncoding() throws {
        let rule = try exception("/wc-webhook")
        XCTAssertTrue(rule.matches(path: "/wc-webhook/order", query: nil))
        XCTAssertFalse(rule.matches(path: "/wc-webhook/../wp-admin/", query: nil))
        XCTAssertFalse(rule.matches(path: "/wc-webhook%2F..%2Fwp-admin", query: nil))
    }

    func testInvalidExceptionsAreRejected() {
        for text in ["", "wp-json", "?", "?=x"] {
            XCTAssertThrowsError(try ShareException(parsing: text), text) { error in
                guard case ShareError.invalidException = error else {
                    return XCTFail("unexpected error \(error)")
                }
            }
        }
    }

    func testEffectiveProviderFallsBackToNgrok() {
        var share = ShareSettings.generated()
        XCTAssertEqual(StoreEnvelope().effectiveProvider(for: share), "ngrok")
        XCTAssertEqual(StoreEnvelope().effectiveProvider(for: nil), "ngrok")
        let envelope = StoreEnvelope(shareDefaultProvider: "cloudflared")
        XCTAssertEqual(envelope.effectiveProvider(for: share), "cloudflared")
        share.provider = "my-script"
        XCTAssertEqual(envelope.effectiveProvider(for: share), "my-script")
    }

    func testShareLocalOriginsForSite() {
        let origins = site(customDomain: "my-site.local").shareLocalOrigins
        for expected in ["http://my-site.localhost", "https://my-site.localhost",
                         "http://my-site.local", "https://my-site.local", "http://127.0.0.1:8881"] {
            XCTAssertTrue(origins.contains(expected), expected)
        }
    }

    func testShareLocalOriginsForEnv() {
        let instance = env()
        let origins = instance.shareLocalOrigins
        XCTAssertTrue(origins.contains("http://\(instance.domainHost)"))
        XCTAssertTrue(origins.contains("https://\(instance.domainHost)"))
        XCTAssertTrue(origins.contains("http://127.0.0.1:8906"))
    }

    func testShareOriginHelpersDeriveFromURL() {
        let instance = env()
        XCTAssertFalse(instance.sharePrimaryOrigin.hasSuffix("/"))
        XCTAssertEqual(instance.shareUpstreamHost, "127.0.0.1:8906")
    }

    func testSharedEnvIsNotStale() {
        let plain = env(lastUsedDaysAgo: 10)
        XCTAssertTrue(EnvSettlement.isStale(plain))
        var share = ShareSettings.generated()
        share.active = true
        XCTAssertFalse(EnvSettlement.isStale(env(share: share, lastUsedDaysAgo: 10)))
    }
}
