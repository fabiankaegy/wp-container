import SwiftUI
import UniformTypeIdentifiers
import WPContainerKit

/// Sheet for creating a new site: name (with live slug + path preview), an
/// optional folder-override picker, a WordPress/PHP image picker, and a Create
/// button that creates + starts + provisions with inline progress and error
/// surfacing.
struct AddSiteSheet: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var imageTag = SiteRecipe.defaultWordPressImage
    @State private var parentFolder: URL?
    @State private var choosingFolder = false
    @State private var groupID: UUID?

    @State private var phase: Phase = .idle
    @State private var hintIndex = 0
    @State private var errorText: String?

    private enum Phase { case idle, working, failed }

    private let hints = ["Seeding WordPress core…", "Starting database…", "Installing WordPress…", "Finishing up…"]

    var body: some View {
        // Step-container pattern: the sheet renders one "step" at a time so later
        // phases (PLAN.md §2i–2k) can add version/options steps without reshaping
        // the surrounding chrome. Today there is a single setup step.
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            setupStep
            if phase == .working { progressBar }
            if phase == .failed, let errorText { errorBanner(errorText) }
            Divider()
            footer
        }
        .frame(width: 460)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { parentFolder = url }
        }
    }

    private var setupStep: some View {
        Form {
            Section {
                TextField("Site name", text: $name, prompt: Text("My Blog"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(phase == .working)
                if !name.isEmpty {
                    Text(pathPreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Picker("Group", selection: $groupID) {
                    Text("None").tag(UUID?.none)
                    ForEach(vm.store.sortedGroups) { group in
                        Text(group.name).tag(UUID?.some(group.id))
                    }
                }
                .disabled(phase == .working)
            }

            Section("Location") {
                    HStack {
                        Text(rootFolder.path(percentEncoded: false))
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") { choosingFolder = true }
                            .disabled(phase == .working)
                        if parentFolder != nil {
                            Button("Reset") { parentFolder = nil }
                                .disabled(phase == .working)
                        }
                    }
                }

                Section("WordPress Image") {
                    Picker("Version", selection: $imageTag) {
                        ForEach(SiteRecipe.wordPressImageOptions, id: \.tag) { option in
                            Text(option.label).tag(option.tag)
                        }
                    }
                    .disabled(phase == .working)
                }
            }
            .formStyle(.grouped)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 12) {
            SiteAvatar(name: name.isEmpty ? "New Site" : name, slug: slug.isEmpty ? "new" : slug, size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("New Site").font(.headline)
                Text("Runs in an Apple container; files live on disk.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var progressBar: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(hints[min(hintIndex, hints.count - 1)])
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func errorBanner(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(phase == .working)
            Spacer()
            Button("Create Site") { Task { await create() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || phase == .working)
        }
        .padding(16)
    }

    // MARK: Derived

    private var slug: String {
        Slug.unique(name, existing: vm.store.existingSlugs)
    }
    private var rootFolder: URL { parentFolder ?? SiteFolders.defaultSitesRoot }
    private var pathPreview: String {
        rootFolder.appendingPathComponent(slug, isDirectory: true).path(percentEncoded: false)
    }

    // MARK: Actions

    private func create() async {
        phase = .working
        errorText = nil
        vm.lastError = nil
        startHintTicker()

        let phpLabel = SiteRecipe.wordPressImageOptions.first { $0.tag == imageTag }?.label
        let site = await vm.createAndStartSite(name: name, parentFolder: parentFolder,
                                               imageTag: imageTag, phpVersion: phpLabel,
                                               groupID: groupID)

        // Success iff the site now exists and is running; otherwise surface the error.
        if let site, vm.store.site(id: site.id)?.status.isRunning == true {
            dismiss()
        } else {
            errorText = vm.lastError ?? "Could not create the site."
            phase = .failed
        }
    }

    private func startHintTicker() {
        Task {
            while phase == .working {
                try? await Task.sleep(for: .seconds(4))
                if phase == .working, hintIndex < hints.count - 1 { hintIndex += 1 }
            }
        }
    }
}
