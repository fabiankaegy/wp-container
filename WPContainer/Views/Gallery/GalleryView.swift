import SwiftUI
import WPContainerKit

/// The library as a gallery of homepage cards: every site, the running ones,
/// or one group. Click selects (the inspector follows), double-click opens the
/// site screen, and hovering a card offers Start/Stop and Open.
struct GalleryView: View {
    @Environment(AppViewModel.self) private var vm
    let item: LibraryItem
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 20, alignment: .top)]

    var body: some View {
        let sections = self.sections
        Group {
            if sections.allSatisfy({ $0.sites.isEmpty }) {
                emptyState
            } else if vm.libraryStyle == .list {
                LibraryListView(sections: sections)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(sections) { section in
                            if !section.sites.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    if let title = section.title {
                                        HStack(spacing: 6) {
                                            Text(title).font(.headline)
                                            Text("\(section.sites.count)").foregroundStyle(.tertiary)
                                        }
                                    }
                                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                                        ForEach(section.sites) { site in
                                            SiteCard(site: site)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(24)
                }
                // Clicking empty space clears the selection, as in Finder.
                .background { Color.clear.contentShape(Rectangle()).onTapGesture { vm.selection = nil } }
            }
        }
        // A fixed-width field beside the other actions rather than `.searchable`:
        // the system placements either drift over the inspector or claim so much
        // width that a narrow window pushes every action into the overflow menu.
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem {
                ToolbarSearchField(text: $search, prompt: "Search Sites", focused: $searchFocused)
            }
            ToolbarItem {
                @Bindable var vm = vm
                Picker("View", selection: $vm.libraryStyle) {
                    Label("Gallery", systemImage: "square.grid.2x2").tag(LibraryStyle.gallery)
                    Label("List", systemImage: "list.bullet").tag(LibraryStyle.list)
                }
                .pickerStyle(.segmented)
                .help("View as Gallery (⌘1) or List (⌘2)")
            }
            ToolbarItem {
                Button { vm.presentingAddSite = true } label: { Label("New Site", systemImage: "plus") }
                    .help("New Site (⌘N)")
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle(sections))
    }



    private var sections: [GallerySection] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let matches: (Site) -> Bool = { q.isEmpty || $0.name.lowercased().contains(q) || $0.displayHost.lowercased().contains(q) }
        // Archived sites only appear in their own list.
        let sites = vm.sites.filter { matches($0) && $0.isArchived == (item == .archived) }
        switch item {
        case .archived:
            return [GallerySection(title: nil, sites: sites)]
        case .running:
            return [GallerySection(title: nil, sites: sites.filter { $0.status.isRunning || $0.status.isTransitional })]
        case .group(let id):
            return [GallerySection(title: nil, sites: sites.filter { $0.groupID == id })]
        case .allSites, .branches:
            let groups = vm.store.sortedGroups
            guard !groups.isEmpty, q.isEmpty else { return [GallerySection(title: nil, sites: sites)] }
            return [GallerySection(title: "Ungrouped", sites: sites.filter { $0.groupID == nil })]
                + groups.map { g in GallerySection(id: g.id, title: g.name, sites: sites.filter { $0.groupID == g.id }) }
        }
    }

    private var title: String {
        switch item {
        case .allSites, .branches: return "All Sites"
        case .running: return "Running"
        case .archived: return "Archived"
        case .group(let id): return vm.store.group(id: id)?.name ?? "Group"
        }
    }

    private func subtitle(_ sections: [GallerySection]) -> String {
        let sites = sections.flatMap(\.sites)
        return "\(sites.count) site\(sites.count == 1 ? "" : "s"), \(sites.filter { $0.status.isRunning }.count) running"
    }

    @ViewBuilder
    private var emptyState: some View {
        if !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else if item == .archived {
            ContentUnavailableView("No Archived Sites", systemImage: "archivebox",
                                   description: Text("Archive a site you aren’t using to stop it and tuck it away. Its files and database are kept, and you can bring it back anytime."))
        } else if item == .running {
            ContentUnavailableView("Nothing Running", systemImage: "play.slash",
                                   description: Text("Start a site and it shows up here."))
        } else {
            ContentUnavailableView {
                Label("No Sites", systemImage: "square.grid.2x2")
            } description: {
                Text("Spin up a local WordPress site running in an Apple container. The whole install lives in a folder you can edit and version with git.")
            } actions: {
                Button("Add Site…") { vm.presentingAddSite = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// One site in the gallery: its homepage preview with hover actions, then
/// avatar, name and status, and a strip of its branch environments so they
/// are one click away rather than hidden inside the site.
struct SiteCard: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site

    @State private var hovering = false
    @State private var confirmingDelete = false
    @FocusState private var focused: Bool

    private var isSelected: Bool { vm.selection == site.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            preview
            HStack(spacing: 9) {
                SiteAvatar(name: site.name, slug: site.slug, size: 26,
                           wordpressFolder: site.wordpressFolder, reloadToken: site.status)
                VStack(alignment: .leading, spacing: 1) {
                    Text(site.name).font(.body.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        StatusDot(status: site.status, size: 7)
                        Text("\(site.status.label) · \(site.displayHost)").lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 2)
            if !site.isArchived { BranchStrip(site: site) }
        }
        .contentShape(Rectangle())
        // Keyboard focus selects the card, so the accent selection ring is the
        // one indicator for both mouse and keyboard (no second system ring).
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onChange(of: focused) { _, isFocused in
            if isFocused { vm.selection = site.id; vm.branchSelection = [] }
        }
        .onKeyPress(.return) { vm.openScreen(site.id); return .handled }
        .onKeyPress(.space) { vm.selection = site.id; return .handled }
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { vm.openScreen(site.id) }
        .simultaneousGesture(TapGesture().onEnded { vm.selection = site.id; vm.branchSelection = [] })
        .draggable(site.id.uuidString)
        .contextMenu { contextMenu }
        .confirmationDialog("Delete \"\(site.name)\"?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Site & Move Folder to Trash", role: .destructive) { vm.deleteSite(site, trashFolder: true) }
            Button("Delete Site (Keep Folder)", role: .destructive) { vm.deleteSite(site, trashFolder: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the site's containers. Choose whether to also move \(site.path.lastPathComponent) to the Trash.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Open") { vm.openScreen(site.id) }
    }

    private var preview: some View {
        SitePreviewView(id: site.id, name: site.name, slug: site.slug, url: site.url, status: site.status)
            .accessibilityHidden(true)
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : Color.primary.opacity(0.08), lineWidth: isSelected ? 3 : 0.5)
            )
            .shadow(color: .black.opacity(hovering ? 0.18 : 0.08), radius: hovering ? 12 : 4, y: hovering ? 6 : 2)
            .offset(y: hovering ? -2 : 0)
            .animation(.easeOut(duration: 0.2), value: hovering)
            .overlay(alignment: .topTrailing) {
                if hovering || isSelected { hoverActions.padding(8) }
            }
            .overlay(alignment: .bottomTrailing) {
                if site.isArchived { chip(Label("Archived", systemImage: "archivebox")).padding(8) }
                else if site.status == .stopped { chip(Text("Asleep")).padding(8) }
            }
    }

    @ViewBuilder
    private var hoverActions: some View {
        HStack(spacing: 6) {
            if site.status.isTransitional {
                ProgressView().controlSize(.small).frame(width: 30, height: 30).glassEffect(in: .circle)
            } else if site.status.isRunning {
                roundButton("stop.fill", "Stop") { vm.stopSite(site) }
                roundButton("safari", "Open in Browser") { SystemActions.openInBrowser(site.url) }
            } else if site.isArchived {
                roundButton("arrow.uturn.backward", "Unarchive") { vm.unarchiveSite(site) }
            } else {
                roundButton("play.fill", "Start") { vm.startSite(site) }
            }
            if !site.isArchived {
                roundButton("arrow.triangle.branch", "New Branch Environment…") {
                    vm.selection = site.id
                    vm.presentingNewEnv = true
                }
            }
        }
    }

    private func roundButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(help)
    }

    private func chip(_ content: some View) -> some View {
        content
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Open", systemImage: "rectangle.portrait.and.arrow.right") { vm.openScreen(site.id) }
        Divider()
        if site.status.isRunning {
            Button("Stop", systemImage: "stop.fill") { vm.stopSite(site) }
        } else {
            Button("Start", systemImage: "play.fill") { vm.startSite(site) }
                .disabled(site.status.isTransitional)
            if !vm.store.envs(forSite: site.id).filter({ !$0.isSettled }).isEmpty {
                Button("Start with Branch Environments", systemImage: "play.fill") { vm.startSiteWithEnvs(site) }
                    .disabled(site.status.isTransitional)
            }
        }
        Button("Open in Browser", systemImage: "safari") { SystemActions.openInBrowser(site.url) }
            .disabled(!site.status.isRunning)
        Button("WP Admin", systemImage: "person.badge.key") { SystemActions.openInBrowser(site.wpAdminURL) }
            .disabled(!site.status.isRunning)
        SiteMoreMenuItems(site: site)
        Divider()
        Menu("Move to Group") {
            Button("Ungrouped") { vm.moveSite(site, toGroup: nil) }
                .disabled(site.groupID == nil)
            Divider()
            ForEach(vm.store.sortedGroups) { group in
                Button(group.name) { vm.moveSite(site, toGroup: group.id) }
                    .disabled(site.groupID == group.id)
            }
        }
        Button("Refresh Preview", systemImage: "arrow.clockwise") {
            vm.previews.refresh(id: site.id, url: site.url, isRunning: site.status.isRunning, force: true)
        }
        .disabled(!site.status.isRunning)
        Divider()
        if site.isArchived {
            Button("Unarchive", systemImage: "arrow.uturn.backward") { vm.unarchiveSite(site) }
        } else {
            Button("Archive", systemImage: "archivebox") { vm.archiveSite(site) }
        }
        Button("Delete Site…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
    }
}

/// A site's branch environments under its card: running ones as chips that
/// open the env, then a count that opens the site's branch table (with an
/// orange dot when some have gone unused for a week).
private struct BranchStrip: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site

    private let shown = 2

    var body: some View {
        let envs = vm.store.envs(forSite: site.id).filter { !$0.isSettled }
        let running = envs.filter { $0.status.isRunning || $0.status.isTransitional }
        let stale = envs.contains { EnvSettlement.isStale($0) }
        HStack(spacing: 5) {
            if envs.isEmpty {
                Button {
                    vm.selection = site.id
                    vm.presentingNewEnv = true
                } label: {
                    Label("New Branch", systemImage: "plus")
                }
                .buttonStyle(StripChipStyle(tint: .secondary))
                .help("Run a git branch of a plugin or theme in its own copy of this site")
            } else {
                ForEach(running.prefix(shown)) { env in
                    Button { vm.openScreen(env.id) } label: {
                        HStack(spacing: 4) {
                            StatusDot(status: env.status, size: 6)
                            Text(env.branch).font(.system(.caption2, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .buttonStyle(StripChipStyle(tint: .purple))
                    .help("Open \(env.branch)")
                }
                let rest = envs.count - min(running.count, shown)
                if rest > 0 {
                    Button { vm.openScreen(site.id, tab: .branches) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.branch")
                            Text(running.isEmpty ? "\(envs.count) branch\(envs.count == 1 ? "" : "es")" : "+\(rest)")
                            if stale { Circle().fill(.orange).frame(width: 5, height: 5) }
                        }
                    }
                    .buttonStyle(StripChipStyle(tint: .secondary))
                    .help("Show all \(envs.count) branch environments\(stale ? " (some unused for a week or more)" : "")")
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 20)
    }
}

/// A small capsule button used in a card's branch strip.
private struct StripChipStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(configuration.isPressed ? 0.25 : 0.12), in: Capsule())
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
            .frame(maxWidth: 150, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A compact search field for the toolbar: magnifier, text, clear button.
/// ⌘F focuses it and Escape clears it.
struct ToolbarSearchField: View {
    @Binding var text: String
    let prompt: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused(focused)
                .onKeyPress(.escape) { text = ""; focused.wrappedValue = false; return .handled }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
                    .help("Clear Search")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 180)
        .background {
            // Invisible ⌘F target, so the shortcut works without a menu item.
            Button("Find") { focused.wrappedValue = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(prompt)
    }
}

/// A run of library sites, optionally under a group heading. Shared by the
/// gallery and the list view, where a titled section becomes a header row.
struct GallerySection: Identifiable {
    /// The group's ID, or a fixed ID for the "Ungrouped" (or untitled) section.
    var id = GallerySection.ungroupedID
    let title: String?
    let sites: [Site]

    static let ungroupedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}
