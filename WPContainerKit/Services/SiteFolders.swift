import Foundation

/// Errors from the folder-layout helpers.
public enum SiteFoldersError: Error, Sendable, CustomStringConvertible {
    /// Seeding a worktree's gitignored runtime deps from the parent failed;
    /// carries the underlying rsync stderr/stdout for surfacing.
    case seedFailed(String)

    public var description: String {
        switch self {
        case .seedFailed(let detail):
            return "Failed to seed worktree runtime dependencies from the parent site: \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
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

    /// APFS copy-on-write clone (`cp -Rc`), falling back to a regular copy if
    /// CoW is unavailable. Destination's parent is created if needed.
    public static func cloneCopyOnWrite(from source: URL, to destination: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Remove an existing destination so `cp` semantics are predictable.
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        let result = try await ProcessRunner.run(
            executable: "/bin/cp",
            args: ["-Rc", source.path, destination.path]
        )
        if !result.succeeded {
            // Fallback: plain deep copy.
            if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
            try fm.copyItem(at: source, to: destination)
        }
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
    /// A no-op-but-successful run (parent has nothing gitignored) is fine. Throws
    /// `SiteFoldersError.seedFailed` on a real rsync error so the caller can roll
    /// back the half-created env.
    public static func seedIgnoredRuntimeDeps(from parentRepo: URL, into worktree: URL) async throws {
        // Trailing slashes make rsync copy the *contents* of parentRepo into
        // worktree (not nest it under a subfolder).
        func withSlash(_ u: URL) -> String { u.path.hasSuffix("/") ? u.path : u.path + "/" }
        var args = ["-a", "--ignore-existing"]
        for pattern in seedExcludes { args += ["--exclude", pattern] }
        args += [withSlash(parentRepo), withSlash(worktree)]
        let result = try await ProcessRunner.run(executable: "/usr/bin/rsync", args: args)
        guard result.succeeded else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw SiteFoldersError.seedFailed(detail)
        }
    }
}
