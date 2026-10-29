import SwiftUI
import WPContainerKit

/// Settings-tab "Domain" card (PLAN.md §2i): set/clear a custom domain, routed
/// via a managed /etc/hosts block and the host proxy.
struct DomainCard: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site

    @State private var field = ""
    @State private var missing: [String] = []

    var body: some View {
        SectionCard(title: "Domain", systemImage: "globe") {
            VStack(alignment: .leading, spacing: 12) {
                current
                if !missing.isEmpty {
                    MissingHostsRow(site: site, missing: $missing)
                }
                editor
                if site.networkType.isSubdomain {
                    Label("Each subsite on a custom domain needs its own hosts entry. New subsites appear here after the site starts or its Network Sites list refreshes.",
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
        .onAppear { field = site.customDomain ?? "" }
        .trackingMissingHosts(of: site, into: $missing)
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
