import SwiftUI
import WPContainerKit

/// Settings-tab "Development" card (PLAN.md §2c + §2c-bis): Xdebug + Elasticsearch
/// toggles (restart-to-apply), and live WordPress debug constants read/written
/// straight to wp-config.php (per-request, no restart).
struct DevelopmentCard: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site

    @State private var debug: [String: Bool] = [:]
    @State private var devMode = ""
    @State private var environment = ""
    @State private var esEndpoint: String?

    private let debugLabels: [(String, String)] = [
        ("WP_DEBUG", "WP_DEBUG"),
        ("WP_DEBUG_LOG", "WP_DEBUG_LOG"),
        ("WP_DEBUG_DISPLAY", "WP_DEBUG_DISPLAY"),
        ("SCRIPT_DEBUG", "SCRIPT_DEBUG"),
        ("SAVEQUERIES", "SAVEQUERIES"),
    ]

    var body: some View {
        SectionCard(title: "Development", systemImage: "hammer") {
            VStack(alignment: .leading, spacing: 14) {
                xdebugRow
                Divider().opacity(0.5)
                elasticsearchRow
                Divider().opacity(0.5)
                debugSection
            }
        }
        .onAppear(perform: reload)
        .task(id: site.status) {
            esEndpoint = await vm.elasticsearchEndpoint(site)
        }
    }

    private func reload() {
        let c = vm.devConstants(site)
        debug = c.debug
        devMode = c.mode
        environment = c.environment
    }

    // MARK: Xdebug

    private var xdebugRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Xdebug").font(.callout.weight(.medium))
                Text("Step debugging on port 9003. Map `\(site.wordpressFolder.path)` ↔ `/var/www/html` in your IDE.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if site.status.isRunning {
                    Text("Toggling restarts the site.").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { site.xdebugEnabled },
                                     set: { vm.setXdebug(site, enabled: $0) }))
                .labelsHidden().toggleStyle(.switch)
        }
    }

    // MARK: Elasticsearch

    private var elasticsearchRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Elasticsearch").font(.callout.weight(.medium))
                if site.elasticsearchEnabled, let esEndpoint {
                    Text("Endpoint \(esEndpoint) — ElasticPress-ready.")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    Text("Single-node Elasticsearch sidecar; WordPress connects automatically (ElasticPress).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { site.elasticsearchEnabled },
                                     set: { vm.setElasticsearch(site, enabled: $0) }))
                .labelsHidden().toggleStyle(.switch)
        }
    }

    // MARK: Debug constants

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Debugging").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(debugLabels, id: \.0) { name, label in
                Toggle(isOn: Binding(
                    get: { debug[name] ?? false },
                    set: { newValue in debug[name] = newValue; vm.setDebugConstant(site, name: name, enabled: newValue) }
                )) {
                    Text(label).font(.caption).monospaced()
                }
                .toggleStyle(.switch).controlSize(.mini)
            }

            if debug["WP_DEBUG_LOG"] == true {
                Button {
                    let log = site.wordpressFolder.appendingPathComponent("wp-content/debug.log")
                    SystemActions.revealInFinder(log)
                } label: {
                    Label("Open debug.log", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.link).controlSize(.small)
            }

            HStack(spacing: 10) {
                Picker("WP_DEVELOPMENT_MODE", selection: Binding(
                    get: { devMode },
                    set: { newValue in devMode = newValue; vm.setDevelopmentMode(site, mode: newValue) }
                )) {
                    Text("off").tag("")
                    Text("all").tag("all")
                    Text("core").tag("core")
                    Text("plugin").tag("plugin")
                    Text("theme").tag("theme")
                }
                .pickerStyle(.menu).controlSize(.small)
            }
            Text("Environment: \(environment.isEmpty ? "local" : environment)")
                .font(.caption2).foregroundStyle(.tertiary)
            Text("Constants take effect immediately — no restart.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
