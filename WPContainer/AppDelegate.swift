import AppKit
import WPContainerKit

/// Bridges the one `NSApplication` lifecycle hook SwiftUI's `App` doesn't expose:
/// `applicationShouldTerminate`. On a full quit we stop every site (and worktree
/// env) this app started, so nothing is left running in the background once the
/// app is gone. Installed via `@NSApplicationDelegateAdaptor` in `WPContainerApp`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The shared view model, wired by `WPContainerApp` right after it's built.
    weak var viewModel: AppViewModel?

    /// Guards against re-entry: if the user hits ⌘Q again while we're already
    /// winding sites down, let the second request terminate immediately.
    private var isStopping = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Nothing to wind down (or already doing it) → terminate right away.
        guard let vm = viewModel, !isStopping, vm.hasRunningInstances else {
            return .terminateNow
        }
        isStopping = true
        // Defer termination until the stops finish. Stopping shells out to the
        // `container` CLI, so it's async — reply once it's done.
        Task { @MainActor in
            await vm.stopAllForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
