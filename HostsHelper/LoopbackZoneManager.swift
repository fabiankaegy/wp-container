import Foundation
import os

/// Root-side setup of the owned loopback zone (PLAN.md §2f-ter): lo0 aliases,
/// the resolver file, the pf redirect anchor, and keeping the managed
/// `/etc/hosts` block pointed at the right addresses.
///
/// Everything it writes comes from `LoopbackZone`'s compiled-in constants;
/// the client contributes one Bool. Every step is idempotent, so the proxy can
/// simply call `activate` on every start — after a reboot (which drops aliases
/// and pf state but keeps the resolver file) that is what brings the zone back.
enum LoopbackZoneManager {
    static let log = Logger(subsystem: "com.fabiankaegy.wpcontainer.hostshelper", category: "zone")

    /// Where we keep the pf enable reference token. `/var/run` is cleared at
    /// boot, exactly like the pf state the token refers to.
    static let pfTokenPath = "/var/run/com.fabiankaegy.wpcontainer.pf-token"

    struct ZoneError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - Activate / deactivate

    static func activate(legacyLoopback: Bool) throws {
        try ensureAliases()
        try ensureResolverFile()
        try loadAnchor(legacyLoopback: legacyLoopback)
        try ensurePFEnabled()
        repointHostsBlock(toZone: true)
    }

    /// Best-effort teardown: every step runs even if an earlier one failed, and
    /// the first failure is reported.
    static func deactivate() throws {
        var failures: [String] = []
        if case .failure(let out) = run("/sbin/pfctl", ["-a", LoopbackZone.pfAnchor, "-F", "all"]) {
            failures.append("pfctl flush: \(out)")
        }
        if let token = try? String(contentsOfFile: pfTokenPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            // Releases only OUR reference; pf stays enabled for anyone else
            // holding one. Never `pfctl -d`.
            _ = run("/sbin/pfctl", ["-X", token])
        }
        unlink(pfTokenPath)
        if hasAddress(LoopbackZone.ipv4) {
            if case .failure(let out) = run("/sbin/ifconfig", ["lo0", "-alias", LoopbackZone.ipv4]) {
                failures.append("ifconfig: \(out)")
            }
        }
        if hasAddress(LoopbackZone.ipv6) {
            _ = run("/sbin/ifconfig", ["lo0", "inet6", LoopbackZone.ipv6, "-alias"])
        }
        if unlink(LoopbackZone.resolverPath) == 0 { HelperService.flushDNS() }
        repointHostsBlock(toZone: false)
        if let first = failures.first { throw ZoneError(description: first) }
    }

    // MARK: - Steps

    /// Add the lo0 aliases unless already present (re-adding an existing alias
    /// is harmless, but checking first keeps the log quiet on every start).
    static func ensureAliases() throws {
        if !hasAddress(LoopbackZone.ipv4) {
            if case .failure(let out) = run("/sbin/ifconfig",
                                            ["lo0", "alias", LoopbackZone.ipv4, "netmask", "255.255.255.255"]) {
                throw ZoneError(description: "could not add \(LoopbackZone.ipv4) to lo0: \(out)")
            }
            log.notice("added lo0 alias \(LoopbackZone.ipv4, privacy: .public)")
        }
        if !hasAddress(LoopbackZone.ipv6) {
            // IPv6 is a nicety (AAAA answers / .local hosts lines); IPv4 carries
            // the zone, so a failure here is logged, not fatal.
            if case .failure(let out) = run("/sbin/ifconfig",
                                            ["lo0", "inet6", LoopbackZone.ipv6, "prefixlen", "128", "alias"]) {
                log.error("could not add \(LoopbackZone.ipv6, privacy: .public) to lo0: \(out, privacy: .public)")
            }
        }
    }

