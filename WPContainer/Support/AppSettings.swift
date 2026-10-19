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
    static let notificationsEnabledKey = "notificationsEnabled"
    // New-site defaults (all default TRUE via `registerDefaults()`): applied when
    // the Add Site guide creates a site. Surfaced in Settings → Sites.
    static let defaultHTTPSKey = "defaultHTTPS"
    static let defaultWPDebugKey = "defaultWPDebug"
    static let defaultScriptDebugKey = "defaultScriptDebug"
    static let defaultGlobalWPRouterKey = "defaultGlobalWPRouter"
    /// The terminal app the Terminal buttons open (`TerminalApp` raw value).
    /// Absent → Terminal; read through `TerminalApps.selected`.
    static let terminalAppKey = "terminalApp"
    /// Whether the one-time "install the command-line tool?" offer has been shown.
    /// Defaults FALSE (absent → not yet offered), so it fires once and never nags.
    static let didOfferCLIInstallKey = "didOfferCLIInstall"

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

    /// Master switch for native notifications (PLAN.md Task 1). Defaults TRUE via
    /// `registerDefaults()`; the actual system authorization is a separate,
    /// lazily-requested gate handled by `NotificationService`.
    static var notificationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: notificationsEnabledKey)
    }

    // New-site defaults. All default TRUE via `registerDefaults()`; the Add Site
    // guide seeds its toggles from these and `AppViewModel.createAndStartSite`
    // applies them (HTTPS + debug constants per-site; the global wp router once).
    static var defaultHTTPS: Bool { UserDefaults.standard.bool(forKey: defaultHTTPSKey) }
    static var defaultWPDebug: Bool { UserDefaults.standard.bool(forKey: defaultWPDebugKey) }
    static var defaultScriptDebug: Bool { UserDefaults.standard.bool(forKey: defaultScriptDebugKey) }
    static var defaultGlobalWPRouter: Bool { UserDefaults.standard.bool(forKey: defaultGlobalWPRouterKey) }

    /// One-time gate for the first-run CLI-install offer (see
    /// `AppViewModel.maybeOfferCLIInstall`). Not registered as a default — absent
    /// reads as false (not yet offered).
    static var didOfferCLIInstall: Bool {
        get { UserDefaults.standard.bool(forKey: didOfferCLIInstallKey) }
        set { UserDefaults.standard.set(newValue, forKey: didOfferCLIInstallKey) }
    }

    /// Register defaults for keys whose ABSENT value must not read as false.
    /// Call once, as early as possible.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoStartProxyKey: true,
            notificationsEnabledKey: true,
            defaultHTTPSKey: true,
            defaultWPDebugKey: true,
            defaultScriptDebugKey: true,
            defaultGlobalWPRouterKey: true,
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
