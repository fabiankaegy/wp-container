import Foundation
import WPContainerKit

/// Copy for how recently a worktree env was used and when a settled one is
/// purged, shared by the Branches card, the sidebar and the env detail pane.
enum EnvUsageText {
    /// "Used 2 hours ago", or "Unused for 12 days" once the env is stale.
    static func lastUsed(_ env: WorktreeEnv, now: Date = Date()) -> String {
        if EnvSettlement.isStale(env, now: now) {
            return "Unused for \(EnvSettlement.daysUnused(env, now: now)) days"
        }
        return "Used " + relative(env.lastUsedAt, now: now)
    }

    /// "Settled 3 days ago · deletes in 27 days" (the second part only while
    /// auto-purge is on).
    static func settled(_ env: WorktreeEnv, now: Date = Date()) -> String {
        guard let settledAt = env.settledAt else { return "" }
        var text = "Settled " + relative(settledAt, now: now)
        if AppSettings.autoPurgeSettledEnvs,
           let purge = EnvSettlement.purgeDate(env, afterDays: AppSettings.purgeSettledAfterDays) {
            text += purge > now ? " · deletes " + relative(purge, now: now) : " · deletes soon"
        }
        return text
    }

    private static func relative(_ date: Date, now: Date) -> String {
        guard abs(date.timeIntervalSince(now)) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
