import AppKit
import SwiftUI
import WPContainerKit

/// The main window: a native split view. The sidebar picks a library list
/// (all sites, running, branches, a group); the detail shows it as a gallery
/// or a branch table, or one site's screen; the inspector on the right holds
/// every setting for the selection. Live metrics poll while this window is open.
struct MainWindow: View {
    @Environment(AppViewModel.self) private var vm
    /// Whether a dragged file is hovering the detail column.
    @State private var archiveDropTargeted = false

    var body: some View {
        @Bindable var vm = vm
        Group {
            if let status = vm.systemStatus, !status.isReady {
                OnboardingView(status: status)
            } else {
                NavigationSplitView {
                    LibrarySidebar()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
                } detail: {
                    detail
                        // Never pass the content's minimum width up to the split
                        // view: a detail wider than its column (a narrow window, a
                        // wide inspector) sends AppKit into a layout loop that
                        // crashes the app. Content that can't fit clips instead.
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        // A .zip site export dropped anywhere on the detail opens
                        // the Import Site sheet with it. A site's screen handles
                        // drops on itself.
                        .dropDestination(for: URL.self) { urls, _ in
                            guard let archive = urls.first(where: { $0.pathExtension.lowercased() == "zip" }) else { return false }
                            vm.pendingImportArchive = archive
                            vm.presentingImportSite = true
                            return true
                        } isTargeted: { archiveDropTargeted = $0 }
                        .overlay {
                            if archiveDropTargeted { ImportDropOverlay() }
                        }
                        .animation(.easeOut(duration: 0.12), value: archiveDropTargeted)
                        .toolbar {
                            // While the inspector is open its toggle lives in the
                            // inspector's own toolbar section (InspectorView).
                            if !vm.showsInspector {
                                ToolbarItem { InspectorToggle() }
                            }
                        }
                }
                .inspector(isPresented: $vm.showsInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 280, ideal: 310, max: 420)
                }
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                localNetworkBanner
                errorBanner
            }
            .frame(maxWidth: 640)
        }
        .task { await vm.runLiveMetrics() }
        // Re-check Site Icons whenever the set of running sites changes.
        .task(id: vm.sites.filter { $0.status.isRunning }.map(\.id)) { await vm.syncSiteIcons() }
        #if DEBUG
        .task {
            // Wait for the store to load before resolving the slug.
            for _ in 0..<100 where vm.sites.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            openLaunchScreen()
        }
        #endif
        .sheet(isPresented: $vm.presentingAddSite) {
            AddSiteSheet()
        }
        .sheet(isPresented: $vm.presentingNewEnv) {
            if let site = vm.selectedSite ?? vm.selectedEnv.flatMap({ vm.store.site(id: $0.parentSiteID) }) {
                NewBranchEnvSheet(site: site)
            }
        }
        .sheet(isPresented: $vm.presentingImportDB, onDismiss: { vm.pendingImportDump = nil }) {
            if let site = vm.selectedSite {
                ImportDatabaseSheet(site: site, initialDump: vm.pendingImportDump)
            }
        }
        .sheet(isPresented: $vm.presentingExportSite, onDismiss: { vm.exportSiteTarget = nil }) {
            if let site = vm.exportSiteTarget {
                ExportSiteSheet(site: site)
            }
        }
        .sheet(isPresented: $vm.presentingImportSite, onDismiss: { vm.pendingImportArchive = nil }) {
            ImportSiteSheet(initialArchive: vm.pendingImportArchive)
        }
        .sheet(isPresented: $vm.presentingCLIInstallOffer) {
            CLIInstallOfferSheet()
        }
    }

    #if DEBUG
    /// Debug-only: `-uiScreen <slug> [-uiTab branches] [-uiStyle list] [-uiLibrary branches|archived]` opens a
    /// screen at launch, so layout can be checked from screenshots alone.
    private func openLaunchScreen() {
        let defaults = UserDefaults.standard
        if let style = defaults.string(forKey: "uiStyle").flatMap(LibraryStyle.init(rawValue:)) { vm.libraryStyle = style }
        switch defaults.string(forKey: "uiLibrary") {
        case "branches": vm.showLibrary(.branches)
        case "archived": vm.showLibrary(.archived)
        default: break
        }
        guard let slug = defaults.string(forKey: "uiScreen") else { return }
        let id = vm.sites.first { $0.slug == slug }?.id ?? vm.envs.first { $0.envSlug == slug }?.id
        if let id { vm.openScreen(id, tab: defaults.string(forKey: "uiTab") == "branches" ? .branches : .overview) }
    }
    #endif

    @ViewBuilder
    private var detail: some View {
        if let route = vm.screen {
            SiteScreen(route: route)
                .id(route)
        } else if vm.library == .branches {
            BranchTable(site: nil)
                .navigationTitle("Branches")
                .navigationSubtitle("\(vm.activeEnvs.count) environments across \(Set(vm.activeEnvs.map(\.parentSiteID)).count) sites")
        } else {
            GalleryView(item: vm.library)
                .id(vm.library)
        }
    }

    /// macOS is refusing this app's connections to the container network, so every
    /// site and environment is unreachable. Deliberately NOT dismissible: it is a
    /// TCC decision, nothing in this app can clear it, and it disappears by itself
    /// within one reconcile tick of the user granting access.
    @ViewBuilder
    private var localNetworkBanner: some View {
        if vm.localNetworkDenied {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "network.slash")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("WP Container needs Local Network access")
                        .font(.callout.weight(.medium))
                    Text("macOS is blocking WP Container from reaching your containers, so sites and environments can’t load. Enable WP Container under Privacy & Security → Local Network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Open System Settings") { vm.openLocalNetworkSettings() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.red.opacity(0.4), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            .padding(16)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let err = vm.lastError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    vm.lastError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.orange.opacity(0.4), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            .padding(16)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Drop overlay

/// The dashed highlight shown while a file is dragged over a drop target.
struct ImportDropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Theme.accent.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8]))
            )
            .overlay {
                Label("Drop to import", systemImage: "arrow.down.doc.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.accent)
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .allowsHitTesting(false)
            .padding(8)
    }
}
