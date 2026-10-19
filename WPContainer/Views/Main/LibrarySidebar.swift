import SwiftUI
import WPContainerKit

/// The window's source list: the library (all sites, running, every branch
/// environment), every branch environment that is running right now, and the
/// user's groups, each with a colored icon, plus live CPU and memory for all
/// running containers at the bottom. Sites can be dragged onto a group.
struct LibrarySidebar: View {
    @Environment(AppViewModel.self) private var vm

    @State private var newGroupPresented = false
    @State private var newGroupName = ""
    @State private var renamingGroup: SiteGroup?
    @State private var renameText = ""

    private static let groupColors: [Color] = [.orange, .indigo, .teal, .pink, .mint, .brown]

    var body: some View {
        List(selection: selection) {
            Section("Library") {
                row(.allSites, "All Sites", "square.grid.2x2", .blue, count: vm.activeSites.count)
                row(.running, "Running", "play.fill", .green, count: vm.activeSites.filter { $0.status.isRunning }.count)
                row(.branches, "Branches", "arrow.triangle.branch", .purple, count: vm.activeEnvs.count,
                    stale: vm.activeEnvs.filter { EnvSettlement.isStale($0) }.count)
                let archived = vm.sites.filter(\.isArchived).count
                if archived > 0 {
                    row(.archived, "Archived", "archivebox.fill", .gray, count: archived)
                }
            }
            runningBranches
            Section("Groups") {
                ForEach(Array(vm.store.sortedGroups.enumerated()), id: \.element.id) { index, group in
                    row(.group(group.id), group.name, "folder.fill", Self.groupColors[index % Self.groupColors.count],
                        count: vm.activeSites.filter { $0.groupID == group.id }.count)
                        .dropDestination(for: String.self) { items, _ in move(items, to: group.id) }
                        .contextMenu {
                            Button("Rename Group…") { renameText = group.name; renamingGroup = group }
                            Button("Delete Group", role: .destructive) { vm.deleteGroup(group) }
                        }
                }
                Button {
                    newGroupName = ""
                    newGroupPresented = true
                } label: {
                    Label("New Group…", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { meters }
        .alert("New Group", isPresented: $newGroupPresented) {
            TextField("Group name", text: $newGroupName)
            Button("Create") { vm.addGroup(named: newGroupName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Organize sites into a named group.")
        }
        .alert("Rename Group", isPresented: Binding(get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })) {
            TextField("Group name", text: $renameText)
            Button("Rename") { if let g = renamingGroup { vm.renameGroup(g, to: renameText) }; renamingGroup = nil }
            Button("Cancel", role: .cancel) { renamingGroup = nil }
        }
    }

    /// Live branch environments, one click from their screen. Branches are the
    /// app's headline feature, so the running ones never hide inside a site.
    @ViewBuilder
    private var runningBranches: some View {
        let running = vm.envs.filter { $0.status.isRunning || $0.status.isTransitional }
            .sorted { $0.branch.localizedStandardCompare($1.branch) == .orderedAscending }
        if !running.isEmpty {
            Section("Running Branches") {
                ForEach(running) { env in
                    Button { vm.openScreen(env.id) } label: {
                        HStack(spacing: 8) {
                            StatusDot(status: env.status, size: 7).frame(width: 20)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(env.branch).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Text(vm.store.site(id: env.parentSiteID)?.name ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fontWeight(vm.screen?.id == env.id ? .semibold : .regular)
                    .contextMenu {
                        Button("Stop", systemImage: "stop.fill") { vm.stopEnv(env) }
                        Button("Open in Browser", systemImage: "safari") { SystemActions.openInBrowser(env.url) }
                        EnvMoreMenuItems(env: env)
                    }
                }
            }
        }
    }

    /// The highlighted library item. It stays highlighted while a site screen
    /// opened from it is showing; picking any item returns to the library.
    private var selection: Binding<LibraryItem?> {
        Binding(get: { vm.library }, set: { if let item = $0 { vm.showLibrary(item) } })
    }

    private func row(_ item: LibraryItem, _ title: String, _ symbol: String, _ color: Color, count: Int, stale: Int = 0) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(title)
                Spacer(minLength: 4)
                if stale > 0 {
                    StaleBadge(text: "\(stale)")
                        .help("\(stale) unused for \(EnvSettlement.suggestAfterDays)+ days")
                }
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
        } icon: {
            SectionIcon(systemName: symbol, color: color, size: 20)
        }
        .tag(item)
    }

    private func move(_ items: [String], to groupID: UUID?) -> Bool {
        let sites = items.compactMap(UUID.init(uuidString:)).compactMap(vm.store.site(id:))
        sites.forEach { vm.moveSite($0, toGroup: groupID) }
        return !sites.isEmpty
    }

    /// CPU and memory used by every running container, from `container stats`.
    @ViewBuilder
    private var meters: some View {
        if let total = vm.metrics.total, vm.sites.contains(where: { $0.status.isRunning }) || vm.envs.contains(where: { $0.status.isRunning }) {
            let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
            let memory = Double(ProcessInfo.processInfo.physicalMemory)
            VStack(alignment: .leading, spacing: 6) {
                meter("CPU", Format.percent(total.cpuPercent), fraction: total.cpuPercent / (cores * 100), color: .blue)
                meter("Memory", Format.bytes(total.memoryBytes), fraction: Double(total.memoryBytes) / memory, color: .purple)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .help("All running sites and branch environments")
        }
    }

    private func meter(_ label: String, _ value: String, fraction: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).monospacedDigit()
            }
            .font(.caption)
            ProgressView(value: min(max(fraction, 0), 1))
                .tint(color)
                .controlSize(.small)
        }
    }
}
