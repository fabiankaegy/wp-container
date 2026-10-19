import SwiftUI
import WPContainerKit

/// Every setting for one worktree environment: live stats, where it lives
/// (URL, port, branch, repo, paths, parent), auto-stop, and settle / restore /
/// delete. Delete keeps the git branch (optionally the worktree checkout too).
struct EnvInspector: View {
    @Environment(AppViewModel.self) private var vm
    let env: WorktreeEnv

    @State private var confirmingDelete = false
    @State private var keepWorktree = false
    /// Who holds this env's `127.0.0.1:<port>` socket — the proxy, somebody else,
    /// or nobody (issue #16 follow-through). Re-read on appear rather than computed
    /// inline: it touches the filesystem and probes a port.
    @State private var portOwnership: ProxyControl.EnvPortOwnership = .unknown

    private var parent: Site? { vm.store.site(id: env.parentSiteID) }

    var body: some View {
        InspectorStack {
            header
            if env.status.isRunning { LiveSection(id: env.id) }
            overviewCard
            if !env.isSettled {
                IdleStopCard(configured: env.idleStopMinutes, isEnv: true, envPort: env.port) { minutes in
                    vm.setIdleStop(env, minutes: minutes)
                }
            }
            dangerZone
        }
        // The proxy may have been started or killed by another process since
        // this view was built, and `vm.proxyPort` is only refreshed on request.
        .task(id: env.id) {
            vm.refreshProxyLiveness()
            portOwnership = ProxyControl.envPortOwnership(env.port)
        }
    }

    // MARK: Header

    private var header: some View {
        InspectorHeader(title: env.branch, monospacedTitle: true) {
            SectionIcon(systemName: "arrow.triangle.branch", color: .purple, size: 44)
        } subtitle: {
            if env.isSettled { SettledPill() } else { StatusPill(status: env.status) }
            if let parent { Text(parent.name) }
        } actions: {
            EnvRunButton(env: env)
            Button("Open") { SystemActions.openInBrowser(env.url) }
                .disabled(!env.status.isRunning)
            Button("WP Admin") { SystemActions.openInBrowser(env.adminURL) }
                .disabled(!env.status.isRunning)
            Spacer(minLength: 0)
            Menu {
                EnvMoreMenuItems(env: env)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
    }

    // MARK: Overview

    private var overviewCard: some View {
        SectionCard(title: "Environment", systemImage: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 10) {
                InfoRow(label: "URL") {
                    HStack(spacing: 6) {
                        Link(env.url.absoluteString, destination: env.url)
                        CopyButton(value: env.url.absoluteString)
                    }
                }
                // This URL is the reverse proxy's to serve: an environment's
                // container publishes no port of its own (issue #16
                // follow-through), so unless the proxy holds the socket the link
                // either refuses or — worse, and silently — reaches whatever else
                // took the port. Distinguish the two: only the first is fixed by
                // starting a proxy.
                switch portOwnership {
                case .noProxy:
                    HStack(spacing: 6) {
                        Text("The reverse proxy serves this URL and isn’t running.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Button("Start Proxy") {
                            Task {
                                await vm.ensureProxyRunning()
                                portOwnership = ProxyControl.envPortOwnership(env.port)
                            }
                        }
                        .buttonStyle(.link).font(.caption2)
                    }
                case .conflicted:
                    Text("The proxy is running but doesn’t own port \(env.port), so this URL "
                         + "and idle-stop aren’t being served. If this environment was started "
                         + "by an older build, stop and start it once; otherwise something else "
                         + "is holding the port.")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                case .owned, .unknown:
                    EmptyView()
                }
                // An env on its domain still answers on its loopback port too.
                if env.url != env.localURL {
                    InfoRow(label: "Local URL") {
                        HStack(spacing: 6) {
                            Text(env.localURL.absoluteString).foregroundStyle(.secondary).textSelection(.enabled)
                            CopyButton(value: env.localURL.absoluteString, help: "Copy local URL")
                        }
                    }
                }
                InfoRow(label: "Local port") {
                    Text(String(env.port)).monospaced()
                }
                InfoRow(label: "Last used") {
                    Text(EnvUsageText.lastUsed(env))
                        .foregroundStyle(EnvSettlement.isStale(env) ? .orange : .secondary)
                }
                InfoRow(label: "Branch") {
                    Text(env.branch).monospaced().textSelection(.enabled)
                }
                InfoRow(label: "Repository") {
                    Text(env.repoRelPath).monospaced().textSelection(.enabled)
                }
                InfoRow(label: "Worktree") {
                    HStack(spacing: 6) {
                        Text(env.worktreePath.path)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        CopyButton(value: env.worktreePath.path)
                    }
                }
                InfoRow(label: "Files") {
                    HStack(spacing: 6) {
                        Text(env.envPath.path)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        CopyButton(value: env.envPath.path)
                    }
                }
                if let parent {
                    InfoRow(label: "Parent site") {
                        Button(parent.name) { vm.openScreen(parent.id) }
                            .buttonStyle(.link)
                    }
                }
                InfoRow(label: "Image") {
                    Text(env.imageTag).monospaced().textSelection(.enabled)
                }
            }
        }
    }

    // MARK: Danger zone

    private var dangerZone: some View {
        SectionCard(title: "Danger Zone", systemImage: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 12) {
                if env.isSettled {
                    Text(EnvUsageText.settled(env))
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Restore") { vm.restoreEnv(env) }
                } else {
                    Text("Settling stops it and frees its port. Its checkout, files and database are kept until you restore it.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Settle") { vm.settleEnvs([env]) }
                }
                Divider().opacity(0.5)
                Text("Deleting stops its containers and removes the cloned files. The git branch is always kept.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: $keepWorktree) {
                    Text("Keep the worktree checkout on disk")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                .foregroundStyle(.secondary)
                Button("Delete Environment…", role: .destructive) { confirmingDelete = true }
                    .tint(.red)
            }
        }
        .confirmationDialog("Delete environment \"\(env.branch)\"?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Environment", role: .destructive) {
                vm.deleteEnv(env, keepWorktree: keepWorktree)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(keepWorktree
                 ? "Removes containers and cloned files; the worktree checkout and the branch \(env.branch) are kept."
                 : "Removes containers, cloned files and the worktree checkout. The branch \(env.branch) is kept.")
        }
    }
}

/// Start / Stop for an env; a settled env offers Restore instead.
struct EnvRunButton: View {
    @Environment(AppViewModel.self) private var vm
    let env: WorktreeEnv

    var body: some View {
        if env.isSettled {
            Button("Restore", systemImage: "arrow.uturn.backward") { vm.restoreEnv(env) }
                .buttonStyle(.borderedProminent)
        } else if env.status.isTransitional {
            Button {} label: {
                HStack(spacing: 5) { ProgressView().controlSize(.mini); Text(env.status.label) }
            }
            .disabled(true)
        } else if env.status.isRunning {
            Button("Stop", systemImage: "stop.fill") { vm.stopEnv(env) }
        } else {
            Button("Start", systemImage: "play.fill") { vm.startEnv(env) }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Secondary env actions for the inspector's ••• menu and context menus.
struct EnvMoreMenuItems: View {
    let env: WorktreeEnv

    var body: some View {
        Button("Copy URL", systemImage: "link") { SystemActions.copyToClipboard(env.url.absoluteString) }
        Button("Reveal in Finder", systemImage: "folder") { SystemActions.revealInFinder(env.envPath) }
        // Envs open the worktree checkout — that's the branch you edit.
        OpenInSubmenu(folder: env.worktreePath)
    }
}
