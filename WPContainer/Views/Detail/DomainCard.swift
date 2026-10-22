import SwiftUI
import WPContainerKit

/// Settings-tab "Domain" card (PLAN.md §2i): set/clear a custom domain, routed
/// via a managed /etc/hosts block and the host proxy.
struct DomainCard: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site

    @State private var field = ""
    @State private var registered = true

    private var showNotRegistered: Bool {
        (site.customDomain?.isEmpty == false) && !registered
    }

    var body: some View {
        SectionCard(title: "Domain", systemImage: "globe") {
            VStack(alignment: .leading, spacing: 12) {
                current
                if showNotRegistered { notRegisteredRow }
                editor
                if site.networkType.isSubdomain {
                    Label("Subdomain networks need a hosts entry for each subsite. Use subdirectories with a custom domain.",
                          systemImage: "info.circle")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(HostsHelperClient.isEnabled
                     ? "Setting a domain edits /etc/hosts, which you confirm with Touch ID."
                     : "Setting a domain edits /etc/hosts, which needs your admin password. Turn on the Touch ID helper in Settings to skip it.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            field = site.customDomain ?? ""
            registered = vm.isDomainRegistered(site)
        }
        .task(id: site.customDomain) { registered = vm.isDomainRegistered(site) }
    }

    /// Shown when a domain is configured but has no /etc/hosts entry (e.g. the
    /// admin prompt was skipped during creation) — offers a one-click re-trigger.
    private var notRegisteredRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Label("Not in /etc/hosts", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium)).foregroundStyle(.orange)
                Spacer(minLength: 8)
                Button("Add to Hosts") {
                    Task {
                        _ = await vm.registerCustomDomain(site)
                        registered = vm.isDomainRegistered(site)
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            }
            Text("\(site.customDomain ?? "") won’t load until it’s added.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var current: some View {
        HStack {
            Text("Current").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(site.url.absoluteString).font(.callout.monospaced()).textSelection(.enabled)
        }
    }

    private var editor: some View {
        HStack(spacing: 8) {
            TextField("mysite.test", text: $field)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            Button("Set") {
                vm.setDomain(site, domain: field)
            }
            .buttonStyle(.borderedProminent).controlSize(.regular)
            .disabled(field.trimmingCharacters(in: .whitespaces).isEmpty || field == site.customDomain)
            if site.customDomain != nil {
                Button("Clear") { vm.clearDomain(site); field = "" }
                    .buttonStyle(.bordered).controlSize(.regular)
            }
        }
    }
}
