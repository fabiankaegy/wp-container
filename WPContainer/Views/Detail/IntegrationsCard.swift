import SwiftUI
import UniformTypeIdentifiers
import WPContainerKit

/// Settings-tab card for per-site integrations (§2d/§2f/§2i/§2e): trusted HTTPS
/// with CA-trust status, effective-URL display, the AI agent-tools toggle with a
/// selectable placement root, and the global `wp` router switch.
struct IntegrationsCard: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site

    @State private var choosingRoot = false

    /// Derived fresh on every render (never cached in `@State`) — the parent
    /// `SiteDetailView` is mounted with `.id(site.id)` (MainWindow.swift), so a
    /// view identity persists for as long as the same site stays selected. An
    /// `@State` seeded only once via `.onAppear` would freeze at whatever was
    /// true at first mount and never re-sync — e.g. after a fresh app launch
    /// races the store's async disk load, after an external CLI mutation
    /// reloads the store while this card stays mounted, or after the
    /// reconcile loop runs. Computing this the same way `httpsRow` derives
    /// `site.httpsEnabled` avoids that whole class of staleness.
    private var agentToolsOn: Bool { vm.agentToolsEnabled(site) }

    var body: some View {
        SectionCard(title: "Integrations", systemImage: "puzzlepiece.extension") {
            VStack(alignment: .leading, spacing: 14) {
                httpsRow
                caTrustRow
                Divider().opacity(0.5)
                agentToolsRow
                Divider().opacity(0.5)
                globalWPRow
            }
        }
        .fileImporter(isPresented: $choosingRoot, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                vm.enableAgentTools(site, root: url)
            }
        }
    }

    // MARK: HTTPS

    private var httpsRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Trusted HTTPS").font(.callout.weight(.medium))
                Text(site.httpsEnabled ? "Serving \(site.url.absoluteString)"
                                       : "Serve this site over https://\(site.primaryHost)")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { site.httpsEnabled },
                                     set: { vm.setHTTPS(site, enabled: $0) }))
                .labelsHidden().toggleStyle(.switch)
        }
    }

    private var caTrustRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Label(vm.caTrusted ? "Certificate authority trusted" : "Certificate authority not trusted",
                      systemImage: vm.caTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(vm.caTrusted ? .green : .orange)
                Text(vm.caTrusted
                     ? "Browsers trust local HTTPS for every site."
                     : "Trust the WP Container CA (no admin password — Touch ID supported).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if vm.caTrusted {
                Button("Recheck") { Task { await vm.refreshCATrusted() } }
                    .buttonStyle(.bordered).controlSize(.small)
            } else {
                Button("Trust CA…") { vm.trustCA() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
    }

    // MARK: Agent tools

    private var agentToolsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Agent Tools").font(.callout.weight(.medium))
                    Text(agentToolsOn && site.agentToolsRoot != nil
                         ? "Written to \(site.agentToolsRoot!)"
                         : "Write MCP configs + AGENTS.md and the wp shim for coding agents.")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { agentToolsOn },
                    set: { newValue in
                        if newValue { vm.enableAgentTools(site) } else { vm.disableAgentTools(site) }
                    }))
                    .labelsHidden().toggleStyle(.switch)
            }
            if agentToolsOn {
                Button("Change location…") { choosingRoot = true }
                    .buttonStyle(.link).controlSize(.small)
                    .help("Place the files at your wp-content repo root so IDEs opened there discover the MCP server.")
            }
        }
    }

    // MARK: Global wp

    private var globalWPRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Global `wp` command").font(.callout.weight(.medium))
                Text("Type plain `wp` anywhere inside a site's files to run containerized wp-cli (defers to Homebrew wp elsewhere). Edits ~/.zshrc PATH.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { vm.globalWPInstalled },
                                     set: { vm.setGlobalWP(enabled: $0) }))
                .labelsHidden().toggleStyle(.switch)
        }
    }
}
