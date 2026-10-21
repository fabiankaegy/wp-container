import Foundation

/// Errors from the folder-layout helpers.
public enum SiteFoldersError: Error, Sendable, CustomStringConvertible {
    /// Seeding a worktree's gitignored runtime deps from the parent failed;
    /// carries the underlying rsync stderr/stdout for surfacing.
    case seedFailed(String)
    /// `cp -Rc` couldn't copy part of a folder (e.g. an unreadable file);
    /// carries cp's error lines.
    case cloneFailed(String)

    public var description: String {
        switch self {
        case .seedFailed(let detail):
            return "Failed to seed worktree runtime dependencies from the parent site: \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .cloneFailed(let detail):
            return "Failed to copy the parent site's files: \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// Filesystem helpers for site / env folder layout.
public enum SiteFolders {
    /// The built-in default root for new sites: `~/WP Container Sites`. Used as
    /// the fallback when no user override is set.
    public static var builtInDefaultSitesRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("WP Container Sites", isDirectory: true)
    }

    /// The preferences domain the app saves its settings in.
    static let appPreferencesDomain = "com.fabiankaegy.wpcontainer"

    /// Default root for new sites: the user's override from Settings (PLAN.md
    /// §2l, `UserDefaults` key `defaultSitesRoot`) when set, else the built-in
    /// `~/WP Container Sites`. Both the app's Add Site guide and the CLI honor it.
    public static var defaultSitesRoot: URL {
        defaultSitesRoot(preferencesDomain: appPreferencesDomain)
    }

    /// Reads the override from `preferencesDomain` by name, so the CLI sees the
    /// app's setting when it runs through the `wpc` symlink or as an installed
    /// copy, where the process has no bundle identifier of its own.
    static func defaultSitesRoot(preferencesDomain: String) -> URL {
        let override = CFPreferencesCopyAppValue("defaultSitesRoot" as CFString, preferencesDomain as CFString) as? String
        if let override, !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return builtInDefaultSitesRoot
    }

    /// Ensure `wordpress/` (and, for an instance that owns its DB container,
    /// `database/`) exist. A shared-database worktree env has no mariadb data
    /// directory of its own, so `.envs/<branch>/database/` is never created for
    /// it (issue #17).
    public static func ensure(for inst: any RunnableInstance) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: inst.wordpressFolder, withIntermediateDirectories: true)
        if inst.ownsDatabaseContainer {
            try fm.createDirectory(at: inst.databaseFolder, withIntermediateDirectories: true)
        }
    }

    /// APFS copy-on-write clone (`cp -Rc`). Off APFS, cp falls back to a plain
    /// copy on its own. Destination's parent is created if needed.
    public static func cloneCopyOnWrite(from source: URL, to destination: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Remove an existing destination so `cp` semantics are predictable.
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try await copyClone([source.path], to: destination.path)
    }

