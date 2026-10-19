import XCTest
@testable import WPContainerKit

/// Archived sites: decoding old stores, and staying out of the proxy's routes.
final class SiteArchiveTests: XCTestCase {

    private func site(slug: String, archived: Bool) -> Site {
        Site(name: slug, slug: slug, path: URL(fileURLWithPath: "/tmp/\(slug)"), port: 8881,
             imageTag: "wordpress:6.8", archivedAt: archived ? Date() : nil)
    }

    private func env(of parent: Site, port: Int) -> WorktreeEnv {
        WorktreeEnv(parentSiteID: parent.id, parentSlug: parent.slug, envSlug: "\(parent.slug)-wt-x",
                    repoRelPath: "wp-content", branch: "feature/x",
                    worktreePath: URL(fileURLWithPath: "/tmp/wt"), envPath: URL(fileURLWithPath: "/tmp/env"),
                    port: port, imageTag: "wordpress:6.8")
    }

    func testArchivedSiteAndItsEnvsAreNotRouted() {
        let archived = site(slug: "old", archived: true)
        let active = site(slug: "live", archived: false)
        let envelope = StoreEnvelope(sites: [archived, active], envs: [env(of: archived, port: 8890), env(of: active, port: 8891)])

        let routes = HTTPSProxy.routes(from: envelope)

        XCTAssertNil(routes["old.localhost"])
        XCTAssertNil(routes["old-wt-x.localhost"])
        XCTAssertNotNil(routes["live.localhost"])
        XCTAssertNotNil(routes["live-wt-x.localhost"])
    }

    func testArchiveMarkRoundTripsAndOldStoresDecodeActive() throws {
        let encoded = try JSONEncoder().encode(site(slug: "old", archived: true))
        XCTAssertTrue(try JSONDecoder().decode(Site.self, from: encoded).isArchived)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "archivedAt")
        let legacy = try JSONDecoder().decode(Site.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(legacy.isArchived)
    }
}
