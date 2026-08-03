import Foundation

/// Auto-stop-when-idle policy (issue #16).
///
/// Apple `container` runs one lightweight VM per container and never returns
/// guest memory to macOS, so a VM's host footprint is its high-water mark and
/// the ONLY way to reclaim it is to stop the container outright. VM boot is ~1s,
/// which makes stop-when-idle / start-on-request the cheapest lever available:
/// the proxy parks instances nobody is using and wakes them on the next request.
///
/// **Envs default to 15 minutes; sites default to OFF.**
///
/// That asymmetry is about observability, not about which kind matters more.
/// Activity is measured from
///
/// 1. requests the proxy routes, and
/// 2. the persisted `lastActivityAt` stamp that wp-cli, MCP tool calls,
///    magic-login and explicit starts write.
///
/// For a worktree ENV, (1) is now everything. An env's container publishes no
/// host port: the proxy binds `127.0.0.1:<port>` itself and relays to the
/// container (`RunnableInstance.publishesPort`), so the URL the app, the CLI, the
/// JSON payloads and WordPress's own `home`/`siteurl` all point at is a proxied
/// URL. Every browser request to an env is observed, and a parked env wakes at
/// the exact URL its user already has open. Nothing about an env is invisible any
/// more, which is what makes an on-by-default timeout honest — and envs are the
/// many-of-them, ~500-MB-each case the feature exists for.
///
/// A SITE still publishes its own port, so a request straight to
/// `http://127.0.0.1:<port>` bypasses the proxy and is invisible to the idle
/// clock. That is the one remaining blind spot (see `activityNote(isEnv:)`), and it is
/// why sites stay opt-in — plus you are usually *working* in a site, whereas the
/// proxied `https://<slug>.localhost` / custom-domain URL is what a site is
/// normally opened at anyway.
///
/// Configured values are per-instance and PERSISTED (`Site.idleStopMinutes` /
/// `WorktreeEnv.idleStopMinutes`) rather than kept in `UserDefaults`: the proxy
/// that enforces them may be running inside the app OR inside a headless
/// `wp-container proxy serve`, and UserDefaults is invisible across processes.
public enum IdlePolicy {
    /// Default idle timeout for a worktree environment, in minutes. On by
    /// default: every request to an env goes through the proxy, so the clock sees
    /// real use (see the type doc), and an unused env is ~500 MB of VM.
    public static let defaultEnvMinutes = 15
    /// Default idle timeout for a parent site, in minutes. `0` ⇒ disabled — a
    /// site is only ever auto-stopped when the user explicitly opts in.
    public static let defaultSiteMinutes = 0

    /// The value we recommend — the env default, and what a site should pick if it
    /// opts in. Long enough that a short pause in an agent's work never costs a
    /// restart, short enough that a forgotten environment doesn't hold ~500 MB all
    /// afternoon.
    public static let recommendedMinutes = 15

    /// The minute values the app pickers and the docs advertise (besides
    /// "Default" and "Never"). `recommendedMinutes` leads deliberately: it is the
    /// value the docs point at, so it should be the first thing offered rather
    /// than something to scroll past. Kept here so surfaces can't drift apart.
    public static let selectableMinutes = [recommendedMinutes, 5, 30, 60]

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

    /// Which traffic the idle clock can and cannot see, as one paragraph surfaces
    /// can print verbatim. Kept next to the policy so the wording travels with it.
    ///
    /// The two kinds genuinely differ, so this takes `isEnv` rather than hedging
    /// into one sentence that is wrong for both: an env has no blind spot left
    /// (the proxy owns its port), while a site's own published port still bypasses
    /// the proxy entirely.
    public static func activityNote(isEnv: Bool) -> String {
        if isEnv {
            return "Every request to this environment is counted: its "
                + "http://127.0.0.1:<port> URL and its <slug>.localhost hostname both "
                + "run through the reverse proxy. So do wp-cli, MCP tool calls and "
                + "magic-login. The next request after a stop starts it again."
        }
        return "Activity is counted from requests to the proxied hostnames "
            + "(<slug>.localhost or a custom domain), plus wp-cli, MCP and magic-login "
            + "use. A site also publishes http://127.0.0.1:<port> itself, and requests "
            + "to that address bypass the proxy — they neither keep the site alive nor "
            + "wake it."
    }
}
