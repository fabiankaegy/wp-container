import XCTest
@testable import WPContainerKit

/// Pure-logic tests for the proxy's routing table and the pages it serves when
/// no upstream answers. Everything here is a static function over a store
/// envelope — no listener, no containers, no network.
final class HTTPSProxyRoutingTests: XCTestCase {

    private let parentID = UUID()

    private func env(slug: String, port: Int, branch: String = "feature/x") -> WorktreeEnv {
        WorktreeEnv(parentSiteID: parentID,
                    parentSlug: "my-site",
                    envSlug: slug,
                    repoRelPath: "wp-content",
                    branch: branch,
                    worktreePath: URL(fileURLWithPath: "/tmp/\(slug)/worktree"),
                    envPath: URL(fileURLWithPath: "/tmp/\(slug)"),
                    port: port,
                    imageTag: "wordpress:6.8")
    }

    // MARK: - Duplicate env slugs

    /// The real failure this guards: `sites.json` held two envs both slugged
    /// `my-site-wt-feature-…`, on ports 8906 and 8907. They collide on
    /// `<envSlug>.localhost`, and whichever lost the dictionary write had its port
    /// orphaned — no listener bound it and it answered the unknown-host page.
    /// First wins, deterministically.
    func testDuplicateEnvSlugYieldsOneRouteKeepingTheFirst() {
        let envelope = StoreEnvelope(sites: [],
                                     envs: [env(slug: "my-site-wt-authors", port: 8906),
                                            env(slug: "my-site-wt-authors", port: 8907)])

        let routes = HTTPSProxy.routes(from: envelope)

        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes["my-site-wt-authors.localhost"]?.port, 8906)
    }

    func testDistinctEnvSlugsBothRoute() {
        let envelope = StoreEnvelope(sites: [],
                                     envs: [env(slug: "my-site-wt-authors", port: 8906),
                                            env(slug: "my-site-wt-blocks", port: 8907)])

        let routes = HTTPSProxy.routes(from: envelope)

        XCTAssertEqual(routes.count, 2)
        XCTAssertEqual(routes["my-site-wt-authors.localhost"]?.port, 8906)
        XCTAssertEqual(routes["my-site-wt-blocks.localhost"]?.port, 8907)
    }

    func testEnvRoutesAreTaggedAsEnvsWithTheirParent() {
        let envelope = StoreEnvelope(sites: [], envs: [env(slug: "my-site-wt-authors", port: 8906)])

        let route = HTTPSProxy.routes(from: envelope)["my-site-wt-authors.localhost"]

        XCTAssertEqual(route?.isEnv, true)
        XCTAssertEqual(route?.parentSlug, "my-site")
        XCTAssertEqual(route?.slug, "my-site-wt-authors")
    }

    // MARK: - Local Network Privacy page

    func testLocalNetworkDeniedPageLinksToTheSettingsPaneAndSelfRefreshes() {
        let route = HTTPSProxy.Route(port: 8906, slug: "my-site-wt-authors",
                                     displayName: "my-site · feature/x",
                                     containerName: "wpc-my-site-wt-authors-wp",
                                     isEnv: true, parentSlug: "my-site")

        let page = HTTPSProxy.localNetworkDeniedPage(host: "127.0.0.1:8906", route: route)

        XCTAssertTrue(page.contains("WP Container needs Local Network access"))
        XCTAssertTrue(page.contains(HTTPSProxy.localNetworkSettingsURL))
        XCTAssertTrue(page.contains("<meta http-equiv=\"refresh\" content=\"5\">"))
        // It must NOT send the user after the container: nothing is wrong with it.
        XCTAssertFalse(page.contains("container logs"))
    }

    // MARK: - Accept negotiation (the HTML/plain-text fork every page uses)

    func testAcceptsHTML() {
        XCTAssertTrue(HTTPSProxy.acceptsHTML(nil))
        XCTAssertTrue(HTTPSProxy.acceptsHTML("*/*"))
        XCTAssertTrue(HTTPSProxy.acceptsHTML("text/html,application/xhtml+xml"))
        XCTAssertFalse(HTTPSProxy.acceptsHTML("text/css"))
        XCTAssertFalse(HTTPSProxy.acceptsHTML("application/json"))
    }
}
