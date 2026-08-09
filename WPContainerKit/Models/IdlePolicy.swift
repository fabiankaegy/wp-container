import Foundation

/// Auto-stop-when-idle policy (issue #16).
///
/// Apple `container` runs one lightweight VM per container and never returns
/// guest memory to macOS, so a VM's host footprint is its high-water mark and
/// the ONLY way to reclaim it is to stop the container outright. VM boot is ~1s,
/// which makes stop-when-idle / start-on-request the cheapest lever available:
/// the proxy parks instances nobody is using and wakes them on the next request.
///
/// **Envs default to 180 minutes (3h); sites default to OFF.** A freshly
/// created env that is still on the BUILT-IN DEFAULT additionally gets a
/// `envCreationGraceMinutes` grace window during which it is never
/// idle-stopped (see that constant). An env with an EXPLICIT timeout
/// (`wp-container idle <env> --minutes 15`, `--off`, or any other configured
/// value) is never subject to the grace window — an explicit override always
/// wins, exactly like it always wins over the default itself.
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
    /// real use (see the type doc), and an unused env is ~500 MB of VM. 180
    /// minutes (3h) rather than something tighter because a fresh env is usually
    /// part of a whole day's work session — see `envCreationGraceMinutes`, which
    /// suspends this timeout entirely right after creation.
    public static let defaultEnvMinutes = 180
    /// Default idle timeout for a parent site, in minutes. `0` ⇒ disabled — a
    /// site is only ever auto-stopped when the user explicitly opts in.
    public static let defaultSiteMinutes = 0

    /// Minutes after an env's CREATION during which it is never idle-stopped,
    /// regardless of traffic (or the lack of it) — PROVIDED it is still on the
    /// built-in default (see `isExemptFromIdleStop(configured:createdAt:now:)`).
    /// A freshly created env is part of an active work session that can easily
    /// span most of a day; the memory-reclaiming benefit of idle-stop only
    /// matters once work has moved on to a LATER day, so day-one is exempt.
    /// Applies only to envs on the default — sites default to off and opt in
    /// deliberately, and an env with an explicit timeout has already opted out
    /// of the default's judgment call. See `HTTPSProxy.sweepIdleInstances`.
    public static let envCreationGraceMinutes = 360

    /// The value we recommend — the env default, and what a site should pick if it
    /// opts in. Long enough that a short pause in an agent's work never costs a
    /// restart, short enough that a forgotten environment doesn't hold ~500 MB for
    /// days.
    public static let recommendedMinutes = defaultEnvMinutes

    /// The minute values the app pickers and the docs advertise (besides
    /// "Default" and "Never"). `recommendedMinutes` leads deliberately: it is the
    /// value the docs point at, so it should be the first thing offered rather
    /// than something to scroll past. Kept here so surfaces can't drift apart.
    public static let selectableMinutes = [recommendedMinutes, 15, 30, 60]

    /// Resolve a persisted (possibly nil) setting into the timeout actually in
    /// force. `0` ⇒ auto-stop is off. Negative values (only reachable via a
    /// hand-edited store) are treated as off rather than as "stop immediately".
    public static func effectiveMinutes(configured: Int?, isEnv: Bool) -> Int {
        guard let configured else { return isEnv ? defaultEnvMinutes : defaultSiteMinutes }
        return configured > 0 ? configured : 0
    }

    /// Whether an env created at `createdAt` is still inside its post-creation
    /// grace window at `now`, purely as a function of age. Exposed mainly so
    /// that window can be tested in isolation; `HTTPSProxy.sweepIdleInstances`
    /// should call `isExemptFromIdleStop(configured:createdAt:now:)` instead,
    /// which also accounts for an explicit per-instance override.
    public static func isWithinCreationGrace(createdAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(createdAt) / 60 < Double(envCreationGraceMinutes)
    }

    /// Whether the creation-grace window currently exempts this env from
    /// idle-stop. Only applies when `configured` is `nil` — i.e. the env is
    /// still on the built-in default — because an EXPLICIT timeout (`--minutes
    /// N`, `--off`, or any other configured value) is a deliberate opt-out of
    /// the default's judgment call and must always win, exactly like it already
    /// wins in `effectiveMinutes`. An env with `idleStopMinutes = 15` set one
    /// minute after creation is sweepable the moment it's been idle 15 minutes;
    /// only an env still following the default gets the day-one exemption.
    public static func isExemptFromIdleStop(configured: Int?, createdAt: Date, now: Date) -> Bool {
        guard configured == nil else { return false }
        return isWithinCreationGrace(createdAt: createdAt, now: now)
    }

    /// Human-friendly rendering of a minute count: whole hours render as "N
    /// hour(s)", anything else as "N min". Kept here so CLI output (`label`) and
    /// the app's picker (`IdleStopCard`) can't drift apart on wording.
    public static func formatMinutes(_ minutes: Int) -> String {
        guard minutes >= 60, minutes.isMultiple(of: 60) else { return "\(minutes) min" }
        let hours = minutes / 60
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    /// Human label for a configured value, for CLI output and UI hints.
    public static func label(configured: Int?, isEnv: Bool) -> String {
        let effective = effectiveMinutes(configured: configured, isEnv: isEnv)
        guard configured != nil else {
            return effective == 0 ? "default (off)" : "default (\(formatMinutes(effective)))"
        }
        return effective == 0 ? "off" : formatMinutes(effective)
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
