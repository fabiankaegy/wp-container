import XCTest
@testable import WPContainerKit

/// `worktree adopt`: mapping a checkout another tool made (e.g. T3 Code or
/// herdr) back to its site, and the env record that keeps wp-container's hands
/// off it.
final class WorktreeAdoptTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpc-adopt-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Site lookup

    func testFindsSiteAndRepoPathForWPContentRepo() {
        let site = makeSite("blog")
        let other = makeSite("shop")
        let repo = site.wordpressFolder.appendingPathComponent("wp-content", isDirectory: true)
        let match = WorktreeEnvService.adoptionParent(mainCheckout: repo, sites: [other, site])
        XCTAssertEqual(match?.site.slug, "blog")
        XCTAssertEqual(match?.repoRelPath, "wp-content")
    }

    func testFindsNestedPluginRepo() {
        let site = makeSite("blog")
        let repo = site.wordpressFolder.appendingPathComponent("wp-content/plugins/my-plugin", isDirectory: true)
        XCTAssertEqual(WorktreeEnvService.adoptionParent(mainCheckout: repo, sites: [site])?.repoRelPath,
                       "wp-content/plugins/my-plugin")
    }

    func testRepoOutsideEverySiteIsUnmatched() {
        let site = makeSite("blog")
        let elsewhere = tempRoot.appendingPathComponent("Developer/gutenberg", isDirectory: true)
        XCTAssertNil(WorktreeEnvService.adoptionParent(mainCheckout: elsewhere, sites: [site]))
        // The wordpress/ folder itself is not a repo path that can be mounted.
        XCTAssertNil(WorktreeEnvService.adoptionParent(mainCheckout: site.wordpressFolder, sites: [site]))
        // A sibling folder whose name merely starts with the site's path.
        let lookalike = tempRoot.appendingPathComponent("blog/wordpress-old/wp-content", isDirectory: true)
        XCTAssertNil(WorktreeEnvService.adoptionParent(mainCheckout: lookalike, sites: [site]))
    }

    // MARK: - Env record

    func testAdoptingDescriptorKeepsTheGivenCheckout() {
        let site = makeSite("blog")
        let checkout = tempRoot.appendingPathComponent(".t3/worktrees/wp-content/t3code-1234", isDirectory: true)
        let env = WorktreeEnvService.descriptor(parent: site, repoRelPath: "wp-content",
                                                branch: "t3code/1234", port: 8890, adopting: checkout)
        XCTAssertTrue(env.adoptedWorktree)
        XCTAssertEqual(env.worktreePath, checkout)
        XCTAssertEqual(env.envSlug, "blog-wt-t3code-1234")
        // Env files still live with the site; only the checkout is elsewhere.
        XCTAssertEqual(env.envPath, site.envsFolder.appendingPathComponent("t3code-1234", isDirectory: true))
        // The checkout is what shadows the repo inside the container.
        XCTAssertEqual(env.extraMounts.last?.hostPath, checkout.path)
        XCTAssertEqual(env.extraMounts.last?.containerPath, "/var/www/html/wp-content")
    }

    func testRegularDescriptorIsNotAdopted() {
        let site = makeSite("blog")
        let env = WorktreeEnvService.descriptor(parent: site, repoRelPath: "wp-content", branch: "feat/x", port: 8890)
        XCTAssertFalse(env.adoptedWorktree)
        XCTAssertEqual(env.worktreePath, site.worktreesFolder.appendingPathComponent("feat-x", isDirectory: true))
    }

    func testAdoptedFlagRoundTripsAndDefaultsToFalse() throws {
        let site = makeSite("blog")
        let adopted = WorktreeEnvService.descriptor(parent: site, repoRelPath: "wp-content", branch: "b",
                                                    port: 8890, adopting: tempRoot)
        let data = try JSONEncoder().encode(adopted)
        XCTAssertTrue(try JSONDecoder().decode(WorktreeEnv.self, from: data).adoptedWorktree)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "adoptedWorktree")
        let legacy = try JSONDecoder().decode(WorktreeEnv.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(legacy.adoptedWorktree)
    }

    // MARK: - Env lookup by checkout path

    func testFindsEnvByCheckoutPathWhenTheCheckoutIsGone() {
        let site = makeSite("blog")
        let checkout = tempRoot.appendingPathComponent(".herdr/worktrees/wp-content/feat-x", isDirectory: true)
        let env = WorktreeEnvService.descriptor(parent: site, repoRelPath: "wp-content", branch: "feat/x",
                                                port: 8890, adopting: checkout)
        let other = WorktreeEnvService.descriptor(parent: site, repoRelPath: "wp-content", branch: "feat/y", port: 8891)
        let envs = [other, env]
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkout.path))

        XCTAssertEqual(WorktreeEnvService.env(forCheckoutPath: checkout, in: envs)?.id, env.id)
        let subfolder = checkout.appendingPathComponent("themes/twentytwentyfive", isDirectory: true)
        XCTAssertEqual(WorktreeEnvService.env(forCheckoutPath: subfolder, in: envs)?.id, env.id)
        // A sibling whose name only starts with the checkout's name.
        let lookalike = tempRoot.appendingPathComponent(".herdr/worktrees/wp-content/feat-x-2", isDirectory: true)
        XCTAssertNil(WorktreeEnvService.env(forCheckoutPath: lookalike, in: envs))
        XCTAssertNil(WorktreeEnvService.env(forCheckoutPath: checkout.deletingLastPathComponent(), in: envs))
    }

    func testDeepestCheckoutWinsWhenCheckoutsNest() {
        let site = makeSite("blog")
        let outer = tempRoot.appendingPathComponent("work/wp-content", isDirectory: true)
        let inner = outer.appendingPathComponent("plugins/my-plugin", isDirectory: true)
        let outerEnv = WorktreeEnvService.descriptor(parent: site, repoRelPath: "wp-content", branch: "a",
                                                     port: 8890, adopting: outer)
        let innerEnv = WorktreeEnvService.descriptor(parent: site, repoRelPath: "wp-content/plugins/my-plugin",
                                                     branch: "b", port: 8891, adopting: inner)
        let path = inner.appendingPathComponent("src", isDirectory: true)
        XCTAssertEqual(WorktreeEnvService.env(forCheckoutPath: path, in: [outerEnv, innerEnv])?.id, innerEnv.id)
        XCTAssertEqual(WorktreeEnvService.env(forCheckoutPath: path, in: [innerEnv, outerEnv])?.id, innerEnv.id)
    }

    // MARK: - Git checkout location

    func testCheckoutLocationOfLinkedWorktree() async throws {
        let main = tempRoot.appendingPathComponent("site/wordpress/wp-content", isDirectory: true)
        let linked = tempRoot.appendingPathComponent("elsewhere/t3code-1234", isDirectory: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: main.appendingPathComponent("themes"), withIntermediateDirectories: true)
        try "x".write(to: main.appendingPathComponent("themes/a.txt"), atomically: true, encoding: .utf8)
        try await shell(["git", "init", "-q", "-b", "main"], in: main)
        try await shell(["git", "-c", "user.email=t@t", "-c", "user.name=t", "add", "-A"], in: main)
        try await shell(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"], in: main)
        try await shell(["git", "worktree", "add", "-q", "-b", "t3code/1234", linked.path], in: main)

        let git = GitService()
        // From a subfolder of the linked checkout, as a setup script's cwd might be.
        let fromLinked = try await git.checkoutLocation(of: linked.appendingPathComponent("themes"))
        XCTAssertEqual(fromLinked.topLevel.path, linked.resolvingSymlinksInPath().path)
        XCTAssertEqual(fromLinked.mainCheckout.path, main.resolvingSymlinksInPath().path)
        XCTAssertTrue(fromLinked.isLinkedWorktree)

        let fromMain = try await git.checkoutLocation(of: main)
        XCTAssertFalse(fromMain.isLinkedWorktree)

        let branch = try await git.currentBranch(repo: linked)
        XCTAssertEqual(branch, "t3code/1234")
    }

    func testCheckoutLocationOutsideGitThrows() async {
        do {
            _ = try await GitService().checkoutLocation(of: tempRoot)
            XCTFail("expected a git error")
        } catch {}
    }

    // MARK: - Helpers

    private func makeSite(_ slug: String) -> Site {
        Site(name: slug, slug: slug, path: tempRoot.appendingPathComponent(slug, isDirectory: true),
             port: 8881, imageTag: SiteRecipe.defaultWordPressImage)
    }

    private func shell(_ args: [String], in dir: URL) async throws {
        let result = try await ProcessRunner.run(executable: "/usr/bin/env", args: args, cwd: dir)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
    }
}
