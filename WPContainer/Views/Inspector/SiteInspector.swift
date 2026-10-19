import SwiftUI
import WPContainerKit

/// Every setting for one site, as foldable sections: live stats, branches,
/// overview, development add-ons, software, domain, resources, auto-stop,
/// integrations and the danger zone.
struct SiteInspector: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site

    var body: some View {
        InspectorStack {
            header
            if site.status.isRunning { LiveSection(id: site.id) }
            // The site's own Overview already shows its branches.
            if vm.screen?.id != site.id { BranchesSummary(site: site) }
            OverviewCard(site: site)
            if site.networkType.isMultisite { SubsitesCard(site: site) }
            DevelopmentCard(site: site)
            SoftwareCard(site: site)
            DomainCard(site: site)
            ResourcesCard(site: site)
            IdleStopCard(configured: site.idleStopMinutes, isEnv: false) { minutes in
                vm.setIdleStop(site, minutes: minutes)
            }
            IntegrationsCard(site: site)
            SiteDangerZone(site: site)
        }
    }

    private var header: some View {
        InspectorHeader(title: site.name) {
            SiteAvatar(name: site.name, slug: site.slug, size: 44,
                       wordpressFolder: site.wordpressFolder, reloadToken: site.status)
        } subtitle: {
            StatusPill(status: site.status)
            Text(site.displayHost)
        } actions: {
            SiteRunButton(site: site)
            Button("Open") { SystemActions.openInBrowser(site.url) }
                .disabled(!site.status.isRunning)
            Button("WP Admin") { SystemActions.openInBrowser(site.wpAdminURL) }
                .disabled(!site.status.isRunning)
            Spacer(minLength: 0)
            Menu {
                SiteMoreMenuItems(site: site)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
    }
}

/// Start / Stop for a site. With branch environments, Start also offers
/// starting them together (opt-in fan-out, issue #18).
struct SiteRunButton: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site

    var body: some View {
        if site.status.isTransitional {
            Button {} label: {
                HStack(spacing: 5) { ProgressView().controlSize(.mini); Text(site.status.label) }
            }
            .disabled(true)
        } else if site.status.isRunning {
            Button("Stop", systemImage: "stop.fill") { vm.stopSite(site) }
        } else if !vm.store.envs(forSite: site.id).filter({ !$0.isSettled }).isEmpty {
            Menu {
                Button("Start with Branch Environments", systemImage: "play.fill") { vm.startSiteWithEnvs(site) }
            } label: {
                Label("Start", systemImage: "play.fill")
            } primaryAction: {
                vm.startSite(site)
            }
            .fixedSize()
            .buttonStyle(.borderedProminent)
        } else {
            Button("Start", systemImage: "play.fill") { vm.startSite(site) }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// The secondary site actions shared by the inspector's ••• menu, the
/// toolbar and context menus.
struct SiteMoreMenuItems: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site

    var body: some View {
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
    }
}

/// Branch environment counts for a site, with the actions that matter when a
/// site has dozens of them: open the full table, or settle the stale ones.
private struct BranchesSummary: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site

    var body: some View {
        let envs = vm.store.envs(forSite: site.id)
        let stale = envs.filter { EnvSettlement.isStale($0) }
        SectionCard(title: "Branches", systemImage: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 10) {
                if envs.isEmpty {
                    Text("Run any git branch of a plugin or theme in its own copy of this site.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 6) {
                        count(envs.filter { $0.status.isRunning }.count, "Running", .green)
                        count(envs.filter { !$0.isSettled }.count, "Active", .blue)
                        count(stale.count, "Stale", .orange)
                        count(envs.filter(\.isSettled).count, "Settled", .gray)
                    }
                }
                FlowLayout(spacing: 6) {
                    if !envs.isEmpty {
                        Button("Show All Branches") { vm.openScreen(site.id, tab: .branches) }
                    }
                    if !stale.isEmpty {
                        Button("Settle \(stale.count) Stale") { vm.settleEnvs(stale) }
                            .help("Stops them and frees their ports. Checkouts, files and databases are kept.")
                    }
                    Button("New Branch…") {
                        vm.selection = site.id
                        vm.presentingNewEnv = true
                    }
                }
            }
        }
    }

    private func count(_ n: Int, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(n)").font(.callout.weight(.bold)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Delete a site, optionally trashing its folder.
private struct SiteDangerZone: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site
    @State private var confirmingDelete = false
    @State private var trashFolder = true

    var body: some View {
        SectionCard(title: "Danger Zone", systemImage: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Stops and removes the site's containers.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Also move the site folder to the Trash", isOn: $trashFolder)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Button("Delete Site…", role: .destructive) { confirmingDelete = true }
                    .tint(.red)
            }
        }
        .confirmationDialog("Delete \"\(site.name)\"?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(trashFolder ? "Delete Site & Move Folder to Trash" : "Delete Site", role: .destructive) {
                vm.deleteSite(site, trashFolder: trashFolder)
                if vm.selection == site.id { vm.selection = nil }
                if vm.screen?.id == site.id { vm.showLibrary(vm.library) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(trashFolder
                 ? "This removes the site's containers and moves \(site.path.lastPathComponent) to the Trash."
                 : "This removes the site's containers. The site folder is left on disk.")
        }
    }
}
