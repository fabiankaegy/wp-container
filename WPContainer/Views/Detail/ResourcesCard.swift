import SwiftUI
import WPContainerKit

/// Settings-tab "Resources" card (issue #11): optional per-site CPU / memory
/// caps passed to `container run`. nil (the "Default" state) means the built-in
/// `container` defaults — 4 CPUs / 1 GB — which are scheduling/size caps, not
/// upfront reservations. Changes apply on the next start; a running site shows a
/// restart hint (matching the Xdebug pattern in DevelopmentCard).
struct ResourcesCard: View {
    @Environment(AppViewModel.self) private var vm
    let site: Site

    // 0 is the "Default" (nil) sentinel used by the pickers.
    private var cpuSelection: Binding<Int> {
        Binding(get: { site.cpuLimit ?? 0 },
                set: { vm.setResources(site, cpuLimit: $0 == 0 ? nil : $0, memoryLimitMB: site.memoryLimitMB) })
    }
    private var memorySelection: Binding<Int> {
        Binding(get: { site.memoryLimitMB ?? 0 },
                set: { vm.setResources(site, cpuLimit: site.cpuLimit, memoryLimitMB: $0 == 0 ? nil : $0) })
    }

    var body: some View {
        SectionCard(title: "Resources", systemImage: "cpu") {
            VStack(alignment: .leading, spacing: 14) {
                SettingRow(title: "CPU cores",
                           detail: Text("Maximum CPUs per container. Idle containers use almost none.")) {
                    Picker("", selection: cpuSelection) {
                        Text("Default (4)").tag(0)
                        ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                .help("A scheduling limit, not a reservation.")

                Divider().opacity(0.5)

                SettingRow(title: "Memory",
                           detail: Text("Maximum memory per container. Choose 512 MB to fit more sites on a 16 GB Mac.")) {
                    Picker("", selection: memorySelection) {
                        Text("Default (1 GB)").tag(0)
                        Text("512 MB").tag(512)
                        Text("1 GB").tag(1024)
                        Text("2 GB").tag(2048)
                        Text("4 GB").tag(4096)
                    }
                    .labelsHidden().fixedSize()
                }
                .help("Elasticsearch’s Java heap alone is 512 MB.")

                if site.status.isRunning {
                    Text("Restart the site to apply new limits.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
