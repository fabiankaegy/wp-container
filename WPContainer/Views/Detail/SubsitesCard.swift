import SwiftUI
import WPContainerKit

/// Overview card listing a multisite network's subsites (PLAN.md §2j), fetched
/// via `wp site list` when the site is running, each with an Open button.
struct SubsitesCard: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site

    @State private var subsites: [(blogID: String, url: String)] = []

    var body: some View {
        SectionCard(title: "Network Sites", systemImage: "square.grid.2x2") {
            if !site.status.isRunning {
                Text("Start the site to list its network subsites.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if subsites.isEmpty {
                Text("No subsites yet — add one from Network Admin.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(subsites.enumerated()), id: \.offset) { index, sub in
                        if index > 0 { Divider() }
                        HStack {
                            Text("#\(sub.blogID)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(sub.url).font(.callout).textSelection(.enabled)
                            Spacer()
                            Button("Open") {
                                if let url = URL(string: sub.url) { SystemActions.openInBrowser(url) }
                            }
                            .buttonStyle(.link).controlSize(.small)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .task(id: site.status) { subsites = await vm.subsites(site) }
    }
}
