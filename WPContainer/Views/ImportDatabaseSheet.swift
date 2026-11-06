import SwiftUI
import UniformTypeIdentifiers
import WPContainerKit

/// Shared helper for recognizing a database dump file by extension, used by
/// both this sheet's own dropzone/picker and `SiteDetailView`'s pane-level
/// drag & drop entry point (PLAN.md §2m).
enum DumpFile {
    static func isDumpFile(_ url: URL) -> Bool {
        ["sql", "gz"].contains(url.pathExtension.lowercased())
    }

    /// `UTType`s accepted by the `.fileImporter` dump picker.
    static var contentTypes: [UTType] {
        var types: [UTType] = []
        if let sql = UTType(filenameExtension: "sql") { types.append(sql) }
        if let gz = UTType(filenameExtension: "gz") { types.append(gz) }
        return types.isEmpty ? [.data] : types
    }
}

/// "Import Database" sheet (PLAN.md §2m): pick or drop a `.sql`/`.sql.gz`
/// dump, choose scrub/media/admin options, then run
/// `DatabaseImportService`'s pipeline with live phase progress and a
/// summary/failure view. Mirrors `NewBranchEnvSheet`'s shape (header/Divider/
/// content/Divider/footer, `Phase` enum, working section, failure section
/// with a `DisclosureGroup` for full detail).
struct ImportDatabaseSheet: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    let site: Site
    /// Pre-filled from a file dropped on the site detail pane before this
    /// sheet was opened.
    var initialDump: URL?

    @State private var dumpURL: URL?
    @State private var dumpSizeText: String?
    @State private var dropTargeted = false
    @State private var choosingDump = false
    @State private var choosingCopyFolder = false

    @State private var scrub = true
    @State private var allowlistExpanded = false
    @State private var allowedEmailsText = ""
    @State private var allowedDomainsText = ""

    @State private var mediaChoice: MediaChoice = .remote
    @State private var copyFolderURL: URL?

    @State private var createAdmin = true
    @State private var sourceURLOverride = ""

    @State private var phase: Phase = .idle
    @State private var currentStepText = "Preparing…"
    @State private var summary: DBImportSummary?
    @State private var errorShort: String?
    @State private var errorDetail: String?
    @State private var errorRolledBack: Bool?

    private enum Phase { case idle, working, done, failed }

    private enum MediaChoice: String, CaseIterable, Identifiable {
        case remote, copy, skip
        var id: String { rawValue }
        var label: String {
            switch self {
            case .remote: return "Load from original site"
            case .copy: return "Copy uploads folder…"
            case .skip: return "Skip"
            }
        }
        var caption: String? {
            switch self {
            case .remote:
                return "Loads missing images from the source site. Needs the source URL."
            case .copy:
                return "Copies a local uploads folder into wp-content/uploads."
            case .skip:
                return nil
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 520)
        .task {
            if let initialDump, dumpURL == nil { setDump(initialDump) }
        }
        .fileImporter(isPresented: $choosingDump, allowedContentTypes: DumpFile.contentTypes) { result in
            if case .success(let url) = result { setDump(url) }
        }
        .fileImporter(isPresented: $choosingCopyFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { copyFolderURL = url }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cylinder.split.1x2")
                .font(.title2).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Import Database").font(.headline)
                Text("Bring a production or staging dump into \(site.name).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if phase == .done, let summary {
            successView(summary)
        } else {
            form
        }
    }

    private var footer: some View {
        HStack {
            Button(phase == .done ? "Done" : "Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(phase == .working)
            Spacer()
            if phase != .done {
                Button(phase == .failed ? "Retry Import" : "Import") { Task { await runImport() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport || phase == .working)
            }
        }
        .padding(16)
    }

    // MARK: Form (setup / working / failed)

    private var form: some View {
        Form {
            fileSection
            if dumpURL != nil {
                scrubSection
                mediaSection
                adminSection
                sourceURLSection
            }
            if phase == .working {
                workingSection
            }
            if phase == .failed {
                failedSection
            }
        }
        .formStyle(.grouped)
    }

    private var fileSection: some View {
        Section("Database dump") {
            dropZone
            HStack(spacing: 8) {
                Button("Choose…") { choosingDump = true }
                    .disabled(phase == .working)
                if let dumpURL {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(dumpURL.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        if let dumpSizeText {
                            Text(dumpSizeText).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("No file chosen").foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            .foregroundStyle(dropTargeted ? Theme.accent : Color.secondary.opacity(0.35))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(dropTargeted ? Theme.accent.opacity(0.08) : Color.clear)
            )
            .frame(height: 60)
            .overlay {
                VStack(spacing: 2) {
                    Image(systemName: "arrow.down.doc")
                        .foregroundStyle(dropTargeted ? Theme.accent : .secondary)
                    Text("Drop a .sql or .sql.gz file here")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: DumpFile.isDumpFile) else { return false }
                setDump(url)
                return true
            } isTargeted: { dropTargeted = $0 }
            .animation(.easeOut(duration: 0.1), value: dropTargeted)
    }

    private var scrubSection: some View {
        Section("Privacy") {
            Toggle("Scrub sensitive data", isOn: $scrub).disabled(phase == .working)
            Text("Replaces user emails, names and passwords with random values, and deletes comments.")
                .font(.caption).foregroundStyle(.secondary)
            if scrub {
                DisclosureGroup("Keep these emails/domains", isExpanded: $allowlistExpanded) {
                    TextField("Emails", text: $allowedEmailsText, prompt: Text("me@example.com, you@example.com"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Domains", text: $allowedDomainsText, prompt: Text("example.com"))
                        .textFieldStyle(.roundedBorder)
                }
                .disabled(phase == .working)
            }
        }
    }

    private var mediaSection: some View {
        Section("Media") {
            Picker("", selection: $mediaChoice) {
                ForEach(MediaChoice.allCases) { choice in Text(choice.label).tag(choice) }
            }
            .labelsHidden()
            .pickerStyle(.inline)
            .disabled(phase == .working)
            if let caption = mediaChoice.caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            if mediaChoice == .copy {
                HStack {
                    Text(copyFolderURL?.path(percentEncoded: false) ?? "No folder chosen")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { choosingCopyFolder = true }.disabled(phase == .working)
                }
            }
        }
    }

    private var adminSection: some View {
        Section("Admin account") {
            Toggle("Create local admin account (\(SiteRecipe.adminUser) / \(SiteRecipe.adminPassword))", isOn: $createAdmin)
                .disabled(phase == .working)
        }
    }

    private var sourceURLSection: some View {
        Section("Source URL") {
            TextField("Source URL", text: $sourceURLOverride, prompt: Text("Auto-detect from dump"))
                .textFieldStyle(.roundedBorder)
                .disabled(phase == .working)
            Text("Used to rewrite URLs and, with “Load from original site”, to fetch missing images.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var workingSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(currentStepText).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var failedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                if let errorShort {
                    Label(errorShort, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                if let errorRolledBack {
                    Text(errorRolledBack
                         ? "The previous database was restored, so the site is as it was before."
                         : "Restoring the previous database also failed, so it may be incomplete. The backup is in the site’s .backups folder.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let errorDetail, errorDetail != errorShort {
                    DisclosureGroup("Details") {
                        ScrollView {
                            Text(errorDetail)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: Success

    private func successView(_ summary: DBImportSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 32)).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Database imported").font(.headline)
                        Text("\(summary.usersScrubbed) users scrubbed, \(summary.commentsRemoved) comments removed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 10) {
                    if let source = summary.sourceURL {
                        InfoRow(label: "Source URL") {
                            Text(source).font(.caption).textSelection(.enabled)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    InfoRow(label: "Local URL") {
                        HStack(spacing: 6) {
                            Button(summary.localURL) {
                                if let u = URL(string: summary.localURL) { SystemActions.openInBrowser(u) }
                            }
                            .buttonStyle(.link)
                            CopyButton(value: summary.localURL)
                        }
                    }
                    InfoRow(label: "Users") {
                        Text("\(summary.usersScrubbed) scrubbed, \(summary.usersPreserved) preserved")
                    }
                    InfoRow(label: "Comments") {
                        Text("\(summary.commentsRemoved) removed")
                    }
                    if let replacements = summary.replacementsMade {
                        InfoRow(label: "URL replacements") { Text("\(replacements)") }
                    }
                    InfoRow(label: "Media") { Text(mediaModeLabel(summary.mediaMode)) }
                    InfoRow(label: "Dump size") {
                        Text(ByteCountFormatter.string(fromByteCount: summary.dumpSizeBytes, countStyle: .file))
                    }
                    InfoRow(label: "Backup") {
                        HStack(spacing: 6) {
                            Button("Reveal in Finder") {
                                SystemActions.revealInFinder(URL(fileURLWithPath: summary.backupPath))
                            }
                            .buttonStyle(.link)
                            CopyButton(value: summary.backupPath)
                        }
                    }
                    if let user = summary.adminUser, let pass = summary.adminPassword {
                        InfoRow(label: "Admin") {
                            HStack(spacing: 6) {
                                credential(user)
                                Text("/").foregroundStyle(.tertiary)
                                credential(pass)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(maxHeight: 420)
    }

    private func credential(_ value: String) -> some View {
        HStack(spacing: 3) {
            Text(value).monospaced()
            CopyButton(value: value, help: "Copy \(value)")
        }
    }

    private func mediaModeLabel(_ mode: String) -> String {
        switch mode {
        case "remote": return "Loading from original site"
        case "copy": return "Copied from folder"
        default: return "Skipped"
        }
    }

    // MARK: Derived

    private var canImport: Bool {
        guard dumpURL != nil else { return false }
        if mediaChoice == .copy && copyFolderURL == nil { return false }
        return true
    }

    private func setDump(_ url: URL) {
        dumpURL = url
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber {
            dumpSizeText = ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
        } else {
            dumpSizeText = nil
        }
    }

    private func caption(for phase: DBImportPhase) -> String {
        switch phase {
        case .preflight:    return "Checking dump and free disk space…"
        case .backup:       return "Backing up current database…"
        case .importing:    return "Importing dump\(dumpSizeText.map { " (\($0))" } ?? "")…"
        case .urlMigration: return "Rewriting URLs…"
        case .scrubbing:    return "Scrubbing sensitive data…"
        case .media:        return "Setting up media…"
        case .admin:        return "Creating admin account…"
        case .finishing:    return "Finishing up…"
        case .rollingBack:  return "Rolling back…"
        }
    }

    // MARK: Actions

    private func runImport() async {
        guard let dumpURL else { return }
        phase = .working
        currentStepText = "Preparing…"
        errorShort = nil
        errorDetail = nil
        errorRolledBack = nil

        let emails = allowedEmailsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let domains = allowedDomainsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        guard mediaChoice != .copy || copyFolderURL != nil else { return }
        let media: DBImportMediaOption
        switch mediaChoice {
        case .remote: media = .remote
        case .copy:   media = .copy(from: copyFolderURL!)
        case .skip:   media = .skip
        }

        let override = sourceURLOverride.trimmingCharacters(in: .whitespaces)
        let options = DBImportOptions(
            scrub: scrub,
            allowedEmails: emails,
            allowedDomains: domains,
            media: media,
            createAdmin: createAdmin,
            sourceURLOverride: override.isEmpty ? nil : override
        )

        let result = await vm.importDatabase(into: site, dump: dumpURL, options: options) { step in
            switch step {
            case .startingSite: currentStepText = "Starting site…"
            case .phase(let p): currentStepText = caption(for: p)
            }
        }

        if let result {
            summary = result
            phase = .done
        } else {
            errorShort = vm.lastError ?? "Couldn’t import the database."
            errorDetail = vm.lastErrorDetail
            errorRolledBack = vm.lastImportRolledBack
            phase = .failed
        }
    }
}
