import SwiftUI
import WPContainerKit

/// Root window, Studio-style: a DARK FRAME (near-black shell spanning the whole
/// window, including the sidebar and the hidden-title-bar band) with the detail
/// content floating inside it as a light, rounded, inset panel. The top band is
/// left free of controls so the window stays draggable there.
struct MainWindow: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm
        ZStack(alignment: .topLeading) {
            Theme.frame.ignoresSafeArea()

            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 272)

                panel
                    .padding(.top, 10)
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
            }
        }
        .sheet(isPresented: $vm.presentingAddSite) {
            AddSiteSheet()
        }
        .sheet(isPresented: $vm.presentingNewEnv) {
            if let site = vm.selectedSite {
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

    // MARK: Floating light panel

    private var panel: some View {
        detail
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.panelBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .top) { errorBanner }
            .shadow(color: .black.opacity(0.28), radius: 12, y: 3)
    }

    @ViewBuilder
    private var detail: some View {
        if let status = vm.systemStatus, !status.isReady {
            OnboardingView(status: status)
        } else if let site = vm.selectedSite {
            SiteDetailView(site: site)
                .id(site.id)
        } else if let env = vm.selectedEnv {
            // Worktree-env rows are selectable in the sidebar (§2b) and get a
            // compact detail pane of their own.
            EnvDetailView(env: env)
                .id(env.id)
        } else {
            ContentUnavailableView {
                Label("No Site Selected", systemImage: "square.stack.3d.up")
            } description: {
                Text("Select a site from the sidebar, or add a new one.")
            } actions: {
                Button("Add Site") { vm.presentingAddSite = true }
                    .buttonStyle(.borderedProminent)
            }
            // Fill the panel and center: the enclosing `panel` frame pins its
            // content to `.topLeading` (correct for the scrolling site detail),
            // which otherwise strands this placeholder at the very top. Expanding
            // to fill makes the placeholder own the whole panel and center within.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
