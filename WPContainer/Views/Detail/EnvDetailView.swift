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
                    IdleStopCard(configured: env.idleStopMinutes, isEnv: true) { minutes in
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
            actionButton("Open", "safari") { SystemActions.openInBrowser(env.localURL) }
                .disabled(!env.status.isRunning)
            actionButton("WP Admin", "person.badge.key") { SystemActions.openInBrowser(env.adminURL) }
                .disabled(!env.status.isRunning)
            actionButton("Copy URL", "link") { SystemActions.copyToClipboard(env.localURL.absoluteString) }
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
                        Link(env.localURL.absoluteString, destination: env.localURL)
                        CopyButton(value: env.localURL.absoluteString)
                    }
                }
                // This URL is the reverse proxy's to serve: an environment's
                // container publishes no port of its own (issue #16
                // follow-through), so with nothing listening the link just
                // refuses — say so rather than letting it look broken.
                if vm.proxyPort == nil {
                    HStack(spacing: 6) {
                        Text("The reverse proxy serves this URL and isn’t running.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Button("Start Proxy") { Task { await vm.ensureProxyRunning() } }
                            .buttonStyle(.link).font(.caption2)
                    }
                }
                InfoRow(label: "Local port") {
                    Text(String(env.port)).monospaced()
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
            }
        }
    }

    // MARK: Danger zone

    private var dangerZone: some View {
        SectionCard(title: "Danger Zone", systemImage: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 12) {
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
