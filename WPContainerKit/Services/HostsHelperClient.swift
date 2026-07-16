import Foundation
import Security
import ServiceManagement
import os

/// App/CLI-side driver for the privileged `wpc-hosts-helper` daemon (PLAN.md
/// §2f-bis). Owns three things:
///   1. SMAppService registration state for the embedded daemon,
///   2. the interactive authorization (`AuthorizationCreate` +
///      `AuthorizationCopyRights` with interaction → the Touch ID-capable system
///      dialog), and
///   3. the XPC round-trip that hands the resulting `AuthorizationExternalForm`
///      to the helper, which re-verifies everything before writing `/etc/hosts`.
///
/// The security boundary lives in the helper; this side is a thin, best-effort
/// client. `HostsFileService` prefers it when the helper is registered and falls
/// back to the legacy `osascript` flow otherwise.
public enum HostsHelperClient {
    static let log = Logger(subsystem: "com.fabiankaegy.wpcontainer", category: "hostshelper-client")

    public enum HelperError: Error, Sendable, CustomStringConvertible {
        /// The user dismissed the Touch ID / password dialog.
        case cancelled
        /// The helper is not registered/approved, or the connection dropped —
        /// callers should fall back to the legacy path.
        case unavailable(String)
        /// The helper accepted the connection but rejected the operation
        /// (validation failure, authorization not granted, write error).
        case rejected(String)

        public var description: String {
            switch self {
            case .cancelled:            return "authorization was cancelled"
            case .unavailable(let s):   return "hosts helper unavailable: \(s)"
            case .rejected(let s):      return "hosts helper rejected the change: \(s)"
            }
        }
    }

    // MARK: - Registration (SMAppService.daemon)

    private static var service: SMAppService {
        SMAppService.daemon(plistName: HostsHelperInfo.daemonPlistName)
    }

    /// Current registration status of the embedded daemon.
    public static var status: SMAppService.Status { service.status }

    /// True once the daemon is registered AND approved by the user (Login Items).
    public static var isEnabled: Bool { service.status == .enabled }

