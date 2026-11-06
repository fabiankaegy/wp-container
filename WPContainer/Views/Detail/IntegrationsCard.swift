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
        // Honest status (§2f fix): "Serving …" only when the proxy is actually
        // listening; otherwise say so instead of implying the https URL works.
        SettingRow(title: "Trusted HTTPS",
                   detail: Text(httpsSubtitle)
                       .foregroundStyle(proxyDown ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))) {
            if proxyDown {
                Button("Start Proxy") { Task { await vm.ensureProxyRunning() } }
                    .controlSize(.small)
            }
            Toggle("", isOn: Binding(get: { site.httpsEnabled },
                                     set: { vm.setHTTPS(site, enabled: $0) }))
                .labelsHidden().toggleStyle(.switch)
        }
        .textSelection(.enabled)
        .task(id: site.id) { vm.refreshProxyLiveness() }
    }

    private var proxyDown: Bool { site.httpsEnabled && vm.proxyPort == nil }

    private var httpsSubtitle: String {
        guard site.httpsEnabled else { return "Serve this site over https://\(site.primaryHost)" }
        return vm.proxyPort != nil
            ? "Serving \(site.url.absoluteString)"
            : "\(site.url.absoluteString) won’t load until the proxy is running."
    }

    private var caTrustRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Label(vm.caTrusted ? "Certificate authority trusted" : "Certificate authority not trusted",
                      systemImage: vm.caTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(vm.caTrusted ? .green : .orange)
                Spacer(minLength: 8)
                if vm.caTrusted {
                    Button("Check Again") { Task { await vm.refreshCATrusted() } }
                        .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button("Trust CA…") { vm.trustCA() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            Text(vm.caTrusted
                 ? "Browsers trust local HTTPS for every site."
                 : "Trust it so browsers accept local HTTPS. No admin password needed.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Agent tools

    private var agentToolsRow: some View {
        SettingRow(title: "AI Agent Tools",
                   detail: agentToolsOn && site.agentToolsRoot != nil
                       ? Text("Written to \(site.agentToolsRoot!)")
                       : Text("Writes MCP configs, AGENTS.md and a `wp` shim for coding agents.")) {
            Toggle("", isOn: Binding(
                get: { agentToolsOn },
                set: { newValue in
                    if newValue { vm.enableAgentTools(site) } else { vm.disableAgentTools(site) }
                }))
                .labelsHidden().toggleStyle(.switch)
        } footer: {
            if agentToolsOn {
                Button("Change Location…") { choosingRoot = true }
                    .buttonStyle(.link).controlSize(.small)
                    .help("Put the files at your repository root so editors opened there find the MCP server.")
            }
        }
    }

    // MARK: Global wp

    private var globalWPRow: some View {
        SettingRow(title: "Global `wp` command",
                   detail: Text("Run plain `wp` inside any site folder to use its wp-cli. Adds a line to ~/.zshrc.")) {
            Toggle("", isOn: Binding(get: { vm.globalWPInstalled },
                                     set: { vm.setGlobalWP(enabled: $0) }))
                .labelsHidden().toggleStyle(.switch)
        }
        .help("Outside a site folder, `wp` falls back to your Homebrew wp-cli.")
    }
}
