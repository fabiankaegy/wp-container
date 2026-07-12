import SwiftUI
import WPContainerKit

@main
struct WPContainerApp: App {
    @State private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .task { await viewModel.onAppear() }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Dummy Site") { viewModel.addDummySite() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }
}
