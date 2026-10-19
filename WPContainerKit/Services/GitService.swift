import Foundation

public struct GitError: Error, Sendable, CustomStringConvertible {
    public let command: [String]
    public let exitCode: Int32
    public let stderr: String
    public var description: String {
        "`git \(command.joined(separator: " "))` failed (exit \(exitCode)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

/// A git repository discovered under a site's `wp-content`.
public struct GitRepo: Sendable, Equatable, Identifiable {
    public var id: String { relativePath }
    /// Path relative to `wordpress/`, e.g. `wp-content/plugins/my-plugin`.
    public var relativePath: String
    public var absolutePath: URL
    public var currentBranch: String?

    public init(relativePath: String, absolutePath: URL, currentBranch: String?) {
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.currentBranch = currentBranch
    }
}

/// Actor wrapping `/usr/bin/git` with argument arrays.
public actor GitService {
    public static let defaultBinaryPath = "/usr/bin/git"
    public let binaryPath: String

    public init(binaryPath: String = GitService.defaultBinaryPath) {
        self.binaryPath = binaryPath
    }

    @discardableResult
    private func git(_ args: [String], cwd: URL? = nil) async throws -> String {
        let result = try await ProcessRunner.run(executable: binaryPath, args: args, cwd: cwd)
        guard result.exitCode == 0 else {
            throw GitError(command: args, exitCode: result.exitCode, stderr: result.stderr)
        }
        return result.stdout
    }

    /// Scan `wp-content` for git repos (dirs or files named `.git`), max depth 4
    /// below `wordpressFolder`. `relativePath` is expressed relative to
    /// `wordpressFolder` (so it reads `wp-content/...`).
    public func repos(under wordpressFolder: URL, maxDepth: Int = 4) async -> [GitRepo] {
        let fm = FileManager.default
        let root = wordpressFolder.appendingPathComponent("wp-content", isDirectory: true)
        guard fm.fileExists(atPath: root.path) else { return [] }

        var found: [GitRepo] = []
        var stack: [(url: URL, depth: Int)] = [(root, 0)]
        while let (dir, depth) = stack.popLast() {
            let dotGit = dir.appendingPathComponent(".git")
            if fm.fileExists(atPath: dotGit.path) {
                let rel = relativePath(of: dir, from: wordpressFolder)
                let branch = try? await currentBranch(repo: dir)
                found.append(GitRepo(relativePath: rel, absolutePath: dir, currentBranch: branch))
                continue // don't descend into a repo
            }
            guard depth < maxDepth else { continue }
            let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir { stack.append((entry, depth + 1)) }
            }
        }
        return found.sorted { $0.relativePath < $1.relativePath }
    }

    public func currentBranch(repo: URL) async throws -> String {
        let out = try await git(["-C", repo.path, "rev-parse", "--abbrev-ref", "HEAD"], cwd: repo)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func branches(repo: URL) async throws -> [String] {
        let out = try await git(["-C", repo.path, "for-each-ref", "--format=%(refname:short)", "refs/heads"], cwd: repo)
        return out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public func branchExists(repo: URL, branch: String) async -> Bool {
        (try? await git(["-C", repo.path, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"])) != nil
    }

    /// `git -C <repo> worktree add [-b <branch> [<from>]] <path> [<branch>]`.
    public func worktreeAdd(repo: URL, path: URL, branch: String, createIfMissing: Bool, from: String?) async throws {
        let exists = await branchExists(repo: repo, branch: branch)
        var args = ["-C", repo.path, "worktree", "add"]
        if exists {
            args += [path.path, branch]
        } else if createIfMissing {
            args += ["-b", branch, path.path]
            if let from { args.append(from) }
        } else {
            args += [path.path, branch]
        }
        try await git(args, cwd: repo)
    }

    /// `git -C <repo> worktree remove [--force] <path>`.
    public func worktreeRemove(repo: URL, path: URL, force: Bool) async throws {
        var args = ["-C", repo.path, "worktree", "remove"]
        if force { args.append("--force") }
        args.append(path.path)
        try await git(args, cwd: repo)
    }

    /// Whether the checkout at `path` has uncommitted changes, untracked files
    /// included. A missing checkout has none. Any other git failure reads as
    /// dirty, so a caller deciding whether removal is safe errs toward keeping it.
    public func hasUncommittedChanges(at path: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        guard let status = try? await git(["-C", path.path, "status", "--porcelain"], cwd: path) else { return true }
        return !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func relativePath(of url: URL, from base: URL) -> String {
        let baseComps = base.standardizedFileURL.pathComponents
        let urlComps = url.standardizedFileURL.pathComponents
        if urlComps.count > baseComps.count && Array(urlComps.prefix(baseComps.count)) == baseComps {
            return urlComps.dropFirst(baseComps.count).joined(separator: "/")
        }
        return url.lastPathComponent
    }
}
