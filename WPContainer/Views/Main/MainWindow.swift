import AppKit
import SwiftUI
import WPContainerKit

/// The main window: a native split view. The sidebar picks a library list
/// (all sites, running, branches, a group); the detail shows it as a gallery
/// or a branch table, or one site's screen; the inspector on the right holds
/// every setting for the selection. Live metrics poll while this window is open.
struct MainWindow: View {
    @Environment(AppViewModel.self) private var vm

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
        .sheet(isPresented: $vm.presentingCLIInstallOffer) {
            CLIInstallOfferSheet()
        }
    }

    #if DEBUG
    /// Debug-only: `-uiScreen <slug> [-uiTab branches] [-uiStyle list]` opens a
    /// screen at launch, so layout can be checked from screenshots alone.
    private func openLaunchScreen() {
        let defaults = UserDefaults.standard
        if let style = defaults.string(forKey: "uiStyle").flatMap(LibraryStyle.init(rawValue:)) { vm.libraryStyle = style }
        if defaults.string(forKey: "uiLibrary") == "branches" { vm.showLibrary(.branches) }
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
                .navigationSubtitle("\(vm.envs.count) environments across \(Set(vm.envs.map(\.parentSiteID)).count) sites")
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
