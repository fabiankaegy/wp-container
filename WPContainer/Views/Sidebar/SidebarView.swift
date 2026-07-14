import SwiftUI
import WPContainerKit

/// The dark sidebar: a compact brand header (kept clear of the traffic lights),
/// a scrollable list of sites organized into collapsible groups (PLAN.md §2g)
/// with ungrouped sites at the top, and a prominent bottom-pinned "Add Site"
/// button. Sites can be dragged between groups; groups have context menus for
/// rename/delete and a "New Group" affordance lives in the header.
struct SidebarView: View {
    @Environment(AppViewModel.self) private var vm

    @State private var collapsed: Set<UUID> = []
    /// Sites whose nested env rows are collapsed (§2b). Persisted so the
    /// disclosure state survives relaunch; default (absent) = expanded.
    @State private var envCollapsed: Set<UUID> = SidebarView.loadEnvCollapsed()
    @State private var newGroupPresented = false
    @State private var newGroupName = ""
    @State private var renamingGroup: SiteGroup?
    @State private var renameText = ""

    private var groups: [SiteGroup] { vm.store.sortedGroups }
    private var ungrouped: [Site] { vm.sites.filter { $0.groupID == nil } }

    // MARK: Env-collapse persistence (§2b)

    private static let envCollapsedKey = "sidebarEnvCollapsedSites"

