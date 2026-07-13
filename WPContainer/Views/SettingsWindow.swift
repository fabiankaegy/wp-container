import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import WPContainerKit

/// The app Settings window (⌘,) — PLAN.md §2l. Three panes in a native settings
/// TabView, each reusing the in-app card/row design language (`SectionCard` +
/// label/explanation/trailing-control rows). Everything persists via
/// `@AppStorage`; kit and launch wiring read the same keys through `AppSettings`.
///
/// Scope note: these are APP-wide defaults only. Per-SITE settings (HTTPS, agent
/// tools, add-ons, debug constants, domain) stay in the site detail Settings tab.
struct SettingsWindow: View {
    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            SitesSettingsPane()
                .tabItem { Label("Sites", systemImage: "square.stack.3d.up") }
            ProxySettingsPane()
                .tabItem { Label("Proxy", systemImage: "lock.shield") }
        }
        .frame(width: 520)
    }
}

// MARK: - Pane scaffold

/// Shared chrome for a settings pane: the SectionCards scroll inside a fixed
/// width so the window reads like the in-app Settings tab.
private struct SettingsPane<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A label + explanation on the left, a trailing control on the right — the same
/// shape used throughout the in-app Settings cards (e.g. IntegrationsCard).
private struct SettingRow<Control: View>: View {
    let title: String
    let explanation: String
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(explanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @AppStorage(AppSettings.showDockIconKey) private var showDockIcon = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        SettingsPane {
            SectionCard(title: "General", systemImage: "gearshape") {
                VStack(alignment: .leading, spacing: 14) {
                    SettingRow(title: "Show Dock icon",
                               explanation: "Turn off to run WP Container as a menu-bar-first app: the Dock icon is hidden and the app stays available from the menu bar extra.") {
                        Toggle("", isOn: $showDockIcon)
                            .labelsHidden().toggleStyle(.switch)
                    }
                    .onChange(of: showDockIcon) {
                        AppSettings.applyActivationPolicy()
                        // Flipping to `.accessory` can background the app; keep it
                        // active so the settings window the user is holding stays up.
                        NSApp.activate(ignoringOtherApps: true)
                    }

                    Divider().opacity(0.5)

                    SettingRow(title: "Launch at login",
                               explanation: "Start WP Container automatically when you log in, so your sites and the HTTPS proxy are ready.") {
                        Toggle("", isOn: $launchAtLogin)
                            .labelsHidden().toggleStyle(.switch)
                    }
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }

                    if let loginError {
                        Label(loginError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginError = "Could not \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)"
            // Reflect the true state back into the toggle.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Sites

private struct SitesSettingsPane: View {
    @Environment(AppViewModel.self) private var vm
    @AppStorage(AppSettings.defaultSitesRootKey) private var defaultSitesRoot = ""
    @AppStorage(AppSettings.defaultWordPressVersionKey) private var defaultWordPress = "latest"
    @AppStorage(AppSettings.defaultPHPVersionKey) private var defaultPHP = WordPressImageCatalog.defaultPHP

    @State private var choosingFolder = false

    private var effectiveRoot: URL {
        defaultSitesRoot.isEmpty
            ? SiteFolders.builtInDefaultSitesRoot
            : URL(fileURLWithPath: defaultSitesRoot, isDirectory: true)
    }

    var body: some View {
        SettingsPane {
            SectionCard(title: "New Site Defaults", systemImage: "square.stack.3d.up") {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Default sites folder").font(.callout.weight(.medium))
                        Text("Where the Add Site guide puts new sites unless you pick another location.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text(effectiveRoot.path(percentEncoded: false))
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Choose…") { choosingFolder = true }
                                .controlSize(.small)
                            if !defaultSitesRoot.isEmpty {
                                Button("Reset") { defaultSitesRoot = "" }
                                    .controlSize(.small)
                            }
                        }
                    }

                    Divider().opacity(0.5)

                    SettingRow(title: "WordPress version",
                               explanation: "Prefilled in the Add Site guide's version step.") {
                        Picker("", selection: $defaultWordPress) {
                            ForEach(vm.versionMatrix.wordPressVersions, id: \.self) { v in
                                Text(v == "latest" ? "Latest" : v).tag(v)
                            }
                        }
                        .labelsHidden().fixedSize()
                    }

                    SettingRow(title: "PHP version",
                               explanation: "Prefilled in the Add Site guide's version step.") {
                        Picker("", selection: $defaultPHP) {
                            ForEach(vm.versionMatrix.phpVersions(for: defaultWordPress), id: \.self) { v in Text(v).tag(v) }
                        }
                        .labelsHidden().fixedSize()
                    }

                    if !vm.versionMatrix.isValid(wp: defaultWordPress, php: defaultPHP) {
                        Label("This WordPress × PHP combination may not be published on Docker Hub.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { defaultSitesRoot = url.path(percentEncoded: false) }
        }
    }
}

// MARK: - Proxy / HTTPS

private struct ProxySettingsPane: View {
    @Environment(AppViewModel.self) private var vm
    @AppStorage(AppSettings.autoStartProxyKey) private var autoStartProxy = false

    var body: some View {
        SettingsPane {
            SectionCard(title: "HTTPS Proxy", systemImage: "lock.shield") {
                VStack(alignment: .leading, spacing: 14) {
                    SettingRow(title: "Start HTTPS proxy at launch",
                               explanation: "Automatically start the local HTTPS reverse proxy when WP Container opens, so https://<site>.localhost works right away.") {
                        Toggle("", isOn: $autoStartProxy)
                            .labelsHidden().toggleStyle(.switch)
                    }
                    .onChange(of: autoStartProxy) { _, newValue in
                        if newValue { Task { await vm.ensureProxyRunning() } }
                    }

                    Divider().opacity(0.5)

                    HStack(spacing: 8) {
                        Image(systemName: vm.proxyPort != nil ? "checkmark.seal.fill" : "pause.circle")
                            .foregroundStyle(vm.proxyPort != nil ? .green : .secondary)
                        if let port = vm.proxyPort {
                            Text("Proxy running on port \(String(port)).")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Proxy not running. It starts on demand when a site enables HTTPS.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if vm.proxyPort == nil {
                            Button("Start now") { Task { await vm.ensureProxyRunning() } }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}
