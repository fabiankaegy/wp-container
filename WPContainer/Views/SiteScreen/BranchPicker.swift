import SwiftUI
import WPContainerKit

/// The toolbar's branch switcher (⌃⌘B): type to filter. Running branch
/// environments first, then recently used ones; settled ones appear only when
/// searching, so dozens of envs stay one keystroke away.
struct BranchPicker: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site
    /// The env being shown, or nil for the main site.
    let current: WorktreeEnv?

    @State private var query = ""
    @FocusState private var focused: Bool

    private let recentLimit = 8

    var body: some View {
        let envs = vm.store.envs(forSite: site.id)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let match: (WorktreeEnv) -> Bool = { q.isEmpty || $0.branch.lowercased().contains(q) || $0.repoRelPath.lowercased().contains(q) }
        let running = envs.filter { ($0.status.isRunning || $0.status.isTransitional) && match($0) }
        let recent = envs.filter { !$0.isSettled && !$0.status.isRunning && !$0.status.isTransitional && match($0) }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
        let settled = q.isEmpty ? [] : envs.filter { $0.isSettled && match($0) }
        let firstMatch = (q.isEmpty || "main".contains(q)) ? nil : (running + recent + settled).first

        VStack(alignment: .leading, spacing: 0) {
            TextField("Find a Branch", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit {
                    if let firstMatch { go(firstMatch.id) } else { go(site.id) }
                }
                .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if q.isEmpty || "main".contains(q) || site.name.lowercased().contains(q) {
                        row(isCurrent: current == nil, action: { go(site.id) }) {
                            StatusDot(status: site.status, size: 7)
                            Text("Main Site")
                            Spacer()
                            Text(site.displayHost).foregroundStyle(.tertiary)
                        }
                    }
                    section("Running", running)
                    section("Recently Used", q.isEmpty ? Array(recent.prefix(recentLimit)) : recent)
                    if q.isEmpty, recent.count > recentLimit {
                        Button("Show All \(envs.count) in Branches…") { vm.openScreen(site.id, tab: .branches) }
                            .buttonStyle(.link)
                            .font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    section("Settled", settled)
                    if !q.isEmpty, running.isEmpty, recent.isEmpty, settled.isEmpty {
                        Text("No branch matches “\(query)”.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(16)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 380)
        }
        .frame(width: 320)
        .onAppear { focused = true }
    }

    @ViewBuilder
    private func section(_ title: String, _ envs: [WorktreeEnv]) -> some View {
        if !envs.isEmpty {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
            ForEach(envs) { env in
                row(isCurrent: current?.id == env.id, action: { go(env.id) }) {
                    if env.isSettled {
                        Image(systemName: "archivebox").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        StatusDot(status: env.status, size: 7)
                    }
                    Text(env.branch).font(.system(.callout, design: .monospaced)).lineLimit(1)
                    if EnvSettlement.isStale(env) { Circle().fill(.orange).frame(width: 6, height: 6) }
                    Spacer()
                    Text(env.status.isRunning ? ":\(env.port)" : env.isSettled ? "settled" : env.lastUsedAt.formatted(.relative(presentation: .named)))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func row(isCurrent: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> some View) -> some View {
        Button(action: action) {
            HStack(spacing: 8) { content() }
                .fontWeight(isCurrent ? .semibold : .regular)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(PickerRowStyle())
    }

    private func go(_ id: UUID) {
        vm.presentingBranchPicker = false
        if id == site.id, current == nil { return }
        vm.openScreen(id)
    }
}

/// A list row that highlights on hover like a menu item.
private struct PickerRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverHighlight(pressed: configuration.isPressed) { configuration.label }
    }
}

private struct HoverHighlight<Content: View>: View {
    let pressed: Bool
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering || pressed ? Color.accentColor.opacity(0.18) : .clear))
            .onHover { hovering = $0 }
    }
}