    /// Whether the running binary is Developer-ID signed by our team. Ad-hoc
    /// Debug builds cannot register or be verified as an SMAppService daemon, so
    /// the helper UI is hidden/disabled for them.
    public static var isSupportedBuild: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(HostsHelperInfo.selfDeveloperIDRequirement as CFString,
                                             [], &req) == errSecSuccess, let req else { return false }
        return SecStaticCodeCheckValidity(staticCode, [], req) == errSecSuccess
    }

    /// Register the daemon. Reaching `.requiresApproval` is the expected result
    /// on first run — the user must approve it in System Settings > Login Items.
    public static func register() throws { try service.register() }

    /// Unregister the daemon (used by an on/off toggle).
    public static func unregister() throws { try service.unregister() }

    /// Deep-link to the Login Items pane where the user approves the daemon.
    public static var loginItemsSettingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    }

    // MARK: - Privileged operations

    /// Write the managed block for `domains` via the helper (empty ⇒ remove).
    /// Presents the Touch ID-capable authorization dialog, then hands the signed
    /// external form to the daemon over XPC.
    public static func apply(domains: [String]) async throws {
        let clean = domains
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let entries = clean.map { "\(HostsFileService.loopbackIPv4)\t\($0)" }

        let authData = try makeAuthorizationExternalForm()

        try await withConnection { (proxy, resumer: Resumer<Void>) in
            let handler: @Sendable (String?) -> Void = { errString in
                if let errString {
                    resumer.resume(throwing: HelperError.rejected(errString))
                } else {
                    resumer.resume(returning: ())
                }
            }
            if entries.isEmpty {
                proxy.removeHostsBlock(authorization: authData, reply: handler)
            } else {
                proxy.writeHostsBlock(entries: entries, authorization: authData, reply: handler)
            }
        }
    }

    /// Restart mDNSResponder via the helper — the repair for a wedged etc-hosts
    /// subsystem where custom domains resolve everywhere except Safari/CFNetwork
    /// (see `MDNSHostCheck`). Needs no user authorization (the operation is
    /// non-destructive and the daemon pins our code signature), but does need a
    /// helper that implements the call — older daemons are reported as
    /// `.unavailable` via the version gate.
    public static func repairDNSResolver() async throws {
        let remote = try await reachableVersion()
        guard remote == hostsHelperVersion else {
            throw HelperError.unavailable("helper v\(remote) predates DNS repair (need v\(hostsHelperVersion))")
        }
        try await withConnection { (proxy, resumer: Resumer<Void>) in
            proxy.repairDNSResolver { errString in
                if let errString {
                    resumer.resume(throwing: HelperError.rejected(errString))
                } else {
                    resumer.resume(returning: ())
                }
            }
        }
    }

    /// Probe reachability: connect and ask for the helper version. Throws
    /// `.unavailable` if the daemon can't be reached (e.g. not yet approved).
    @discardableResult
    public static func reachableVersion() async throws -> String {
        try await withConnection { (proxy, resumer: Resumer<String>) in
            proxy.helperVersion { version in resumer.resume(returning: version) }
        }
    }

    // MARK: - Authorization (interactive)

    private static func makeAuthorizationExternalForm() throws -> Data {
        var authRef: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authRef) == errAuthorizationSuccess, let authRef else {
            throw HelperError.unavailable("could not create authorization")
        }
        defer { AuthorizationFree(authRef, []) }

        // Ensure the custom right exists (idempotent) so the dialog uses our
        // rule + comment rather than the default.
        wpcInstallHostsAuthorizationRight(authRef)

        let name = HostsHelperInfo.authorizationRightName
        let copyStatus = name.withCString { namePtr -> OSStatus in
            var item = AuthorizationItem(name: namePtr, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPtr -> OSStatus in
                var rights = AuthorizationRights(count: 1, items: itemPtr)
                let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
                return AuthorizationCopyRights(authRef, &rights, nil, flags, nil)
            }
        }
        switch copyStatus {
        case errAuthorizationSuccess:
            break
        case errAuthorizationCanceled:
            throw HelperError.cancelled
        default:
            throw HelperError.rejected("authorization denied (status \(copyStatus))")
        }

        var extForm = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(authRef, &extForm) == errAuthorizationSuccess else {
            throw HelperError.unavailable("could not externalize authorization")
        }
        return withUnsafeBytes(of: extForm) { Data($0) }
    }

    // MARK: - XPC plumbing

    /// Open a privileged XPC connection to the daemon, run `body` (which must
    /// resume the `Resumer` exactly once), and tear the connection down when it
    /// does. `body` runs synchronously; the reply/invalidation callbacks it
    /// registers may fire on any queue.
    private static func withConnection<T: Sendable>(
        _ body: (HostsHelperProtocol, Resumer<T>) -> Void
    ) async throws -> T {
        let connection = NSXPCConnection(machServiceName: HostsHelperInfo.machServiceName,
                                         options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HostsHelperProtocol.self)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let resumer = Resumer(continuation, teardown: { connection.invalidate() })

            connection.invalidationHandler = { resumer.resume(throwing: HelperError.unavailable("connection invalidated")) }
            connection.interruptionHandler = { resumer.resume(throwing: HelperError.unavailable("connection interrupted")) }
            connection.resume()

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                resumer.resume(throwing: HelperError.unavailable(error.localizedDescription))
            }) as? HostsHelperProtocol else {
                resumer.resume(throwing: HelperError.unavailable("could not obtain helper proxy"))
                return
            }

            body(proxy, resumer)
        }
    }

    /// Resumes a `CheckedContinuation` exactly once (guarding against XPC
    /// delivering both a reply and an invalidation) and tears the connection
    /// down on the first resume. `@unchecked Sendable`: access to the mutable
    /// state is serialized by `lock`, and the non-Sendable `connection` captured
    /// by `teardown` is only touched under that lock.
    private final class Resumer<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var teardown: (() -> Void)?

        init(_ continuation: CheckedContinuation<T, Error>, teardown: @escaping () -> Void) {
            self.continuation = continuation
            self.teardown = teardown
        }

        func resume(returning value: T) { finish { $0.resume(returning: value) } }
        func resume(throwing error: Error) { finish { $0.resume(throwing: error) } }

        private func finish(_ action: (CheckedContinuation<T, Error>) -> Void) {
            lock.lock()
            let cont = continuation
            continuation = nil
            let td = teardown
            teardown = nil
            lock.unlock()
            guard let cont else { return }
            td?()
            action(cont)
        }
    }
}
