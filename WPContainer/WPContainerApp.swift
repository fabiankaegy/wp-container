import SwiftUI
import WPContainerKit

@main
struct WPContainerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel: AppViewModel

    init() {
        AppSettings.registerDefaults()
        let vm = AppViewModel()
        _viewModel = State(initialValue: vm)
        // Give the app delegate the shared view model so a full quit can stop
        // every running site/env before the process exits.
        appDelegate.viewModel = vm
        // Bootstrap at APP level, not window level: the menu bar extra must have
        // a loaded store + running reconcile loop even if the popover is opened
        // before the main window appears (or after it has been closed).
        Task { @MainActor in
            // Apply the persisted Dock-icon preference (menu-bar-first mode) as
            // early as possible — but NOT from `init`, where the shared
            // application object does not yet exist. This main-actor task runs
            // once the run loop is up, so `NSApplication.shared` is valid.
            AppSettings.applyActivationPolicy()
            // Release the proxy pidfile on quit (#4) so a relaunch never
            // depends on stale-PID detection. Ownership-checked: quitting an
            // instance that doesn't own the proxy (e.g. `proxy serve` does)
            // must not delete the real owner's record.
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { _ in
                ProxyControl.releaseIfOwned()
            }
            await vm.onAppear()
            // HTTPS proxy at launch (PLAN.md §2f): the opt-out setting
            // (registered default: on) starts it unconditionally; even when
            // opted out, correctness wins — any HTTPS/custom-domain site needs
            // a 443 listener, so ensure one exists whenever such a site does.
            if AppSettings.autoStartProxy {
                await vm.ensureProxyRunning()
            } else {
                await vm.ensureProxyIfNeeded()
            }
            // DNS health (2026-07-16): mDNSResponder can wedge and silently stop
            // serving the /etc/hosts entries, which breaks custom domains ONLY
            // in Safari/CFNetwork apps (Chrome and curl use libinfo and keep
            // working). Verify every managed domain through the resolver path
            // Safari uses and auto-restart the daemon via the privileged helper
            // when needed. Logged, silent, off the main actor.
            Task.detached(priority: .utility) {
                _ = await DNSHealthService.checkAndRepair()
            }
        }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindow()
                .environment(viewModel)
                .frame(minWidth: 880, minHeight: 560)
                .task {
                    await viewModel.onAppear() // idempotent belt-and-braces
                    // One-time offer to install the CLI, once the window is up and
                    // the environment is ready (never over the onboarding screen).
                    if viewModel.systemStatus?.isReady == true {
                        viewModel.maybeOfferCLIInstall()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(vm: viewModel) }

        // App Settings window (PLAN.md §2l). Declaring a `Settings` scene gives
        // ⌘, and the "Settings…" app-menu item for free.
        Settings {
            SettingsWindow()
                .environment(viewModel)
        }

        // In-app feature guide, opened from Help → "WP Container Help". Its
        // content is static so it needs no environment; single-instance window.
        Window("WP Container Help", id: "help") {
            HelpView()
        }
        .windowResizability(.contentMinSize)

        // Menu bar extra (PLAN.md §2h): a compact list of all sites + running
        // envs with inline start/stop. Keeps the app alive when the main window
        // is closed; Dock presence stays normal.
        // The `server.rack` SF Symbol renders as a template image, so macOS
        // tints and sizes it like every other status item.
        MenuBarExtra("WP Container", systemImage: "server.rack") {
            MenuBarContent()
                .environment(viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu-bar commands. Kept in the app scene where the shared view model is in
/// scope; each command flips a UI-intent flag or calls a lifecycle action.
private struct AppCommands: Commands {
    let vm: AppViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Replace the default "WP Container Help" item so ⌘? opens our in-app guide.
        CommandGroup(replacing: .help) {
            Button("WP Container Help") { openWindow(id: "help") }
                .keyboardShortcut("?", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Site…") { vm.presentingAddSite = true }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Branch Environment…") { vm.presentingNewEnv = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(vm.selectedSite == nil)
            Divider()
            Button("Import Site…") {
                vm.pendingImportArchive = nil
                vm.presentingImportSite = true
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandMenu("Site") {
            Button("Start") { if let s = vm.selectedSite { vm.startSite(s) } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!(vm.selectedSite.map { $0.status == .stopped } ?? false))
            Button("Stop") { if let s = vm.selectedSite { vm.stopSite(s) } }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!(vm.selectedSite?.status.isRunning ?? false))
            Divider()
            Button("Open in Browser") { if let s = vm.selectedSite { SystemActions.openInBrowser(s.localURL) } }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!(vm.selectedSite?.status.isRunning ?? false))
            Button("Open WP Admin") { if let s = vm.selectedSite { SystemActions.openInBrowser(s.adminURL) } }
                .disabled(!(vm.selectedSite?.status.isRunning ?? false))
            Button("Reveal in Finder") { if let s = vm.selectedSite { SystemActions.revealInFinder(s.path) } }
        }
    }
}
