import SwiftUI
import WPContainerKit

/// The dark sidebar: a compact brand header (kept clear of the traffic lights),
/// a scrollable list of sites with rounded selection/hover highlights, and a
/// prominent bottom-pinned "Add Site" button. Rendered transparently over the
/// window's dark frame.
struct SidebarView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        VStack(spacing: 0) {
            brand
            if vm.sites.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(vm.sites) { site in
                            SidebarSiteRow(site: site)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                }
            }
            addButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Brand

    private var brand: some View {
        HStack(spacing: 8) {
            Image(systemName: "cube.transparent.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("WP Container")
                .font(.headline)
                .foregroundStyle(Theme.onFrame)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, Theme.titlebarInset + 8)
        .padding(.bottom, 12)
    }

    // MARK: Add button

    private var addButton: some View {
        VStack(spacing: 0) {
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
        }
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

/// A selectable, hover-highlighted site row wired to the app selection.
struct SidebarSiteRow: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site

    @State private var hovering = false

    private var isSelected: Bool { vm.selection == site.id }

    var body: some View {
        SiteRow(site: site, envCount: vm.store.envs(forSite: site.id).count)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Theme.sidebarSelection
                          : (hovering ? Theme.sidebarHover : Color.clear))
            )
            .onHover { hovering = $0 }
            .onTapGesture { vm.selection = site.id }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}
