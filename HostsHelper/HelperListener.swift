import Foundation
import Security
import os

/// `NSXPCListener` delegate. Hardens every incoming connection: before exporting
/// the service object it pins the connecting client's code signature to our
/// team + bundle IDs using the peer's audit token. Anything else is refused.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    static let log = Logger(subsystem: "com.fabiankaegy.wpcontainer.hostshelper", category: "listener")

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard Self.clientIsTrusted(newConnection) else {
            Self.log.error("refused XPC connection: client failed code-signing requirement")
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: HostsHelperProtocol.self)
        newConnection.exportedObject = HelperService()
        newConnection.resume()
        return true
    }

    /// Verify the connecting peer satisfies `HostsHelperInfo.clientCodeRequirement`
    /// (same team + one of our bundle IDs), keyed off the audit token so it can't
    /// be defeated by PID reuse.
    static func clientIsTrusted(_ connection: NSXPCConnection) -> Bool {
        var token = audit_token_t()
        guard WPCGetAuditToken(connection, &token) else { return false }

        let tokenData = withUnsafeBytes(of: token) { Data($0) }
        let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary

        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let code else { return false }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(HostsHelperInfo.clientCodeRequirement as CFString,
                                             [], &requirement) == errSecSuccess,
              let requirement else { return false }

        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
