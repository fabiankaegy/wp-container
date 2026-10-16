import Foundation
import Security

/// Shared identifiers and the XPC contract between the WP Container app/CLI
/// (unprivileged clients) and the `wpc-hosts-helper` privileged daemon.
///
/// This file is compiled into BOTH `WPContainerKit` (so the app and CLI can talk
/// to the helper) and the `wpc-hosts-helper` target (so the daemon vends the
/// exact same interface). Keeping one source of truth guarantees the
/// `NSXPCInterface` matches on both ends.
public enum HostsHelperInfo {
    /// launchd `MachServices` name the daemon listens on and clients connect to.
    public static let machServiceName = "com.fabiankaegy.wpcontainer.hostshelper"

    /// Filename of the embedded launchd plist under
    /// `WPContainer.app/Contents/Library/LaunchDaemons/`. Passed to
    /// `SMAppService.daemon(plistName:)`.
    public static let daemonPlistName = "com.fabiankaegy.wpcontainer.hostshelper.plist"

    /// Custom authorization right that gates hosts writes. Installed into the
    /// policy database on first use; its rule is `authenticate-admin`, which is
    /// Touch ID-capable on hardware that supports it and shares a credential for
    /// a short grace period so back-to-back edits don't re-prompt.
    public static let authorizationRightName = "com.fabiankaegy.wpcontainer.modify-hosts"

    /// Comment shown in the system authorization dialog.
    public static let authorizationPrompt =
        "WP Container is updating /etc/hosts so your custom site domains resolve to this Mac."

    /// Code-signing requirement the helper enforces on every connecting client:
    /// same Apple Developer Team (OU `6FUP592FJ4`) and one of our two bundle IDs
    /// (the app or the CLI). Nothing else may drive the privileged operations.
    public static let clientCodeRequirement =
        "anchor apple generic"
        + " and certificate leaf[subject.OU] = \"6FUP592FJ4\""
        + " and (identifier \"com.fabiankaegy.wpcontainer\""
        + " or identifier \"com.fabiankaegy.wpcontainer.cli\")"

    /// Requirement matching any Developer-ID-signed WP Container binary from our
    /// team. Used app-side to decide whether the helper path is even available
    /// (ad-hoc Debug builds can't register or be verified as SMAppService daemons).
    public static let selfDeveloperIDRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"6FUP592FJ4\""
}

/// The privileged operations the helper exposes over XPC. Two hosts-file
/// mutations, a DNS-resolver repair, loopback-zone setup/teardown, and a
/// version probe. Every hosts-file mutation that can ADD a hostname carries an
/// `AuthorizationExternalForm` (as `Data`) that the helper independently
/// re-verifies against `authorizationRightName` before touching the file.
/// `reply` returns `nil` on success or a human-readable error string on failure.
@objc public protocol HostsHelperProtocol {
    func writeHostsBlock(entries: [String],
                         authorization: Data,
                         reply: @escaping @Sendable (String?) -> Void)
    func removeHostsBlock(authorization: Data,
                          reply: @escaping @Sendable (String?) -> Void)
    /// Restart mDNSResponder — the repair for a wedged etc-hosts subsystem,
    /// where hosts entries resolve everywhere EXCEPT Safari/CFNetwork (see
    /// `MDNSHostCheck`). Deliberately carries no authorization: restarting
    /// Apple's DNS daemon is non-destructive and discloses nothing, launchd
    /// respawns it on demand, and the listener already pins every client to our
    /// code-signing requirement — while an auth prompt would defeat the point,
    /// because the app calls this automatically when it detects the wedge.
    func repairDNSResolver(reply: @escaping @Sendable (String?) -> Void)
    /// Set up the owned loopback zone (PLAN.md §2f-ter, `LoopbackZone`):
    /// idempotently add the lo0 aliases, write `/etc/resolver/wpc.test`, load
    /// the pf redirect anchor (enabling pf with a reference token if needed),
    /// and re-point an existing managed `/etc/hosts` block at the aliases.
    /// Called by the proxy on every start.
    ///
    /// No authorization, like `repairDNSResolver`: every address, port and rule
    /// is a constant compiled into the helper, so the only client input is one
    /// Bool; it changes nothing beyond our own aliases, anchor and resolver file
    /// and our own marker block (whose hostnames it never adds to — it only
    /// swaps their address); and the listener already pins the client's code
    /// signature. A prompt on every proxy start would be unusable.
    ///
    /// `legacyLoopback` additionally redirects `127.0.0.1`/`::1` :80/:443 for
    /// instances still served at `*.localhost` URLs.
    func activateLoopbackZone(legacyLoopback: Bool, reply: @escaping @Sendable (String?) -> Void)
    /// Undo `activateLoopbackZone`: flush the anchor, release our pf enable
    /// token, remove the aliases and the resolver file, and re-point the managed
    /// hosts block back at 127.0.0.1/::1. Same no-authorization rationale — it
    /// only removes what activation added.
    func deactivateLoopbackZone(reply: @escaping @Sendable (String?) -> Void)
    func helperVersion(reply: @escaping @Sendable (String) -> Void)
}

/// The helper's implementation version, returned by `helperVersion` and used as
/// a reachability probe. Clients also gate calls an older helper didn't
/// implement on it — see `HostsHelperFeature`. An app update does not restart
/// an already-running helper, so a newer client meeting an older helper is the
/// normal state right after an upgrade, until the helper is next relaunched.
public let hostsHelperVersion = "0.3.0"

/// Helper operations newer than the original two, keyed by the helper version
/// that introduced them. Calling one on an older helper fails with an opaque
/// XPC error, so clients check `isSupported(by:)` first and degrade instead
/// (e.g. to the legacy wildcard proxy).
public enum HostsHelperFeature: String, Sendable {
    /// `repairDNSResolver`.
    case dnsRepair = "0.2.0"
    /// `activateLoopbackZone` / `deactivateLoopbackZone`, and hosts entries
    /// addressed to `LoopbackZone.ipv4`.
    case loopbackZone = "0.3.0"

    /// Whether a helper reporting `version` implements this feature.
    public func isSupported(by version: String) -> Bool {
        Self.compare(version, rawValue) != .orderedAscending
    }

    /// Numeric dotted-version comparison ("0.10.0" > "0.9.0").
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// Install (idempotently) the custom authorization right into the policy
/// database using `authRef`. Both the client (which holds an interactive ref)
/// and the root helper call this; `AuthorizationRightGet` short-circuits when it
/// already exists. Silent on failure — a missing right simply falls back to the
/// default (admin-authentication) rule, which is still safe.
public func wpcInstallHostsAuthorizationRight(_ authRef: AuthorizationRef) {
    let name = HostsHelperInfo.authorizationRightName
    let getStatus = name.withCString { AuthorizationRightGet($0, nil) }
    guard getStatus == errAuthorizationDenied else { return } // already present (or unknown error)
    _ = name.withCString { namePtr in
        AuthorizationRightSet(
            authRef,
            namePtr,
            kAuthorizationRuleAuthenticateAsAdmin as CFString,
            HostsHelperInfo.authorizationPrompt as CFString,
            nil,
            nil
        )
    }
}
