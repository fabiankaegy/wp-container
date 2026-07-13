import Foundation

/// Manages a clearly-delimited block in `/etc/hosts` for custom-domain sites
/// (PLAN.md §2i). All entries live between `# wp-container begin` / `# wp-container
/// end` markers so nothing outside our block is ever touched; the file is
/// rewritten in one shot and installed via a single `osascript` admin prompt.
///
/// The block-manipulation core (`rewrite` / `managedDomains`) is pure and
/// side-effect free so it can be unit/spot tested against a copy of the file
/// without elevation.
public enum HostsFileService {
    public static let beginMarker = "# wp-container begin"
    public static let endMarker = "# wp-container end"
    public static let hostsPath = "/etc/hosts"
    public static let loopbackIPv4 = "127.0.0.1"

    public enum HostsError: Error, Sendable, CustomStringConvertible {
        case adminFailed(String)
        case readFailed(String)
        /// The user dismissed the admin/Touch-ID dialog (osascript error -128),
        /// or we terminated the prompt (skip / timeout). Callers treat this as a
        /// skip rather than a hard failure.
        case cancelled

        public var description: String {
            switch self {
            case .adminFailed(let s): return "updating /etc/hosts failed: \(s)"
            case .readFailed(let s):  return "reading /etc/hosts failed: \(s)"
            case .cancelled:          return "domain registration was cancelled"
            }
        }
    }

    // MARK: - Pure block manipulation (testable)

    /// Return `contents` with the managed block replaced by fresh entries for
    /// `domains` (deduped, order-preserving). An empty `domains` removes the
    /// block entirely. Robust to a missing or half-written (corrupted) block.
    public static func rewrite(_ contents: String, domains: [String]) -> String {
        var lines = contents.components(separatedBy: "\n")

        // Remove a well-formed managed block if present.
        if let begin = lines.firstIndex(of: beginMarker),
           let endRel = lines[begin...].firstIndex(of: endMarker) {
            lines.removeSubrange(begin...endRel)
        } else if let begin = lines.firstIndex(of: beginMarker) {
            // Corrupted: a begin without an end. Remove the marker and the run of
            // our-format entry lines (`127.0.0.1\t<host>`) that follow it.
            var last = begin
            var i = begin + 1
            while i < lines.count, lines[i].hasPrefix("\(loopbackIPv4)\t") { last = i; i += 1 }
            lines.removeSubrange(begin...last)
        }
        // Drop any orphaned marker lines left by a corrupted prior edit.
        lines.removeAll { $0 == beginMarker || $0 == endMarker }
        // Trim trailing blanks so we append cleanly.
        while lines.last?.isEmpty == true { lines.removeLast() }

        var seen = Set<String>()
        let clean = domains
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }

        if !clean.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append(beginMarker)
            for domain in clean { lines.append("\(loopbackIPv4)\t\(domain)") }
            lines.append(endMarker)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The domains currently listed inside the managed block of `contents`.
    public static func managedDomains(in contents: String) -> [String] {
        let lines = contents.components(separatedBy: "\n")
        guard let begin = lines.firstIndex(of: beginMarker),
              let endRel = lines[begin...].firstIndex(of: endMarker), endRel > begin else { return [] }
        return lines[(begin + 1)..<endRel].compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return parts.count >= 2 ? String(parts[1]) : nil
        }
    }

    // MARK: - Apply (admin prompt)

    /// Whether a single custom domain currently has a managed `/etc/hosts` entry
    /// (used to flag a site whose domain was configured but not yet registered).
    public static func isRegistered(_ domain: String) -> Bool {
        let want = domain.trimmingCharacters(in: .whitespaces)
        guard !want.isEmpty,
              let current = try? String(contentsOfFile: hostsPath, encoding: .utf8) else { return false }
        return managedDomains(in: current).contains(want)
    }

    /// True if the managed block already exactly matches `domains` (no admin
    /// prompt needed).
    public static func isUpToDate(domains: [String]) -> Bool {
        guard let current = try? String(contentsOfFile: hostsPath, encoding: .utf8) else { return false }
        let want = Set(domains.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return Set(managedDomains(in: current)) == want
    }

    /// Rewrite the managed block to exactly `domains` (the union across all
    /// custom-domain sites). No-op when already up to date.
    ///
    /// Prefers the privileged `wpc-hosts-helper` when it is registered and
    /// approved (SMAppService): that path uses the Touch ID-capable system
    /// authorization dialog. If the helper is unavailable (not approved yet,
    /// connection dropped, or an ad-hoc Debug build where it can't run) it falls
    /// back to the legacy single `osascript … with administrator privileges`
    /// prompt — behavior unchanged from before the helper existed.
    public static func apply(domains: [String]) async throws {
        if isUpToDate(domains: domains) { return }

        if HostsHelperClient.isEnabled {
            do {
                try await HostsHelperClient.apply(domains: domains)
                return
            } catch HostsHelperClient.HelperError.cancelled {
                throw HostsError.cancelled
            } catch HostsHelperClient.HelperError.rejected(let msg) {
                throw HostsError.adminFailed(msg)
            } catch {
                // .unavailable → the daemon isn't reachable; fall through to the
                // legacy osascript path rather than blocking the user.
            }
        }

        let current = (try? String(contentsOfFile: hostsPath, encoding: .utf8)) ?? ""
        let updated = rewrite(current, domains: domains)

        // Stage the new file in a user-writable temp location, then copy it over
        // /etc/hosts under admin (cp preserves the destination's root:wheel/644).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpc-hosts-\(UUID().uuidString)")
        try updated.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let inner = "/bin/cp " + shellQuote(tmp.path) + " " + shellQuote(hostsPath)
            + " && /usr/bin/dscacheutil -flushcache 2>/dev/null; /usr/bin/killall -HUP mDNSResponder 2>/dev/null; true"
        let script = "do shell script \"\(appleScriptEscape(inner))\" with administrator privileges"
        let result = try await ProcessRunner.run(executable: "/usr/bin/osascript", args: ["-e", script])
        if result.exitCode != 0 {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            // A dismissed auth dialog reports AppleScript error -128 ("User
            // canceled"); a SIGTERM'd osascript (our skip/timeout) exits without
            // writing. Either way there is no partial write — surface as a skip.
            if isCancellation(detail) || result.exitCode == 15 /* SIGTERM */ {
                throw HostsError.cancelled
            }
            throw HostsError.adminFailed(detail)
        }
    }

    /// Whether an osascript failure represents a user-dismissed dialog.
    private static func isCancellation(_ detail: String) -> Bool {
        let d = detail.lowercased()
        return d.contains("-128") || d.contains("user canceled") || d.contains("user cancelled")
    }

    // MARK: - Helpers

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
