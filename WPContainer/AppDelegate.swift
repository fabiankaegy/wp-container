import AppKit
import WPContainerKit

/// Bridges the one `NSApplication` lifecycle hook SwiftUI's `App` doesn't expose:
/// `applicationShouldTerminate`. On a full quit we stop every site (and worktree
/// env) this app started, so nothing is left running in the background once the
/// app is gone. Installed via `@NSApplicationDelegateAdaptor` in `WPContainerApp`.
///
/// The wind-down is BOUNDED: quitting must always end the process. An unbounded
/// wait on `container stop` (a wedged apiserver, dozens of containers) used to
/// leave the app stuck mid-quit forever — which also blocked restarts/logouts,
/// since macOS waits on the same reply.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The shared view model, wired by `WPContainerApp` right after it's built.
    weak var viewModel: AppViewModel?

    /// How long a regular quit waits for the stops before exiting anyway. The
    /// `container stop` calls are separate processes, so any still in flight
    /// keep running (and finish the job) after we exit.
    private static let quitBudget: Duration = .seconds(15)
    /// Restart/shutdown/logout gets far less: macOS aborts the power-off if an
    /// app takes too long to answer, and the VMs go down with the host anyway.
    private static let powerOffBudget: Duration = .seconds(3)

    /// Guards against re-entry: if the user hits ⌘Q again while we're already
    /// winding sites down, let the second request terminate immediately.
    private var isStopping = false
    /// Set when the session is ending (restart/shutdown/logout), which arrives
    /// just before the quit request it causes.
    private var isPoweringOff = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPoweringOff = true }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Nothing to wind down (or already doing it) → terminate right away.
        guard let vm = viewModel, !isStopping, vm.hasRunningInstances else {
            return .terminateNow
        }
        isStopping = true
        let budget = isPoweringOff ? Self.powerOffBudget : Self.quitBudget
        // Defer termination until the stops finish OR the budget runs out,
        // whichever comes first.
        Task { @MainActor in
            await vm.stopAllForQuit()
            self.replyToTerminate()
        }
        Task { @MainActor in
            try? await Task.sleep(for: budget)
            self.replyToTerminate()
        }
        return .terminateLater
    }

    /// Answers the pending `.terminateLater` exactly once, whichever of the
    /// stops or the deadline gets here first.
    private var didReply = false
    private func replyToTerminate() {
        guard !didReply else { return }
        didReply = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
