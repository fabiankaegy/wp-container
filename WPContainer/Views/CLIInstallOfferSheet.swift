import SwiftUI
import WPContainerKit

/// One-time first-run offer to install the `wp-container` command-line tool.
/// Presented from `MainWindow` when `AppViewModel.maybeOfferCLIInstall()` decides
/// the CLI is embedded but not yet installed. Purely optional — "Not Now"
/// dismisses it for good, and it can always be (re)installed from Settings.
struct CLIInstallOfferSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .idle
    @State private var errorText: String?

    private enum Phase { case idle, working, done, failed }

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(width: 460)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.accent.opacity(0.14))
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: phase == .done ? "checkmark.circle.fill" : "terminal")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(phase == .done ? Color.green : Theme.accent)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(phase == .done ? "Command-line tool installed" : "Install the command-line tool?")
                        .font(.headline)
                    Text(phase == .done ? "You're all set." : "Optional. You can install it later in Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if phase == .done {
                Text("Open a new Terminal and run `wp-container list`, or `wp` inside any site's folder.")
                    .font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Adds `wp-container` and its `wpc` alias to /usr/local/bin, so you can script sites from Terminal and let AI agents drive the app over MCP.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label("Asks for your admin password once. It updates with the app.",
                      systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if phase == .failed, let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            if phase == .done {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if phase == .working {
                    ProgressView().controlSize(.small).padding(.trailing, 6)
                }
                Button("Install…") { install() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(phase == .working)
            }
        }
        .padding(16)
    }

    private func install() {
        phase = .working
        errorText = nil
        Task {
            do {
                try await CLIToolInstaller.install()
                phase = .done
            } catch CLIToolInstaller.InstallError.cancelled {
                // User dismissed the admin dialog — return to the offer, no error.
                phase = .idle
            } catch {
                errorText = "\(error)"
                phase = .failed
            }
        }
    }
}
