import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
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
        VStack(spacing: 0) {
            TabView {
                GeneralSettingsPane()
                    .tabItem { Label("General", systemImage: "gearshape") }
                SitesSettingsPane()
                    .tabItem { Label("Sites", systemImage: "square.stack.3d.up") }
                ProxySettingsPane()
                    .tabItem { Label("Proxy", systemImage: "lock.shield") }
            }
            Divider()
            Text("WP Container \(WPContainerVersion.marketing)")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
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
    @AppStorage(AppSettings.notificationsEnabledKey) private var notificationsEnabled = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var authStatus: UNAuthorizationStatus = .notDetermined

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

            SectionCard(title: "Notifications", systemImage: "bell.badge") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingRow(title: "Notifications",
                               explanation: "Notify me when a site or environment starts or stops while WP Container is in the background, a new site or branch environment is ready, WordPress core finishes updating, or the HTTPS proxy can’t start.") {
                        Toggle("", isOn: $notificationsEnabled)
                            .labelsHidden().toggleStyle(.switch)
                    }
                    if notificationsEnabled {
                        authorizationNote
                    }
                }
            }

            CLIToolsSettingsSection()

            HostsHelperSettingsSection()
        }
        .task { authStatus = await NotificationService.shared.authorizationStatus() }
    }

    /// Reflects the system authorization state (PLAN Task 1): a Request button
    /// while undecided, a deep-link to System Settings once the user has denied.
    @ViewBuilder private var authorizationNote: some View {
        switch authStatus {
        case .authorized, .provisional, .ephemeral:
            Label("Allowed in macOS System Settings.", systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        case .denied:
            HStack(alignment: .top, spacing: 8) {
                Label("Turned off in System Settings — WP Container can’t show notifications until you allow them there.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                Spacer(minLength: 8)
                Button("Open Notification Settings…") { openNotificationSettings() }
                    .controlSize(.small)
            }
        case .notDetermined:
            HStack(alignment: .top, spacing: 8) {
                Text("WP Container will ask for permission the first time it needs to notify you.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Request…") {
                    Task {
                        _ = await NotificationService.shared.requestAuthorization()
                        authStatus = await NotificationService.shared.authorizationStatus()
                    }
                }
                .controlSize(.small)
            }
        @unknown default:
            EmptyView()
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
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

// MARK: - Custom domains (Touch ID hosts helper, §2f-bis)

/// Registration UI for the privileged `wpc-hosts-helper`. When enabled, custom
/// Install the bundled `wp-container` command-line tool (+ `wpc` alias) into
/// `/usr/local/bin` with one admin prompt. It's symlinked to the app's embedded
/// binary, so it tracks app updates automatically.
private struct CLIToolsSettingsSection: View {
    @State private var state: CLIToolInstaller.State = .notInstalled
    @State private var working = false
    @State private var error: String?

    var body: some View {
        SectionCard(title: "Command-Line Tools", systemImage: "terminal") {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(title: "wp-container CLI",
                           explanation: "Install the `wp-container` command (and its `wpc` alias) into /usr/local/bin so you can script sites and branch environments from Terminal — and drive the app from AI agents over MCP. It's symlinked to this app, so it stays in sync with updates.") {
                    control
                }
                statusLabel
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { state = CLIToolInstaller.currentState() }
    }

    @ViewBuilder private var control: some View {
        HStack(spacing: 8) {
            if working {
                ProgressView().controlSize(.small)
            }
            switch state {
            case .notInstalled:
                Button("Install…") { run { try await CLIToolInstaller.install() } }
                    .disabled(working)
            case .outdated:
                Button("Update…") { run { try await CLIToolInstaller.install() } }
                    .disabled(working)
            case .installed:
                Button("Uninstall…") { run { try await CLIToolInstaller.uninstall() } }
                    .disabled(working)
            }
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch state {
        case .installed:
            Label("Installed at \(CLIToolInstaller.cliPath).", systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        case .outdated:
            Label("An older or external wp-container is on your PATH — update it to point at this app.",
                  systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .notInstalled:
            Text("Not installed. Installing needs your administrator password once.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Run a privileged action, then refresh state. A cancelled auth dialog is
    /// silent (the user chose to back out); other failures surface inline.
    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            do { try await action() }
            catch CLIToolInstaller.InstallError.cancelled { /* user backed out */ }
            catch { self.error = "\(error)" }
            state = CLIToolInstaller.currentState()
            working = false
        }
    }
}

/// domain changes rewrite `/etc/hosts` behind the Touch ID-capable system
/// authorization dialog instead of the osascript password prompt. Registration
/// needs a one-time user approval in System Settings > Login Items — reaching
/// `.requiresApproval` is expected and the button deep-links there.
private struct HostsHelperSettingsSection: View {
    @State private var status = HostsHelperClient.status
    @State private var error: String?

    var body: some View {
        SectionCard(title: "Custom Domains", systemImage: "touchid") {
            VStack(alignment: .leading, spacing: 10) {
                if HostsHelperClient.isSupportedBuild {
                    content
                } else {
                    Label("The Touch ID helper is available in the signed release build. This build uses the one-time admin-password prompt for /etc/hosts.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { status = HostsHelperClient.status }
    }

    @ViewBuilder private var content: some View {
        switch status {
        case .enabled:
            HStack(alignment: .top, spacing: 8) {
                Label("Enabled — custom domain changes use Touch ID (no password).",
                      systemImage: "checkmark.seal.fill")
                    .font(.callout).foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Disable") { setEnabled(false) }
                    .controlSize(.small)
            }
        case .requiresApproval:
            statusRow(
                text: "Almost done — approve “WP Container” in System Settings › General › Login Items › Allow in the Background, then reopen this window.",
                systemImage: "exclamationmark.circle.fill", tint: .orange,
                button: "Open Login Items…") { openLoginItems() }
        default:
            statusRow(
                text: "Enable the privileged helper to update /etc/hosts with Touch ID. One-time setup — you'll approve it once in System Settings.",
                systemImage: "touchid", tint: .secondary,
                button: "Enable Helper…") { setEnabled(true) }
        }
    }

    private func statusRow(text: String, systemImage: String, tint: Color,
                           button: String,
                           action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Label(text, systemImage: systemImage)
                .font(.callout).foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(button, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    private func setEnabled(_ enabled: Bool) {
        error = nil
        do {
            if enabled {
                try HostsHelperClient.register()
            } else {
                try HostsHelperClient.unregister()
            }
        } catch {
            self.error = "Could not \(enabled ? "enable" : "disable") the helper: \(error.localizedDescription)"
        }
        status = HostsHelperClient.status
        // Registration typically lands in .requiresApproval — send the user
        // straight to the approval pane.
        if enabled, status == .requiresApproval { openLoginItems() }
    }

    private func openLoginItems() {
        if let url = HostsHelperClient.loginItemsSettingsURL {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Sites

private struct SitesSettingsPane: View {
    @Environment(AppViewModel.self) private var vm
    @AppStorage(AppSettings.defaultSitesRootKey) private var defaultSitesRoot = ""
    @AppStorage(AppSettings.defaultWordPressVersionKey) private var defaultWordPress = "latest"
    @AppStorage(AppSettings.defaultPHPVersionKey) private var defaultPHP = WordPressImageCatalog.defaultPHP
    @AppStorage(ExternalEditors.targetKey) private var openInTarget = OpenInTarget.siteFolder.rawValue
    @AppStorage(AppSettings.terminalAppKey) private var terminalApp = TerminalApp.terminal.rawValue
    @AppStorage(AppSettings.defaultHTTPSKey) private var defaultHTTPS = true
    @AppStorage(AppSettings.defaultWPDebugKey) private var defaultWPDebug = true
    @AppStorage(AppSettings.defaultScriptDebugKey) private var defaultScriptDebug = true
    @AppStorage(AppSettings.defaultGlobalWPRouterKey) private var defaultGlobalWPRouter = true

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

                    Divider().opacity(0.5)

                    SettingRow(title: "\u{201C}Open In\u{201D} folder",
                               explanation: "Which folder the Open In button and menus hand to external editors.") {
                        Picker("", selection: $openInTarget) {
                            ForEach(OpenInTarget.allCases) { t in Text(t.label).tag(t.rawValue) }
                        }
                        .labelsHidden().fixedSize()
                    }

                    SettingRow(title: "Terminal app",
                               explanation: "Which app the Terminal buttons and menus open. Ghostty 1.3+ and iTerm2 appear here when installed.") {
                        Picker("", selection: $terminalApp) {
                            ForEach(TerminalApps.installed()) { app in Text(app.name).tag(app.rawValue) }
                        }
                        .labelsHidden().fixedSize()
                    }

                    Divider().opacity(0.5)

                    SettingRow(title: "Enable HTTPS",
                               explanation: "New sites serve over https://<slug>.localhost through the local proxy, with the certificate trusted automatically.") {
                        Toggle("", isOn: $defaultHTTPS).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow(title: "WP_DEBUG",
                               explanation: "Turn on WordPress debug mode in new sites' wp-config.php.") {
                        Toggle("", isOn: $defaultWPDebug).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow(title: "SCRIPT_DEBUG",
                               explanation: "Load unminified core CSS/JS in new sites' wp-config.php.") {
                        Toggle("", isOn: $defaultScriptDebug).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow(title: "Global wp router",
                               explanation: "When you create a site, install the global wp router (once) so plain `wp` inside any site folder runs containerized wp-cli. Adds a PATH line to ~/.zshrc; remove it anytime from a site's Integrations settings.") {
                        Toggle("", isOn: $defaultGlobalWPRouter).labelsHidden().toggleStyle(.switch)
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
    // Registered default is TRUE (AppSettings.registerDefaults): the proxy is
    // required for HTTPS/custom-domain sites, so launch-start is opt-OUT.
    @AppStorage(AppSettings.autoStartProxyKey) private var autoStartProxy = true

    var body: some View {
        SettingsPane {
            SectionCard(title: "HTTPS Proxy", systemImage: "lock.shield") {
                VStack(alignment: .leading, spacing: 14) {
                    SettingRow(title: "Start HTTPS proxy at launch",
                               explanation: "Start the local HTTPS reverse proxy when WP Container opens, so https://<site>.localhost and custom domains work right away. Turning it off has little effect in practice: the proxy also starts whenever anything needs it — including any branch environment, whose http://127.0.0.1:<port> URL the proxy serves directly (its container publishes no port of its own), so it auto-starts as soon as one environment exists.") {
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
                            Text("Proxy not running. Branch-environment URLs don’t answer without it, and it starts on demand when a site enables HTTPS.")
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
