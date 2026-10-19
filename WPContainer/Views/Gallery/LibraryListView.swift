import SwiftUI
import WPContainerKit

/// The library as a sortable table, for when there are too many sites for
/// cards. Each site expands to show its active branch environments as child
/// rows, with live CPU and memory for everything running. Click selects (the
/// inspector follows); double-click opens the site or env screen.
struct LibraryListView: View {
    @Environment(AppViewModel.self) private var vm
    let sites: [Site]

    @State private var sortOrder = [KeyPathComparator(\LibraryRow.name)]

    var body: some View {
        let rows = sites.map(row(for:)).sorted(using: sortOrder)
        Table(rows, children: \.children, selection: selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in nameCell(row) }
                .width(min: 200, ideal: 280)
            TableColumn("Status", value: \.statusRank) { row in statusCell(row) }
                .width(min: 80, ideal: 100)
            TableColumn("Address", value: \.address) { row in
                Text(row.address).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 110, ideal: 170)
            TableColumn("Branches", value: \.branchRank) { row in branchCell(row) }
                .width(min: 90, ideal: 130)
            TableColumn("CPU", value: \.cpu) { row in
                Text(row.cpu > 0 || row.isRunning ? Format.percent(row.cpu) : "—").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 60)
            TableColumn("Memory", value: \.memory) { row in
                Text(row.memory > 0 ? Format.bytes(row.memory) : "—").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 80)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first { contextMenu(id) }
        } primaryAction: { ids in
            if let id = ids.first { vm.openScreen(id) }
        }
    }

    private var selection: Binding<UUID?> {
        Binding(get: { vm.selection }, set: { vm.selection = $0; vm.branchSelection = [] })
    }

    // MARK: Rows

    private func row(for site: Site) -> LibraryRow {
        // Running envs first, then most recently used; settled ones stay in the Branches table.
        let envs = vm.store.envs(forSite: site.id).filter { !$0.isSettled }
            .sorted { ($0.status.isRunning ? 1 : 0, $0.lastUsedAt) > ($1.status.isRunning ? 1 : 0, $1.lastUsedAt) }
        let sample = vm.metrics.latest(site.id)
        return LibraryRow(id: site.id, site: site, env: nil, name: site.name, status: site.status,
                          address: site.displayHost, cpu: sample?.cpuPercent ?? 0, memory: sample?.memoryBytes ?? 0,
                          branchRank: envs.count * 1000 + envs.filter { $0.status.isRunning }.count,
                          children: envs.isEmpty ? nil : envs.map { env in
                              let s = vm.metrics.latest(env.id)
                              return LibraryRow(id: env.id, site: site, env: env, name: env.branch, status: env.status,
                                                address: env.url.host() ?? "localhost:\(env.port)", cpu: s?.cpuPercent ?? 0,
                                                memory: s?.memoryBytes ?? 0, branchRank: 0, children: nil)
                          })
    }

    // MARK: Cells

    @ViewBuilder
    private func nameCell(_ row: LibraryRow) -> some View {
        if let env = row.env {
            HStack(spacing: 7) {
                SectionIcon(systemName: "arrow.triangle.branch", color: .purple, size: 18)
                Text(env.branch).font(.system(.body, design: .monospaced)).lineLimit(1)
                if EnvSettlement.isStale(env) {
                    Text("Stale").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
        } else {
            HStack(spacing: 8) {
                SiteAvatar(name: row.site.name, slug: row.site.slug, size: 22,
                           wordpressFolder: row.site.wordpressFolder, reloadToken: row.site.status)
                Text(row.site.name).fontWeight(.medium).lineLimit(1)
            }
        }
    }

    private func statusCell(_ row: LibraryRow) -> some View {
        HStack(spacing: 6) {
            StatusDot(status: row.status, size: 7)
            Text(row.status.label)
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func branchCell(_ row: LibraryRow) -> some View {
        if let env = row.env {
            Label((env.repoRelPath as NSString).lastPathComponent,
                  systemImage: env.repoRelPath.contains("/themes/") ? "paintbrush" : "puzzlepiece")
                .foregroundStyle(.secondary)
                .help(env.repoRelPath)
        } else if let children = row.children {
            let running = children.filter(\.isRunning).count
            HStack(spacing: 4) {
                if running > 0 { Text("\(running) running ·").foregroundStyle(.green) }
                Text("\(children.count)").foregroundStyle(.secondary)
            }
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func contextMenu(_ id: UUID) -> some View {
        if let env = vm.store.env(id: id) {
            Button("Open", systemImage: "rectangle.portrait.and.arrow.right") { vm.openScreen(env.id) }
            if env.status.isRunning {
                Button("Stop", systemImage: "stop.fill") { vm.stopEnv(env) }
            } else {
                Button("Start", systemImage: "play.fill") { vm.startEnv(env) }.disabled(env.status.isTransitional)
            }
            Button("Open in Browser", systemImage: "safari") { SystemActions.openInBrowser(env.url) }
                .disabled(!env.status.isRunning)
            EnvMoreMenuItems(env: env)
            Divider()
            Button("Settle", systemImage: "archivebox") { vm.settleEnvs([env]) }
        } else if let site = vm.store.site(id: id) {
            Button("Open", systemImage: "rectangle.portrait.and.arrow.right") { vm.openScreen(site.id) }
            Button("Show Branches", systemImage: "arrow.triangle.branch") { vm.openScreen(site.id, tab: .branches) }
            Divider()
            if site.status.isRunning {
                Button("Stop", systemImage: "stop.fill") { vm.stopSite(site) }
            } else {
                Button("Start", systemImage: "play.fill") { vm.startSite(site) }.disabled(site.status.isTransitional)
            }
            Button("Open in Browser", systemImage: "safari") { SystemActions.openInBrowser(site.url) }
                .disabled(!site.status.isRunning)
            SiteMoreMenuItems(site: site)
        }
    }
}

/// One library table row: a site, or one of its branch environments.
struct LibraryRow: Identifiable {
    let id: UUID
    let site: Site
    let env: WorktreeEnv?
    let name: String
    let status: SiteStatus
    let address: String
    let cpu: Double
    let memory: UInt64
    /// Sorts sites by how many branch environments they have.
    let branchRank: Int
    var children: [LibraryRow]?

    var isRunning: Bool { status.isRunning }
    /// Running first, then transitional, then stopped.
    var statusRank: Int { status.isRunning ? 0 : status.isTransitional ? 1 : 2 }
}
