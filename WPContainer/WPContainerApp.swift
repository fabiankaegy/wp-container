import SwiftUI
import WPContainerKit

@main
struct WPContainerApp: App {
    @State private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindow()
                .environment(viewModel)
                .frame(minWidth: 880, minHeight: 560)
                .task { await viewModel.onAppear() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(vm: viewModel) }

        // Menu bar extra (PLAN.md §2h): a compact list of all sites + running
        // envs with inline start/stop. Keeps the app alive when the main window
        // is closed; Dock presence stays normal.
        MenuBarExtra {
            MenuBarContent()
                .environment(viewModel)
        } label: {
            Image(systemName: "cube.transparent.fill")
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
