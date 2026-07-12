import SwiftUI
import WPContainerKit

/// Minimal placeholder UI. A parallel phase (U) builds the real Studio-style
/// interface on top of these services, so everything here stays deliberately
/// thin — all logic lives in `AppViewModel` and the kit services.
struct ContentView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm
        NavigationSplitView {
            List(selection: $vm.selection) {
                if let status = vm.systemStatus, !status.isReady {
                    Section("System") {
                        SystemBanner()
                    }
                }
                Section("Sites") {
                    ForEach(vm.sites) { site in
                        SiteRow(site: site).tag(site.id)
                    }
                    if vm.sites.isEmpty {
                        Text("No sites yet").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("WP Container")
            .toolbar {
                ToolbarItem {
                    Button {
                        vm.addDummySite()
                    } label: {
                        Label("Add Dummy Site", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let id = vm.selection, let site = vm.sites.first(where: { $0.id == id }) {
                SiteDetailPlaceholder(site: site)
            } else {
                ContentUnavailableView("Select a site", systemImage: "square.stack.3d.up")
            }
        }
        .overlay(alignment: .bottom) {
            if let err = vm.lastError {
                Text(err)
                    .font(.callout)
                    .padding(10)
                    .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    .padding()
                    .onTapGesture { vm.lastError = nil }
            }
        }
    }
}

private struct SystemBanner: View {
    @Environment(AppViewModel.self) private var vm
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Container system not ready")
                .font(.headline)
            if let raw = vm.systemStatus?.rawStatus {
                Text(raw).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Button("Start container system") {
                Task { await vm.startSystemService() }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SiteRow: View {
    let site: Site
    var body: some View {
        HStack {
            Circle()
                .fill(color(for: site.status))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading) {
                Text(site.name)
                Text(site.localURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(site.status.label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func color(for status: SiteStatus) -> Color {
        switch status {
        case .running: return .green
        case .starting, .stopping: return .orange
        case .error: return .red
        case .stopped: return .gray
        }
    }
}

private struct SiteDetailPlaceholder: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(site.name).font(.largeTitle.bold())
                Spacer()
                Text(site.status.label)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("URL", site.localURL.absoluteString)
                row("Slug", site.slug)
                row("Port", "\(site.port)")
                row("Image", site.imageTag)
                row("Path", site.path.path)
                row("Provisioned", site.provisioned ? "yes" : "no")
            }
            HStack {
                Button("Start") { vm.startSite(site) }
                    .disabled(site.status == .running || site.status.isTransitional)
                Button("Stop") { vm.stopSite(site) }
                    .disabled(site.status == .stopped || site.status.isTransitional)
                Button("Delete", role: .destructive) { vm.deleteSite(site, trashFolder: false) }
            }

            let envs = vm.store.envs(forSite: site.id)
            if !envs.isEmpty {
                Divider()
                Text("Branch environments").font(.headline)
                ForEach(envs) { env in
                    HStack {
                        Text(env.branch)
                        Text(env.localURL.absoluteString).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(env.status.label).font(.caption)
                    }
                }
            }
            Spacer()
        }
        .padding()
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
