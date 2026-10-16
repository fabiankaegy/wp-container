import Foundation

/// Pure, side-effect-free manipulation and validation of the `# wp-container
/// begin/end` marker block in an `/etc/hosts` document.
///
/// This is the privileged helper's security boundary: it NEVER trusts the
/// caller. Every entry the app or CLI hands over is re-validated here against
/// the same strict DNS-label rules as `DomainService.normalize`, may only name
/// one of our two fixed IPv4 addresses, and only the managed marker block is
/// ever rewritten — every other line is preserved byte-for-byte. The logic is
/// duplicated (not shared with `HostsFileService`) on purpose: the helper runs
/// as root and must not depend on a type controlled by the unprivileged app.
/// For the same reason the addresses are literals here rather than references
/// to `LoopbackZone`; `HostsHelperTests` pins them to it.
enum HostsBlockRewriter {
    static let beginMarker = "# wp-container begin"
    static let endMarker = "# wp-container end"
    /// Legacy target (zone not set up): the proxy listens on the wildcard.
    static let loopbackIPv4 = "127.0.0.1"
    /// Written next to every IPv4 entry. Without an AAAA answer from
    /// `/etc/hosts`, macOS sends the IPv6 lookup for a `.local` name to mDNS and
    /// waits out its 5s timeout on every page load. Callers still send IPv4-only
    /// entries; the helper derives the IPv6 line itself.
    static let loopbackIPv6 = "::1"
    /// Owned loopback zone target (`LoopbackZone.ipv4` / `.ipv6`).
    static let zoneIPv4 = "127.0.0.77"
    static let zoneIPv6 = "fd77:7063::77"

    /// The only IPv4 addresses an entry may name, each with the IPv6 line the
    /// helper writes beside it.
    static let ipv6Partner: [String: String] = [loopbackIPv4: loopbackIPv6, zoneIPv4: zoneIPv6]

    enum ValidationError: Error, CustomStringConvertible, Equatable {
        case malformedEntry(String)
        case invalidHostname(String)

        var description: String {
            switch self {
            case .malformedEntry(let e): return "rejected malformed hosts entry: \(e)"
            case .invalidHostname(let h): return "rejected invalid hostname: \(h)"
            }
        }
    }

    // MARK: - Validation

