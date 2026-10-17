import AppKit
import Foundation
import WPContainerKit

/// Detection and launch for the terminal app the "Terminal" buttons open
/// (Settings → Sites → Terminal app).
enum TerminalApps {
    /// Terminal apps installed at a version that supports opening a window
    /// running a command, in declaration order.
    static func installed() -> [TerminalApp] {
        TerminalApp.allCases.filter(isUsable)
    }

    /// The chosen terminal app, or Terminal when the choice is no longer usable.
    static var selected: TerminalApp {
        let stored = UserDefaults.standard.string(forKey: AppSettings.terminalAppKey) ?? ""
        guard let app = TerminalApp(rawValue: stored), isUsable(app) else { return .terminal }
        return app
    }

    /// Open a new window of the chosen terminal app running `command`. When the
    /// script fails (an Automation permission denied, a missing app), the
    /// command opens in Terminal.
    static func open(running command: String) {
        let app = selected
        run(app.openScript(running: command)) { succeeded in
            guard !succeeded, app != .terminal else { return }
            NSLog("Terminal: \(app.name) failed to open a window; using Terminal")
            run(TerminalApp.terminal.openScript(running: command)) { _ in }
        }
    }

    private static func isUsable(_ app: TerminalApp) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else { return false }
        let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return app.supports(version: version)
    }

    private static func run(_ script: String, completion: @escaping @Sendable (Bool) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.terminationHandler = { completion($0.terminationStatus == 0) }
        do {
            try process.run()
        } catch {
            completion(false)
        }
    }
}
