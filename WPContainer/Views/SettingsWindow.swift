import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import WPContainerKit

/// The app Settings window (⌘,) — PLAN.md §2l. Three panes in a native settings
/// TabView, each reusing the in-app card/row design language (`SectionCard` +
/// `SettingRow`). Everything persists via
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
                               detail: Text("When off, WP Container lives only in the menu bar.")) {
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
                               detail: Text("Opens WP Container when you log in, so the proxy is ready.")) {
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
                    SettingRow(title: "Show notifications",
                               detail: Text("When a site or environment is ready, starts or stops in the background, or something fails.")) {
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
            Label("Allowed in System Settings.", systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        case .denied:
            HStack(alignment: .top, spacing: 8) {
                Label("Notifications are turned off for WP Container in System Settings.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                Spacer(minLength: 8)
                Button("Open Notification Settings…") { openNotificationSettings() }
                    .controlSize(.small)
            }
        case .notDetermined:
            HStack(alignment: .top, spacing: 8) {
                Text("macOS asks for permission the first time WP Container notifies you.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Allow…") {
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
            loginError = "Couldn’t \(enabled ? "turn on" : "turn off") launch at login: \(error.localizedDescription)"
            // Reflect the true state back into the toggle.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Custom domains (Touch ID hosts helper, §2f-bis)

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
                           detail: Text("Adds `wp-container` and its `wpc` alias to /usr/local/bin, for scripts, Terminal and AI agents over MCP. Updates with the app.")) {
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
            Label("Another wp-container is on your PATH. Update it to use this app’s version.",
                  systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .notInstalled:
            Text("Not installed. Installing asks for your admin password once.")
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

/// Registration UI for the privileged `wpc-hosts-helper`. When enabled, custom
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
                    Label("The Touch ID helper needs the signed release build. This build asks for your admin password instead.",
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
                Label("On. Custom domain changes use Touch ID.",
                      systemImage: "checkmark.seal.fill")
                    .font(.callout).foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Turn Off") { setEnabled(false) }
                    .controlSize(.small)
            }
        case .requiresApproval:
            statusRow(
                text: "Allow “WP Container” to run in the background in Login Items, then reopen Settings.",
                systemImage: "exclamationmark.circle.fill", tint: .orange,
                button: "Open Login Items…") { openLoginItems() }
        default:
            statusRow(
                text: "Confirm custom domain changes with Touch ID instead of your admin password. You approve the helper once in System Settings.",
                systemImage: "touchid", tint: .secondary,
                button: "Turn On…") { setEnabled(true) }
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
            self.error = "Couldn’t \(enabled ? "turn on" : "turn off") the helper: \(error.localizedDescription)"
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
    @AppStorage(AppSettings.autoPurgeSettledEnvsKey) private var autoPurgeSettledEnvs = true
    @AppStorage(AppSettings.purgeSettledAfterDaysKey) private var purgeSettledAfterDays = EnvSettlement.defaultPurgeAfterDays

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
                        Text("Where new sites go unless you choose another location.")
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

                    SettingRow(title: "WordPress version") {
                        Picker("", selection: $defaultWordPress) {
                            ForEach(vm.versionMatrix.wordPressVersions, id: \.self) { v in
                                Text(v == "latest" ? "Latest" : v).tag(v)
                            }
                        }
                        .labelsHidden().fixedSize()
                    }

                    SettingRow(title: "PHP version") {
                        Picker("", selection: $defaultPHP) {
                            ForEach(vm.versionMatrix.phpVersions(for: defaultWordPress), id: \.self) { v in Text(v).tag(v) }
                        }
                        .labelsHidden().fixedSize()
                    }

                    Divider().opacity(0.5)

                    SettingRow(title: "Open In folder",
                               detail: Text("The folder Open In opens in your editor.")) {
                        Picker("", selection: $openInTarget) {
                            ForEach(OpenInTarget.allCases) { t in Text(t.label).tag(t.rawValue) }
                        }
                        .labelsHidden().fixedSize()
                    }

                    SettingRow(title: "Terminal app",
                               detail: Text("Used by Open in Terminal. Lists Ghostty 1.3+ and iTerm2 when installed.")) {
                        Picker("", selection: $terminalApp) {
                            ForEach(TerminalApps.installed()) { app in Text(app.name).tag(app.rawValue) }
                        }
                        .labelsHidden().fixedSize()
                    }

                    Divider().opacity(0.5)

                    SettingRow(title: "Use HTTPS",
                               detail: Text("Serves new sites at https://<slug>.localhost.")) {
                        Toggle("", isOn: $defaultHTTPS).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow(title: "WP_DEBUG",
                               detail: Text("Turns on WordPress debug mode.")) {
                        Toggle("", isOn: $defaultWPDebug).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow(title: "SCRIPT_DEBUG",
                               detail: Text("Loads unminified core CSS and JavaScript.")) {
                        Toggle("", isOn: $defaultScriptDebug).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow(title: "Global `wp` command",
                               detail: Text("Run plain `wp` inside any site folder. Adds a line to ~/.zshrc.")) {
                        Toggle("", isOn: $defaultGlobalWPRouter).labelsHidden().toggleStyle(.switch)
                    }

                    if !vm.versionMatrix.isValid(wp: defaultWordPress, php: defaultPHP) {
                        Label("This WordPress and PHP combination may not exist on Docker Hub.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            SectionCard(title: "Branch Environments", systemImage: "arrow.triangle.branch") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingRow(title: "Delete settled environments",
                               detail: Text("Deletes environments that stay settled past the time below. Branches, and checkouts with uncommitted changes, are kept.")) {
                        Toggle("", isOn: $autoPurgeSettledEnvs).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow(title: "Delete after") {
                        Picker("", selection: $purgeSettledAfterDays) {
                            ForEach(EnvSettlement.purgeAfterDayChoices, id: \.self) { Text("\($0) days").tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        .disabled(!autoPurgeSettledEnvs)
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
                    SettingRow(title: "Start proxy at launch",
                               detail: Text("Serves HTTPS sites and custom domains as soon as WP Container opens. The proxy also starts on its own whenever a site or branch environment needs it.")) {
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
                            Text("Running on port \(String(port)).")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Not running. HTTPS sites and branch environments don’t load without it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if vm.proxyPort == nil {
                            Button("Start Proxy") { Task { await vm.ensureProxyRunning() } }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}
