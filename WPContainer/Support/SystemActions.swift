import AppKit
import Foundation

/// Thin wrappers around AppKit for the quiet action-bar buttons. Keeps views
/// free of direct `NSWorkspace` / `NSPasteboard` calls.
@MainActor
enum SystemActions {
    /// Open a URL in the user's default browser.
    static func openInBrowser(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Reveal a folder (or file) in Finder.
    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Open the chosen terminal app at the given directory. When `pathPrepend`
    /// is set, the new shell has that dir first on PATH (so a site's `./wp` shim
    /// answers to a plain `wp` in that shell — a lightweight local alternative
    /// to the global router). Plain Terminal with no PATH change opens through
    /// NSWorkspace, which needs no Automation permission.
    static func openTerminal(at directory: URL, pathPrepend: URL? = nil) {
        if pathPrepend == nil, TerminalApps.selected == .terminal {
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([directory], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        var cmd = "cd \(shellQuote(directory.path)); "
        if let pathPrepend {
            cmd += "export PATH=\(shellQuote(pathPrepend.path)):\"$PATH\"; "
        }
        cmd += "clear"
        openTerminalRunning(cmd)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Open a new window of the chosen terminal app running `command` (used for
    /// the interactive wp-cli container).
    static func openTerminalRunning(_ command: String) {
        TerminalApps.open(running: command)
    }

    /// Copy a string to the general pasteboard.
    static func copyToClipboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}
