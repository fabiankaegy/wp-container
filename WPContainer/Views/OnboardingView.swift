import SwiftUI
import WPContainerKit

/// Shown when the `container` tooling isn't ready: either the binary is missing
/// (offer the install guide) or the system service is stopped (offer to start
/// it). Re-checks automatically after starting.
struct OnboardingView: View {
    @Environment(AppViewModel.self) private var vm
    let status: SystemCheckResult

    @State private var starting = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: status.binaryInstalled ? "bolt.horizontal.circle" : "shippingbox")
                .font(.system(size: 52))
                .foregroundStyle(Theme.accent.gradient)

            Text(status.binaryInstalled ? "Start the container system" : "Apple container not found")
                .font(.title2.bold())

            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)

            if !status.rawStatus.isEmpty {
                Text(status.rawStatus)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
                    .padding(10)
                    .frame(maxWidth: 420)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }

            action
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var explanation: String {
        if status.binaryInstalled {
            return "The Apple container CLI is installed, but its service isn’t running. Start it to create and run sites."
        }
        return "WP Container runs each WordPress site in an Apple container. Install the `container` CLI from Apple, then reopen this app."
    }

    @ViewBuilder
    private var action: some View {
        if status.binaryInstalled {
            Button {
                start()
            } label: {
                HStack(spacing: 8) {
                    if starting { ProgressView().controlSize(.small) }
                    Text(starting ? "Starting…" : "Start Container System")
                }
                .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(starting)

            Button("Check Again") { Task { await vm.refreshSystemStatus() } }
                .buttonStyle(.link)
                .disabled(starting)
        } else {
            Link(destination: URL(string: "https://github.com/apple/container")!) {
                Label("Open Install Guide", systemImage: "arrow.up.right.square")
                    .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("Check Again") { Task { await vm.refreshSystemStatus() } }
                .buttonStyle(.link)
        }
    }

    private func start() {
        starting = true
        Task {
            await vm.startSystemService()
            starting = false
        }
    }
}