    /// Like `cloneCopyOnWrite(from:to:)`, but leaves the folder at `skipping`
    /// (a path relative to `source`, e.g. `wp-content`) out of the clone and puts
    /// an empty directory in its place. Every ancestor of that folder is
    /// recreated with the source's permissions and extended attributes, and its
    /// other entries cloned, so only that one subtree is missing.
    ///
    /// Path components match the on-disk names case-insensitively, like APFS
    /// does. If an ancestor is a symlink, it is cloned as a symlink (as a full
    /// clone would) and the skipped folder, which lives in its target, stays
    /// where it is.
    ///
    /// Used for a worktree env's `wordpress/`: the repo folder is shadow-mounted
    /// from the worktree, so a copy of it is never read. It's also usually the
    /// heaviest part of the site (node_modules, build output, agent worktrees
    /// nested inside the repo), where cloning file by file can take many minutes.
    public static func cloneCopyOnWrite(from source: URL, to destination: URL, skipping relativePath: String) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        var src = source
        var dst = destination
        var recreated: [(from: URL, to: URL)] = []
        // Metadata (mode, flags, xattrs, ACLs) is applied once each directory is
        // filled, deepest first, so a read-only ancestor doesn't block writing
        // its children. Best effort, like cp's own `-R` metadata handling.
        defer {
            for pair in recreated.reversed() {
                copyfile(pair.from.path, pair.to.path, nil, copyfile_flags_t(COPYFILE_METADATA))
            }
        }
        for component in relativePath.split(separator: "/").map(String.init) {
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            recreated.append((src, dst))
            let entries = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isSymbolicLinkKey])
            let match = entries.first { $0.lastPathComponent == component }
                ?? entries.first { $0.lastPathComponent.caseInsensitiveCompare(component) == .orderedSame }
            let isSymlink = (try? match?.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            guard let next = match, !isSymlink else {
                try await copyClone(entries.map(\.path), to: dst.path)
                // Missing in the source: still leave the empty folder.
                if match == nil {
                    try fm.createDirectory(at: destination.appendingPathComponent(relativePath, isDirectory: true),
                                           withIntermediateDirectories: true)
                }
                return
            }
            try await copyClone(entries.filter { $0.lastPathComponent != next.lastPathComponent }.map(\.path), to: dst.path)
            src = next
            dst = dst.appendingPathComponent(next.lastPathComponent, isDirectory: true)
        }
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
    }

    /// `cp -Rc <sources…> <destination>`. cp can't copy sockets: it skips them
    /// with a warning and exits 1 after copying everything else. A stale socket
    /// is never needed in a clone, so that alone counts as success. Anything else
    /// (e.g. an unreadable file) throws `SiteFoldersError.cloneFailed`.
    private static func copyClone(_ sources: [String], to destination: String) async throws {
        guard !sources.isEmpty else { return }
        let result = try await ProcessRunner.run(executable: "/bin/cp", args: ["-Rc"] + sources + [destination])
        guard !result.succeeded else { return }
        let lines = result.stderr.split(separator: "\n")
        let problems = lines.filter { !$0.hasSuffix(" is a socket (not copied).") }
        if !lines.isEmpty && problems.isEmpty { return }
        throw SiteFoldersError.cloneFailed(problems.isEmpty ? "cp exited \(result.exitCode)" : problems.joined(separator: "\n"))
    }

    /// Files rsync never seeds into a worktree: `.git` (the worktree already has
    /// its own gitlink) and `node_modules` — a build *input*, not needed at
    /// runtime once the built output (e.g. `dist/`) is copied, and by far the
    /// largest cost. Kept as a constant so the policy is visible in one place.
    public static let seedExcludes = [".git", "node_modules"]

    /// Seed a freshly-checked-out worktree with the gitignored runtime deps that
    /// live in the parent site's on-disk repo folder — `vendor/` (Composer),
    /// built assets like `dist/`, and any provisioned `mu-plugins`/`plugins`
    /// when the whole `wp-content` is the repo. Without this the shadow-mounted
    /// worktree only carries committed files and the env 500s on missing
    /// autoloaders / silently loads a broken site (issue #14).
    ///
    /// `rsync --ignore-existing` is the whole trick: `git worktree add` has
    /// already checked out the branch's tracked files, so ignoring existing
    /// destination paths means we ONLY fill in what the worktree lacks and never
    /// clobber a branch-specific version of a tracked file with the parent's
    /// working copy. See `seedExcludes` for what is skipped.
    ///
    /// Git worktrees nested anywhere inside the parent repo are skipped as well
    /// (see `nestedWorktrees(in:)`). Each is a full checkout of its own, and
    /// copying them would multiply the seed by the number of worktrees.
    ///
    /// A no-op-but-successful run (parent has nothing gitignored) is fine. Throws
    /// `SiteFoldersError.seedFailed` on a real rsync error so the caller can roll
    /// back the half-created env.
    public static func seedIgnoredRuntimeDeps(from parentRepo: URL, into worktree: URL) async throws {
        // Trailing slashes make rsync copy the *contents* of parentRepo into
        // worktree (not nest it under a subfolder).
        func withSlash(_ u: URL) -> String { u.path.hasSuffix("/") ? u.path : u.path + "/" }
        var args = ["-a", "--ignore-existing"]
        for pattern in seedExcludes { args += ["--exclude", pattern] }
        // A leading `/` anchors the pattern at the transfer root, so only that
        // exact path is skipped, not every folder that happens to share its name.
        for path in nestedWorktrees(in: parentRepo) { args += ["--exclude", "/" + rsyncLiteral(path)] }
        args += [withSlash(parentRepo), withSlash(worktree)]
        let result = try await ProcessRunner.run(executable: "/usr/bin/rsync", args: args)
        guard result.succeeded else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw SiteFoldersError.seedFailed(detail)
        }
    }

    /// Paths, relative to `repo`, of every git worktree nested inside it: any
    /// folder whose `.git` is a FILE pointing into a `worktrees/` admin dir. That
    /// covers the repo's own linked worktrees (`.claude/worktrees/agent-1`) and
    /// those of gitignored repos inside it (`plugins/x/.worktrees/fix`), whether
    /// or not git still tracks them. Regular clones (e.g. Composer source
    /// packages) have a `.git` directory, and submodules point into `modules/`,
    /// so both are kept.
    static func nestedWorktrees(in repo: URL) -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: repo.path) else { return [] }
        var found: [String] = []
        while let rel = walker.nextObject() as? String {
            guard walker.fileAttributes?[.type] as? FileAttributeType == .typeDirectory else { continue }
            let name = (rel as NSString).lastPathComponent
            // Never seeded anyway (see `seedExcludes`), and often huge.
            if seedExcludes.contains(name) {
                walker.skipDescendants()
                continue
            }
            let dotGit = repo.appendingPathComponent(rel).appendingPathComponent(".git")
            guard let link = try? String(contentsOf: dotGit, encoding: .utf8),
                  link.hasPrefix("gitdir: "), link.contains("/worktrees/") else { continue }
            found.append(rel)
            walker.skipDescendants()
        }
        return found.sorted()
    }

    /// Escape `path` for use as a literal rsync filter pattern. rsync only
    /// treats `\` as an escape when the pattern also has a wildcard, so a path
    /// without one is returned unchanged.
    static func rsyncLiteral(_ path: String) -> String {
        guard path.contains(where: { "*?[".contains($0) }) else { return path }
        return path.reduce(into: "") { out, c in
            if "*?[\\".contains(c) { out.append("\\") }
            out.append(c)
        }
    }
}
