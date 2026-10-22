import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WPContainerKit

/// "Export Site" sheet: edit the folders left out of the archive, choose a
/// destination in a save panel, then follow the export phase by phase.
struct ExportSiteSheet: View {
    /// `UserDefaults` key of the remembered exclude list.
    static let excludesKey = "siteExportExcludes"

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

    @State private var excludes = ExportSiteSheet.storedExcludes()
    @State private var newExclude = ""

    @State private var phase: Phase = .idle
    @State private var steps: [Step] = []
    @State private var currentStep: Step?
    @State private var summary: SiteExportSummary?
    @State private var errorText: String?

    private enum Phase { case idle, working, done, failed }

    private enum Step: Hashable {
        case startingSite
        case export(SiteExportPhase)

        var title: String {
            switch self {
            case .startingSite: return "Start the site"
            case .export(.preflight): return "Check the site"
            case .export(.dumpingDatabase): return "Dump the database"
            case .export(.archiving): return "Package the files"
            case .export(.finishing): return "Finish"
            }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.up")
                .font(.title2).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Export Site").font(.headline)
                Text("Package \(site.name)'s files and database into a zip archive.")
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
                Button("Export…") { chooseDestination() }
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
            if phase == .idle || phase == .failed {
                excludesSection
            }
            if !steps.isEmpty {
                Section("Progress") {
                    ArchiveStepList(
                        titles: steps.map(\.title),
                        currentIndex: currentStep.flatMap { steps.firstIndex(of: $0) },
                        outcome: stepOutcome
                    )
                }
            }
            if let summary {
                resultSection(summary)
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
        .frame(minHeight: 240, maxHeight: 460)
    }

    private var excludesSection: some View {
        Section {
            ForEach(excludes, id: \.self) { pattern in
                HStack {
                    Text(pattern).monospaced()
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") { removeExclude(pattern) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Remove \(pattern)")
                }
            }
            HStack {
                TextField("Folder or file name", text: $newExclude)
                    .onSubmit(addExclude)
                Button("Add", action: addExclude)
                    .disabled(trimmedNewExclude.isEmpty || excludes.contains(trimmedNewExclude))
            }
        } header: {
            HStack {
                Text("Excluded from the archive")
                Spacer()
                Button("Reset", action: resetExcludes)
                    .buttonStyle(.borderless)
                    .disabled(excludes == SiteArchiveService.defaultExcludes)
            }
        } footer: {
            Text("Matched by name at any depth inside the site's wordpress folder.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func resultSection(_ summary: SiteExportSummary) -> some View {
        Section("Archive") {
            LabeledContent("File") {
                Text(summary.archive.lastPathComponent)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            LabeledContent("Size") {
                Text(ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file))
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([summary.archive])
            }
            ForEach(summary.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Derived

    private var trimmedNewExclude: String {
        newExclude.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var stepOutcome: ArchiveStepList.Outcome {
        switch phase {
        case .done: return .succeeded
        case .failed: return .failed
        case .idle, .working: return .running
        }
    }

    /// The remembered exclude list, or the defaults when none is stored.
    private static func storedExcludes() -> [String] {
        UserDefaults.standard.stringArray(forKey: excludesKey) ?? SiteArchiveService.defaultExcludes
    }

    // MARK: Exclude list

    private func addExclude() {
        let pattern = trimmedNewExclude
        guard !pattern.isEmpty, !excludes.contains(pattern) else { return }
        excludes.append(pattern)
        newExclude = ""
        saveExcludes()
    }

    private func removeExclude(_ pattern: String) {
        excludes.removeAll { $0 == pattern }
        saveExcludes()
    }

    private func resetExcludes() {
        excludes = SiteArchiveService.defaultExcludes
        UserDefaults.standard.removeObject(forKey: Self.excludesKey)
    }

    private func saveExcludes() {
        UserDefaults.standard.set(excludes, forKey: Self.excludesKey)
    }

    // MARK: Actions

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = "Export \(site.name)"
        panel.nameFieldStringValue = SiteArchiveService.defaultFileName(slug: site.slug, date: Date())
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        let response = panel.runModal()
        guard response == .OK, let destination = panel.url else { return }
        Task { await runExport(to: destination) }
    }

    private func runExport(to destination: URL) async {
        let running = vm.store.site(id: site.id)?.status.isRunning ?? site.status.isRunning
        var planned: [Step] = running ? [] : [.startingSite]
        planned += [.export(.preflight), .export(.dumpingDatabase), .export(.archiving), .export(.finishing)]
        steps = planned
        currentStep = planned.first
        summary = nil
        errorText = nil
        phase = .working

        let result = await vm.exportSite(site, to: destination, excludes: excludes) { step in
            Task { @MainActor in
                guard phase == .working else { return }
                switch step {
                case .startingSite: currentStep = .startingSite
                case .phase(let exportPhase): currentStep = .export(exportPhase)
                }
            }
        }

        if let result {
            summary = result
            phase = .done
        } else {
            errorText = vm.lastError ?? "The site could not be exported."
            phase = .failed
        }
    }
}

/// A checklist of steps: finished steps show a checkmark, the current step a
/// spinner (or a cross once the run failed), and later steps an empty circle.
struct ArchiveStepList: View {
    enum Outcome { case running, succeeded, failed }

    let titles: [String]
    let currentIndex: Int?
    let outcome: Outcome

    var body: some View {
        ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
            HStack(spacing: 8) {
                icon(at: index)
                    .frame(width: 16)
                Text(title)
                    .foregroundStyle(isPending(index) ? .secondary : .primary)
                Spacer()
            }
        }
    }

    private func isPending(_ index: Int) -> Bool {
        guard outcome != .succeeded else { return false }
        guard let currentIndex else { return true }
        return index > currentIndex
    }

    @ViewBuilder
    private func icon(at index: Int) -> some View {
        let current = currentIndex ?? -1
        if outcome == .succeeded || index < current {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if index == current, outcome == .running {
            ProgressView().controlSize(.small)
        } else if index == current {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        } else {
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}
