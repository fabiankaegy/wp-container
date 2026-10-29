import SwiftUI
import WPContainerKit

/// Settings-tab "Development" card (PLAN.md §2c + §2c-bis): Xdebug, Elasticsearch,
/// Mailpit and Redis toggles (restart-to-apply), and live WordPress debug
/// constants read/written straight to wp-config.php (per-request, no restart).
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
                mailpitRow
                Divider().opacity(0.5)
                redisRow
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
        SettingRow(title: "Xdebug",
                   detail: Text("Step debugging on port 9003. In your IDE, map `\(site.wordpressFolder.path)` to `/var/www/html`.")) {
            Toggle("", isOn: Binding(get: { site.xdebugEnabled },
                                     set: { vm.setXdebug(site, enabled: $0) }))
                .labelsHidden().toggleStyle(.switch)
        } footer: {
            if site.status.isRunning { RestartNote() }
        }
    }

    // MARK: Elasticsearch

    private var elasticsearchRow: some View {
        SettingRow(title: "Elasticsearch",
                   detail: site.elasticsearchEnabled && esEndpoint != nil
                       ? Text("Endpoint \(esEndpoint ?? ""), ready for ElasticPress.")
                       : Text("A search server WordPress connects to automatically, for ElasticPress.")) {
            Toggle("", isOn: Binding(get: { site.elasticsearchEnabled },
                                     set: { vm.setElasticsearch(site, enabled: $0) }))
                .labelsHidden().toggleStyle(.switch)
        } footer: {
            if site.status.isRunning { RestartNote() }
        }
        .textSelection(.enabled)
    }

    // MARK: Mailpit

    private var mailpitRow: some View {
        SettingRow(title: "Mailpit",
                   detail: Text("Catches all email the site sends. Nothing leaves your Mac.")) {
            Toggle("", isOn: Binding(get: { site.mailpitEnabled },
                                     set: { vm.setMailpit(site, enabled: $0) }))
                .labelsHidden().toggleStyle(.switch)
        } footer: {
            if site.mailpitEnabled, let mailbox = site.mailboxURL {
                Button {
                    SystemActions.openInBrowser(mailbox)
                } label: {
                    Label("Open Mailbox", systemImage: "envelope")
                }
                .buttonStyle(.link).controlSize(.small)
                .disabled(!site.status.isRunning)
            }
            if site.status.isRunning { RestartNote() }
        }
    }

    // MARK: Redis

    private var redisRow: some View {
        SettingRow(title: "Redis",
                   detail: Text("Object cache server, emptied on every restart. Install a drop-in such as Redis Object Cache to use it.")) {
            Toggle("", isOn: Binding(get: { site.redisEnabled },
                                     set: { vm.setRedis(site, enabled: $0) }))
                .labelsHidden().toggleStyle(.switch)
        } footer: {
            if site.status.isRunning { RestartNote() }
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
            Text("Changes apply right away, without a restart.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
