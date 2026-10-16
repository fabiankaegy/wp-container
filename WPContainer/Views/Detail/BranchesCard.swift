import SwiftUI
import WPContainerKit

/// The worktree-environments feature (PLAN §2b): lists this site's branch envs
/// with per-row actions, a header button to create a new one, and an empty
/// state that also teaches the equivalent `wp-container` CLI command (a target
/// audience is coding agents).
struct BranchesCard: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site

    private var envs: [WorktreeEnv] { vm.store.envs(forSite: site.id) }

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
                VStack(spacing: 0) {
                    ForEach(Array(envs.enumerated()), id: \.element.id) { index, env in
                        if index > 0 { Divider() }
                        EnvRow(env: env)
                    }
                }
            }
        }
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

/// One worktree-env row: branch, status dot, port, and per-row actions.
private struct EnvRow: View {
    @Environment(AppViewModel.self) private var vm
    let env: WorktreeEnv
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(env.branch).font(.body.weight(.medium)).lineLimit(1)
                Text("\(env.repoRelPath) · localhost:\(String(env.port))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            StatusDot(status: env.status)

            HStack(spacing: 2) {
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
