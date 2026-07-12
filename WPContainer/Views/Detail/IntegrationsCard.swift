import SwiftUI
import WPContainerKit

/// Settings-tab card for the per-site integrations added in §2d/§2f: a trusted
/// HTTPS toggle (with a one-time "Trust CA" prompt) and an AI agent-tools toggle.
/// Additive only — rows in an existing `SectionCard`, no layout restructuring.
struct IntegrationsCard: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site

    @State private var agentToolsOn = false

    var body: some View {
        SectionCard(title: "Integrations", systemImage: "puzzlepiece.extension") {
            VStack(alignment: .leading, spacing: 14) {
                httpsRow
                if !vm.caTrusted {
                    trustRow
                }
                Divider().opacity(0.5)
                agentToolsRow
            }
        }
        .onAppear { agentToolsOn = vm.agentToolsEnabled(site) }
    }

    // MARK: HTTPS

    private var httpsRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Trusted HTTPS").font(.callout.weight(.medium))
                Text(site.httpsEnabled
                     ? site.secureURL.absoluteString
                     : "Serve this site over https://\(site.httpsHost)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { site.httpsEnabled },
                set: { vm.setHTTPS(site, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }

    private var trustRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Certificate authority not trusted").font(.caption.weight(.medium))
                Text("Install the WP Container CA so browsers trust local HTTPS.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Trust WP Container CA…") { vm.trustCA() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    // MARK: Agent tools

    private var agentToolsRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Agent Tools").font(.callout.weight(.medium))
                Text("Write MCP configs, CLAUDE.md and the wp shim into the site folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { agentToolsOn },
                set: { newValue in
                    agentToolsOn = newValue
                    vm.setAgentTools(site, enabled: newValue)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }
}
