import SwiftUI
import WPContainerKit

/// Live streaming container logs with a wp/db picker, follow toggle, and clear
/// button. The stream lifecycle is tied to view appearance and cancelled on
/// disappear (or when the picker/follow/instance changes) by
/// `SiteDetailViewModel`. Serves both sites and worktree envs — anything with
/// wp/db container names (§2b env detail pane).
struct LogsView: View {
    @Environment(AppViewModel.self) private var appVM
    /// Stable identity of the shown instance (site or env id).
    let instanceID: UUID
    let wpContainer: String
    let dbContainer: String

    init(site: Site) {
        self.instanceID = site.id
        self.wpContainer = site.wpContainerName
        self.dbContainer = site.dbContainerName
    }

    init(env: WorktreeEnv) {
        self.instanceID = env.id
        self.wpContainer = env.wpContainerName
        self.dbContainer = env.dbContainerName
    }

    @State private var model: SiteDetailViewModel?

    var body: some View {
        SectionCard(title: "Logs", systemImage: "text.alignleft") {
            if let model { controls(model) }
        } content: {
            if let model {
                logBody(model)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .task(id: instanceID) {
            let m = model ?? SiteDetailViewModel(cli: appVM.cli)
            m.configure(wpContainer: wpContainer, dbContainer: dbContainer)
            model = m
            m.start()
            defer { m.stop() }
            // Keep the task alive for the lifetime of this selection.
            try? await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
        }
    }

    @ViewBuilder
    private func controls(_ model: SiteDetailViewModel) -> some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            Picker("", selection: $model.source) {
                ForEach(SiteDetailViewModel.LogSource.allCases) { src in
                    Label(src.rawValue, systemImage: src.symbol).tag(src)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Toggle("Follow", isOn: $model.follow)
                .toggleStyle(.switch)
                .controlSize(.mini)

            Button("Clear") { model.clear() }
                .controlSize(.small)
        }
    }

    private func logBody(_ model: SiteDetailViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if model.lines.isEmpty {
                        Text(model.isStreaming ? "Waiting for output…" : "Not running — start the site to stream logs.")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    }
                    ForEach(model.lines) { line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(10)
            }
            .frame(height: 240)
            .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onChange(of: model.lines.count) {
                if model.follow { withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) } }
            }
        }
    }

    private let bottomID = "logs-bottom"
}
