import SwiftUI
import WPContainerKit

/// Root window: a `NavigationSplitView` with the site sidebar and the detail
/// pane. Surfaces the onboarding screen when the container tooling isn't ready,
/// and shows `lastError` as a dismissible banner over the detail pane.
struct MainWindow: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 300)
        } detail: {
            detail
        }
        .sheet(isPresented: $vm.presentingAddSite) {
            AddSiteSheet()
        }
        .sheet(isPresented: $vm.presentingNewEnv) {
            if let site = vm.selectedSite {
                NewBranchEnvSheet(site: site)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let status = vm.systemStatus, !status.isReady {
            OnboardingView(status: status)
        } else if let site = vm.selectedSite {
            SiteDetailView(site: site)
                .id(site.id)
                .overlay(alignment: .top) { errorBanner }
        } else {
            ContentUnavailableView {
                Label("No Site Selected", systemImage: "square.stack.3d.up")
            } description: {
                Text("Select a site from the sidebar, or add a new one.")
            } actions: {
                Button("Add Site") { vm.presentingAddSite = true }
                    .buttonStyle(.borderedProminent)
            }
            .overlay(alignment: .top) { errorBanner }
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
