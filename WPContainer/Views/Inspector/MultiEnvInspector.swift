import SwiftUI
import WPContainerKit

/// Several branch environments selected in a table: what state they're in,
/// and the actions that apply to all of them at once.
struct MultiEnvInspector: View {
    @Environment(AppViewModel.self) private var vm
    let envs: [WorktreeEnv]

    @State private var confirmingDelete = false

    private var running: [WorktreeEnv] { envs.filter { $0.status.isRunning } }
    private var startable: [WorktreeEnv] { envs.filter { !$0.isSettled && $0.status == .stopped } }
    private var active: [WorktreeEnv] { envs.filter { !$0.isSettled } }
    private var settled: [WorktreeEnv] { envs.filter(\.isSettled) }

    var body: some View {
        InspectorStack {
            InspectorHeader(title: "\(envs.count) Branch Environments") {
                SectionIcon(systemName: "square.stack.3d.up", color: .purple, size: 44)
            } subtitle: {
                Text(summary)
            } actions: {
                Button("Start All", systemImage: "play.fill") { startable.forEach(vm.startEnv) }
                    .disabled(startable.isEmpty)
                Button("Stop All", systemImage: "stop.fill") { running.forEach(vm.stopEnv) }
                    .disabled(running.isEmpty)
            }
            SectionCard(title: "Lifecycle", systemImage: "archivebox") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Settling stops environments and frees their ports. Checkouts, files and databases are kept until restored.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        if !active.isEmpty { Button("Settle \(active.count)") { vm.settleEnvs(active) } }
                        if !settled.isEmpty { Button("Restore \(settled.count)") { settled.forEach(vm.restoreEnv) } }
                    }
                }
            }
            SectionCard(title: "Danger Zone", systemImage: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Deleting removes each environment's containers and cloned files. Git branches are always kept.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Delete \(envs.count) Environments…", role: .destructive) { confirmingDelete = true }
                        .tint(.red)
                }
            }
        }
        .confirmationDialog("Delete \(envs.count) branch environments?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete \(envs.count) Environments", role: .destructive) {
                envs.forEach { vm.deleteEnv($0) }
                vm.branchSelection = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their containers, cloned files and worktree checkouts are removed. The git branches are kept.")
        }
    }

    private var summary: String {
        var parts = ["\(running.count) running", "\(active.count - running.count) stopped"]
        if !settled.isEmpty { parts.append("\(settled.count) settled") }
        return parts.joined(separator: " · ")
    }
}
