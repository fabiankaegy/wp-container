import Foundation

/// Manages a clearly-delimited block in `/etc/hosts` for custom-domain sites
/// (PLAN.md §2i). All entries live between `# wp-container begin` / `# wp-container
/// end` markers so nothing outside our block is ever touched; the file is
/// rewritten in one shot via the privileged helper (or a single `osascript`
/// admin prompt when it is unavailable).
///
/// Entries point at the owned loopback zone's aliases (`LoopbackZone.ipv4` /
/// `.ipv6`, §2f-ter) once the helper has set the zone up, else at
/// `127.0.0.1` / `::1` where the legacy wildcard proxy listens. The helper also
/// re-points an existing block itself when the zone is activated or torn down.
///
/// The block-manipulation core (`rewrite` / `managedDomains`) is pure and
/// side-effect free so it can be unit/spot tested against a copy of the file
/// without elevation.
public enum HostsFileService {
    public static let beginMarker = "# wp-container begin"
    public static let endMarker = "# wp-container end"
    public static let hostsPath = "/etc/hosts"
    public static let loopbackIPv4 = "127.0.0.1"
    /// Written next to every IPv4 entry. Without an AAAA answer from
    /// `/etc/hosts`, macOS sends the IPv6 lookup for a `.local` name to mDNS and
    /// waits out its 5s timeout on every page load. The legacy proxy listens
    /// dual-stack, so `::1` reaches it too (in zone mode the pair is the zone's
    /// IPv4/IPv6 aliases instead).
    public static let loopbackIPv6 = "::1"

    /// The (IPv4, IPv6) pair entries point at: the zone aliases when `zone`,
    /// else the classic loopback addresses.
    static func addresses(zone: Bool) -> (v4: String, v6: String) {
        zone ? (LoopbackZone.ipv4, LoopbackZone.ipv6) : (loopbackIPv4, loopbackIPv6)
    }

    /// Whether `line` is in one of the formats we write — old or zone — so a
    /// corrupted block left by any version is recognised and cleaned up.
    private static func isOurEntryLine(_ line: String) -> Bool {
        [loopbackIPv4, loopbackIPv6, LoopbackZone.ipv4, LoopbackZone.ipv6]
            .contains { line.hasPrefix("\($0)\t") }
    }

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
    /// `domains` (deduped, order-preserving), pointed at the zone aliases when
    /// `zone`. An empty `domains` removes the block entirely. Robust to a
    /// missing or half-written (corrupted) block.
    public static func rewrite(_ contents: String, domains: [String], zone: Bool = false) -> String {
        var lines = contents.components(separatedBy: "\n")

        // Remove a well-formed managed block if present.
        if let begin = lines.firstIndex(of: beginMarker),
           let endRel = lines[begin...].firstIndex(of: endMarker) {
            lines.removeSubrange(begin...endRel)
        } else if let begin = lines.firstIndex(of: beginMarker) {
            // Corrupted: a begin without an end. Remove the marker and the run of
            // our-format entry lines (any of the four addresses) that follow it.
            var last = begin
            var i = begin + 1
            while i < lines.count, isOurEntryLine(lines[i]) {
                last = i; i += 1
            }
            lines.removeSubrange(begin...last)
        }
        // Drop any orphaned marker lines left by a corrupted prior edit.
        lines.removeAll { $0 == beginMarker || $0 == endMarker }
        // Trim trailing blanks so we append cleanly.
        while lines.last?.isEmpty == true { lines.removeLast() }

        let entries = entryLines(for: domains, zone: zone)
        if !entries.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append(beginMarker)
            lines.append(contentsOf: entries)
            lines.append(endMarker)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The lines the managed block should hold for `domains`: an IPv4 and an
    /// IPv6 entry per domain (deduped, order-preserving), at `addresses(zone:)`.
    static func entryLines(for domains: [String], zone: Bool = false) -> [String] {
        var seen = Set<String>()
        let (v4, v6) = addresses(zone: zone)
        return domains
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .flatMap { ["\(v4)\t\($0)", "\(v6)\t\($0)"] }
    }

    /// The raw lines between the managed block's markers, or [] when there is none.
    private static func managedBlockLines(in contents: String) -> [String] {
        let lines = contents.components(separatedBy: "\n")
        guard let begin = lines.firstIndex(of: beginMarker),
              let endRel = lines[begin...].firstIndex(of: endMarker), endRel > begin else { return [] }
        return Array(lines[(begin + 1)..<endRel])
    }

    /// The domains currently listed inside the managed block of `contents`
    /// (each once, even though it has both an IPv4 and an IPv6 line).
    public static func managedDomains(in contents: String) -> [String] {
        var seen = Set<String>()
        return managedBlockLines(in: contents).compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { return nil }
            let domain = String(parts[1])
            return seen.insert(domain).inserted ? domain : nil
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
    /// prompt needed). Compares whole lines, not just domains, so a block written
    /// before the `::1` entries existed — or pointing at the wrong addresses for
    /// the current zone state — counts as stale and gets upgraded.
    public static func isUpToDate(domains: [String]) -> Bool {
        guard let current = try? String(contentsOfFile: hostsPath, encoding: .utf8) else { return false }
        return isUpToDate(current, domains: domains, zone: LoopbackZone.isInstalled)
    }

    /// Pure form of `isUpToDate(domains:)` for testing.
    static func isUpToDate(_ contents: String, domains: [String], zone: Bool = false) -> Bool {
        Set(managedBlockLines(in: contents)) == Set(entryLines(for: domains, zone: zone))
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
    ///
    /// Entries target the zone aliases whenever the zone is installed (only the
    /// helper ever installs it, and pf only routes the aliases while it does).
    public static func apply(domains: [String]) async throws {
        if isUpToDate(domains: domains) { return }
        let zone = LoopbackZone.isInstalled

        if HostsHelperClient.isEnabled {
            do {
                try await HostsHelperClient.apply(domains: domains, address: addresses(zone: zone).v4)
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
        let updated = rewrite(current, domains: domains, zone: zone)

        // Stage the new file in a user-writable temp location, then copy it over
        // /etc/hosts under admin (cp preserves the destination's root:wheel/644).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpc-hosts-\(UUID().uuidString)")
        try updated.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Full mDNSResponder restart, not SIGHUP: HUP does not recover a wedged
        // etc-hosts subsystem (Safari-only resolution failures — see
        // MDNSHostCheck), and inside this single admin prompt there is no way to
        // verify-and-escalate like the helper does. launchd respawns the daemon
        // on demand, so the restart is a momentary cache flush at worst.
        let inner = "/bin/cp " + shellQuote(tmp.path) + " " + shellQuote(hostsPath)
            + " && /usr/bin/dscacheutil -flushcache 2>/dev/null; /usr/bin/killall mDNSResponder 2>/dev/null; true"
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