    /// Write `/etc/resolver/wpc.test` when missing or different, then flush so
    /// mDNSResponder picks the new resolver up.
    static func ensureResolverFile() throws {
        let path = LoopbackZone.resolverPath
        let wanted = LoopbackZone.resolverFileContents
        if (try? String(contentsOfFile: path, encoding: .utf8)) == wanted { return }
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
            try HelperService.atomicWrite(wanted, to: path)
        } catch {
            throw ZoneError(description: "could not write \(path): \(error)")
        }
        log.notice("wrote \(path, privacy: .public)")
        HelperService.flushDNS()
    }

    /// Replace the anchor's rules. If the full set is refused, retry without the
    /// vmnet gateway rules: host-side browsing is the essential part, and the
    /// in-container loopback path degrades to a failed self-request rather than
    /// taking the whole zone down.
    static func loadAnchor(legacyLoopback: Bool) throws {
        let full = LoopbackZone.pfRules(legacyLoopback: legacyLoopback)
        guard case .failure(let fullError) = run("/sbin/pfctl", ["-a", LoopbackZone.pfAnchor, "-f", "-"], stdin: full) else {
            return
        }
        log.error("pf refused the full rule set (\(fullError, privacy: .public)); retrying without the vmnet rules")
        let reduced = LoopbackZone.pfRules(legacyLoopback: legacyLoopback, includeVMNet: false)
        if case .failure(let out) = run("/sbin/pfctl", ["-a", LoopbackZone.pfAnchor, "-f", "-"], stdin: reduced) {
            throw ZoneError(description: "pf refused the loopback zone rules: \(out)")
        }
    }

    /// Make sure pf is enabled, holding a reference token of our own (`-E`) so
    /// pf stays on exactly as long as someone needs it. Takes a new reference
    /// only when we hold none (no token file since boot) or pf has been
    /// disabled behind our back, so repeated activations don't pile them up.
    static func ensurePFEnabled() throws {
        let hasToken = FileManager.default.fileExists(atPath: pfTokenPath)
        if hasToken, isPFEnabled() { return }
        guard case .success(let out) = run("/sbin/pfctl", ["-E"]) else {
            throw ZoneError(description: "could not enable pf")
        }
        // pfctl prints "Token : <n>" (on stderr, which `run` merges).
        let token = out.split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("Token : ") }
            .map { String($0.dropFirst("Token : ".count)).trimmingCharacters(in: .whitespaces) }
        if let token, !token.isEmpty {
            try? HelperService.atomicWrite(token + "\n", to: pfTokenPath)
        }
    }

    static func isPFEnabled() -> Bool {
        guard case .success(let out) = run("/sbin/pfctl", ["-s", "info"]) else { return false }
        return out.contains("Status: Enabled")
    }

    /// Swap the managed hosts block's addresses so custom domains follow the
    /// zone. Never adds or drops a hostname (see `HostsBlockRewriter.repoint`).
    static func repointHostsBlock(toZone: Bool) {
        let path = HelperService.hostsPath
        guard let current = try? String(contentsOfFile: path, encoding: .utf8),
              let updated = HostsBlockRewriter.repoint(current, toZone: toZone) else { return }
        do {
            try HelperService.atomicWrite(updated, to: path)
            log.notice("re-pointed the managed /etc/hosts block at \(toZone ? LoopbackZone.ipv4 : "127.0.0.1", privacy: .public)")
            HelperService.flushDNS()
        } catch {
            log.error("could not re-point the managed /etc/hosts block: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

    /// Whether any interface currently carries `address` (lo0 is the only one
    /// that ever could for ours).
    static func hasAddress(_ address: String) -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return false }
        defer { freeifaddrs(head) }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ifa.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let len = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sa, len, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: buffer)
            // Strip any `%scope` suffix from link-local IPv6.
            if text.split(separator: "%").first.map(String.init) == address { return true }
        }
        return false
    }

    enum RunResult { case success(String), failure(String) }

    /// Run a fixed system tool, capturing stdout+stderr. Arguments are always
    /// built from constants in this file — never from client input.
    @discardableResult
    static func run(_ launchPath: String, _ args: [String], stdin: String? = nil) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let input = Pipe()
        if stdin != nil { p.standardInput = input }
        do { try p.run() } catch { return .failure("\(launchPath): \(error.localizedDescription)") }
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 ? .success(text) : .failure(text.isEmpty ? "exit \(p.terminationStatus)" : text)
    }
}
