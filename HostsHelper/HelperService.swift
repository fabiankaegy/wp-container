import Foundation
import Security
import os

/// The object vended over XPC. Implements the two privileged operations. Every
/// mutating call:
///   1. re-verifies the caller's `AuthorizationExternalForm` grants our custom
///      right WITHOUT allowing interaction (the interactive Touch ID / password
///      dialog already happened in the client), and
///   2. re-validates every entry against `HostsBlockRewriter` (never trusting
///      the app), then
///   3. writes `/etc/hosts` atomically preserving `0644 root:wheel`, fsync'd.
final class HelperService: NSObject, HostsHelperProtocol {
    static let log = Logger(subsystem: "com.fabiankaegy.wpcontainer.hostshelper", category: "helper")
    static let hostsPath = "/etc/hosts"

    // MARK: HostsHelperProtocol

    func helperVersion(reply: @escaping @Sendable (String) -> Void) {
        reply(hostsHelperVersion)
    }

    func writeHostsBlock(entries: [String],
                         authorization: Data,
                         reply: @escaping @Sendable (String?) -> Void) {
        if let denied = verifyAuthorization(authorization) { reply(denied); return }
        do {
            let current = (try? String(contentsOfFile: Self.hostsPath, encoding: .utf8)) ?? ""
            let updated = try HostsBlockRewriter.rewrite(current, entries: entries)
            try Self.atomicWrite(updated, to: Self.hostsPath)
            Self.flushDNS()
            reply(nil)
        } catch let error as HostsBlockRewriter.ValidationError {
            Self.log.error("rejected write: \(error.description, privacy: .public)")
            reply(error.description)
        } catch {
            reply("failed to write /etc/hosts: \(error.localizedDescription)")
        }
    }

    func removeHostsBlock(authorization: Data,
                          reply: @escaping @Sendable (String?) -> Void) {
        if let denied = verifyAuthorization(authorization) { reply(denied); return }
        do {
            let current = (try? String(contentsOfFile: Self.hostsPath, encoding: .utf8)) ?? ""
            let updated = HostsBlockRewriter.removeBlock(current)
            try Self.atomicWrite(updated, to: Self.hostsPath)
            Self.flushDNS()
            reply(nil)
        } catch {
            reply("failed to update /etc/hosts: \(error.localizedDescription)")
        }
    }

    // MARK: - Authorization (verify, no interaction)

    /// Reconstruct the external authorization form and confirm it grants our
    /// custom right, WITHOUT allowing interaction. Returns `nil` when authorized
    /// or an error string to send back to the client.
    private func verifyAuthorization(_ data: Data) -> String? {
        guard data.count == MemoryLayout<AuthorizationExternalForm>.size else {
            return "malformed authorization"
        }
        var extForm = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &extForm) { data.copyBytes(to: $0) }

        var authRef: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&extForm, &authRef) == errAuthorizationSuccess,
              let authRef else {
            return "authorization could not be restored"
        }
        defer { AuthorizationFree(authRef, []) }

        let name = HostsHelperInfo.authorizationRightName
        let status = name.withCString { namePtr -> OSStatus in
            var item = AuthorizationItem(name: namePtr, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPtr -> OSStatus in
                var rights = AuthorizationRights(count: 1, items: itemPtr)
                // No .interactionAllowed: the client already presented the dialog.
                // We only confirm the previously-granted right is still valid.
                return AuthorizationCopyRights(authRef, &rights, nil, [.extendRights], nil)
            }
        }
        guard status == errAuthorizationSuccess else {
            return "not authorized to modify /etc/hosts"
        }
        return nil
    }

    // MARK: - Atomic write (root:wheel 0644, fsync)

    static func atomicWrite(_ contents: String, to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = dir + "/.wpc-hosts.\(getpid()).\(UUID().uuidString).tmp"
        let bytes = Array(contents.utf8)

        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw POSIXError(path: tmp, errnoValue: errno) }

        var ok = true
        var savedErrno: Int32 = 0
        bytes.withUnsafeBytes { raw in
            var offset = 0
            let base = raw.baseAddress!
            while offset < raw.count {
                let n = write(fd, base.advanced(by: offset), raw.count - offset)
                if n <= 0 { ok = false; savedErrno = errno; break }
                offset += n
            }
        }
        if ok { if fsync(fd) != 0 { ok = false; savedErrno = errno } }
        close(fd)
        guard ok else {
            unlink(tmp)
            throw POSIXError(path: tmp, errnoValue: savedErrno)
        }

        // Preserve canonical ownership/permissions on the staged file before it
        // takes /etc/hosts's place (the helper runs as root, so this sticks).
        chmod(tmp, 0o644)
        chown(tmp, 0, 0) // root:wheel

        guard rename(tmp, path) == 0 else {
            let e = errno
            unlink(tmp)
            throw POSIXError(path: path, errnoValue: e)
        }
        // fsync the directory so the rename is durable.
        let dfd = open(dir, O_RDONLY)
        if dfd >= 0 { fsync(dfd); close(dfd) }
    }

    struct POSIXError: Error, CustomStringConvertible {
        let path: String
        let errnoValue: Int32
        var description: String { "\(path): \(String(cString: strerror(errnoValue)))" }
        var localizedDescription: String { description }
    }

    // MARK: - DNS flush

    static func flushDNS() {
        run("/usr/bin/dscacheutil", ["-flushcache"])
        run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }

    private static func run(_ launchPath: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}
