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

        public var description: String {
            switch self {
            case .adminFailed(let s): return "updating /etc/hosts failed: \(s)"
            case .readFailed(let s):  return "reading /etc/hosts failed: \(s)"
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

    /// True if the managed block already exactly matches `domains` (no admin
    /// prompt needed).
    public static func isUpToDate(domains: [String]) -> Bool {
        guard let current = try? String(contentsOfFile: hostsPath, encoding: .utf8) else { return false }
        let want = Set(domains.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return Set(managedDomains(in: current)) == want
    }

    /// Rewrite the managed block to exactly `domains` (the union across all
    /// custom-domain sites) via ONE admin prompt. No-op when already up to date.
    public static func apply(domains: [String]) async throws {
        if isUpToDate(domains: domains) { return }
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
            throw HostsError.adminFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    // MARK: - Helpers

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
