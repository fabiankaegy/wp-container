import SwiftUI
import WPContainerKit

/// Sheet for creating a worktree branch environment: pick a git repo found
/// under the site's `wp-content`, name a branch (with existing-branch
/// autocomplete), optionally set a base ref, then Create with inline progress
/// and a prominent result URL on success.
struct NewBranchEnvSheet: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    let site: Site

    @State private var repos: [GitRepo] = []
    @State private var loadingRepos = true
    @State private var selectedRepoPath: String?
    @State private var branch = ""
    @State private var fromRef = ""
    @State private var knownBranches: [String] = []

    @State private var phase: Phase = .idle
    @State private var errorText: String?
    @State private var errorDetail: String?
    @State private var createdEnv: WorktreeEnv?

    private enum Phase { case idle, working, done, failed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 480)
        .task {
            repos = await vm.repos(for: site)
            selectedRepoPath = repos.first?.relativePath
            loadingRepos = false
            await loadBranches()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.title2).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("New Branch Environment").font(.headline)
                Text("An isolated copy of \(site.name) on its own port.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if phase == .done, let env = createdEnv {
            successView(env)
        } else if loadingRepos {
            ProgressView("Looking for git repositories…")
                .frame(maxWidth: .infinity).padding(30)
        } else if repos.isEmpty {
            noReposView
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            Section("Repository") {
                Picker("Repo", selection: $selectedRepoPath) {
                    ForEach(repos) { repo in
                        Text(repo.relativePath).tag(Optional(repo.relativePath))
                    }
                }
                .disabled(phase == .working)
                .onChange(of: selectedRepoPath) { Task { await loadBranches() } }
            }
            Section("Branch") {
                TextField("Branch name", text: $branch, prompt: Text("feature-x"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(phase == .working)
                if !branchSuggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(branchSuggestions, id: \.self) { name in
                                Button(name) { branch = name }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                }
                if isNewBranch {
                    TextField("Base ref (optional)", text: $fromRef, prompt: Text("main"))
                        .textFieldStyle(.roundedBorder)
                        .disabled(phase == .working)
                    Text("Branch doesn't exist yet — it will be created\(fromRef.isEmpty ? "" : " from \(fromRef)").")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if phase == .working {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Cloning site files, database, and starting containers… (~5s)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if phase == .failed, let errorText {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red)
                        Text("The half-created environment was rolled back (the branch was kept).")
                            .font(.caption2).foregroundStyle(.secondary)
                        if let errorDetail, errorDetail != errorText {
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
        }
        .formStyle(.grouped)
    }

    private func successView(_ env: WorktreeEnv) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40)).foregroundStyle(.green)
            Text("Environment ready").font(.headline)
            Text("Branch \(env.branch) of \(env.repoRelPath)")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(env.localURL.absoluteString) { SystemActions.openInBrowser(env.localURL) }
                    .buttonStyle(.link)
                CopyButton(value: env.localURL.absoluteString)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(28)
    }

    private var noReposView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No git repositories found under this site's `wp-content`.")
                .font(.callout)
            Text("Add a plugin or theme that is a git repo (has a `.git` folder), then try again.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }

    private var footer: some View {
        HStack {
            Button(phase == .done ? "Done" : "Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(phase == .working)
            Spacer()
            if phase != .done {
                Button("Create Environment") { Task { await create() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedRepo == nil || branch.trimmingCharacters(in: .whitespaces).isEmpty || phase == .working)
            }
        }
        .padding(16)
    }

    // MARK: Derived

    private var selectedRepo: GitRepo? {
        repos.first { $0.relativePath == selectedRepoPath }
    }
    private var isNewBranch: Bool {
        !branch.isEmpty && !knownBranches.contains(branch)
    }
    private var branchSuggestions: [String] {
        let q = branch.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? knownBranches : knownBranches.filter { $0.localizedCaseInsensitiveContains(q) && $0 != q }
        return Array(base.prefix(6))
    }

    // MARK: Actions

    private func loadBranches() async {
        guard let repo = selectedRepo else { knownBranches = []; return }
        knownBranches = await vm.branches(inRepo: repo)
    }

    private func create() async {
        guard let repo = selectedRepo else { return }
        phase = .working
        errorText = nil
        errorDetail = nil
        vm.lastError = nil
        vm.lastErrorDetail = nil
        let from = fromRef.trimmingCharacters(in: .whitespaces)
        let env = await vm.createEnvAwaiting(parent: site, repoRelPath: repo.relativePath,
                                             branch: branch.trimmingCharacters(in: .whitespaces),
                                             from: from.isEmpty ? nil : from)
        if let env {
            createdEnv = env
            phase = .done
        } else {
            errorText = vm.lastError ?? "Could not create the environment."
            errorDetail = vm.lastErrorDetail
            phase = .failed
        }
    }
}
