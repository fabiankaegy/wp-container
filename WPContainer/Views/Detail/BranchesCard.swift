import SwiftUI
import WPContainerKit

/// The worktree-environments feature (PLAN §2b): lists this site's branch envs
/// with per-row actions, a header button to create a new one, and an empty
/// state that also teaches the equivalent `wp-container` CLI command (a target
/// audience is coding agents).
///
/// Active envs come first, with a banner suggesting to settle the ones unused
/// for `EnvSettlement.suggestAfterDays`. Settled envs sit in a collapsed
/// section at the bottom, where they can be restored or deleted.
struct BranchesCard: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site
    @State private var showingSettled = false

    private var envs: [WorktreeEnv] { vm.store.envs(forSite: site.id) }
    private var active: [WorktreeEnv] { envs.filter { !$0.isSettled } }
    private var settled: [WorktreeEnv] {
        envs.filter(\.isSettled).sorted { ($0.settledAt ?? .distantPast) > ($1.settledAt ?? .distantPast) }
    }
    private var stale: [WorktreeEnv] { active.filter { EnvSettlement.isStale($0) } }

    var body: some View {
        SectionCard(title: "Branches", systemImage: "arrow.triangle.branch") {
            Button {
                vm.presentingNewEnv = true
            } label: {
                Label("New Branch Environment…", systemImage: "plus")
            }
            .controlSize(.small)
        } content: {
            if envs.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if !stale.isEmpty {
                        staleBanner.padding(.bottom, 8)
                    }
                    ForEach(Array(active.enumerated()), id: \.element.id) { index, env in
                        if index > 0 { Divider() }
                        EnvRow(env: env)
                    }
                    if active.isEmpty {
                        Text("No active environments.")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    if !settled.isEmpty {
                        Divider()
                        DisclosureGroup(isExpanded: $showingSettled) {
                            VStack(spacing: 0) {
                                ForEach(Array(settled.enumerated()), id: \.element.id) { index, env in
                                    if index > 0 { Divider() }
                                    EnvRow(env: env)
                                }
                            }
                        } label: {
                            Text("Settled (\(settled.count))")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)
                    }
                }
            }
        }
    }

    private var staleBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(stale.count == 1
                     ? "1 environment unused for \(EnvSettlement.suggestAfterDays)+ days"
                     : "\(stale.count) environments unused for \(EnvSettlement.suggestAfterDays)+ days")
                    .font(.callout.weight(.medium))
                Text("Settling stops them and frees their ports. Their checkouts, files and databases are kept.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(stale.count == 1 ? "Settle" : "Settle All") { vm.settleEnvs(stale) }
                .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Spin up an isolated, throwaway copy of this site for any git branch of a plugin or theme in its `wp-content` — running on its own port, in seconds.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            CLISnippet(command: "wp-container worktree create --site \(site.slug) --repo <path> --branch <name> --json")
        }
    }
}

/// One worktree-env row: branch, how recently it was used (or when it was
/// settled), status dot, and per-row actions.
private struct EnvRow: View {
    @Environment(AppViewModel.self) private var vm
    let env: WorktreeEnv
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: env.isSettled ? "archivebox" : "arrow.triangle.branch")
                .foregroundStyle(env.isSettled ? Color.secondary : Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(env.branch).font(.body.weight(.medium)).lineLimit(1)
                    .foregroundStyle(env.isSettled ? .secondary : .primary)
                HStack(spacing: 0) {
                    Text("\(env.repoRelPath) · ")
                    Text(env.isSettled ? EnvUsageText.settled(env) : EnvUsageText.lastUsed(env))
                        .foregroundStyle(EnvSettlement.isStale(env) ? Color.orange : Color.secondary)
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !env.isSettled { StatusDot(status: env.status) }

            HStack(spacing: 2) {
                if env.isSettled {
                    iconButton("arrow.uturn.backward", help: "Restore — get a port back and start it") {
                        vm.restoreEnv(env)
                    }
                } else {
                    iconButton("safari", help: "Open in browser") {
                        SystemActions.openInBrowser(env.url)
                    }
                    .disabled(!env.status.isRunning)

                    if env.status.isRunning {
                        iconButton("stop.fill", help: "Stop") { vm.stopEnv(env) }
                    } else {
                        iconButton("play.fill", help: "Start") { vm.startEnv(env) }
                            .disabled(env.status.isTransitional)
                    }

                    iconButton("archivebox", help: "Settle — stop it and free its port, keeping its data") {
                        vm.settleEnvs([env])
                    }
                    .disabled(env.status.isTransitional)
                }

                iconButton("trash", help: "Delete environment", tint: .red) {
                    confirmingDelete = true
                }
            }
        }
        .padding(.vertical, 8)
        .confirmationDialog("Delete environment \"\(env.branch)\"?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { vm.deleteEnv(env) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stops its containers and removes the git worktree and cloned files. The branch itself is kept.")
        }
    }

    private func iconButton(_ symbol: String, help: String, tint: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 22)
                .foregroundStyle(tint)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// A monospaced command snippet with a copy button.
struct CLISnippet: View {
    let command: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            CopyButton(value: command, help: "Copy command")
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
