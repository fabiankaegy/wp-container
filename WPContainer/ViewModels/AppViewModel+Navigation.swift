import Foundation
import WPContainerKit

/// The lists the sidebar offers: every site, the running ones, every branch
/// environment across sites, archived sites, or one group.
enum LibraryItem: Hashable {
    case allSites, running, branches, archived
    case group(UUID)
}

/// The two tabs of a site screen. A branch env's screen only has an overview.
enum SiteScreenTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case branches = "Branches"
    var id: String { rawValue }
}

/// How the library lists sites: homepage cards, or a table with each site's
/// branch environments nested under it.
enum LibraryStyle: String { case gallery, list }

/// An open site or env screen.
struct SiteScreenRoute: Hashable {
    var id: UUID
    var tab: SiteScreenTab = .overview
}

/// Main-window navigation: library ↔ site screen, with a Back history, and the
/// selection the inspector and menu commands act on.
extension AppViewModel {
    /// Opens a site or env screen, remembering where we came from for Back.
    func openScreen(_ id: UUID, tab: SiteScreenTab = .overview) {
        let route = SiteScreenRoute(id: id, tab: store.env(id: id) == nil ? tab : .overview)
        guard route != screen else { return }
        screenHistory.append(screen)
        screen = route
        selection = id
        branchSelection = []
    }

    /// Switches the open site screen's tab in place (no history entry). From an
    /// env screen, "Branches" opens the parent site's branch table.
    func showTab(_ tab: SiteScreenTab) {
        guard let current = screen else { return }
        if let env = store.env(id: current.id) {
            openScreen(env.parentSiteID, tab: tab)
        } else {
            screen?.tab = tab
            branchSelection = []
        }
    }

    var canGoBack: Bool { screen != nil }

    /// The site whose screen is open (an env screen's parent site).
    var screenSiteID: UUID? {
        guard let id = screen?.id else { return nil }
        return store.env(id: id)?.parentSiteID ?? id
    }

    /// Returns to the previous screen, or to the library.
    func goBack() {
        screen = screenHistory.popLast() ?? nil
        if let screen { selection = screen.id }
        branchSelection = []
    }

    /// Shows a library list, closing any site screen.
    func showLibrary(_ item: LibraryItem) {
        library = item
        screen = nil
        screenHistory = []
        branchSelection = []
    }

    /// Whether a branch table is on screen (its selection then drives the inspector).
    var isShowingBranchTable: Bool {
        if let screen { return screen.tab == .branches && store.site(id: screen.id) != nil }
        return library == .branches
    }

    /// The envs selected in the visible branch table.
    var selectedEnvs: [WorktreeEnv] {
        guard isShowingBranchTable else { return [] }
        return store.envs.filter { branchSelection.contains($0.id) }
    }
}
