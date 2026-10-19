import Charts
import SwiftUI
import WPContainerKit

/// A site or branch environment's own screen, opened from the gallery or a
/// branch table. Overview: the homepage up top, live CPU / memory / network,
/// the container stack, and live logs. A site's Branches tab is its branch
/// table. Settings stay in the inspector.
struct SiteScreen: View {
    @Environment(AppViewModel.self) private var vm
    let route: SiteScreenRoute

    var body: some View {
        if let env = vm.store.env(id: route.id), let site = vm.store.site(id: env.parentSiteID) {
            screen(site: site, env: env)
        } else if let site = vm.store.site(id: route.id) {
            screen(site: site, env: nil)
        } else {
            ContentUnavailableView("Not Found", systemImage: "questionmark.square.dashed",
                                   description: Text("This site or environment was deleted."))
                .toolbar { backButton }
        }
    }

    @ViewBuilder
    private func screen(site: Site, env: WorktreeEnv?) -> some View {
        Group {
            if env == nil, route.tab == .branches {
                VStack(spacing: 0) {
                    header(site: site, env: nil)
                        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 4)
                    BranchTable(site: site)
                }
            } else {
                overview(site: site, env: env)
            }
        }
        // Drop a .sql/.sql.gz dump on a site's screen to import it (PLAN.md §2m).
        .dropDestination(for: URL.self) { urls, _ in
            guard env == nil, let dump = urls.first(where: DumpFile.isDumpFile) else { return false }
            vm.selection = site.id
            vm.pendingImportDump = dump
            vm.presentingImportDB = true
            return true
        }
        .navigationTitle(env?.branch ?? site.name)
        .navigationSubtitle(env.map { $0.isSettled ? "Settled" : $0.url.host() ?? "" } ?? site.displayHost)
        .toolbar { toolbar(site: site, env: env) }
    }

    // MARK: Overview

    private func overview(site: Site, env: WorktreeEnv?) -> some View {
        let id = env?.id ?? site.id
        let status = env?.status ?? site.status
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // A homepage snapshot earns the hero; without one (a site that
                // has never run) the header starts at the top instead.
                if hasSnapshot(id, fallback: env == nil ? nil : site.id) {
                SitePreviewView(id: id, name: site.name, slug: site.slug, url: env?.url ?? site.url,
                                status: status, fallbackID: env == nil ? nil : site.id)
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .topTrailing) {
                        if let env { branchRibbon(env).padding(14) }
                    }
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.45), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                } else {
                    Color.clear.frame(height: 20)
                        // Still ask for a snapshot, so one appears once the site runs.
                        .task(id: status) { vm.previews.refresh(id: id, url: env?.url ?? site.url, isRunning: status.isRunning) }
                }
                VStack(alignment: .leading, spacing: 20) {
                    header(site: site, env: env)
                        .padding(.top, hasSnapshot(id, fallback: env == nil ? nil : site.id) ? -48 : 0)
                    if env == nil { BranchesPanel(site: site) }
                    if status.isRunning {
                        LiveTiles(id: id)
                    } else {
                        Label(env?.isSettled == true
                              ? "Settled. Restore it to bring it back on its port."
                              : "Start \(env == nil ? "the site" : "this environment") to see live CPU, memory and network.",
                              systemImage: env?.isSettled == true ? "archivebox" : "moon.zzz")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    StackStrip(site: site, env: env)
                    if !status.isRunning {
                        SectionCard(title: "Logs", systemImage: "text.alignleft") {
                            Text("Logs stream here while \(env == nil ? "the site" : "this environment") is running.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    } else if let env {
                        LogsView(env: env).id(env.id)
                    } else {
                        LogsView(site: site).id(site.id)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private func hasSnapshot(_ id: UUID, fallback: UUID?) -> Bool {
        vm.previews.images[id] != nil || fallback.map { vm.previews.images[$0] != nil } == true
    }

    private func header(site: Site, env: WorktreeEnv?) -> some View {
        HStack(alignment: .bottom, spacing: 14) {
            Group {
                if env != nil {
                    SectionIcon(systemName: "arrow.triangle.branch", color: .purple, size: 64)
                } else {
                    SiteAvatar(name: site.name, slug: site.slug, size: 64,
                               wordpressFolder: site.wordpressFolder, reloadToken: site.status)
                }
            }
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(env?.branch ?? site.name)
                    .font(env == nil ? .system(.largeTitle, weight: .bold) : .system(.title, design: .monospaced, weight: .bold))
                    .lineLimit(1)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    if let env {
                        if env.isSettled { SettledPill() } else { StatusPill(status: env.status) }
                        Text("Branch of")
                        Button(site.name) { vm.openScreen(site.id) }.buttonStyle(.link)
                    } else {
                        StatusPill(status: site.status)
                        Text(site.displayHost)
                        let envs = vm.store.envs(forSite: site.id)
                        if !envs.isEmpty {
                            Text("· \(envs.filter { $0.status.isRunning }.count) of \(envs.count) branches running")
                        }
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func branchRibbon(_ env: WorktreeEnv) -> some View {
        Label(env.branch, systemImage: "arrow.triangle.branch")
            .font(.system(.caption, design: .monospaced, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glassEffect(.regular.tint(.purple), in: .capsule)
    }

    // MARK: Toolbar

    private var backButton: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { vm.goBack() } label: { Label("Back", systemImage: "chevron.backward") }
                .help("Back (⌘[)")
        }
    }

    @ToolbarContentBuilder
    private func toolbar(site: Site, env: WorktreeEnv?) -> some ToolbarContent {
        @Bindable var vm = vm
        backButton
        if env == nil {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: Binding(get: { route.tab }, set: { vm.showTab($0) })) {
                    Text("Overview").tag(SiteScreenTab.overview)
                    Text("Branches \(vm.store.envs(forSite: site.id).count)").tag(SiteScreenTab.branches)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        if route.tab == .overview, !vm.store.envs(forSite: site.id).isEmpty {
            ToolbarItem {
                Button {
                    vm.presentingBranchPicker.toggle()
                } label: {
                    Label(env?.branch ?? "Main", systemImage: "arrow.triangle.branch")
                        .labelStyle(.titleAndIcon)
                }
                .help("Switch Branch (⌃⌘B)")
                .popover(isPresented: $vm.presentingBranchPicker, arrowEdge: .bottom) {
                    BranchPicker(site: site, current: env)
                }
            }
        }
        // Keep the branch switcher visually separate from run controls.
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            if let env {
                EnvRunButton(env: env)
                Button { SystemActions.openInBrowser(env.url) } label: { Label("Open in Browser", systemImage: "safari") }
                    .disabled(!env.status.isRunning)
                    .help("Open in Browser")
            } else {
                SiteRunButton(site: site)
                Button { SystemActions.openInBrowser(site.url) } label: { Label("Open in Browser", systemImage: "safari") }
                    .disabled(!site.status.isRunning)
                    .help("Open in Browser (⌘O)")
            }
        }
    }
}

/// Three live charts: CPU, memory and network, each with its current value.
private struct LiveTiles: View {
    @Environment(AppViewModel.self) private var vm
    let id: UUID

    var body: some View {
        let samples = vm.metrics.history[id] ?? []
        let latest = samples.last
        HStack(spacing: 14) {
            tile("CPU", "cpu", .blue, latest.map { Format.percent($0.cpuPercent) }, samples.map(\.cpuPercent))
            tile("Memory", "memorychip", .purple, latest.map { Format.bytes($0.memoryBytes) }, samples.map { Double($0.memoryBytes) })
            tile("Network", "arrow.up.arrow.down", .green,
                 latest.map { "↓ \(Format.rate($0.rxBytesPerSecond)) ↑ \(Format.rate($0.txBytesPerSecond))" },
                 samples.map { $0.rxBytesPerSecond + $0.txBytesPerSecond })
        }
    }

    private func tile(_ title: String, _ symbol: String, _ color: Color, _ value: String?, _ values: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value ?? "—").font(.title2.weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Sparkline(values: values, color: color).frame(height: 44)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .animation(.easeOut(duration: 0.3), value: value)
    }
}

/// A site's branch environments right on its Overview: running ones as live
/// cards, then the most recently used, with New and Show All. The full table
/// is one click away on the Branches tab.
private struct BranchesPanel: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site

    private let recentLimit = 4

    var body: some View {
        let envs = vm.store.envs(forSite: site.id)
        let running = envs.filter { $0.status.isRunning || $0.status.isTransitional }
        let recent = envs.filter { !$0.isSettled && !$0.status.isRunning && !$0.status.isTransitional }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
        let stale = envs.filter { EnvSettlement.isStale($0) }
        SectionCard(title: "Branches", systemImage: "arrow.triangle.branch") {
            HStack(spacing: 6) {
                if !stale.isEmpty {
                    Button("Settle \(stale.count) Stale") { vm.settleEnvs(stale) }
                        .help("Unused for \(EnvSettlement.suggestAfterDays)+ days. Settling stops them and frees their ports; files and databases are kept.")
                }
                if !envs.isEmpty {
                    Button("Show All \(envs.count)") { vm.showTab(.branches) }
                }
                Button("New Branch…", systemImage: "plus") {
                    vm.selection = site.id
                    vm.presentingNewEnv = true
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        } content: {
            if envs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Run any git branch of a plugin or theme in wp-content in its own copy of this site, on its own port, in seconds.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    CLISnippet(command: "wp-container worktree create --site \(site.slug) --repo <path> --branch <name> --json")
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if !running.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                            ForEach(running) { RunningBranchCard(env: $0) }
                        }
                    }
                    if !recent.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(running.isEmpty ? "Recently Used" : "Recently Used · Stopped")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.bottom, 4)
                            ForEach(Array(recent.prefix(recentLimit).enumerated()), id: \.element.id) { index, env in
                                if index > 0 { Divider() }
                                RecentBranchRow(env: env)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// A running branch environment: its name, where it lives, live CPU, and
/// Open / Stop. Clicking the card opens the env's screen.
private struct RunningBranchCard: View {
    @Environment(AppViewModel.self) private var vm
    let env: WorktreeEnv

    var body: some View {
        let samples = vm.metrics.history[env.id] ?? []
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusDot(status: env.status, size: 7)
                Text(env.branch).font(.system(.callout, design: .monospaced, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            }
            Text("\((env.repoRelPath as NSString).lastPathComponent) · \(env.url.host() ?? ""):\(env.url.port.map(String.init) ?? "")")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .bottom, spacing: 8) {
                Sparkline(values: samples.map(\.cpuPercent), color: .blue).frame(height: 22)
                Text(samples.last.map { Format.percent($0.cpuPercent) } ?? "—")
                    .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Button("Open") { SystemActions.openInBrowser(env.url) }.disabled(!env.status.isRunning)
                Button("Stop") { vm.stopEnv(env) }.disabled(!env.status.isRunning)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.purple.opacity(0.2), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { vm.openScreen(env.id) }
        .help("Open \(env.branch)")
    }
}

/// A stopped branch environment: name, when it was last used, and Start.
private struct RecentBranchRow: View {
    @Environment(AppViewModel.self) private var vm
    let env: WorktreeEnv

    var body: some View {
        HStack(spacing: 8) {
            Button(env.branch) { vm.openScreen(env.id) }
                .buttonStyle(.link)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(EnvUsageText.lastUsed(env))
                .font(.caption)
                .foregroundStyle(EnvSettlement.isStale(env) ? .orange : .secondary)
            Button("Start") { vm.startEnv(env) }
                .controlSize(.small)
                .disabled(env.status.isTransitional)
        }
        .padding(.vertical, 5)
    }
}

/// The instance's containers and add-ons as a row of chips. For a site the
/// add-on chips are switches (each restarts the site); an env shows its own.
private struct StackStrip: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site
    let env: WorktreeEnv?

    var body: some View {
        SectionCard(title: "Stack", systemImage: "square.stack.3d.up") {
            FlowLayout(spacing: 8) {
                chip("WordPress", detail: (env?.imageTag ?? site.imageTag).replacingOccurrences(of: "wordpress:", with: ""),
                     symbol: "server.rack", color: .orange, on: true)
                chip("MariaDB", detail: env?.sharedDatabase == true ? "shared with \(site.name)" : "own server",
                     symbol: "cylinder.split.1x2", color: .teal, on: true)
                addon("Mailpit", "envelope", .pink, on: env?.mailpitEnabled ?? site.mailpitEnabled) { vm.setMailpit(site, enabled: $0) }
                addon("Elasticsearch", "magnifyingglass", .yellow, on: env?.elasticsearchEnabled ?? site.elasticsearchEnabled) { vm.setElasticsearch(site, enabled: $0) }
                addon("Redis", "bolt.horizontal", .red, on: env?.redisEnabled ?? site.redisEnabled) { vm.setRedis(site, enabled: $0) }
                addon("Xdebug", "ant", .indigo, on: env?.xdebugEnabled ?? site.xdebugEnabled) { vm.setXdebug(site, enabled: $0) }
            }
        }
    }

    @ViewBuilder
    private func addon(_ name: String, _ symbol: String, _ color: Color, on: Bool, set: @escaping (Bool) -> Void) -> some View {
        if env == nil {
            Button { set(!on) } label: {
                chipLabel(name, detail: on ? "on" : "off", symbol: symbol, color: color, on: on)
            }
            .buttonStyle(.plain)
            .help("Turn \(name) \(on ? "off" : "on")\(site.status.isRunning ? " (restarts the site)" : "")")
        } else {
            chip(name, detail: on ? "on" : "off", symbol: symbol, color: color, on: on)
        }
    }

    private func chip(_ name: String, detail: String, symbol: String, color: Color, on: Bool) -> some View {
        chipLabel(name, detail: detail, symbol: symbol, color: color, on: on)
    }

    private func chipLabel(_ name: String, detail: String, symbol: String, color: Color, on: Bool) -> some View {
        HStack(spacing: 7) {
            SectionIcon(systemName: symbol, color: on ? color : .gray, size: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.callout.weight(.medium))
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 5)
        .background((on ? color : .gray).opacity(on ? 0.1 : 0.06), in: Capsule())
        .opacity(on ? 1 : 0.75)
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
