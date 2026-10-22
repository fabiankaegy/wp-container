import SwiftUI
import WPContainerKit

/// The menu bar extra popover (PLAN.md §2h): a compact list of every site plus
/// any running worktree environments, each with a status dot, name, port
/// subtitle, and an inline start/stop control. Clicking a row (not the control)
/// focuses the main window with that site selected. A footer offers "Open WP
/// Container" and "Quit". Start/stop reuse the same AppViewModel actions the
/// sidebar uses — no new logic paths.
struct MenuBarContent: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(\.openWindow) private var openWindow

    private var runningEnvs: [WorktreeEnv] { vm.envs.filter { $0.status.isRunning } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // The menu bar is the only surface when the main window is closed, and
            // while this is true nothing in the list below can be opened at all.
            if vm.localNetworkDenied {
                localNetworkWarning
                Divider()
            }
            if vm.sites.isEmpty {
                emptyState
            } else if rowCount <= 9 {
                // Plain VStack so the popover window sizes to the content.
                // (A ScrollView with `.frame(maxHeight:)` collapses to ZERO
                // height inside a MenuBarExtra window — its ideal height is
                // not derived from the content there, which rendered the list
                // invisible while header/footer still showed.)
                list
            } else {
                // Long lists: scroll inside an EXPLICIT height (never maxHeight,
                // see above).
                ScrollView {
                    list
                }
                .frame(height: 380)
            }
            Divider()
            footer
        }
        .frame(width: 300)
    }

    /// Row-ish units used to decide between intrinsic sizing and scrolling.
    private var rowCount: Int {
        var count = vm.sites.count + runningEnvs.count
        count += vm.store.sortedGroups.filter { group in
            vm.sites.contains { $0.groupID == group.id }
        }.count
        return count
    }

    /// The site/env list itself (shared by the intrinsic and scrolling layouts).
    /// Running worktree envs are nested directly under their parent site with a
    /// small indent + branch glyph (§2b), mirroring the sidebar's nesting.
    private var list: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Ungrouped sites first.
            ForEach(vm.sites.filter { $0.groupID == nil }) { site in
                siteBlock(site)
            }
            // Grouped sites, in sidebar order, with tiny headers.
            ForEach(vm.store.sortedGroups) { group in
                let sites = vm.sites.filter { $0.groupID == group.id }
                if !sites.isEmpty {
                    sectionHeader(group.name)
                    ForEach(sites) { site in
                        siteBlock(site)
                    }
                }
            }
        }
        .padding(6)
    }

    /// One site row plus its running envs nested/indented underneath.
    @ViewBuilder
    private func siteBlock(_ site: Site) -> some View {
        SiteMenuRow(site: site, focus: focusMainWindow)
        ForEach(runningEnvs.filter { $0.parentSiteID == site.id }) { env in
            EnvMenuRow(env: env, focus: focusMainWindow)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("WP Container").font(.headline)
            Spacer()
            let running = vm.sites.filter { $0.status.isRunning }.count
            Text("\(running)/\(vm.sites.count) running")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var localNetworkWarning: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Local Network access is off", systemImage: "network.slash")
                .font(.callout.weight(.medium))
                .foregroundStyle(.red)
            Text("macOS is blocking WP Container from reaching your containers, so no site will load.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings…") { vm.openLocalNetworkSettings() }
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8).padding(.bottom, 2)
    }

    private var footer: some View {
        HStack {
            Button("Open WP Container") { focusMainWindow(select: nil) }
                .buttonStyle(.link)
            Spacer()
            Button("Help") { openWindow(id: "help") }
                .buttonStyle(.link)
                .foregroundStyle(.secondary)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.link)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No sites yet").font(.callout).foregroundStyle(.secondary)
            Button("Add a Site…") { vm.presentingAddSite = true; focusMainWindow(select: nil) }
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
    }

    /// Bring the main window forward, optionally selecting a site.
    private func focusMainWindow(select siteID: UUID?) {
        if let siteID { vm.selection = siteID }
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Order an existing content window front, or open one if it was closed.
        if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain && $0.contentView != nil && $0.styleMask.contains(.titled) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}

/// One site row in the menu bar popover.
private struct SiteMenuRow: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site
    let focus: (UUID?) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            StatusDot(status: site.status, size: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(site.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(site.displayHost)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if vm.isShareLive(site.id) {
                Image(systemName: "link")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Shared")
            }
            RunControl(status: site.status,
                       start: { vm.startSite(site) },
                       stop: { vm.stopSite(site) })
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { focus(site.id) }
    }
}

/// One running worktree-env row in the menu bar popover: indented under its
/// parent site with a branch glyph (§2b). Clicking focuses the env's detail
/// pane in the main window.
private struct EnvMenuRow: View {
    @Environment(AppViewModel.self) private var vm
    let env: WorktreeEnv
    let focus: (UUID?) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            StatusDot(status: env.status, size: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(env.branch)
                    .font(.footnote.weight(.medium)).lineLimit(1)
                Text("localhost:\(String(env.port))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if vm.isShareLive(env.id) {
                Image(systemName: "link")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Shared")
            }
            RunControl(status: env.status,
                       start: { vm.startEnv(env) },
                       stop: { vm.stopEnv(env) })
        }
        .padding(.vertical, 4)
        .padding(.trailing, 8)
        .padding(.leading, 8)
        // Nest under the parent row.
        .padding(.leading, 18)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(hovering ? Color.primary.opacity(0.06) : .clear)
            .padding(.leading, 18))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { focus(env.id) }
    }
}

/// A compact inline start/stop control that shows a spinner during transitions.
private struct RunControl: View {
    let status: SiteStatus
    let start: () -> Void
    let stop: () -> Void

    var body: some View {
        if status.isTransitional {
            ProgressView().controlSize(.small).frame(width: 22)
        } else if status.isRunning {
            iconButton("stop.fill", tint: .red, help: "Stop", action: stop)
        } else {
            iconButton("play.fill", tint: Theme.accent, help: "Start", action: start)
        }
    }

    private func iconButton(_ symbol: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
