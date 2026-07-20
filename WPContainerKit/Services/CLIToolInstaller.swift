import Foundation

/// Installs the `wp-container` command-line tool (and its `wpc` alias) that ships
/// embedded inside `WPContainer.app`, by symlinking it into `/usr/local/bin` with
/// a single administrator prompt. A symlink (not a copy) means the CLI tracks the
/// app: update the app and the installed `wp-container` updates with it.
///
/// The embedded binary lives at `Contents/MacOS/wp-container` (found via
/// `Bundle.url(forAuxiliaryExecutable:)`); it is the exact same product shipped
/// in the release CLI zip, code-signed as part of the app bundle.
public enum CLIToolInstaller {
    public enum InstallError: Error, Sendable, CustomStringConvertible {
        /// The embedded CLI wasn't found in the app bundle (dev build without the
        /// embed, or a corrupted bundle).
        case embeddedCLIMissing
        /// The user dismissed the admin-password dialog.
        case cancelled
        /// The privileged step failed; carries osascript's stderr/stdout.
        case adminFailed(String)

        public var description: String {
            switch self {
            case .embeddedCLIMissing: return "The wp-container tool isn't bundled in this build of the app."
            case .cancelled:          return "Installation was cancelled."
            case .adminFailed(let d): return "Could not install the command-line tool: \(d.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
    }

    /// Directory the CLI (and `wpc` alias) are symlinked into. The conventional
    /// Homebrew-style location; already on most developers' `PATH`.
    public static let prefix = "/usr/local/bin"
    public static var cliPath: String { "\(prefix)/wp-container" }
    public static var aliasPath: String { "\(prefix)/wpc" }

    /// The embedded CLI inside the running app bundle, if present.
    public static var embeddedCLIURL: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "wp-container")
    }

    /// Install state: `.installed` only when `/usr/local/bin/wp-container` is a
    /// symlink resolving to THIS app's embedded CLI (so an install from an old
    /// app copy reads as `.outdated` and invites a refresh).
    public enum State: Sendable, Equatable { case installed, outdated, notInstalled }

    public static func currentState() -> State {
        let fm = FileManager.default
        guard fm.fileExists(atPath: cliPath) else { return .notInstalled }
        guard let embedded = embeddedCLIURL?.resolvingSymlinksInPath().path else { return .installed }
        // Resolve what's on disk and compare to our embedded binary.
        let resolved = URL(fileURLWithPath: cliPath).resolvingSymlinksInPath().path
        return resolved == embedded ? .installed : .outdated
    }

    /// Symlink the embedded CLI to `/usr/local/bin/wp-container` (+ `wpc`), via a
    /// single `osascript … with administrator privileges` prompt. Idempotent:
    /// re-running repoints the symlinks at the current app.
    public static func install() async throws {
        guard let cli = embeddedCLIURL, FileManager.default.fileExists(atPath: cli.path) else {
            throw InstallError.embeddedCLIMissing
        }
        let inner = "/bin/mkdir -p \(shellQuote(prefix))"
            + " && /bin/ln -sf \(shellQuote(cli.path)) \(shellQuote(cliPath))"
            + " && /bin/ln -sf \(shellQuote(cliPath)) \(shellQuote(aliasPath))"
        try await runAdmin(inner)
    }

    /// Remove the `wp-container` and `wpc` symlinks — only when they point at this
    /// app (never clobber a user's own binary of the same name).
    public static func uninstall() async throws {
        var cmds: [String] = []
        if symlinkPointsAtUs(cliPath)  { cmds.append("/bin/rm -f \(shellQuote(cliPath))") }
        if symlinkPointsAtUs(aliasPath, expected: cliPath) { cmds.append("/bin/rm -f \(shellQuote(aliasPath))") }
        guard !cmds.isEmpty else { return }
        try await runAdmin(cmds.joined(separator: " && "))
    }

    // MARK: - Helpers

    /// Whether `path` is a symlink resolving to our embedded CLI (or, for the
    /// alias, to `expected`).
    private static func symlinkPointsAtUs(_ path: String, expected: String? = nil) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if let expected {
            return resolved == URL(fileURLWithPath: expected).resolvingSymlinksInPath().path
        }
        return resolved == embeddedCLIURL?.resolvingSymlinksInPath().path
    }

    private static func runAdmin(_ inner: String) async throws {
        let script = "do shell script \"\(appleScriptEscape(inner))\" with administrator privileges"
        let result = try await ProcessRunner.run(executable: "/usr/bin/osascript", args: ["-e", script])
        guard result.exitCode == 0 else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            if isCancellation(detail) || result.exitCode == 15 /* SIGTERM */ {
                throw InstallError.cancelled
            }
            throw InstallError.adminFailed(detail)
        }
    }

    private static func isCancellation(_ detail: String) -> Bool {
        let d = detail.lowercased()
        return d.contains("-128") || d.contains("user canceled") || d.contains("user cancelled")
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
