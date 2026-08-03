import Foundation

/// Auto-stop-when-idle policy (issue #16).
///
/// Apple `container` runs one lightweight VM per container and never returns
/// guest memory to macOS, so a VM's host footprint is its high-water mark and
/// the ONLY way to reclaim it is to stop the container outright. VM boot is ~1s,
/// which makes stop-when-idle / start-on-request the cheapest lever available:
/// the proxy parks instances nobody is using and wakes them on the next request.
///
/// **Both kinds default to OFF — the feature is entirely opt-in.**
///
/// Envs were briefly defaulted to 15 minutes, which was wrong given what the
/// idle clock can actually observe. Activity is measured from
///
/// 1. requests the proxy routes (i.e. the `<slug>.localhost` / custom-domain
///    hostnames), and
/// 2. the persisted `lastActivityAt` stamp that wp-cli, MCP tool calls,
///    magic-login and explicit starts write.
///
/// It CANNOT see a request that goes straight to `http://127.0.0.1:<port>` —
/// and that is exactly the URL worktree envs are advertised at throughout the
/// app, the CLI and the JSON payloads, and what `wpUpdateURLsArgs` pins
/// WordPress's `home`/`siteurl` to. For such an env a browser-only workflow
/// looks completely idle, so an on-by-default timeout would stop environments
/// while somebody was using them. Wake-on-request has the mirror-image problem:
/// it only fires for hostnames the proxy serves, so the advertised
/// `127.0.0.1:<port>` URL of a parked env just fails to connect.
///
/// Until canonical env URLs move behind the proxy, the honest position is
/// opt-in: 15 minutes is offered first in the pickers and recommended in the
/// docs for agent-driven environments (where the `lastActivityAt` stamps make
/// tracking reliable), but nothing is ever stopped unless it was asked for.
///
/// Configured values are per-instance and PERSISTED (`Site.idleStopMinutes` /
/// `WorktreeEnv.idleStopMinutes`) rather than kept in `UserDefaults`: the proxy
/// that enforces them may be running inside the app OR inside a headless
/// `wp-container proxy serve`, and UserDefaults is invisible across processes.
public enum IdlePolicy {
    /// Default idle timeout for a worktree environment, in minutes. `0` ⇒
    /// disabled (see the type doc — the env's advertised URL bypasses the proxy).
    public static let defaultEnvMinutes = 0
    /// Default idle timeout for a parent site, in minutes. `0` ⇒ disabled — a
    /// site is only ever auto-stopped when the user explicitly opts in.
    public static let defaultSiteMinutes = 0

    /// The value we recommend when somebody does opt in — long enough that a
    /// short pause in an agent's work never costs a restart, short enough that a
    /// forgotten environment doesn't hold ~500 MB all afternoon.
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

    /// Which traffic the idle clock can and cannot see, as one sentence surfaces
    /// can print verbatim. Kept next to the policy so the caveat travels with it.
    public static let activityCaveat =
        "Activity is counted from requests to the proxied hostnames "
        + "(<slug>.localhost or a custom domain), plus wp-cli, MCP and magic-login "
        + "use. Requests straight to http://127.0.0.1:<port> are invisible to it, "
        + "and wake-on-request only works through the proxied hostname."
}
