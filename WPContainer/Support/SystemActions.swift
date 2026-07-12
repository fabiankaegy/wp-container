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

    /// Open Terminal.app at the given directory.
    static func openTerminal(at directory: URL) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([directory], withApplicationAt: terminal, configuration: config)
    }

    /// Copy a string to the general pasteboard.
    static func copyToClipboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}
