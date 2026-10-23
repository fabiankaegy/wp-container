import SwiftUI
import WPContainerKit

/// Compact detail pane for a worktree environment (PLAN.md §2b): header with
/// branch + status + Start/Stop, an action bar (Open / WP Admin / Copy URL /
/// Finder), an overview card (URL, port, branch, repo, paths, parent), live
/// logs, and a danger zone whose delete keeps the git branch (optionally the
/// worktree checkout too).
struct EnvDetailView: View {
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
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                header
                actionBar
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 18)

            Divider().opacity(0.6)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    overviewCard
                    IdleStopCard(configured: env.idleStopMinutes, isEnv: true, envPort: env.port) { minutes in
                        vm.setIdleStop(env, minutes: minutes)
                    }
                    LogsView(env: env)
                    dangerZone
                }
                .padding(26)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Same pattern as IntegrationsCard: the proxy may have been started or
        // killed by another process since this view was built, and `vm.proxyPort`
        // is only refreshed when somebody asks.
        .task(id: env.id) {
            vm.refreshProxyLiveness()
            portOwnership = ProxyControl.envPortOwnership(env.port)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            // Branch glyph avatar — deliberately NOT the site avatar, so envs
            // read as clones, echoing the sidebar's branch rows.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.accent.opacity(0.14))
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(env.branch)
                        .font(.system(.largeTitle, weight: .bold))
                        .lineLimit(1)
                    if let parent {
                        Text("· \(parent.name)")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                StatusPill(status: env.status)
            }
            Spacer()
            startStopButton
        }
    }

    @ViewBuilder
    private var startStopButton: some View {
        if env.status.isRunning {
            Button {
                vm.stopEnv(env)
            } label: {
                Label("Stop", systemImage: "stop.fill").frame(minWidth: 68)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .tint(.red)
        } else {
            Button {
                vm.startEnv(env)
            } label: {
                if env.status.isTransitional {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(env.status.label)
                    }
                    .frame(minWidth: 68)
                } else {
                    Label("Start", systemImage: "play.fill").frame(minWidth: 68)
                }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(env.status.isTransitional)
        }
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 8) {
            actionButton("Open", "safari") { SystemActions.openInBrowser(env.url) }
                .disabled(!env.status.isRunning)
            actionButton("WP Admin", "person.badge.key") { SystemActions.openInBrowser(env.adminURL) }
                .disabled(!env.status.isRunning)
            actionButton("Copy URL", "link") { SystemActions.copyToClipboard(env.url.absoluteString) }
            actionButton("Finder", "folder") { SystemActions.revealInFinder(env.envPath) }
            // Envs open the worktree checkout — that's the branch you edit.
            OpenInButton(folder: env.worktreePath)
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
                        Button(parent.name) { vm.selection = parent.id }
                            .buttonStyle(.link)
                    }
                }
                InfoRow(label: "Image") {
                    Text(env.imageTag).monospaced().textSelection(.enabled)
                }
                InfoRow(label: "Web server") {
                    Text(env.webServer.label).textSelection(.enabled)
                }
            }
        }
    }

    // MARK: Danger zone

    private var dangerZone: some View {
        SectionCard(title: "Danger Zone", systemImage: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Settle this environment").font(.callout.weight(.medium))
                        Text("Stops it and frees its port. Its checkout, files and database are kept until you restore it from the site’s Branches card.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Settle") { vm.settleEnvs([env]) }
                        .buttonStyle(.bordered)
                }
                Divider().opacity(0.5)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delete this environment").font(.callout.weight(.medium))
                        Text("Stops its containers and removes the cloned files. The git branch is always kept.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Delete Environment…", role: .destructive) { confirmingDelete = true }
                        .buttonStyle(.bordered)
                        .tint(.red)
                }
                Toggle(isOn: $keepWorktree) {
                    Text("Keep the worktree checkout on disk")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                .foregroundStyle(.secondary)
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
