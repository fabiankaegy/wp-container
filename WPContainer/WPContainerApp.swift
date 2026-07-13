import SwiftUI
import WPContainerKit

@main
struct WPContainerApp: App {
    @State private var viewModel: AppViewModel

    init() {
        AppSettings.registerDefaults()
        let vm = AppViewModel()
        _viewModel = State(initialValue: vm)
        // Bootstrap at APP level, not window level: the menu bar extra must have
        // a loaded store + running reconcile loop even if the popover is opened
        // before the main window appears (or after it has been closed).
        Task { @MainActor in
            // Apply the persisted Dock-icon preference (menu-bar-first mode) as
            // early as possible — but NOT from `init`, where the shared
            // application object does not yet exist. This main-actor task runs
            // once the run loop is up, so `NSApplication.shared` is valid.
            AppSettings.applyActivationPolicy()
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
        }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindow()
                .environment(viewModel)
                .frame(minWidth: 880, minHeight: 560)
                .task { await viewModel.onAppear() } // idempotent belt-and-braces
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

        // Menu bar extra (PLAN.md §2h): a compact list of all sites + running
        // envs with inline start/stop. Keeps the app alive when the main window
        // is closed; Dock presence stays normal.
        MenuBarExtra {
            MenuBarContent()
                .environment(viewModel)
        } label: {
            // A MONOCHROME TEMPLATE of the WordPress W-in-circle mark (PLAN.md
            // §2h, updated): the "MenuBarIcon" asset is marked Render As Template
            // (template-rendering-intent), so macOS tints it to match light/dark
            // menu bars and accent colors exactly like every other status item.
            // The asset is pre-sized to 18pt (36pt @2x) — MenuBarExtra ignores
            // SwiftUI frame modifiers on its label and sizes from the image's
            // intrinsic size.
            Image("MenuBarIcon")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu-bar commands. Kept in the app scene where the shared view model is in
/// scope; each command flips a UI-intent flag or calls a lifecycle action.
private struct AppCommands: Commands {
    let vm: AppViewModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Site…") { vm.presentingAddSite = true }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Branch Environment…") { vm.presentingNewEnv = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(vm.selectedSite == nil)
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
