import AppKit
import SwiftUI
import WPContainerKit

/// "Move Site Folder" sheet: choose a folder in an open panel, then follow the
/// move step by step.
struct MoveSiteSheet: View {
    let site: Site

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 480)
    }

    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .idle
    @State private var steps: [SiteMovePhase] = []
    @State private var currentStep: SiteMovePhase?
    @State private var outcome: SiteMover.Outcome?
    @State private var errorText: String?

    private enum Phase { case idle, working, done, failed }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.badge.gearshape")
                .font(.title2).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Move Site Folder").font(.headline)
                Text("Move \(site.name)'s folder into another folder. The folder keeps its name.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button(phase == .done ? "Done" : "Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(phase == .working)
            Spacer()
            if phase != .done {
                Button("Move…") { chooseFolder() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(phase == .working)
            }
        }
        .padding(16)
    }

    // MARK: Form

    private var form: some View {
        Form {
            Section("Location") {
                LabeledContent(outcome == nil ? "Folder" : "Before") {
                    pathText(outcome?.from ?? site.path)
                }
                if let outcome {
                    LabeledContent("Now") { pathText(outcome.site.path) }
                }
            }
            if !steps.isEmpty {
                Section("Progress") {
                    ArchiveStepList(
                        titles: steps.map(Self.title),
                        currentIndex: currentStep.flatMap { steps.firstIndex(of: $0) },
                        outcome: stepOutcome
                    )
                }
            }
            if let outcome {
                resultSection(outcome)
            }
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 200, maxHeight: 460)
    }

    private func pathText(_ url: URL) -> some View {
        Text((url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
            .lineLimit(1).truncationMode(.middle)
            .textSelection(.enabled)
    }

    private func resultSection(_ outcome: SiteMover.Outcome) -> some View {
        Section("Result") {
            if !outcome.restarted.isEmpty {
                LabeledContent("Started again") {
                    Text(outcome.restarted.joined(separator: ", "))
                }
            }
            Button("Reveal in Finder") { SystemActions.revealInFinder(outcome.site.path) }
            ForEach(outcome.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Derived

    private var stepOutcome: ArchiveStepList.Outcome {
        switch phase {
        case .done: return .succeeded
        case .failed: return .failed
        case .idle, .working: return .running
        }
    }

    /// Whether a container of the site or one of its envs runs, so the move
    /// stops it first and starts it again after.
    private var anythingRunning: Bool {
        let siteRunning = vm.store.site(id: site.id)?.status.isRunning ?? site.status.isRunning
        return siteRunning || vm.store.envs(forSite: site.id).contains { $0.status.isRunning }
    }

    private static func title(_ step: SiteMovePhase) -> String {
        switch step {
        case .stopping: return "Stop the containers"
        case .moving: return "Move the folder"
        case .updating: return "Update paths and git links"
        case .starting: return "Start again"
        }
    }

    // MARK: Actions

    private func chooseFolder() {
        guard let parent = SystemActions.chooseFolder(
            message: "Choose the folder to move \(site.name) into.",
            prompt: "Move",
            startingAt: SiteFolders.defaultSitesRoot
        ) else { return }
        Task { await runMove(to: parent) }
    }

    private func runMove(to parent: URL) async {
        let running = anythingRunning
        var planned: [SiteMovePhase] = running ? [.stopping] : []
        planned += [.moving, .updating]
        if running { planned.append(.starting) }
        steps = planned
        currentStep = planned.first
        outcome = nil
        errorText = nil
        phase = .working

        let result = await vm.moveSiteFolder(site, toParent: parent) { step in
            Task { @MainActor in
                guard phase == .working else { return }
                if !steps.contains(step) { steps.append(step) }
                currentStep = step
            }
        }

        if let result {
            outcome = result
            phase = .done
        } else {
            errorText = vm.lastError ?? "The site folder could not be moved."
            phase = .failed
        }
    }
}
