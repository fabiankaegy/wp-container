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

/// The privileged operations the helper exposes over XPC. Exactly two mutating
/// operations plus a version probe. Every mutating call carries an
/// `AuthorizationExternalForm` (as `Data`) that the helper independently
/// re-verifies against `authorizationRightName` before touching the file.
/// `reply` returns `nil` on success or a human-readable error string on failure.
@objc public protocol HostsHelperProtocol {
    func writeHostsBlock(entries: [String],
                         authorization: Data,
                         reply: @escaping @Sendable (String?) -> Void)
    func removeHostsBlock(authorization: Data,
                          reply: @escaping @Sendable (String?) -> Void)
    func helperVersion(reply: @escaping @Sendable (String) -> Void)
}

/// The helper's implementation version, returned by `helperVersion` and used as
/// a reachability probe.
public let hostsHelperVersion = "0.1.1"

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
