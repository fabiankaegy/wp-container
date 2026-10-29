import Foundation

/// When to suggest settling a worktree env, and when a settled one is purged.
///
/// Settling parks an env the way T3 Code settles a thread: it stops, gives its
/// ports back for reuse, and leaves the sidebar, but keeps its worktree, files
/// and database, so restoring it picks up where it left off. The app suggests
/// settling envs nobody has used for `suggestAfterDays`, and (when enabled in
/// Settings) purges envs that stayed settled past the purge window.
public enum EnvSettlement {
    /// Days without use before an active env is suggested for settling.
    public static let suggestAfterDays = 7
    /// Days a settled env waits before auto-purge, unless Settings says otherwise.
    public static let defaultPurgeAfterDays = 30
    /// Purge windows offered in Settings.
    public static let purgeAfterDayChoices = [7, 14, 30, 60, 90]

    private static let day: TimeInterval = 86_400

    /// Whole days `env` has gone unused at `now`.
    public static func daysUnused(_ env: WorktreeEnv, now: Date = Date()) -> Int {
        max(0, Int(now.timeIntervalSince(env.lastUsedAt) / day))
    }

    /// Whether an active env has gone unused long enough to suggest settling it.
    public static func isStale(_ env: WorktreeEnv, now: Date = Date()) -> Bool {
        guard env.share?.active != true else { return false }
        return !env.isSettled && daysUnused(env, now: now) >= suggestAfterDays
    }

    /// When a settled env becomes due for purge; nil while it is active.
    public static func purgeDate(_ env: WorktreeEnv, afterDays: Int) -> Date? {
        env.settledAt.map { $0.addingTimeInterval(TimeInterval(afterDays) * day) }
    }

    /// Whether a settled env has waited out the purge window at `now`.
    public static func isDueForPurge(_ env: WorktreeEnv, afterDays: Int, now: Date = Date()) -> Bool {
        guard let date = purgeDate(env, afterDays: afterDays) else { return false }
        return date <= now
    }
}
