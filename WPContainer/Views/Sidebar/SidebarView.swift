import SwiftUI
import WPContainerKit

/// The sidebar: a list of sites (selection-bound to the app view model) with a
/// bottom-pinned prominent "Add Site" button, plus a friendly empty state.
struct SidebarView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm
        Group {
            if vm.sites.isEmpty {
                emptyState
            } else {
                List(selection: $vm.selection) {
                    Section("Sites") {
                        ForEach(vm.sites) { site in
                            SiteRow(site: site, envCount: vm.store.envs(forSite: site.id).count)
                                .tag(site.id)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .safeAreaInset(edge: .bottom) {
            addButton
        }
        .navigationTitle("WP Container")
    }

    private var addButton: some View {
        Button {
            vm.presentingAddSite = true
        } label: {
            Label("Add Site", systemImage: "plus")
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .padding(10)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.accent.gradient)
            Text("Create your first site")
                .font(.headline)
            Text("Spin up a local WordPress site running in an Apple container — the full install lives in a folder you can edit and version with git.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
