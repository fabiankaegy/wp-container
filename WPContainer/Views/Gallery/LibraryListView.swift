import SwiftUI
import WPContainerKit

/// The library as a sortable table, for when there are too many sites for
/// cards. Sites sit under their group headers (as in the gallery) and expand
/// to their active branch environments, with live CPU and memory for
/// everything running. Right-click the header to choose columns, like Music
/// or Finder; the layout is remembered. Click selects (the inspector follows);
/// double-click opens the site or env screen.
struct LibraryListView: View {
    @Environment(AppViewModel.self) private var vm
    /// Sites per section; a section with a title becomes a group header row.
    let sections: [GallerySection]

    @State private var sortOrder = [KeyPathComparator(\LibraryRow.name)]
    @State private var columns: TableColumnCustomization<LibraryRow> = ColumnLayout.load(
        Self.columnsKey, hidden: ["network", "wordpress", "php", "addons", "https", "group", "port", "lastUsed", "created", "folder"])
    /// Groups are open by default; sites with branch environments are closed.
    @State private var collapsedGroups: Set<UUID> = []
    @State private var expandedSites: Set<UUID> = []

    private static let columnsKey = "libraryListColumns"

    var body: some View {
        let groups = groupRows()
        Table(of: LibraryRow.self, selection: selection(ignoring: Set(groups.map(\.id))),
              sortOrder: $sortOrder, columnCustomization: $columns) {
            Group {
                TableColumn("Name", value: \.name) { nameCell($0) }
                    .width(min: 200, ideal: 280)
                    .customizationID("name")
                    .disabledCustomizationBehavior(.visibility)
                TableColumn("Status", value: \.statusRank) { statusCell($0) }
                    .width(min: 80, ideal: 100)
                    .customizationID("status")
                TableColumn("Address", value: \.address) { secondary($0, $0.address) }
                    .width(min: 110, ideal: 170)
                    .customizationID("address")
                TableColumn("Branches", value: \.branchRank) { branchCell($0) }
                    .width(min: 90, ideal: 130)
                    .customizationID("branches")
                TableColumn("CPU", value: \.cpu) { row in
                    secondary(row, row.isRunning ? Format.percent(row.cpu) : "—").monospacedDigit()
                }
                .width(min: 50, ideal: 60)
                .customizationID("cpu")
                TableColumn("Memory", value: \.memory) { row in
                    secondary(row, row.memory > 0 ? Format.bytes(row.memory) : "—").monospacedDigit()
                }
                .width(min: 70, ideal: 80)
                .customizationID("memory")
            }
            Group {
                TableColumn("Network", value: \.network) { row in
                    secondary(row, row.isRunning ? Format.rate(row.network) : "—").monospacedDigit()
                }
                .width(min: 70, ideal: 90)
                .customizationID("network")
                .defaultVisibility(.hidden)
                TableColumn("WordPress", value: \.wordpress) { secondary($0, $0.wordpress) }
                    .width(min: 70, ideal: 110)
                    .customizationID("wordpress")
                    .defaultVisibility(.hidden)
                TableColumn("PHP", value: \.php) { secondary($0, $0.php) }
                    .width(min: 40, ideal: 50)
                    .customizationID("php")
                    .defaultVisibility(.hidden)
                TableColumn("Add-ons", value: \.addons) { secondary($0, $0.addons) }
                    .width(min: 80, ideal: 150)
                    .customizationID("addons")
                    .defaultVisibility(.hidden)
                TableColumn("HTTPS", value: \.https) { secondary($0, $0.https) }
                    .width(min: 44, ideal: 50)
                    .customizationID("https")
                    .defaultVisibility(.hidden)
            }
            Group {
                TableColumn("Group", value: \.groupName) { secondary($0, $0.groupName) }
                    .width(min: 70, ideal: 110)
                    .customizationID("group")
                    .defaultVisibility(.hidden)
                TableColumn("Port", value: \.port) { row in
                    secondary(row, row.port > 0 ? String(row.port) : "—").monospacedDigit()
                }
                .width(min: 44, ideal: 56)
                .customizationID("port")
                .defaultVisibility(.hidden)
                TableColumn("Last Used", value: \.lastUsed) { row in
                    secondary(row, row.isRunning ? "Now" : row.lastUsed.formatted(.relative(presentation: .named)))
                }
                .width(min: 80, ideal: 110)
                .customizationID("lastUsed")
                .defaultVisibility(.hidden)
                TableColumn("Created", value: \.created) { row in
                    secondary(row, row.created.formatted(date: .abbreviated, time: .omitted))
                }
                .width(min: 80, ideal: 100)
                .customizationID("created")
                .defaultVisibility(.hidden)
                TableColumn("Folder", value: \.folder) { secondary($0, $0.folder).truncationMode(.middle) }
                    .width(min: 120, ideal: 220)
                    .customizationID("folder")
                    .defaultVisibility(.hidden)
            }
        } rows: {
            ForEach(groups) { group in
                if let sites = group.children {
                    DisclosureTableRow(group, isExpanded: groupBinding(group.id)) {
                        ForEach(sites) { site in
                            if let envs = site.children {
                                DisclosureTableRow(site, isExpanded: siteBinding(site.id)) {
                                    ForEach(envs) { TableRow($0) }
                                }
                            } else {
                                TableRow(site)
                            }
                        }
                    }
                } else {
                    TableRow(group)
                }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first { contextMenu(id) }
        } primaryAction: { ids in
            if let id = ids.first, vm.store.site(id: id) != nil || vm.store.env(id: id) != nil { vm.openScreen(id) }
        }
        .onChange(of: columns) { _, layout in ColumnLayout.save(layout, Self.columnsKey) }
    }

    /// Row selection drives the inspector; group header rows aren't selectable.
    private func selection(ignoring groups: Set<UUID>) -> Binding<UUID?> {
        Binding(get: { vm.selection }, set: { id in
            if let id, groups.contains(id) { return }
            vm.selection = id
            vm.branchSelection = []
        })
    }

    private func groupBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { !collapsedGroups.contains(id) }, set: { open in
            if open { collapsedGroups.remove(id) } else { collapsedGroups.insert(id) }
        })
    }

    private func siteBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { expandedSites.contains(id) }, set: { open in
            if open { expandedSites.insert(id) } else { expandedSites.remove(id) }
        })
    }

    // MARK: Rows

    /// Top-level rows: a header per titled section holding its sites, or the
    /// sites themselves when the list isn't grouped (search, Running, a group).
    private func groupRows() -> [LibraryRow] {
        sections.flatMap { section -> [LibraryRow] in
            let sites = section.sites.map(siteRow).sorted(using: sortOrder)
            guard let title = section.title else { return sites }
            guard !sites.isEmpty else { return [] }
            return [LibraryRow.group(id: section.id, title: title, sites: sites)]
        }
    }

    private func siteRow(_ site: Site) -> LibraryRow {
        // Running envs first, then most recently used; settled ones stay in the Branches table.
        let envs = vm.store.envs(forSite: site.id).filter { !$0.isSettled }
            .sorted { ($0.status.isRunning ? 1 : 0, $0.lastUsedAt) > ($1.status.isRunning ? 1 : 0, $1.lastUsedAt) }
        let group = site.groupID.flatMap { vm.store.group(id: $0)?.name } ?? "Ungrouped"
        var row = LibraryRow(site: site, sample: vm.metrics.latest(site.id), groupName: group)
        row.branchRank = envs.count * 1000 + envs.filter { $0.status.isRunning }.count
        row.children = envs.isEmpty ? nil : envs.map { LibraryRow(env: $0, site: site, sample: vm.metrics.latest($0.id), groupName: group) }
        return row
    }

    // MARK: Cells

    @ViewBuilder
    private func nameCell(_ row: LibraryRow) -> some View {
        switch row.kind {
        case .group:
            HStack(spacing: 7) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text(row.name).fontWeight(.semibold)
                Text("\(row.children?.count ?? 0)").foregroundStyle(.tertiary)
            }
        case .site(let site):
            HStack(spacing: 8) {
                SiteAvatar(name: site.name, slug: site.slug, size: 22,
                           wordpressFolder: site.wordpressFolder, reloadToken: site.status)
                Text(site.name).fontWeight(.medium).lineLimit(1)
            }
        case .env(_, let env):
            HStack(spacing: 7) {
                SectionIcon(systemName: "arrow.triangle.branch", color: .purple, size: 18)
                Text(env.branch).font(.system(.body, design: .monospaced)).lineLimit(1)
                if EnvSettlement.isStale(env) { StaleBadge(text: "Stale") }
            }
        }
    }

    @ViewBuilder
    private func statusCell(_ row: LibraryRow) -> some View {
        if case .group = row.kind {
            let running = row.children?.filter(\.isRunning).count ?? 0
            if running > 0 { Text("\(running) running").statusTint(.green) }
        } else {
            HStack(spacing: 6) {
                StatusDot(status: row.status, size: 7)
                Text(row.status.label)
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func branchCell(_ row: LibraryRow) -> some View {
        switch row.kind {
        case .group:
            EmptyView()
        case .env(_, let env):
            Label((env.repoRelPath as NSString).lastPathComponent,
                  systemImage: env.repoRelPath.contains("/themes/") ? "paintbrush" : "puzzlepiece")
                .foregroundStyle(.secondary)
                .help(env.repoRelPath)
        case .site:
            if let children = row.children {
                let running = children.filter(\.isRunning).count
                HStack(spacing: 4) {
                    if running > 0 { Text("\(running) running ·").statusTint(.green) }
                    Text("\(children.count)").foregroundStyle(.secondary)
                }
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }

    /// Secondary text for a site or env row; group header rows stay blank.
    @ViewBuilder
    private func secondary(_ row: LibraryRow, _ text: String) -> some View {
        if case .group = row.kind { EmptyView() } else { Text(text).foregroundStyle(.secondary).lineLimit(1) }
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
            Button("Export Site…", systemImage: "square.and.arrow.up") {
                vm.exportSiteTarget = site
                vm.presentingExportSite = true
            }
            Divider()
            if site.isArchived {
                Button("Unarchive", systemImage: "arrow.uturn.backward") { vm.unarchiveSite(site) }
            } else {
                Button("Archive", systemImage: "archivebox") { vm.archiveSite(site) }
            }
        }
    }
}

/// One library table row: a group header, a site, or one of its branch
/// environments. Every column's sort key is a plain stored value.
struct LibraryRow: Identifiable {
    enum Kind {
        case group
        case site(Site)
        case env(Site, WorktreeEnv)
    }

    let id: UUID
    let kind: Kind
    var name = ""
    var status: SiteStatus = .stopped
    var address = ""
    var cpu = 0.0
    var memory: UInt64 = 0
    var network = 0.0
    /// Sorts sites by how many branch environments they have (then running).
    var branchRank = 0
    var wordpress = ""
    var php = ""
    var addons = ""
    var https = ""
    var groupName = ""
    var port = 0
    var lastUsed = Date.distantPast
    var created = Date.distantPast
    var folder = ""
    var children: [LibraryRow]?

    var isRunning: Bool { status.isRunning }
    /// Running first, then transitional, then stopped.
    var statusRank: Int { status.isRunning ? 0 : status.isTransitional ? 1 : 2 }

    static func group(id: UUID, title: String, sites: [LibraryRow]) -> LibraryRow {
        var row = LibraryRow(id: id, kind: .group)
        row.name = title
        row.children = sites
        return row
    }

    init(id: UUID, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    init(site: Site, sample: InstanceMetricsSample?, groupName: String) {
        self.init(id: site.id, kind: .site(site))
        name = site.name
        status = site.status
        address = site.displayHost
        fill(sample: sample, imageTag: site.imageTag, php: site.phpVersion)
        addons = Self.addons(mailpit: site.mailpitEnabled, es: site.elasticsearchEnabled, redis: site.redisEnabled, xdebug: site.xdebugEnabled)
        https = site.httpsEnabled ? "On" : "—"
        self.groupName = groupName
        port = site.port
        lastUsed = site.lastActivityAt ?? site.createdAt
        created = site.createdAt
        folder = (site.path.path as NSString).abbreviatingWithTildeInPath
    }

    init(env: WorktreeEnv, site: Site, sample: InstanceMetricsSample?, groupName: String) {
        self.init(id: env.id, kind: .env(site, env))
        name = env.branch
        status = env.status
        address = env.url.host() ?? "localhost:\(env.port)"
        fill(sample: sample, imageTag: env.imageTag, php: nil)
        addons = Self.addons(mailpit: env.mailpitEnabled, es: env.elasticsearchEnabled, redis: env.redisEnabled, xdebug: env.xdebugEnabled)
        https = env.httpsEnabled ? "On" : "—"
        self.groupName = groupName
        port = env.port
        lastUsed = env.lastUsedAt
        created = env.createdAt
        folder = (env.worktreePath.path as NSString).abbreviatingWithTildeInPath
    }

    private mutating func fill(sample: InstanceMetricsSample?, imageTag: String, php phpVersion: String?) {
        cpu = sample?.cpuPercent ?? 0
        memory = sample?.memoryBytes ?? 0
        network = (sample?.rxBytesPerSecond ?? 0) + (sample?.txBytesPerSecond ?? 0)
        wordpress = imageTag.replacingOccurrences(of: "wordpress:", with: "")
        php = phpVersion ?? imageTag.firstMatch(of: #/php(\d+\.\d+)/#).map { String($0.output.1) } ?? "—"
    }

    private static func addons(mailpit: Bool, es: Bool, redis: Bool, xdebug: Bool) -> String {
        let on = [(mailpit, "Mailpit"), (es, "Elasticsearch"), (redis, "Redis"), (xdebug, "Xdebug")].filter(\.0).map(\.1)
        return on.isEmpty ? "—" : on.joined(separator: ", ")
    }
}
