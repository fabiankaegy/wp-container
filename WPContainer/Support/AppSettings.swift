import AppKit
import Foundation

/// Central registry of app-wide preference keys (PLAN.md §2l) persisted in
/// `UserDefaults` and surfaced by the Settings window (⌘,). Views bind to these
/// keys with `@AppStorage`; non-view code (kit defaults, launch wiring) reads
/// them through the typed accessors here so there is one source of truth for
/// key names and default values.
enum AppSettings {
    // Keys — keep in sync with the `@AppStorage` wrappers in SettingsWindow.
    static let showDockIconKey = "showDockIcon"
    static let defaultSitesRootKey = "defaultSitesRoot"
    static let defaultWordPressVersionKey = "defaultWordPressVersion"
    static let defaultPHPVersionKey = "defaultPHPVersion"
    static let autoStartProxyKey = "autoStartProxy"

    // Defaults.
    static var showDockIcon: Bool {
        // Absent → true (normal Dock presence).
        UserDefaults.standard.object(forKey: showDockIconKey) as? Bool ?? true
    }

    static var autoStartProxy: Bool {
        UserDefaults.standard.bool(forKey: autoStartProxyKey)
    }

    /// Apply the Dock-icon preference to the running app. `.accessory` hides the
    /// Dock icon (menu-bar-first) while keeping the menu bar extra and windows
    /// alive; `.regular` restores normal Dock presence. Flipping to `.accessory`
    /// can background the app, so callers that toggle live should re-activate.
    @MainActor
    static func applyActivationPolicy() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }
}
