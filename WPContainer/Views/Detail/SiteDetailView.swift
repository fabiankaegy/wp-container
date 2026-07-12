import SwiftUI
import WPContainerKit

/// The site detail panel, Studio-style: a header (avatar, name, status pill,
/// Start/Stop), a quiet action bar, then a compact underlined tab bar
/// (Overview / Logs / Settings) whose content scrolls below it.
struct SiteDetailView: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site

    @State private var tab: DetailTab = .overview
    @State private var confirmingDelete = false
    @State private var trashFolder = true

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                header
                actionBar
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 14)

            PanelTabBar(selection: $tab)
                .padding(.horizontal, 24)

            Divider().opacity(0.6)

            ScrollView {
                content
                    .padding(26)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Tab content

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .overview:
            VStack(alignment: .leading, spacing: 18) {
                OverviewCard(site: site)
                BranchesCard(site: site)
            }
        case .logs:
            LogsView(site: site)
        case .settings:
            VStack(alignment: .leading, spacing: 18) {
                IntegrationsCard(site: site)
                dangerZone
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            SiteAvatar(name: site.name, slug: site.slug, size: 48)
            VStack(alignment: .leading, spacing: 6) {
                Text(site.name)
                    .font(.system(.largeTitle, weight: .bold))
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
            actionButton("Open Site", "safari") { SystemActions.openInBrowser(site.url) }
                .disabled(!site.status.isRunning)
            actionButton("WP Admin", "person.badge.key") { SystemActions.openInBrowser(site.wpAdminURL) }
                .disabled(!site.status.isRunning)
            actionButton("Finder", "folder") { SystemActions.revealInFinder(site.path) }
            actionButton("Terminal", "terminal") { SystemActions.openTerminal(at: site.path) }
            actionButton("WP-CLI", "command") { vm.openWPCLI(site) }
                .disabled(!site.status.isRunning)
            actionButton("Copy URL", "link") { SystemActions.copyToClipboard(site.url.absoluteString) }
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

    // MARK: Danger zone (Settings tab)

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

// MARK: - Tabs

/// The tabs hosted in the site detail panel. `Settings` is where the danger zone
/// lives, and where per-site toggles (HTTPS, agent tools, add-ons) are added.
enum DetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case logs = "Logs"
    case settings = "Settings"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "info.circle"
        case .logs:     return "text.alignleft"
        case .settings: return "gearshape"
        }
    }
}

/// Studio-style compact text tabs with a sliding underline for the active tab.
struct PanelTabBar: View {
    @Binding var selection: DetailTab
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 4) {
            ForEach(DetailTab.allCases) { tab in
                tabButton(tab)
            }
            Spacer()
        }
    }

    private func tabButton(_ tab: DetailTab) -> some View {
        let active = selection == tab
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { selection = tab }
        } label: {
            VStack(spacing: 7) {
                Label(tab.rawValue, systemImage: tab.symbol)
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                    .padding(.horizontal, 8)
                ZStack {
                    Capsule().fill(Color.clear).frame(height: 2)
                    if active {
                        Capsule().fill(Theme.accent)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "underline", in: underline)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
