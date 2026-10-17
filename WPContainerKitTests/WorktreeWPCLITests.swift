import XCTest
@testable import WPContainerKit

/// Coverage for wp-cli against a worktree env: one-shot containers and the
/// global router mount the env's checkout over its `wordpress/` copy, so
/// wp-cli loads the branch's code.
final class WorktreeWPCLITests: XCTestCase {

    private let parentRoot = URL(fileURLWithPath: "/tmp/wpc-worktree-tests/example", isDirectory: true)
    private let checkout = URL(fileURLWithPath: "/tmp/wpc-worktree-tests/example/.worktrees/feature", isDirectory: true)

    private var site: Site {
        Site(name: "Example", slug: "example", path: parentRoot, port: 8881, imageTag: SiteRecipe.defaultWordPressImage)
    }

    private var env: WorktreeEnv {
        WorktreeEnv(parentSiteID: site.id, parentSlug: "example", envSlug: "example-wt-feature",
                    repoRelPath: "wp-content/plugins/demo", branch: "feature", worktreePath: checkout,
                    envPath: parentRoot.appendingPathComponent(".envs/feature", isDirectory: true),
                    port: 8882, imageTag: SiteRecipe.defaultWordPressImage)
    }

    private let checkoutMount = "/tmp/wpc-worktree-tests/example/.worktrees/feature:/var/www/html/wp-content/plugins/demo"

    // MARK: - One-shot wp-cli

    func testWPProxyArgsMountTheCheckoutAfterWordPress() throws {
        let args = SiteRecipe.wpProxyArgs(env, dbHost: "10.0.0.2", wpArgs: ["plugin", "list"])
        let wordpressIndex = try XCTUnwrap(args.firstIndex(of: "\(env.wordpressFolder.path):/var/www/html"))
        let checkoutIndex = try XCTUnwrap(args.firstIndex(of: checkoutMount))
        let imageIndex = try XCTUnwrap(args.firstIndex(of: SiteRecipe.cliImage(for: env)))
        XCTAssertEqual(args[checkoutIndex - 1], "-v")
        XCTAssertLessThan(wordpressIndex, checkoutIndex, "the checkout must shadow the wordpress/ mount")
        XCTAssertLessThan(checkoutIndex, imageIndex, "container run options must precede the image")
    }

    func testWPProxyArgsForASiteHaveOneMount() {
        let args = SiteRecipe.wpProxyArgs(site, dbHost: "10.0.0.2", wpArgs: ["plugin", "list"])
        let mounts = zip(args, args.dropFirst()).filter { $0.0 == "-v" }.map(\.1)
        XCTAssertEqual(mounts, ["\(site.wordpressFolder.path):/var/www/html"])
    }

    // MARK: - resolve-site

    func testCheckoutResolvesToTheEnv() throws {
        let src = checkout.appendingPathComponent("src", isDirectory: true)
        let match = try XCTUnwrap(SiteResolver.resolve(path: src.path, in: envelope()))
        XCTAssertEqual(match.kind, "env")
        XCTAssertEqual(match.slug, "example-wt-feature")
        XCTAssertEqual(match.subpath, "wp-content/plugins/demo/src")
        XCTAssertEqual(match.mounts, [checkoutMount])
    }

    func testCheckoutRootResolvesToTheRepoPath() throws {
        let match = try XCTUnwrap(SiteResolver.resolve(path: checkout.path, in: envelope()))
        XCTAssertEqual(match.subpath, "wp-content/plugins/demo")
    }

    func testEnvWordPressFolderCarriesTheCheckoutMount() throws {
        let match = try XCTUnwrap(SiteResolver.resolve(path: env.wordpressFolder.path, in: envelope()))
        XCTAssertEqual(match.slug, "example-wt-feature")
        XCTAssertEqual(match.subpath, "")
        XCTAssertEqual(match.mounts, [checkoutMount])
    }

    func testParentSiteHasNoExtraMounts() throws {
        let match = try XCTUnwrap(SiteResolver.resolve(path: site.wordpressFolder.path, in: envelope()))
        XCTAssertEqual(match.slug, "example")
        XCTAssertEqual(match.mounts, [])
    }

    // MARK: - Router

    func testRouterPassesResolvedMounts() {
        let script = WPCLIShim.routerScript()
        XCTAssertTrue(script.contains(#"d.get("mounts", [])"#))
        XCTAssertTrue(script.contains(#"${WPC_MOUNTS[@]+"${WPC_MOUNTS[@]}"}"#))
    }

    // MARK: - Helpers

    private func envelope() -> StoreEnvelope {
        StoreEnvelope(sites: [site], envs: [env])
    }
}