    /// Validate a strict DNS hostname. Mirrors `DomainService.normalize`'s label
    /// rules exactly (dot-separated `[a-z0-9-]` labels, no leading/trailing dash,
    /// >= 2 labels, <= 253 total, <= 63 per label) but performs NO normalization:
    /// the input must already be lowercased and trimmed. Any deviation is a
    /// rejection — the helper does not massage hostile input into something valid.
    static func isValidHostname(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253, host.contains(".") else { return false }
        // Reject anything that is not exactly its own trimmed/lowercased form so
        // embedded whitespace, tabs, newlines or uppercase can never slip through.
        guard host == host.trimmingCharacters(in: .whitespacesAndNewlines),
              host == host.lowercased() else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63,
                  label.first != "-", label.last != "-",
                  label.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" })
            else { return false }
        }
        return true
    }

    /// Parse and validate a single entry line. The line must be EXACTLY one of
    /// `127.0.0.1` / `127.0.0.77` + one-or-more spaces/tabs + a valid hostname,
    /// with nothing else (no comments, no extra tokens, no second address, no
    /// IPv6 — the helper derives that line). Returns the address and hostname or
    /// throws.
    static func entry(fromLine rawEntry: String) throws -> (address: String, host: String) {
        // No embedded newline may ever appear — that would let a single entry
        // inject additional hosts lines.
        guard !rawEntry.contains("\n"), !rawEntry.contains("\r") else {
            throw ValidationError.malformedEntry(rawEntry)
        }
        let entry = rawEntry.trimmingCharacters(in: .whitespaces)
        let parts = entry.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 2, ipv6Partner[String(parts[0])] != nil else {
            throw ValidationError.malformedEntry(rawEntry)
        }
        let host = String(parts[1])
        guard isValidHostname(host) else {
            throw ValidationError.invalidHostname(host)
        }
        return (String(parts[0]), host)
    }

    /// The hostname of a valid entry line (see `entry(fromLine:)`).
    static func hostname(fromEntry rawEntry: String) throws -> String {
        try entry(fromLine: rawEntry).host
    }

    // MARK: - Block rewrite

    /// Remove any managed block (well-formed or corrupted) plus orphaned markers,
    /// returning the surviving lines with trailing blanks trimmed. Shared by
    /// `rewrite` and `removeBlock`.
    private static func stripManagedBlock(_ contents: String) -> [String] {
        var lines = contents.components(separatedBy: "\n")
        if let begin = lines.firstIndex(of: beginMarker),
           let endRel = lines[begin...].firstIndex(of: endMarker) {
            lines.removeSubrange(begin...endRel)
        } else if let begin = lines.firstIndex(of: beginMarker) {
            // Corrupted: a begin without an end. Remove the marker and the run of
            // our-format entry lines that follow it — old (`127.0.0.1` / `::1`)
            // and zone (`127.0.0.77` / `fd77:7063::77`) alike, so an upgrade
            // still cleans up a block a previous version left half-written.
            var last = begin
            var i = begin + 1
            while i < lines.count, isOurEntryLine(lines[i]) { last = i; i += 1 }
            lines.removeSubrange(begin...last)
        }
        lines.removeAll { $0 == beginMarker || $0 == endMarker }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    private static func isOurEntryLine(_ line: String) -> Bool {
        ipv6Partner.contains { line.hasPrefix("\($0.key)\t") || line.hasPrefix("\($0.value)\t") }
    }

    /// The block lines for `hosts`: an IPv4 line at `address` and its IPv6
    /// partner per host.
    private static func blockLines(hosts: [String], address: String) -> [String] {
        let v6 = ipv6Partner[address] ?? loopbackIPv6
        return hosts.flatMap { ["\(address)\t\($0)", "\(v6)\t\($0)"] }
    }

    /// Append a fresh block to already-stripped `lines`.
    private static func assemble(_ lines: [String], block: [String]) -> String {
        var lines = lines
        if !block.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append(beginMarker)
            lines.append(contentsOf: block)
            lines.append(endMarker)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Return `contents` with the managed block replaced by a fresh block built
    /// from `entries` (each `<127.0.0.1|127.0.0.77> <hostname>`; deduped by
    /// hostname, order-preserving). Every host is written twice: its IPv4 line
    /// and the matching IPv6 line (`::1` / `fd77:7063::77`). Throws
    /// `ValidationError` if ANY entry is malformed or names an invalid hostname —
    /// the whole operation is rejected rather than partially applied. An empty
    /// `entries` removes the block entirely.
    static func rewrite(_ contents: String, entries: [String]) throws -> String {
        var seen = Set<String>()
        var block: [String] = []
        for raw in entries {
            let entry = try entry(fromLine: raw)
            if seen.insert(entry.host).inserted {
                block += blockLines(hosts: [entry.host], address: entry.address)
            }
        }
        return assemble(stripManagedBlock(contents), block: block)
    }

    /// Return `contents` with the managed block removed entirely (everything else
    /// preserved). Never fails.
    static func removeBlock(_ contents: String) -> String {
        return stripManagedBlock(contents).joined(separator: "\n") + "\n"
    }

    /// Re-point an existing, well-formed managed block at the zone aliases
    /// (`toZone`) or back at `127.0.0.1`/`::1`, keeping exactly the hostnames it
    /// already holds. This is what lets the unauthorized zone ops follow the
    /// proxy's mode: it can only change WHERE already-authorized names point,
    /// never add one.
    ///
    /// Returns nil — leave the file alone — when there is no block, when it is
    /// already pointed there, or when any line in it fails validation (a block
    /// we can't fully vouch for is not ours to rewrite unprompted).
    static func repoint(_ contents: String, toZone: Bool) -> String? {
        let lines = contents.components(separatedBy: "\n")
        guard let begin = lines.firstIndex(of: beginMarker),
              let end = lines[begin...].firstIndex(of: endMarker), end > begin else { return nil }
        var seen = Set<String>()
        var hosts: [String] = []
        for line in lines[(begin + 1)..<end] {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 2, isOurEntryLine(line), isValidHostname(String(parts[1])) else { return nil }
            let host = String(parts[1])
            if seen.insert(host).inserted { hosts.append(host) }
        }
        let block = blockLines(hosts: hosts, address: toZone ? zoneIPv4 : loopbackIPv4)
        guard Array(lines[(begin + 1)..<end]) != block else { return nil }
        return assemble(stripManagedBlock(contents), block: block)
    }
}
