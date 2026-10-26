import AppKit
import SwiftUI
import WPContainerKit

/// Warning row for a site whose hostnames (custom domain or subsite hosts) have
/// no /etc/hosts entry — e.g. the admin prompt was skipped during creation, a
/// subsite was added in Network Admin, or another tool removed the entry — with
/// a one-click sync. Pair it with `.trackingMissingHosts(of:into:)` on the
/// containing view, which keeps `missing` current.
struct MissingHostsRow: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site
    @Binding var missing: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Not registered in /etc/hosts").font(.callout.weight(.medium))
                Text("\(missing.joined(separator: ", ")) won't resolve until \(missing.count == 1 ? "it's" : "they're") added to /etc/hosts.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Sync") {
                Task {
                    await vm.registerMissingHosts(site)
                    missing = vm.missingHostsDomains(site)
                }
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
        }
    }
}

/// Re-reads which of a site's hostnames are missing from /etc/hosts when its
/// hostnames or status change and whenever the app becomes active, so an entry
/// removed outside the app is flagged on return.
private struct MissingHostsTracker: ViewModifier {
    @Environment(AppViewModel.self) private var vm
    let site: Site
    @Binding var missing: [String]

    func body(content: Content) -> some View {
        content
            .task(id: site.hostsFileDomains) { refresh() }
            .onChange(of: site.status) { refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refresh()
            }
    }

    private func refresh() {
        missing = vm.missingHostsDomains(site)
    }
}

extension View {
    func trackingMissingHosts(of site: Site, into missing: Binding<[String]>) -> some View {
        modifier(MissingHostsTracker(site: site, missing: missing))
    }
}
