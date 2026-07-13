import Foundation

/// Pure, side-effect-free manipulation and validation of the `# wp-container
/// begin/end` marker block in an `/etc/hosts` document.
///
/// This is the privileged helper's security boundary: it NEVER trusts the
/// caller. Every entry the app or CLI hands over is re-validated here against
/// the same strict DNS-label rules as `DomainService.normalize`, and only the
/// managed marker block is ever rewritten — every other line is preserved
/// byte-for-byte. The logic is duplicated (not shared with `HostsFileService`)
/// on purpose: the helper runs as root and must not depend on a type controlled
/// by the unprivileged app.
enum HostsBlockRewriter {
    static let beginMarker = "# wp-container begin"
    static let endMarker = "# wp-container end"
    static let loopbackIPv4 = "127.0.0.1"

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

    /// Extract and validate the hostname from a single entry line. The line must
    /// be EXACTLY `127.0.0.1` + one-or-more spaces/tabs + a valid hostname, with
    /// nothing else (no comments, no extra tokens, no second address). Returns
    /// the hostname or throws.
    static func hostname(fromEntry rawEntry: String) throws -> String {
        // No embedded newline may ever appear — that would let a single entry
        // inject additional hosts lines.
        guard !rawEntry.contains("\n"), !rawEntry.contains("\r") else {
            throw ValidationError.malformedEntry(rawEntry)
        }
        let entry = rawEntry.trimmingCharacters(in: .whitespaces)
        let parts = entry.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 2, String(parts[0]) == loopbackIPv4 else {
            throw ValidationError.malformedEntry(rawEntry)
        }
        let host = String(parts[1])
        guard isValidHostname(host) else {
            throw ValidationError.invalidHostname(host)
        }
        return host
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
            // our-format entry lines (`127.0.0.1\t<host>`) that follow it.
            var last = begin
            var i = begin + 1
            while i < lines.count, lines[i].hasPrefix("\(loopbackIPv4)\t") { last = i; i += 1 }
            lines.removeSubrange(begin...last)
        }
        lines.removeAll { $0 == beginMarker || $0 == endMarker }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// Return `contents` with the managed block replaced by a fresh block built
    /// from `entries` (each `127.0.0.1 <hostname>`; deduped, order-preserving).
    /// Throws `ValidationError` if ANY entry is malformed or names an invalid
    /// hostname — the whole operation is rejected rather than partially applied.
    /// An empty `entries` removes the block entirely.
    static func rewrite(_ contents: String, entries: [String]) throws -> String {
        var seen = Set<String>()
        var hosts: [String] = []
        for entry in entries {
            let host = try hostname(fromEntry: entry)
            if seen.insert(host).inserted { hosts.append(host) }
        }

        var lines = stripManagedBlock(contents)
        if !hosts.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append(beginMarker)
            for host in hosts { lines.append("\(loopbackIPv4)\t\(host)") }
            lines.append(endMarker)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Return `contents` with the managed block removed entirely (everything else
    /// preserved). Never fails.
    static func removeBlock(_ contents: String) -> String {
        return stripManagedBlock(contents).joined(separator: "\n") + "\n"
    }
}
