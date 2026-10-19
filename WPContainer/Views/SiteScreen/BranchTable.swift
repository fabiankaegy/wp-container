import SwiftUI
import WPContainerKit

/// Which branch environments a table lists.
enum BranchFilter: String, CaseIterable, Identifiable {
    case active = "Active", running = "Running", stale = "Stale", settled = "Settled", all = "All"
    var id: String { rawValue }

    func includes(_ env: WorktreeEnv) -> Bool {
        switch self {
        case .active: return !env.isSettled
        case .running: return env.status.isRunning || env.status.isTransitional
        case .stale: return EnvSettlement.isStale(env)
        case .settled: return env.isSettled
        case .all: return true
        }
    }
}

/// A sortable table of branch environments, built for sites with dozens of
/// them: filter by lifecycle, search, multi-select (⌘/⇧-click, ⌘A), then act
/// on the selection from the bar, the context menu or the inspector.
/// Double-click opens an env's screen. `site == nil` lists every site's envs.
struct BranchTable: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site?

    @AppStorage("branchTableFilter") private var filter: BranchFilter = .active
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\BranchRow.lastUsed, order: .reverse)]
    @State private var confirmingDelete: [WorktreeEnv] = []

    private var scope: [WorktreeEnv] { site.map { vm.store.envs(forSite: $0.id) } ?? vm.activeEnvs }

    var body: some View {
        @Bindable var vm = vm
        let scope = self.scope
        let rows = rows(scope)
        VStack(spacing: 0) {
            bar(scope)
            Table(rows, selection: $vm.branchSelection, sortOrder: $sortOrder) {
                TableColumn("") { row in statusGlyph(row.env) }
                    .width(18)
                TableColumn("Branch", value: \.branch) { row in
                    HStack(spacing: 6) {
                        Text(row.branch).font(.system(.body, design: .monospaced)).lineLimit(1)
                        if row.isStale { StaleBadge(text: "Stale") }
                    }
                }
                .width(min: 200, ideal: 340)
                if site == nil {
                    TableColumn("Site", value: \.siteName) { row in Text(row.siteName).foregroundStyle(.secondary) }
                        .width(min: 90, ideal: 130)
                }
                // Most sites keep every branch in one wp-content repo; the
                // column only earns its width when there's more than one.
                if Set(scope.map(\.repoRelPath)).count > 1 {
                    TableColumn("Repository", value: \.repo) { row in
                        Label(row.repoName, systemImage: row.isTheme ? "paintbrush" : "puzzlepiece")
                            .foregroundStyle(.secondary)
                            .help(row.env.repoRelPath)
                    }
                    .width(min: 100, ideal: 150)
                }
                TableColumn("Port", value: \.port) { row in
                    Text(row.env.isSettled ? "—" : String(row.port)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(56)
                TableColumn("Last Used", value: \.lastUsed) { row in
                    Text(row.env.status.isRunning ? "Now" : row.lastUsed.formatted(.relative(presentation: .named)))
                        .statusTint(.orange, when: row.isStale)
                }
                .width(min: 90, ideal: 110)
                TableColumn("Memory", value: \.memory) { row in
                    Text(row.memory > 0 ? Format.bytes(row.memory) : "—").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 80)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                contextMenu(ids.compactMap(vm.store.env(id:)))
            } primaryAction: { ids in
                if ids.count == 1, let id = ids.first { vm.openScreen(id) }
            }
            .overlay {
                if rows.isEmpty { empty(scope) }
            }
            // Never act on rows the filter or search hides: drop them from the
            // selection, or "Delete 54…" could target rows you can't see.
            .onChange(of: rows.map(\.id), initial: true) { _, ids in
                let visible = Set(ids)
                if !vm.branchSelection.isSubset(of: visible) { vm.branchSelection.formIntersection(visible) }
            }
            footer(shown: rows.count, total: scope.count)
        }
        .confirmationDialog("Delete \(confirmingDelete.count) branch environment\(confirmingDelete.count == 1 ? "" : "s")?",
                            isPresented: Binding(get: { !confirmingDelete.isEmpty }, set: { if !$0 { confirmingDelete = [] } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                confirmingDelete.forEach { vm.deleteEnv($0) }
                vm.branchSelection.subtract(confirmingDelete.map(\.id))
                confirmingDelete = []
            }
            Button("Cancel", role: .cancel) { confirmingDelete = [] }
        } message: {
            Text("Removes containers, cloned files and worktree checkouts. Git branches are kept.")
        }
    }

    // MARK: Rows

    private func rows(_ scope: [WorktreeEnv]) -> [BranchRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return scope
            .filter { filter.includes($0) }
            .map { BranchRow(env: $0, siteName: vm.store.site(id: $0.parentSiteID)?.name ?? "",
                             memory: vm.metrics.latest($0.id)?.memoryBytes ?? 0) }
            .filter { q.isEmpty || $0.branch.lowercased().contains(q) || $0.repo.lowercased().contains(q) || $0.siteName.lowercased().contains(q) }
            .sorted(using: sortOrder)
    }

    private func statusGlyph(_ env: WorktreeEnv) -> some View {
        Group {
            if env.isSettled {
                Image(systemName: "archivebox").font(.caption2).foregroundStyle(.secondary).help("Settled")
            } else {
                StatusDot(status: env.status, size: 7).help(env.status.label)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Bar, footer, empty state

    private func bar(_ scope: [WorktreeEnv]) -> some View {
        HStack(spacing: 10) {
            Picker("Show", selection: $filter) {
                ForEach(BranchFilter.allCases) { f in
                    Text("\(f.rawValue) \(scope.filter(f.includes).count)").tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            TextField("Filter Branches", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
            if let site {
                Button("New", systemImage: "plus") {
                    vm.selection = site.id
                    vm.presentingNewEnv = true
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func footer(shown: Int, total: Int) -> some View {
        let selected = vm.selectedEnvs
        HStack(spacing: 8) {
            if selected.isEmpty {
                Text("\(shown) of \(total) branch environments")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                Text("\(selected.count) selected").fontWeight(.semibold)
                Spacer()
                Button("Start", systemImage: "play.fill") { selected.filter { !$0.isSettled && $0.status == .stopped }.forEach(vm.startEnv) }
                    .disabled(!selected.contains { !$0.isSettled && $0.status == .stopped })
                Button("Stop", systemImage: "stop.fill") { selected.filter { $0.status.isRunning }.forEach(vm.stopEnv) }
                    .disabled(!selected.contains { $0.status.isRunning })
                if selected.contains(where: { !$0.isSettled }) {
                    Button("Settle", systemImage: "archivebox") { vm.settleEnvs(selected.filter { !$0.isSettled }) }
                }
                if selected.contains(where: \.isSettled) {
                    Button("Restore", systemImage: "arrow.uturn.backward") { selected.filter(\.isSettled).forEach(vm.restoreEnv) }
                }
                Button("Delete…", systemImage: "trash", role: .destructive) { confirmingDelete = selected }
            }
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private func empty(_ scope: [WorktreeEnv]) -> some View {
        Group {
            if !search.isEmpty {
                ContentUnavailableView.search(text: search)
            } else if scope.isEmpty {
                ContentUnavailableView {
                    Label("No Branch Environments", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("Run any git branch of a plugin or theme in wp-content in its own copy of the site, on its own port.")
                } actions: {
                    if let site {
                        CLISnippet(command: "wp-container worktree create --site \(site.slug) --repo <path> --branch <name> --json")
                            .frame(maxWidth: 420)
                    }
                }
            } else {
                ContentUnavailableView("No \(filter.rawValue) Branches", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text(filter == .stale ? "Every branch environment was used in the last \(EnvSettlement.suggestAfterDays) days." : "Try another filter."))
            }
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func contextMenu(_ envs: [WorktreeEnv]) -> some View {
        if envs.count == 1, let env = envs.first {
            Button("Open", systemImage: "rectangle.portrait.and.arrow.right") { vm.openScreen(env.id) }
            Button("Open in Browser", systemImage: "safari") { SystemActions.openInBrowser(env.url) }
                .disabled(!env.status.isRunning)
            EnvMoreMenuItems(env: env)
            Divider()
        }
        if envs.contains(where: { !$0.isSettled && $0.status == .stopped }) {
            Button(envs.count == 1 ? "Start" : "Start \(envs.count)", systemImage: "play.fill") {
                envs.filter { !$0.isSettled && $0.status == .stopped }.forEach(vm.startEnv)
            }
        }
        if envs.contains(where: { $0.status.isRunning }) {
            Button(envs.count == 1 ? "Stop" : "Stop \(envs.count)", systemImage: "stop.fill") {
                envs.filter { $0.status.isRunning }.forEach(vm.stopEnv)
            }
        }
        if envs.contains(where: { !$0.isSettled }) {
            Button("Settle", systemImage: "archivebox") { vm.settleEnvs(envs.filter { !$0.isSettled }) }
        }
        if envs.contains(where: \.isSettled) {
            Button("Restore", systemImage: "arrow.uturn.backward") { envs.filter(\.isSettled).forEach(vm.restoreEnv) }
        }
        Divider()
        Button(envs.count == 1 ? "Delete…" : "Delete \(envs.count)…", systemImage: "trash", role: .destructive) {
            confirmingDelete = envs
        }
    }
}

/// A sortable projection of a `WorktreeEnv` for `Table`.
struct BranchRow: Identifiable {
    let env: WorktreeEnv
    let siteName: String
    let memory: UInt64

    var id: UUID { env.id }
    var branch: String { env.branch }
    var repo: String { env.repoRelPath }
    var repoName: String { (env.repoRelPath as NSString).lastPathComponent }
    var isTheme: Bool { env.repoRelPath.contains("/themes/") }
    var port: Int { env.isSettled ? Int.max : env.port }
    var lastUsed: Date { env.status.isRunning ? .distantFuture : env.lastUsedAt }
    var isStale: Bool { EnvSettlement.isStale(env) }
}
