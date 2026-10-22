import SwiftUI
import UniformTypeIdentifiers
import WPContainerKit

/// "Import Site" sheet: pick a site export, review what it holds, name the new
/// site and its domain, then follow the import phase by phase.
struct ImportSiteSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 500)
        .task(id: archiveURL) { await inspectArchive() }
        .fileImporter(isPresented: $choosingArchive, allowedContentTypes: [.zip]) { result in
            if case .success(let url) = result { archiveURL = url }
        }
        .fileImporter(isPresented: $choosingParentFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { parentFolder = url }
        }
    }

    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var archiveURL: URL?
    @State private var info: SiteArchiveInfo?
    @State private var inspecting = false
    @State private var inspectError: String?
    @State private var choosingArchive = false

    @State private var name = ""
    @State private var domainChoice: DomainChoice = .none
    @State private var customDomain = ""
    @State private var parentFolder: URL?
    @State private var choosingParentFolder = false

    @State private var phase: Phase = .idle
    @State private var currentStep: SiteImportPhase?
    @State private var rollingBack = false
    @State private var result: SiteImportResult?
    @State private var errorText: String?
    @State private var errorRolledBack = false

    /// Import phases shown as steps; `.rollingBack` has its own row.
    private static let steps: [SiteImportPhase] = [
        .validating, .creatingSite, .extracting, .startingSite, .importingDatabase,
        .migratingURLs, .applyingSettings, .applyingDomain, .finishing,
    ]

    private enum Phase { case idle, working, done, failed }

    private enum DomainChoice: Hashable { case keep, custom, none }

    init(initialArchive: URL?) {
        _archiveURL = State(initialValue: initialArchive)
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down")
                .font(.title2).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Import Site").font(.headline)
                Text("Create a new site from a WP Container site export.")
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
            if phase == .done, let result {
                Button("Open Site") { SystemActions.openInBrowser(result.site.url) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(phase == .failed ? "Retry Import" : "Import") { Task { await runImport() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
            }
        }
        .padding(16)
    }

    // MARK: Form

    private var form: some View {
        Form {
            archiveSection
            if let info, phase == .idle || phase == .failed {
                settingsSection(info)
            }
            if phase != .idle {
                progressSection
            }
            if let result {
                resultSection(result)
            }
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    if errorRolledBack {
                        Text("Nothing was left behind.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 240, maxHeight: 520)
    }

    private var archiveSection: some View {
        Section("Site export") {
            HStack {
                Text(archiveURL?.lastPathComponent ?? "No file chosen")
                    .foregroundStyle(archiveURL == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { choosingArchive = true }
                    .disabled(phase == .working)
            }
            if inspecting {
                ProgressView("Reading the archive…").controlSize(.small)
            }
            if let inspectError {
                Label(inspectError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if let info {
                summaryRows(info)
            }
        }
    }

    @ViewBuilder
    private func summaryRows(_ info: SiteArchiveInfo) -> some View {
        let manifest = info.manifest
        LabeledContent("WordPress", value: manifest.wordpressVersion ?? "Unknown")
        LabeledContent("PHP", value: phpVersion(manifest.settings))
        LabeledContent("Multisite", value: multisiteLabel(manifest.settings.networkType))
        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: info.uncompressedBytes, countStyle: .file))
        LabeledContent("Source") {
            Text(manifest.source.url)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func settingsSection(_ info: SiteArchiveInfo) -> some View {
        Section("New site") {
            TextField("Name", text: $name, prompt: Text(info.manifest.source.name))
            Picker("Domain", selection: $domainChoice) {
                if let archived = archivedDomain {
                    Text("Keep \(archived)").tag(DomainChoice.keep)
                }
                Text("Custom").tag(DomainChoice.custom)
                Text("None").tag(DomainChoice.none)
            }
            if domainChoice == .custom {
                TextField("Custom domain", text: $customDomain, prompt: Text("mysite.test"))
            }
            LabeledContent("Location") {
                HStack {
                    Text(rootFolder.path(percentEncoded: false))
                        .lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { choosingParentFolder = true }
                    if parentFolder != nil {
                        Button("Reset") { parentFolder = nil }
                    }
                }
            }
        }
    }

    private var progressSection: some View {
        Section("Progress") {
            ArchiveStepList(
                titles: Self.steps.map(stepTitle),
                currentIndex: currentStep.flatMap { Self.steps.firstIndex(of: $0) },
                outcome: stepOutcome
            )
            if rollingBack {
                HStack(spacing: 8) {
                    if phase == .working {
                        ProgressView().controlSize(.small).frame(width: 16)
                    } else {
                        Image(systemName: "arrow.uturn.backward.circle").frame(width: 16)
                    }
                    Text("Remove the partly created site")
                    Spacer()
                }
            }
        }
    }

    private func resultSection(_ result: SiteImportResult) -> some View {
        Section("Imported") {
            LabeledContent("Site", value: result.site.name)
            LabeledContent("URL") {
                Text(result.site.url.absoluteString)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            ForEach(result.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Derived

    private var archivedDomain: String? {
        guard let domain = info?.manifest.settings.customDomain, !domain.isEmpty else { return nil }
        return domain
    }

    private var rootFolder: URL { parentFolder ?? SiteFolders.defaultSitesRoot }

    private var trimmedCustomDomain: String {
        customDomain.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canImport: Bool {
        guard archiveURL != nil, info != nil, phase != .working else { return false }
        if domainChoice == .custom, trimmedCustomDomain.isEmpty { return false }
        return true
    }

    private var stepOutcome: ArchiveStepList.Outcome {
        switch phase {
        case .done: return .succeeded
        case .failed: return .failed
        case .idle, .working: return .running
        }
    }

    private func stepTitle(_ step: SiteImportPhase) -> String {
        switch step {
        case .validating: return "Check the archive"
        case .creatingSite: return "Create the site"
        case .extracting: return "Extract the files"
        case .startingSite: return "Start the site"
        case .importingDatabase: return "Import the database"
        case .migratingURLs: return "Update URLs"
        case .applyingSettings: return "Apply settings"
        case .applyingDomain: return "Register the domain"
        case .finishing: return "Finish"
        case .rollingBack: return "Remove the partly created site"
        }
    }

    private func phpVersion(_ settings: SiteArchiveSettings) -> String {
        WordPressImageCatalog.php(fromTag: settings.imageTag) ?? settings.phpVersion ?? "Unknown"
    }

    private func multisiteLabel(_ networkType: NetworkType) -> String {
        switch networkType {
        case .none: return "No"
        case .subdirectory: return "Yes, subdirectories"
        case .subdomain: return "Yes, subdomains"
        }
    }

    // MARK: Actions

    private func inspectArchive() async {
        info = nil
        inspectError = nil
        guard let archiveURL else { return }
        inspecting = true
        defer { inspecting = false }
        do {
            let inspected = try await SiteArchiveService.inspect(archive: archiveURL)
            info = inspected
            name = inspected.manifest.source.name
            domainChoice = archivedDomain == nil ? .none : .keep
            customDomain = ""
        } catch is CancellationError {
            return
        } catch let error as SiteArchiveError {
            inspectError = error.description
        } catch {
            inspectError = error.localizedDescription
        }
    }

    private func runImport() async {
        guard let archiveURL, info != nil else { return }
        let domain: SiteImportDomain
        switch domainChoice {
        case .keep: domain = .keep
        case .custom: domain = .set(trimmedCustomDomain)
        case .none: domain = .none
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = SiteImportOptions(
            name: trimmedName.isEmpty ? nil : trimmedName,
            domain: domain,
            parentFolder: rootFolder
        )

        currentStep = Self.steps.first
        rollingBack = false
        result = nil
        errorText = nil
        errorRolledBack = false
        phase = .working

        let imported = await vm.importSite(archiveURL, options: options) { step in
            Task { @MainActor in
                guard phase == .working else { return }
                if step == .rollingBack {
                    rollingBack = true
                } else {
                    currentStep = step
                }
            }
        }

        if let imported {
            result = imported
            phase = .done
        } else {
            errorText = vm.lastError ?? "The site could not be imported."
            errorRolledBack = vm.lastSiteImportRolledBack
            rollingBack = errorRolledBack
            phase = .failed
        }
    }
}
