import Foundation

/// Manages a marked PATH block in the user's shell rc so the global `wp` router
/// (`WPCLIShim.routerDir`) wins over Homebrew's `wp` (PLAN.md §2e follow-up).
///
/// The block-manipulation core (`rewrite`) is pure so it can be spot-tested
/// against a scratch copy without touching the real rc file.
public enum ShellPathService {
    public static let begin = "# BEGIN wp-container global wp"
    public static let end = "# END wp-container global wp"

    /// The interactive-shell rc most macOS users have (zsh is the default shell).
    public static var zshrcURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
    }

    public static var pathExport: String { "export PATH=\"\(WPCLIShim.routerDir):$PATH\"" }

    // MARK: - Pure block manipulation (testable)

    /// Return `contents` with our managed PATH block removed and, when
    /// `install` is true, re-appended fresh. Idempotent; robust to a corrupted
    /// (half-written) prior block.
    public static func rewrite(_ contents: String, install: Bool) -> String {
        var lines = contents.components(separatedBy: "\n")
        if let b = lines.firstIndex(of: begin), let eRel = lines[b...].firstIndex(of: end) {
            lines.removeSubrange(b...eRel)
        }
        lines.removeAll { $0 == begin || $0 == end }
        while lines.last?.isEmpty == true { lines.removeLast() }
        if install {
            if !lines.isEmpty { lines.append("") }
            lines.append(contentsOf: [begin, pathExport, end])
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    public static func isInstalled(in contents: String) -> Bool {
        contents.components(separatedBy: "\n").contains(begin)
    }

    // MARK: - Apply

    /// Whether the block is present in the real `~/.zshrc`.
    public static func isInstalled() -> Bool {
        guard let text = try? String(contentsOf: zshrcURL, encoding: .utf8) else { return false }
        return isInstalled(in: text)
    }

    /// Add or remove the block in `~/.zshrc`.
    public static func apply(install: Bool) throws {
        let current = (try? String(contentsOf: zshrcURL, encoding: .utf8)) ?? ""
        let updated = rewrite(current, install: install)
        if updated.isEmpty {
            try? FileManager.default.removeItem(at: zshrcURL)
        } else {
            try updated.write(to: zshrcURL, atomically: true, encoding: .utf8)
        }
    }

    /// The `wp` executables currently on PATH, in order, as seen from a login
    /// interactive shell (so Homebrew's shellenv is applied). Empty on failure.
    public static func wpOnPath() async -> [String] {
        guard let result = try? await ProcessRunner.run(
            executable: "/bin/zsh", args: ["-lic", "which -a wp 2>/dev/null"]) else { return [] }
        return result.stdout.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }
    }
}
