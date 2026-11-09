import XCTest
@testable import WPContainerKit

/// Coverage for moving a site folder: destination checks, path rebasing in
/// the store, and reconnecting git worktrees after the folder moved.
final class SiteMoverTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-mover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary.appendingPathComponent("old/example"), withIntermediateDirectories: true)
        // Git reports real paths (`/private/var/…`), so the test uses them too.
        folder = URL(fileURLWithPath: SiteMover.realPath(temporary), isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func site(at path: URL) -> Site {
        Site(name: "Example", slug: "example", path: path, port: 8080, imageTag: "wordpress:latest")
    }

    // MARK: - Destination

    func testDestinationKeepsTheFolderName() {
        let example = site(at: folder.appendingPathComponent("old/example-folder"))
        let destination = SiteMover.destination(for: example, inParent: folder.appendingPathComponent("new"))
        XCTAssertEqual(destination.path, folder.appendingPathComponent("new/example-folder").path)
    }

    func testValidateAcceptsAFreeDestination() throws {
        let example = site(at: folder.appendingPathComponent("old/example"))
        XCTAssertNoThrow(try SiteMover.validate(example, destination: folder.appendingPathComponent("new/example")))
    }

    func testValidateRejectsInvalidDestinations() throws {
        let source = folder.appendingPathComponent("old/example")
        let example = site(at: source)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("taken/example"), withIntermediateDirectories: true)

        let cases: [(URL, SiteMover.Failure)] = [
            (source, .sameFolder(source.path)),
            (source.appendingPathComponent("inner"), .destinationInsideSite(source.appendingPathComponent("inner").path)),
            (folder.appendingPathComponent("a:b/example"), .invalidDestination(folder.appendingPathComponent("a:b/example").path)),
            (folder.appendingPathComponent("taken/example"), .destinationExists(folder.appendingPathComponent("taken/example").path)),
        ]
        for (destination, expected) in cases {
            XCTAssertThrowsError(try SiteMover.validate(example, destination: destination), destination.path) { error in
                XCTAssertEqual(error as? SiteMover.Failure, expected)
            }
        }
    }

    func testValidateRejectsArchivedAndMissingSites() {
        var archived = site(at: folder.appendingPathComponent("old/example"))
        archived.archivedAt = Date()
        XCTAssertThrowsError(try SiteMover.validate(archived, destination: folder.appendingPathComponent("new/example"))) { error in
            XCTAssertEqual(error as? SiteMover.Failure, .archived("example"))
        }

        let missing = site(at: folder.appendingPathComponent("old/missing"))
        XCTAssertThrowsError(try SiteMover.validate(missing, destination: folder.appendingPathComponent("new/missing"))) { error in
            XCTAssertEqual(error as? SiteMover.Failure, .sourceMissing(folder.appendingPathComponent("old/missing").path))
        }
    }

    // MARK: - Rebasing

    func testRebaseMatchesWholePathComponents() {
        XCTAssertEqual(SiteMover.rebase("/a/site", from: "/a/site", to: "/b/site"), "/b/site")
        XCTAssertEqual(SiteMover.rebase("/a/site/wordpress", from: "/a/site", to: "/b/site"), "/b/site/wordpress")
        XCTAssertNil(SiteMover.rebase("/a/site-two", from: "/a/site", to: "/b/site"))
        XCTAssertNil(SiteMover.rebase("/elsewhere", from: "/a/site", to: "/b/site"))
    }

    func testLexicalPathDropsDotComponentsAndKeepsSymlinks() {
        XCTAssertEqual(SiteMover.lexicalPath(URL(fileURLWithPath: "/a/./b/../c/", isDirectory: true)), "/a/c")
        XCTAssertEqual(SiteMover.lexicalPath(URL(fileURLWithPath: "/private/tmp/../tmp/x")), "/private/tmp/x")
        XCTAssertEqual(SiteMover.lexicalPath(URL(string: "file:///private/var/example/")!), "/private/var/example")
    }

    func testRealPathResolvesSymlinks() throws {
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.appendingPathComponent("old"))
        XCTAssertEqual(SiteMover.realPath(link.appendingPathComponent("example")), folder.appendingPathComponent("old/example").path)
        XCTAssertEqual(SiteMover.realPath(folder.appendingPathComponent("absent")), folder.appendingPathComponent("absent").path)
    }

    func testRebasePathsUpdatesEveryPathInsideTheSiteFolder() {
        let old = URL(fileURLWithPath: "/a/example", isDirectory: true)
        let new = URL(fileURLWithPath: "/b/example", isDirectory: true)
        var example = site(at: old)
        example.agentToolsRoot = "/a/example/wordpress/wp-content/plugins/demo"
        example.mounts = [
            Mount(hostPath: "/a/example/shared", containerPath: "/var/www/html/wp-content/uploads"),
            Mount(hostPath: "/projects/demo", containerPath: "/var/www/html/wp-content/plugins/demo"),
        ]
        let other = Site(name: "Other", slug: "other", path: URL(fileURLWithPath: "/a/example-other", isDirectory: true),
                         port: 8081, imageTag: "wordpress:latest")
        var env = WorktreeEnvService.descriptor(parent: example, repoRelPath: "wp-content/plugins/demo",
                                                branch: "feature", port: 8082)
        env.inheritedMounts = example.mounts
        var envelope = StoreEnvelope(sites: [example, other], envs: [env])

        SiteMover.rebasePaths(in: &envelope, from: old, to: new)

        let moved = envelope.sites[0]
        XCTAssertEqual(moved.path.path, "/b/example")
        XCTAssertEqual(moved.agentToolsRoot, "/b/example/wordpress/wp-content/plugins/demo")
        XCTAssertEqual(moved.mounts.map(\.hostPath), ["/b/example/shared", "/projects/demo"])
        XCTAssertEqual(envelope.sites[1].path.path, "/a/example-other")
        let movedEnv = envelope.envs[0]
        XCTAssertEqual(movedEnv.worktreePath.path, "/b/example/.worktrees/feature")
        XCTAssertEqual(movedEnv.envPath.path, "/b/example/.envs/feature")
        XCTAssertEqual(movedEnv.inheritedMounts.map(\.hostPath), ["/b/example/shared", "/projects/demo"])
    }

    // MARK: - Git worktrees

    func testWorktreeRepairReconnectsMovedWorktrees() async throws {
        let oldSite = folder.appendingPathComponent("old/example")
        let repo = oldSite.appendingPathComponent("wordpress/wp-content/plugins/demo")
        let inside = oldSite.appendingPathComponent(".worktrees/inside")
        let outside = folder.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await run(["init", "-q"], in: repo)
        try await run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        try await run(["worktree", "add", "-q", "-b", "inside", inside.path], in: repo)
        try await run(["worktree", "add", "-q", "-b", "outside", outside.path], in: repo)

        let newSite = folder.appendingPathComponent("new/example")
        try FileManager.default.createDirectory(at: newSite.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: oldSite, to: newSite)
        let movedRepo = newSite.appendingPathComponent("wordpress/wp-content/plugins/demo")

        let git = GitService()
        let stored = try await git.worktreePaths(repo: movedRepo)
        XCTAssertTrue(stored.contains(inside.path))
        let moved = stored.compactMap { SiteMover.rebase($0, from: oldSite.path, to: newSite.path) }
        XCTAssertEqual(moved, [newSite.appendingPathComponent(".worktrees/inside").path])
        try await git.worktreeRepair(repo: movedRepo, paths: moved)

        let insideBranch = try await git.currentBranch(repo: newSite.appendingPathComponent(".worktrees/inside"))
        let outsideBranch = try await git.currentBranch(repo: outside)
        XCTAssertEqual(insideBranch, "inside")
        XCTAssertEqual(outsideBranch, "outside")
        let repaired = try await git.worktreePaths(repo: movedRepo)
        XCTAssertTrue(repaired.contains(newSite.appendingPathComponent(".worktrees/inside").path))
    }

    private func run(_ args: [String], in directory: URL) async throws {
        let result = try await ProcessRunner.run(executable: GitService.defaultBinaryPath, args: args, cwd: directory)
        XCTAssertTrue(result.succeeded, result.stderr)
    }
}
