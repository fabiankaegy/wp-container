import Foundation

/// Auto-stop-when-idle policy (issue #16).
///
/// Apple `container` runs one lightweight VM per container and never returns
/// guest memory to macOS, so a VM's host footprint is its high-water mark and
/// the ONLY way to reclaim it is to stop the container outright. VM boot is ~1s,
/// which makes stop-when-idle / start-on-request the cheapest lever available:
/// the proxy parks instances nobody is using and wakes them on the next request.
///
/// The defaults are deliberately asymmetric:
///
/// - **Worktree envs default to 15 minutes.** They are the agent-fleet explosion
///   case — dozens can exist, most are touched once and then forgotten, and each
///   one is a ~500 MB VM. Losing one costs ~1s on the next request.
/// - **Parent sites default to OFF.** A site is the thing you are actually
///   working on; stopping it under a running `npm run watch`, a `wp-cli` shell,
///   or a long build would be a surprise. Opt in per site when you want it.
///
/// Configured values are per-instance and PERSISTED (`Site.idleStopMinutes` /
/// `WorktreeEnv.idleStopMinutes`) rather than kept in `UserDefaults`: the proxy
/// that enforces them may be running inside the app OR inside a headless
/// `wp-container proxy serve`, and UserDefaults is invisible across processes.
public enum IdlePolicy {
    /// Default idle timeout for a worktree environment, in minutes.
    public static let defaultEnvMinutes = 15
    /// Default idle timeout for a parent site, in minutes. `0` ⇒ disabled — a
    /// site is only ever auto-stopped when the user explicitly opts in.
    public static let defaultSiteMinutes = 0

    /// The minute values the app pickers and the docs advertise (besides
    /// "Default" and "Off"). Kept here so surfaces can't drift apart.
    public static let selectableMinutes = [5, 15, 30, 60]

    /// Resolve a persisted (possibly nil) setting into the timeout actually in
    /// force. `0` ⇒ auto-stop is off. Negative values (only reachable via a
    /// hand-edited store) are treated as off rather than as "stop immediately".
    public static func effectiveMinutes(configured: Int?, isEnv: Bool) -> Int {
        guard let configured else { return isEnv ? defaultEnvMinutes : defaultSiteMinutes }
        return configured > 0 ? configured : 0
    }

    /// Human label for a configured value, for CLI output and UI hints.
    public static func label(configured: Int?, isEnv: Bool) -> String {
        let effective = effectiveMinutes(configured: configured, isEnv: isEnv)
        guard configured != nil else {
            return effective == 0 ? "default (off)" : "default (\(effective) min)"
        }
        return effective == 0 ? "off" : "\(effective) min"
    }
}
