import SwiftUI
import WPContainerKit

/// Settings-tab "Software" card (PLAN.md §2k): live WordPress version + core
/// update, and WP × PHP version pickers that swap the image tag (files/DB
/// untouched) and restart.
struct SoftwareCard: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site

    @State private var wpVersion = WordPressImageCatalog.wordpress(fromTag: "") ?? "latest"
    @State private var php = WordPressImageCatalog.defaultPHP
    @State private var liveVersion: String?
    @State private var confirmingUpdate = false

    private var resultingTag: String { WordPressImageCatalog.imageTag(wordpress: wpVersion, php: php) }
    private var pendingChange: Bool { resultingTag != site.imageTag }

    var body: some View {
        SectionCard(title: "Software", systemImage: "shippingbox") {
            VStack(alignment: .leading, spacing: 14) {
                versionRow
                Divider().opacity(0.5)
                pickers
            }
        }
        .onAppear {
            wpVersion = WordPressImageCatalog.wordpress(fromTag: site.imageTag) ?? "latest"
            php = WordPressImageCatalog.php(fromTag: site.imageTag) ?? WordPressImageCatalog.defaultPHP
        }
        .task(id: site.status) { liveVersion = await vm.liveWordPressVersion(site) }
    }

    private var versionRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("WordPress").font(.callout.weight(.medium))
                Text(liveVersion.map { "Version \($0) (live)" } ?? "Image \(site.imageTag)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button("Update Core…") { confirmingUpdate = true }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(!site.status.isRunning)
        }
        .confirmationDialog("Update WordPress core?", isPresented: $confirmingUpdate, titleVisibility: .visible) {
            Button("Update Core") { vm.updateWordPressCore(site) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Runs `wp core update` and updates the database. Your content is preserved.")
        }
    }

    private var pickers: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("WordPress", selection: $wpVersion) {
                    ForEach(WordPressImageCatalog.wordPressVersions, id: \.self) { v in
                        Text(v == "latest" ? "Latest" : v).tag(v)
                    }
                }
                .controlSize(.small)
                Picker("PHP", selection: $php) {
                    ForEach(WordPressImageCatalog.phpVersions, id: \.self) { v in
                        Text(v)
                            .tag(v)
                    }
                }
                .controlSize(.small)
            }
            if !WordPressImageCatalog.isKnownValid(wordpress: wpVersion, php: php) {
                Label("This WP × PHP combination may not be published.", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
            }
            HStack {
                Text(resultingTag).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button(site.status.isRunning ? "Apply & Restart" : "Apply") {
                    vm.changeImageTag(site, imageTag: resultingTag, phpLabel: "PHP \(php)")
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(!pendingChange)
            }
        }
    }
}
