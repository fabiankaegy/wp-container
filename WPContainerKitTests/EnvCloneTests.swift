import XCTest
@testable import WPContainerKit

/// Coverage for what a worktree env copies from its parent: the env's
/// `wordpress/` clone leaves out the shadow-mounted repo folder, and the seed
/// into the new worktree leaves out git worktrees nested inside the parent repo.
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

    func testCloneMatchesTheRepoPathCaseInsensitively() async throws {
        let src = root.appendingPathComponent("wordpress")
        try write("wp-content/themes/mine/style.css", in: src)
        try write("wp-content/themes/other/style.css", in: src)
        let dst = root.appendingPathComponent("env/wordpress")

        try await SiteFolders.cloneCopyOnWrite(from: src, to: dst, skipping: "wp-content/Themes/mine")

        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dst.appendingPathComponent("wp-content").path), ["themes"])
        XCTAssertTrue(exists("wp-content/themes/other/style.css", in: dst))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dst.appendingPathComponent("wp-content/themes/mine").path), [])
    }

    func testCloneKeepsASymlinkedAncestorAsALink() async throws {
        let shared = root.appendingPathComponent("shared-plugins")
        try write("mine/plugin.php", in: shared)
        try write("other/plugin.php", in: shared)
        let src = root.appendingPathComponent("wordpress")
        try fm.createDirectory(at: src.appendingPathComponent("wp-content"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: src.appendingPathComponent("wp-content/plugins"), withDestinationURL: shared)
        let dst = root.appendingPathComponent("env/wordpress")

        try await SiteFolders.cloneCopyOnWrite(from: src, to: dst, skipping: "wp-content/plugins/mine")

        let link = try fm.destinationOfSymbolicLink(atPath: dst.appendingPathComponent("wp-content/plugins").path)
        XCTAssertEqual(link, shared.path)
    }

    func testCloneKeepsAncestorPermissions() async throws {
        let src = root.appendingPathComponent("wordpress")
        try write("wp-content/themes/mine/style.css", in: src)
        try fm.setAttributes([.posixPermissions: 0o775], ofItemAtPath: src.appendingPathComponent("wp-content").path)
        let dst = root.appendingPathComponent("env/wordpress")

        try await SiteFolders.cloneCopyOnWrite(from: src, to: dst, skipping: "wp-content/themes/mine")

        let mode = try fm.attributesOfItem(atPath: dst.appendingPathComponent("wp-content").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o775)
    }

    func testCloneSkipsSocketsWithoutFailing() async throws {
        let src = root.appendingPathComponent("wordpress")
        try write("wp-content/uploads/a.jpg", in: src)
        try write("wp-content/themes/mine/style.css", in: src)
        let socketPath = src.appendingPathComponent("wp-content/uploads/s").path
        let fd = try bindSocket(at: socketPath)
        defer { close(fd) }
        let dst = root.appendingPathComponent("env/wordpress")

        try await SiteFolders.cloneCopyOnWrite(from: src, to: dst, skipping: "wp-content/themes/mine")

        XCTAssertTrue(exists("wp-content/uploads/a.jpg", in: dst))
        XCTAssertFalse(exists("wp-content/uploads/s", in: dst))
    }

    func testSeedSkipsNestedWorktreesOnly() async throws {
        let repo = root.appendingPathComponent("repo")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        try write("vendor/autoload.php", in: repo)
        // A linked worktree of the repo itself.
        try git(["worktree", "add", "-q", "-b", "inside", ".claude/worktrees/agent"], in: repo)
        try write(".claude/worktrees/agent/vendor/autoload.php", in: repo)
        // A worktree git no longer tracks, inside a gitignored nested repo.
        try write("plugins/x/.worktrees/fix/.git", in: repo, contents: "gitdir: /elsewhere/x/.git/worktrees/fix\n")
        try write("plugins/x/.worktrees/fix/big.bin", in: repo)
        // A Composer source package: a plain clone with a `.git` directory.
        try write("vendor/acme/lib/.git/HEAD", in: repo)
        try write("vendor/acme/lib/src.php", in: repo)
        let worktree = root.appendingPathComponent("worktree")
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)

        XCTAssertEqual(SiteFolders.nestedWorktrees(in: repo), [".claude/worktrees/agent", "plugins/x/.worktrees/fix"])
        try await SiteFolders.seedIgnoredRuntimeDeps(from: repo, into: worktree)

        XCTAssertTrue(exists("vendor/autoload.php", in: worktree))
        XCTAssertTrue(exists("vendor/acme/lib/src.php", in: worktree))
        XCTAssertFalse(exists(".claude/worktrees/agent", in: worktree))
        XCTAssertFalse(exists("plugins/x/.worktrees/fix", in: worktree))
        XCTAssertTrue(exists("plugins/x", in: worktree))
    }

    func testSeedEscapesWildcardsInWorktreePaths() async throws {
        let repo = root.appendingPathComponent("repo")
        try write(".worktrees/agent[1]/.git", in: repo, contents: "gitdir: /r/.git/worktrees/agent1\n")
        try write(".worktrees/agent[1]/big.bin", in: repo)
        try write(".worktrees/agent1/keep.txt", in: repo)
        let worktree = root.appendingPathComponent("worktree")
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)

        try await SiteFolders.seedIgnoredRuntimeDeps(from: repo, into: worktree)

        XCTAssertFalse(exists(".worktrees/agent[1]", in: worktree))
        XCTAssertTrue(exists(".worktrees/agent1/keep.txt", in: worktree))
    }

    private func write(_ relativePath: String, in base: URL, contents: String = "x") throws {
        let url = base.appendingPathComponent(relativePath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    /// Bind a Unix socket at `path` (relative to the cwd, since temp paths
    /// overflow `sun_path`). Returns the descriptor to close.
    private func bindSocket(at path: String) throws -> Int32 {
        let dir = (path as NSString).deletingLastPathComponent
        let previous = fm.currentDirectoryPath
        fm.changeCurrentDirectoryPath(dir)
        defer { fm.changeCurrentDirectoryPath(previous) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let name = (path as NSString).lastPathComponent
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in name.utf8.enumerated() { buf[i] = b }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(rc, 0, "bind \(path)")
        return fd
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
