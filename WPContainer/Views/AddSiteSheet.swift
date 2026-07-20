import SwiftUI
import UniformTypeIdentifiers
import WPContainerKit

/// New-site setup guide (PLAN.md §2k): step 1 name + group + location, step 2
/// WordPress × PHP versions with a live image-tag preview, step 3 options
/// (multisite, custom domain, Xdebug/Elasticsearch). Creates + starts +
/// provisions with inline progress.
struct AddSiteSheet: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0
    @State private var name = ""
    @State private var parentFolder: URL?
    @State private var choosingFolder = false
    @State private var groupID: UUID?

    // Versions — prefilled from the app's Settings defaults (PLAN.md §2l).
    @State private var wpVersion = UserDefaults.standard.string(forKey: AppSettings.defaultWordPressVersionKey) ?? "latest"
    @State private var php = UserDefaults.standard.string(forKey: AppSettings.defaultPHPVersionKey) ?? WordPressImageCatalog.defaultPHP

    // Options
    @State private var networkType: NetworkType = .none
    @State private var customDomain = ""
    @State private var xdebug = false
    @State private var elasticsearch = false
    // HTTPS + debug — prefilled from the app's New Site Defaults (Settings → Sites).
    @State private var https = AppSettings.defaultHTTPS
    @State private var wpDebug = AppSettings.defaultWPDebug
    @State private var scriptDebug = AppSettings.defaultScriptDebug

    @State private var phase: Phase = .idle
    @State private var hintIndex = 0
    @State private var errorText: String?

    // Custom-domain registration step (§2l): honest label + skippable prompt.
    @State private var domainStatus = ""
    @State private var showSkip = false
    @State private var domainRegTask: Task<DomainRegistrationOutcome, Never>?

    private enum Phase { case idle, working, registeringDomain, failed }
    private let hints = ["Seeding WordPress core…", "Starting database…", "Installing WordPress…", "Finishing up…"]
    private let steps = ["Site", "Versions", "Options"]

    private var imageTag: String { WordPressImageCatalog.imageTag(wordpress: wpVersion, php: php) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case 0: setupStep
                case 1: versionStep
                default: optionsStep
                }
            }
            if phase == .working { progressBar }
            if phase == .registeringDomain { domainRegistrationBar }
            if phase == .failed, let errorText { errorBanner(errorText) }
            Divider()
            footer
        }
        .frame(width: 480)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { parentFolder = url }
        }
    }

    // MARK: Steps

    private var setupStep: some View {
        Form {
            Section {
                TextField("Site name", text: $name, prompt: Text("My Blog"))
                    .textFieldStyle(.roundedBorder)
                if !name.isEmpty {
                    Text(pathPreview).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                }
                Picker("Group", selection: $groupID) {
                    Text("None").tag(UUID?.none)
                    ForEach(vm.store.sortedGroups) { group in Text(group.name).tag(UUID?.some(group.id)) }
                }
            }
            Section("Location") {
                HStack {
                    Text(rootFolder.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { choosingFolder = true }
                    if parentFolder != nil { Button("Reset") { parentFolder = nil } }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var versionStep: some View {
        Form {
            Section("WordPress version") {
                Picker("WordPress", selection: $wpVersion) {
                    ForEach(vm.versionMatrix.wordPressVersions, id: \.self) { v in
                        Text(v == "latest" ? "Latest" : v).tag(v)
                    }
                }
                .onChange(of: wpVersion) { _, newWP in
                    // Keep the PHP pick valid for the newly-chosen WP series.
                    if !vm.versionMatrix.isValid(wp: newWP, php: php) {
                        php = vm.versionMatrix.defaultPHP(for: newWP)
                    }
                }
            }
            Section("PHP version") {
                Picker("PHP", selection: $php) {
                    ForEach(vm.versionMatrix.phpVersions(for: wpVersion), id: \.self) { v in Text(v).tag(v) }
                }
                if !vm.versionMatrix.isValid(wp: wpVersion, php: php) {
                    Label("This combination may not be published on Docker Hub.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Image") {
                HStack {
                    Text("Resulting tag").foregroundStyle(.secondary)
                    Spacer()
                    Text(imageTag).monospaced().textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var optionsStep: some View {
        Form {
            Section("Network") {
                Picker("Type", selection: $networkType) {
                    ForEach(NetworkType.allCases) { t in Text(t.label).tag(t) }
                }
                .pickerStyle(.inline)
                if networkType.isSubdomain {
                    Text("Subdomain networks resolve zero-config on <slug>.localhost; use subdirectory for custom domains.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Custom domain (optional)") {
                TextField("mysite.local", text: $customDomain).textFieldStyle(.roundedBorder).autocorrectionDisabled()
            }
            Section("Add-ons") {
                Toggle("Xdebug (step debugging on 9003)", isOn: $xdebug)
                Toggle("Elasticsearch (ElasticPress)", isOn: $elasticsearch)
            }
            Section("HTTPS & Debugging") {
                Toggle("Enable HTTPS (https://\(slug.isEmpty ? "site" : slug).localhost)", isOn: $https)
                Toggle("WP_DEBUG", isOn: $wpDebug)
                Toggle("SCRIPT_DEBUG", isOn: $scriptDebug)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 12) {
            SiteAvatar(name: name.isEmpty ? "New Site" : name, slug: slug.isEmpty ? "new" : slug, size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("New Site").font(.headline)
                Text("Step \(step + 1) of \(steps.count): \(steps[step])")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var progressBar: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(hints[min(hintIndex, hints.count - 1)]).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// Honest, skippable status for the /etc/hosts admin-prompt step (§2l).
    private var domainRegistrationBar: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(domainStatus)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if showSkip {
                Button("Skip domain setup") { domainRegTask?.cancel() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func errorBanner(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Button(step == 0 ? "Cancel" : "Back") {
                if step == 0 { dismiss() } else { step -= 1 }
            }
            .keyboardShortcut(.cancelAction)
            .disabled(phase == .working || phase == .registeringDomain)
            Spacer()
            if step < steps.count - 1 {
                Button("Next") { step += 1 }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
                Button("Create Site") { Task { await create() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || phase == .working || phase == .registeringDomain)
            }
        }
        .padding(16)
    }

    // MARK: Derived

    private var slug: String { Slug.unique(name, existing: vm.store.existingSlugs) }
    private var rootFolder: URL { parentFolder ?? SiteFolders.defaultSitesRoot }
    private var pathPreview: String { rootFolder.appendingPathComponent(slug, isDirectory: true).path(percentEncoded: false) }

    // MARK: Create

    private func create() async {
        phase = .working
        errorText = nil
        vm.lastError = nil
        startHintTicker()

        let domain = customDomain.trimmingCharacters(in: .whitespaces)
        let site = await vm.createAndStartSite(
            name: name, parentFolder: parentFolder, imageTag: imageTag, phpVersion: "PHP \(php)",
            groupID: groupID, networkType: networkType,
            customDomain: domain.isEmpty ? nil : domain,
            xdebugEnabled: xdebug, elasticsearchEnabled: elasticsearch,
            httpsEnabled: https, wpDebug: wpDebug, scriptDebug: scriptDebug)

        guard let site, vm.store.site(id: site.id)?.status.isRunning == true else {
            errorText = vm.lastError ?? "Could not create the site."
            phase = .failed
            return
        }

        // Register the custom domain as a separate, honest, skippable step so the
        // blocking /etc/hosts admin prompt never looks like a hung "Finishing up…".
        if let configured = vm.store.site(id: site.id)?.customDomain, !configured.isEmpty {
            await registerDomainStep(site: site, domain: configured)
        }
        dismiss()
    }

    /// Drive the domain-registration step with an honest label, a Skip button
    /// after 10s, and a hard 2-minute timeout — all resolving to a successful
    /// (domain-unregistered) site rather than an indefinite spinner (§2l).
    private func registerDomainStep(site: Site, domain: String) async {
        phase = .registeringDomain
        domainStatus = "Waiting for admin approval to register \(domain)…"
        showSkip = false

        let task = Task { await vm.registerCustomDomain(site) }
        domainRegTask = task

        let reveal = Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            if !task.isCancelled { showSkip = true }
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(120))
            task.cancel()
        }

        let outcome = await task.value
        reveal.cancel()
        timeout.cancel()
        showSkip = false

        if case .registered = outcome {} else {
            // Skipped, timed out, or a soft failure — the site still exists.
            domainStatus = "Domain not registered. Register it later from the site's Domain settings."
            try? await Task.sleep(for: .seconds(1.2))
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
