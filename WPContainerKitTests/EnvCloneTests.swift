import XCTest
@testable import WPContainerKit

/// Coverage for what a worktree env copies from its parent: the env's
/// `wordpress/` clone leaves out the shadow-mounted repo folder, and the seed
/// into the new worktree leaves out worktrees nested inside the parent repo.
final class EnvCloneTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("wpc-envclone-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    func testCloneSkipsTheRepoFolderButKeepsItsSiblings() async throws {
        let src = root.appendingPathComponent("wordpress")
        try write("wp-config.php", in: src)
        try write("wp-content/uploads/a.jpg", in: src)
        try write("wp-content/themes/mine/style.css", in: src)
        try write("wp-content/themes/other/style.css", in: src)
        let dst = root.appendingPathComponent("env/wordpress")

        try await SiteFolders.cloneCopyOnWrite(from: src, to: dst, skipping: "wp-content/themes/mine")

        XCTAssertTrue(exists("wp-config.php", in: dst))
        XCTAssertTrue(exists("wp-content/uploads/a.jpg", in: dst))
        XCTAssertTrue(exists("wp-content/themes/other/style.css", in: dst))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dst.appendingPathComponent("wp-content/themes/mine").path), [])
    }

    func testCloneReplacesAnExistingDestination() async throws {
        let src = root.appendingPathComponent("wordpress")
        try write("index.php", in: src)
        let dst = root.appendingPathComponent("env/wordpress")
        try write("stale.txt", in: dst)

        try await SiteFolders.cloneCopyOnWrite(from: src, to: dst, skipping: "wp-content")

        XCTAssertTrue(exists("index.php", in: dst))
        XCTAssertFalse(exists("stale.txt", in: dst))
        XCTAssertTrue(exists("wp-content", in: dst))
    }

    func testSeedSkipsNestedCheckoutsOnly() async throws {
        let repo = root.appendingPathComponent("repo")
        try write("vendor/autoload.php", in: repo)
        try write(".worktrees/feature/vendor/autoload.php", in: repo)
        try write("plugins/x/.worktrees/keep.txt", in: repo)
        let worktree = root.appendingPathComponent("worktree")
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)

        try await SiteFolders.seedIgnoredRuntimeDeps(from: repo, into: worktree,
                                                     nestedCheckouts: [".worktrees/feature"])

        XCTAssertTrue(exists("vendor/autoload.php", in: worktree))
        XCTAssertFalse(exists(".worktrees/feature", in: worktree))
        // Anchored: a same-named folder elsewhere is still copied.
        XCTAssertTrue(exists("plugins/x/.worktrees/keep.txt", in: worktree))
    }

    func testNestedWorktreesListsOnlyThoseInsideTheRepo() async throws {
        let repo = root.appendingPathComponent("repo")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        try git(["worktree", "add", "-q", "-b", "inside", ".claude/worktrees/agent"], in: repo)
        try git(["worktree", "add", "-q", "-b", "outside", root.appendingPathComponent("elsewhere").path], in: repo)

        let nested = await GitService().nestedWorktrees(in: repo)

        XCTAssertEqual(nested, [".claude/worktrees/agent"])
    }

    private func write(_ relativePath: String, in base: URL) throws {
        let url = base.appendingPathComponent(relativePath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func exists(_ relativePath: String, in base: URL) -> Bool {
        fm.fileExists(atPath: base.appendingPathComponent(relativePath).path)
    }

    private func git(_ args: [String], in repo: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", repo.path] + args
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "git \(args.joined(separator: " "))")
    }
}