    private static func loadEnvCollapsed() -> Set<UUID> {
        let raw = UserDefaults.standard.stringArray(forKey: envCollapsedKey) ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    private func toggleEnvCollapsed(_ siteID: UUID) {
        withAnimation(.easeOut(duration: 0.15)) {
            if envCollapsed.contains(siteID) { envCollapsed.remove(siteID) }
            else { envCollapsed.insert(siteID) }
        }
        UserDefaults.standard.set(envCollapsed.map(\.uuidString), forKey: Self.envCollapsedKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            brand
            if vm.sites.isEmpty && groups.isEmpty {
                emptyState
            } else {
                list
            }
            addButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("New Group", isPresented: $newGroupPresented) {
            TextField("Group name", text: $newGroupName)
            Button("Create") { vm.addGroup(named: newGroupName); newGroupName = "" }
            Button("Cancel", role: .cancel) { newGroupName = "" }
        } message: {
            Text("Organize sites into a named group in the sidebar.")
        }
        .alert("Rename Group", isPresented: renameBinding) {
            TextField("Group name", text: $renameText)
            Button("Rename") { if let g = renamingGroup { vm.renameGroup(g, to: renameText) }; renamingGroup = nil }
            Button("Cancel", role: .cancel) { renamingGroup = nil }
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                // Ungrouped sites at the top.
                ForEach(ungrouped) { site in
                    siteBlock(site)
                }
                // A drop target so a site can be dragged back to "ungrouped".
                if !groups.isEmpty {
                    ungroupedDropSpacer
                }
                // Groups.
                ForEach(groups) { group in
                    groupSection(group)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .padding(.bottom, 8)
        }
    }

    /// One site row plus its worktree-env rows nested underneath in a
    /// collapsible disclosure (§2b): env rows are indented, smaller, carry a
    /// branch glyph instead of an avatar, and are selectable like sites.
    @ViewBuilder
    private func siteBlock(_ site: Site) -> some View {
        let envs = vm.store.envs(forSite: site.id)
        SidebarSiteRow(site: site, groups: groups,
                       envCount: envs.count,
                       isExpanded: !envCollapsed.contains(site.id),
                       onToggleExpanded: { toggleEnvCollapsed(site.id) },
                       onMove: { vm.moveSite(site, toGroup: $0) })
        if !envs.isEmpty && !envCollapsed.contains(site.id) {
            ForEach(envs) { env in
                SidebarEnvRow(env: env)
            }
        }
    }

    @ViewBuilder
    private func groupSection(_ group: SiteGroup) -> some View {
        let sites = vm.sites.filter { $0.groupID == group.id }
        let isCollapsed = collapsed.contains(group.id)

        VStack(alignment: .leading, spacing: 2) {
            groupHeader(group, count: sites.count, isCollapsed: isCollapsed)
            if !isCollapsed {
                ForEach(sites) { site in
                    siteBlock(site)
                }
                if sites.isEmpty {
                    Text("Drop sites here")
                        .font(.caption)
                        .foregroundStyle(Theme.onFrameTertiary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
        }
        .padding(.top, 6)
        .dropDestination(for: String.self) { items, _ in
            drop(items, into: group.id)
        }
    }

    private func groupHeader(_ group: SiteGroup, count: Int, isCollapsed: Bool) -> some View {
        GroupHeaderRow(group: group, count: count, isCollapsed: isCollapsed) {
            withAnimation(.easeOut(duration: 0.15)) {
                if isCollapsed { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
            }
        } onRename: {
            renameText = group.name; renamingGroup = group
        } onDelete: {
            vm.deleteGroup(group)
        }
    }

    private var ungroupedDropSpacer: some View {
        Color.clear
            .frame(height: 6)
            .dropDestination(for: String.self) { items, _ in drop(items, into: nil) }
    }

    private func drop(_ items: [String], into groupID: UUID?) -> Bool {
        var moved = false
        for raw in items {
            if let id = UUID(uuidString: raw), let site = vm.store.site(id: id) {
                vm.moveSite(site, toGroup: groupID)
                moved = true
            }
        }
        return moved
    }

    // MARK: Brand

    private var brand: some View {
        HStack(spacing: 9) {
            // The real app icon artwork (Liquid Glass W mark) — reads far better
            // at small size than an SF-symbol stand-in.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text("WP Container")
                .font(.headline)
                .foregroundStyle(Theme.onFrame)
            Spacer()
            NewGroupButton { newGroupName = ""; newGroupPresented = true }
        }
        .padding(.horizontal, 16)
        .padding(.top, Theme.titlebarInset + 8)
        .padding(.bottom, 12)
    }

    // MARK: Add button

    private var addButton: some View {
        Button {
            vm.presentingAddSite = true
        } label: {
            Label("Add Site", systemImage: "plus")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 34))
                .foregroundStyle(Theme.accent.gradient)
            Text("Create your first site")
                .font(.headline)
                .foregroundStyle(Theme.onFrame)
            Text("Spin up a local WordPress site running in an Apple container — the full install lives in a folder you can edit and version with git.")
                .font(.caption)
                .foregroundStyle(Theme.onFrameSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A collapsible group section header on the dark chrome: chevron + uppercase
/// name + count, all in explicit on-frame colors (brightening on hover), with
/// the rename/delete context menu. All colors are fixed-light because the
/// sidebar is constant-dark in both system appearances.
private struct GroupHeaderRow: View {
    let group: SiteGroup
    let count: Int
    let isCollapsed: Bool
    let onToggle: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(hovering ? Theme.onFrame : Theme.onFrameSecondary)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
            Text(group.name.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(hovering ? Theme.onFrame : Theme.onFrameSecondary)
                .lineLimit(1)
            Text("\(count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.onFrameTertiary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture(perform: onToggle)
        .contextMenu {
            Button("Rename Group…", action: onRename)
            Button("Delete Group", role: .destructive, action: onDelete)
        }
    }
}

/// The "New Group" affordance in the brand header: a plain-styled button with
/// explicit on-frame coloring (system button/menu styles must never be used on
/// the constant-dark chrome — they resolve dark in light appearance).
private struct NewGroupButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hovering ? Theme.onFrame : Theme.onFrameSecondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Theme.sidebarHover : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("New Group…")
    }
}

/// A selectable, hover-highlighted site row wired to the app selection, with a
/// clickable status dot (start/stop), right-click quick actions (PLAN.md §2l),
/// a Move-to-Group submenu, and a drag payload (its site id).
struct SidebarSiteRow: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site
    let groups: [SiteGroup]
    var envCount: Int = 0
    var isExpanded: Bool = true
    var onToggleExpanded: (() -> Void)? = nil
    let onMove: (UUID?) -> Void

    @State private var hovering = false
    @State private var confirmingDelete = false

    private var isSelected: Bool { vm.selection == site.id }

    var body: some View {
        // The trailing status dot is a start/stop control; its clicks are
        // consumed by its own Button so they never change row selection.
        SiteRow(site: site, envCount: envCount,
                onToggleRun: toggleRun,
                isExpanded: isExpanded,
                onToggleExpanded: onToggleExpanded)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Theme.sidebarSelection
                          : (hovering ? Theme.sidebarHover : Color.clear))
            )
            .onHover { hovering = $0 }
            .onTapGesture { vm.selection = site.id }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.12), value: isSelected)
            .draggable(site.id.uuidString) {
                SiteRow(site: site, envCount: 0)
                    .frame(width: 220)
                    .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 8))
            }
            .contextMenu { contextMenu }
            .confirmationDialog("Delete \"\(site.name)\"?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete Site & Move Folder to Trash", role: .destructive) { delete(trashFolder: true) }
                Button("Delete Site (Keep Folder)", role: .destructive) { delete(trashFolder: false) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes the site's containers. Choose whether to also move \(site.path.lastPathComponent) to the Trash.")
            }
    }

    // MARK: Context menu (reuses AppViewModel actions / SystemActions — §2l)

    @ViewBuilder
    private var contextMenu: some View {
        if site.status.isRunning {
            Button("Stop", systemImage: "stop.fill") { vm.stopSite(site) }
        } else {
            Button("Start", systemImage: "play.fill") { vm.startSite(site) }
                .disabled(site.status.isTransitional)
        }

        Divider()

        Button("Open Site", systemImage: "safari") { SystemActions.openInBrowser(site.url) }
            .disabled(!site.status.isRunning)
        Button("WP Admin", systemImage: "person.badge.key") { SystemActions.openInBrowser(site.wpAdminURL) }
            .disabled(!site.status.isRunning)
        Button("Reveal in Finder", systemImage: "folder") { SystemActions.revealInFinder(site.path) }
        Button("Open in Terminal", systemImage: "terminal") { SystemActions.openTerminal(at: site.path, pathPrepend: site.path) }
        OpenInSubmenu(folder: ExternalEditors.target.url(for: site))
        Button("Copy URL", systemImage: "link") { SystemActions.copyToClipboard(site.url.absoluteString) }

        Divider()

        Button("New Branch Environment…", systemImage: "arrow.triangle.branch") {
            vm.selection = site.id
            vm.presentingNewEnv = true
        }
        Button("Import Database…", systemImage: "cylinder.split.1x2") {
            vm.selection = site.id
            vm.pendingImportDump = nil
            vm.presentingImportDB = true
        }

        Divider()

        Menu("Move to Group") {
            Button("Ungrouped") { onMove(nil) }
                .disabled(site.groupID == nil)
            if !groups.isEmpty { Divider() }
            ForEach(groups) { group in
                Button(group.name) { onMove(group.id) }
                    .disabled(site.groupID == group.id)
            }
        }

        Divider()

        Button("Delete Site…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
    }

    /// Start when stopped, stop when running; no-op while transitional.
    private func toggleRun() {
        if site.status.isRunning { vm.stopSite(site) }
        else if !site.status.isTransitional { vm.startSite(site) }
    }

    private func delete(trashFolder: Bool) {
        vm.deleteSite(site, trashFolder: trashFolder)
        if vm.selection == site.id { vm.selection = nil }
    }
}

/// A worktree-env row nested under its parent site (PLAN.md §2b): indented,
/// visually distinct from site rows — smaller height, a branch glyph instead of
/// an avatar, branch name as title and port as subtitle — selectable (shows the
/// env detail pane), with the same interactive status-dot behavior and a
/// dedicated context menu.
struct SidebarEnvRow: View {
    @Environment(AppViewModel.self) private var vm
    let env: WorktreeEnv

    @State private var hovering = false
    @State private var confirmingDelete = false

    private var isSelected: Bool { vm.selection == env.id }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected || hovering ? Theme.onFrame : Theme.onFrameSecondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 0) {
                Text(env.branch)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.onFrame)
                    .lineLimit(1)
                Text("localhost:\(String(env.port))")
                    .font(.caption2)
                    .foregroundStyle(Theme.onFrameSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            InteractiveStatusDot(status: env.status, onToggle: toggleRun)
        }
        .padding(.vertical, 3)
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .contentShape(Rectangle())
        // Indent the whole row under the parent's avatar column.
        .padding(.leading, 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Theme.sidebarSelection
                      : (hovering ? Theme.sidebarHover : Color.clear))
                .padding(.leading, 26)
        )
        .onHover { hovering = $0 }
        .onTapGesture { vm.selection = env.id }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .contextMenu { contextMenu }
        .confirmationDialog("Delete environment \"\(env.branch)\"?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Environment", role: .destructive) { vm.deleteEnv(env) }
            Button("Delete, Keep Worktree Checkout", role: .destructive) { vm.deleteEnv(env, keepWorktree: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stops its containers and removes the cloned files. The git branch \(env.branch) is always kept; optionally keep the worktree checkout on disk too.")
        }
    }

    // MARK: Context menu (§2b)

    @ViewBuilder
    private var contextMenu: some View {
        Button("Open", systemImage: "safari") { SystemActions.openInBrowser(env.localURL) }
            .disabled(!env.status.isRunning)
        Button("WP Admin", systemImage: "person.badge.key") { SystemActions.openInBrowser(env.adminURL) }
            .disabled(!env.status.isRunning)
        Button("Copy URL", systemImage: "link") { SystemActions.copyToClipboard(env.localURL.absoluteString) }

        if env.status.isRunning {
            Button("Stop", systemImage: "stop.fill") { vm.stopEnv(env) }
        } else {
            Button("Start", systemImage: "play.fill") { vm.startEnv(env) }
                .disabled(env.status.isTransitional)
        }
        Button("Reveal in Finder", systemImage: "folder") { SystemActions.revealInFinder(env.envPath) }
        OpenInSubmenu(folder: env.worktreePath)

        Divider()

        Button("Delete Environment…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
    }

    private func toggleRun() {
        if env.status.isRunning { vm.stopEnv(env) }
        else if !env.status.isTransitional { vm.startEnv(env) }
    }
}
