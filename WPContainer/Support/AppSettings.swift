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

    /// Defaults TRUE via `registerDefaults()`: HTTPS/custom-domain sites are
    /// dead without a 443 listener, so an app relaunch must bring the proxy
    /// back without user action (user-reported bug: "Safari Can't Connect" —
    /// nothing listening on 443 after relaunch). The Settings toggle is now an
    /// opt-OUT override; correctness additionally never depends on it (see
    /// AppViewModel.ensureProxyIfNeeded).
    static var autoStartProxy: Bool {
        UserDefaults.standard.bool(forKey: autoStartProxyKey)
    }

    /// Register defaults for keys whose ABSENT value must not read as false.
    /// Call once, as early as possible.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoStartProxyKey: true,
        ])
    }

    /// Apply the Dock-icon preference to the running app. `.accessory` hides the
    /// Dock icon (menu-bar-first) while keeping the menu bar extra and windows
    /// alive; `.regular` restores normal Dock presence. Flipping to `.accessory`
    /// can background the app, so callers that toggle live should re-activate.
    @MainActor
    static func applyActivationPolicy() {
        // Use `NSApplication.shared` (lazily creates/returns the singleton), not
        // the `NSApp` global, which is nil until the app object exists.
        NSApplication.shared.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }
}
