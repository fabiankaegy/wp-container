import Foundation

/// A terminal app the "Terminal" buttons can open, and the AppleScript that
/// opens a new window of it running a command in the user's login shell.
public enum TerminalApp: String, CaseIterable, Identifiable, Sendable {
    case terminal
    case ghostty

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .terminal: return "Terminal"
        case .ghostty:  return "Ghostty"
        }
    }

    public var bundleID: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .ghostty:  return "com.mitchellh.ghostty"
        }
    }

    /// The first version with the AppleScript commands `openScript` uses, or
    /// nil when every version has them. Ghostty added AppleScript in 1.3.0.
    public var minimumVersion: String? {
        switch self {
        case .terminal: return nil
        case .ghostty:  return "1.3.0"
        }
    }

    /// Whether `version` (a `CFBundleShortVersionString`) supports `openScript`.
    public func supports(version: String?) -> Bool {
        guard let minimumVersion else { return true }
        guard let version else { return false }
        return version.compare(minimumVersion, options: .numeric) != .orderedAscending
    }

    /// AppleScript that opens a new window running `command`. The command is
    /// typed into the user's login shell, which stays open when it exits.
    public func openScript(running command: String) -> String {
        let text = Self.appleScriptString(command)
        switch self {
        case .terminal:
            return """
            tell application "Terminal"
                activate
                do script \(text)
            end tell
            """
        case .ghostty:
            return """
            tell application "Ghostty"
                activate
                set cfg to new surface configuration
                set initial input of cfg to \(text) & linefeed
                new window with configuration cfg
            end tell
            """
        }
    }

    /// `s` as a double-quoted AppleScript string literal.
    static func appleScriptString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
