import SwiftUI
import WPContainerKit

/// The configurable "Open In ▾" control (action bars): primary click opens the
/// folder in the last-used editor (default: first installed known app; Finder
/// when none), the chevron menu lists every installed editor, a "Choose App…"
/// escape hatch, and — for sites — a "Folder to Open" submenu switching the ONE
/// global open-target preference (site folder / wordpress/ / wp-content/).
struct OpenInButton: View {
    /// The folder a click opens. Sites derive it from the global target
    /// preference; envs pass their worktree checkout directly.
    private let site: Site?
    private let fixedFolder: URL?

    @AppStorage(ExternalEditors.lastUsedKey) private var lastUsed = ""
    @AppStorage(ExternalEditors.targetKey) private var targetRaw = OpenInTarget.siteFolder.rawValue

    /// Site variant: folder follows the global open-target preference.
    init(site: Site) {
        self.site = site
        self.fixedFolder = nil
    }

    /// Env (or fixed-folder) variant: always opens this folder.
    init(folder: URL) {
        self.site = nil
        self.fixedFolder = folder
    }

    private var folder: URL {
        if let site {
            return (OpenInTarget(rawValue: targetRaw) ?? .siteFolder).url(for: site)
        }
        return fixedFolder!
    }

    private var preferredName: String {
        ExternalEditors.preferred()?.name ?? "Finder"
    }

    var body: some View {
        Menu {
            OpenInMenuItems(folder: folder)
            if site != nil {
                Divider()
                Menu("Folder to Open") {
                    ForEach(OpenInTarget.allCases) { target in
                        Toggle(target.label, isOn: Binding(
                            get: { targetRaw == target.rawValue },
                            set: { _ in targetRaw = target.rawValue }
                        ))
                    }
                }
            }
        } label: {
            Label("Open In \(preferredName)", systemImage: "arrow.up.forward.app")
        } primaryAction: {
            ExternalEditors.openPreferred(folder)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .fixedSize()
        .help("Open \(folder.lastPathComponent) in \(preferredName); the menu lists other installed editors")
    }
}

/// The shared editor list menu items ("Cursor", "VS Code", …, "Choose App…").
/// Used inside `OpenInButton` and as the body of context-menu "Open In ▸"
/// submenus.
struct OpenInMenuItems: View {
    let folder: URL

    var body: some View {
        ForEach(ExternalEditors.installed()) { editor in
            Button(editor.name) { ExternalEditors.open(folder, in: editor) }
        }
        Divider()
        Button("Choose App…") {
            Task { @MainActor in ExternalEditors.chooseAndOpen(folder) }
        }
    }
}

/// Context-menu submenu: "Open In ▸ <editors>".
struct OpenInSubmenu: View {
    let folder: URL

    var body: some View {
        Menu("Open In") {
            OpenInMenuItems(folder: folder)
        }
    }
}
