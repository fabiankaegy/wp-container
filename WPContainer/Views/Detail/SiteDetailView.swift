import SwiftUI
import WPContainerKit

/// The full site detail pane: header with status pill + Start/Stop, a quiet
/// action bar, and stacked cards (Overview, Branches, Logs, Danger zone).
struct SiteDetailView: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site

    @State private var confirmingDelete = false
    @State private var trashFolder = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                actionBar
                OverviewCard(site: site)
                BranchesCard(site: site)
                LogsView(site: site)
                dangerZone
            }
            .padding(22)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            SiteAvatar(name: site.name, slug: site.slug, size: 52)
            VStack(alignment: .leading, spacing: 6) {
                Text(site.name)
                    .font(.largeTitle.bold())
                    .lineLimit(1)
                StatusPill(status: site.status)
            }
            Spacer()
            startStopButton
        }
    }

    @ViewBuilder
    private var startStopButton: some View {
        if site.status.isRunning {
            Button {
                vm.stopSite(site)
            } label: {
                Label("Stop", systemImage: "stop.fill").frame(minWidth: 68)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .tint(.red)
        } else {
            Button {
                vm.startSite(site)
            } label: {
                if site.status.isTransitional {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(site.status.label)
                    }
                    .frame(minWidth: 68)
                } else {
                    Label("Start", systemImage: "play.fill").frame(minWidth: 68)
                }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(site.status.isTransitional)
        }
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 8) {
            actionButton("Open Site", "safari") { SystemActions.openInBrowser(site.localURL) }
                .disabled(!site.status.isRunning)
            actionButton("WP Admin", "person.badge.key") { SystemActions.openInBrowser(site.adminURL) }
                .disabled(!site.status.isRunning)
            actionButton("Finder", "folder") { SystemActions.revealInFinder(site.path) }
            actionButton("Terminal", "terminal") { SystemActions.openTerminal(at: site.path) }
            actionButton("Copy URL", "link") { SystemActions.copyToClipboard(site.localURL.absoluteString) }
            Spacer()
        }
    }

    private func actionButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    // MARK: Danger zone

    private var dangerZone: some View {
        SectionCard(title: "Danger Zone", systemImage: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delete this site").font(.callout.weight(.medium))
                        Text("Stops and removes its containers.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Delete Site…", role: .destructive) { confirmingDelete = true }
                        .buttonStyle(.bordered)
                        .tint(.red)
                }
                Toggle(isOn: $trashFolder) {
                    Text("Also move the site folder to the Trash")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Delete \"\(site.name)\"?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(trashFolder ? "Delete Site & Move Folder to Trash" : "Delete Site", role: .destructive) {
                vm.deleteSite(site, trashFolder: trashFolder)
                if vm.selection == site.id { vm.selection = nil }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(trashFolder
                 ? "This removes the site's containers and moves \(site.path.lastPathComponent) to the Trash."
                 : "This removes the site's containers. The site folder is left on disk.")
        }
    }
}
