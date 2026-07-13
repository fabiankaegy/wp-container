import AppKit
import Foundation
import WPContainerKit

/// An installed external editor/app the "Open In" control can target.
struct ExternalEditor: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let appURL: URL
    var id: String { bundleID }
}

/// Which folder the "Open In" control opens (ONE global preference, persisted;
/// the action-bar submenu switches it).
enum OpenInTarget: String, CaseIterable, Identifiable {
    case siteFolder = "site"
    case wordpress = "wordpress"
    case wpContent = "wp-content"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .siteFolder: return "Site Folder"
        case .wordpress:  return "wordpress/"
        case .wpContent:  return "wp-content/"
        }
    }

    func url(for site: Site) -> URL {
        switch self {
        case .siteFolder: return site.path
        case .wordpress:  return site.wordpressFolder
        case .wpContent:  return site.wordpressFolder.appendingPathComponent("wp-content", isDirectory: true)
        }
    }
}

/// Detection + persistence + open mechanics for the configurable "Open In"
/// control (site detail action bar and site/env context menus).
enum ExternalEditors {
    // MARK: Known apps (shown when installed)

    /// Curated (name, bundle id) table. Cursor's id was VERIFIED empirically on
    /// this machine (mdls on /Applications/Cursor.app). Apps without a bundle
    /// on this Mac simply don't appear; "Choose App…" covers anything else.
    static let known: [(name: String, bundleID: String)] = [
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Visual Studio Code", "com.microsoft.VSCode"),
        ("Zed", "dev.zed.Zed"),
        ("Sublime Text", "com.sublimetext.4"),
        ("PhpStorm", "com.jetbrains.PhpStorm"),
        ("Nova", "com.panic.Nova"),
        ("Xcode", "com.apple.dt.Xcode"),
        ("TextMate", "com.macromates.TextMate"),
        ("BBEdit", "com.barebones.bbedit"),
    ]

    // MARK: Persistence keys (registered in AppSettings)

    static let lastUsedKey = "openInLastEditor"
    static let customAppsKey = "openInCustomEditors" // [String] bundle ids
    static let targetKey = "openInTarget"            // OpenInTarget rawValue

    // MARK: Detection

    private static func resolve(bundleID: String, name: String? = nil) -> ExternalEditor? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let display = name
            ?? (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return ExternalEditor(bundleID: bundleID, name: display, appURL: url)
    }

    /// Installed editors: curated known apps first (curated order), then any
    /// user-added custom apps that still resolve.
    static func installed() -> [ExternalEditor] {
        var seen = Set<String>()
        var result: [ExternalEditor] = []
        for entry in known {
            if let editor = resolve(bundleID: entry.bundleID, name: entry.name), seen.insert(editor.bundleID).inserted {
                result.append(editor)
            }
        }
        let custom = UserDefaults.standard.stringArray(forKey: customAppsKey) ?? []
        for bundleID in custom {
            if let editor = resolve(bundleID: bundleID), seen.insert(editor.bundleID).inserted {
                result.append(editor)
            }
        }
        return result
    }

    // MARK: Last-used / default

    /// The editor a plain click opens: last used if still installed, else the
    /// first installed known app, else nil (caller falls back to Finder).
    static func preferred() -> ExternalEditor? {
        if let last = UserDefaults.standard.string(forKey: lastUsedKey),
           let editor = resolve(bundleID: last) {
            return editor
        }
        return installed().first
    }

    static var target: OpenInTarget {
        get { OpenInTarget(rawValue: UserDefaults.standard.string(forKey: targetKey) ?? "") ?? .siteFolder }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: targetKey) }
    }

    // MARK: Open mechanics

    /// Open a folder in an editor (folder passed as the document argument so
    /// editors open it as a workspace root), remembering the choice.
    static func open(_ folder: URL, in editor: ExternalEditor) {
        UserDefaults.standard.set(editor.bundleID, forKey: lastUsedKey)
        NSWorkspace.shared.open([folder], withApplicationAt: editor.appURL,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                NSLog("OpenIn: failed to open \(folder.path) in \(editor.name): \(error)")
            }
        }
    }

    /// Open with the preferred editor, else reveal in Finder.
    static func openPreferred(_ folder: URL) {
        if let editor = preferred() {
            open(folder, in: editor)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    /// "Choose App…": pick an .app from /Applications, persist it as a custom
    /// entry (it appears in the list from then on) and open with it right away.
    @MainActor
    static func chooseAndOpen(_ folder: URL) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an application to open the folder with"
        guard panel.runModal() == .OK, let appURL = panel.url,
              let bundleID = Bundle(url: appURL)?.bundleIdentifier else { return }
        var custom = UserDefaults.standard.stringArray(forKey: customAppsKey) ?? []
        if !custom.contains(bundleID), !known.contains(where: { $0.bundleID == bundleID }) {
            custom.append(bundleID)
            UserDefaults.standard.set(custom, forKey: customAppsKey)
        }
        if let editor = resolve(bundleID: bundleID) {
            open(folder, in: editor)
        }
    }
}
