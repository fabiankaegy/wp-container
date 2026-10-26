import SwiftUI
import WPContainerKit

/// "Share" card: publishes the site or environment on a public URL behind a
/// username and password. Starting a share on a stopped instance starts the
/// instance first. The provider, fixed hostname, password exceptions and a password
/// reset apply the next time the share starts; a live share's password can also be
/// reset on demand. A share that went down shows its error and can be retried.
struct ShareCard: View {
    @Environment(AppViewModel.self) private var vm

    let instanceID: UUID
    let share: ShareSettings?
    let networkType: NetworkType

    @State private var provider: String?
    @State private var hostname = ""
    @State private var allow: [String] = []
    @State private var newAllow = ""
    @State private var allowError: String?
    @State private var noAuth = false
    @State private var resetPassword = false
    @State private var revealPassword = false
    @State private var customProviders: [String] = []
    @State private var seeded = false
    @State private var seededSnapshot = Snapshot()

    private struct Snapshot: Equatable {
        var provider: String?
        var hostname = ""
        var allow: [String] = []
    }

    private var current: Snapshot { Snapshot(provider: provider, hostname: hostname, allow: allow) }
    private var status: ShareStatus? { vm.shareStatus(for: instanceID) }
    private var isStarting: Bool { vm.sharesStarting.contains(instanceID) || status?.state == .starting }
    private var isLive: Bool { share?.active == true && status?.state == .live }
    /// The share's last request ended `down`; the store no longer marks it active.
    private var isDown: Bool {
        guard let share, let status, status.state == .down else { return false }
        return status.requestID == share.requestID
    }
    private var errorText: String? {
        if let error = vm.shareErrors[instanceID] { return error }
        guard isDown else { return nil }
        return status?.error ?? "The share is down."
    }

    var body: some View {
        SectionCard(title: "Share", systemImage: "link") {
            if networkType == .subdomain {
                Text("Sharing isn’t available for subdomain multisite networks, which need one public hostname per subsite.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                content
            }
        }
        .onChange(of: share) {
            if current == seededSnapshot { applySaved() }
        }
        .task {
            customProviders = vm.customShareProviders()
            await vm.loadShareDefaultProvider()
            seed()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Public link").font(.callout.weight(.medium))
                    Text("Anyone with the link and password can open this site while it is shared. Sharing ends when the site stops or the app quits.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                actionButton
            }

            if isStarting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Starting…").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let errorText, !isLive {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if isLive, let share, let status {
                liveDetails(share: share, status: status)
            }

            if !isLive && !isStarting {
                Divider().opacity(0.5)
                options
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if isStarting {
            Button("Cancel") { Task { await vm.stopShare(instanceID) } }
        } else if isLive {
            Button("Stop sharing") { Task { await vm.stopShare(instanceID) } }
        } else {
            Button(isDown ? "Retry" : "Start sharing") {
                Task {
                    await vm.startShare(instanceID, request: request(resetPassword: resetPassword, noAuth: noAuth))
                    resetPassword = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!seeded)
        }
    }

    private func liveDetails(share: ShareSettings, status: ShareStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let urlText = status.url {
                valueRow("URL", value: urlText, copyLabel: "Copy share URL") {
                    Text(status.temporary ? "Temporary" : "Permanent")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
            if share.authDisabled {
                Label("This link is open to anyone who has the URL, including wp-admin.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                valueRow("Username", value: share.username, copyLabel: "Copy username") { EmptyView() }
                passwordRow(share.password)
                HStack {
                    Spacer(minLength: 0)
                    Button("Reset password") {
                        Task { await vm.startShare(instanceID, request: request(resetPassword: true, noAuth: false)) }
                    }
                    .help("Generate a new password; the old one stops working at once.")
                }
            }
        }
    }

    private func valueRow<Badge: View>(_ title: String, value: String, copyLabel: String,
                                       @ViewBuilder badge: () -> Badge) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 68, alignment: .leading)
            Text(value).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            badge()
            Spacer(minLength: 0)
            copyButton(value, label: copyLabel)
        }
    }

    private func passwordRow(_ password: String) -> some View {
        HStack(spacing: 8) {
            Text("Password").font(.caption).foregroundStyle(.secondary).frame(width: 68, alignment: .leading)
            Text(revealPassword ? password : String(repeating: "•", count: 12))
                .font(.callout.monospaced()).textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                revealPassword.toggle()
            } label: {
                Image(systemName: revealPassword ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(revealPassword ? "Hide password" : "Show password")
            .help(revealPassword ? "Hide password" : "Show password")
            copyButton(password, label: "Copy password")
        }
    }

    private func copyButton(_ text: String, label: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .help(label)
    }

    private var defaultProvider: String { vm.shareDefaultProvider ?? ShareSettings.defaultProvider }

    /// Every provider except the default, which the Default entry already
    /// stands for. A share that saved the default provider by name still lists
    /// it, so its selection stays visible.
    private var providerChoices: [String] {
        (ShareSettings.builtInProviders + customProviders).filter { $0 != defaultProvider || $0 == provider }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Provider").font(.callout.weight(.medium))
                    Text("The tunnel that publishes the link. Custom providers are executables in the share-providers folder.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Picker("", selection: $provider) {
                    Text("Default (\(defaultProvider))").tag(String?.none)
                    ForEach(providerChoices, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .labelsHidden().fixedSize()
            }

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fixed hostname").font(.callout.weight(.medium))
                    Text("Optional. Leave empty for a temporary address when the provider offers one.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                TextField("share.example.com", text: $hostname)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Open without password").font(.callout.weight(.medium))
                Text("Requests that skip the password: a path prefix such as /wp-json/wc/v3/webhooks or a query such as ?wc-api=wc_stripe. A query applies on every path, and these requests reach the site without cookies.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(allow, id: \.self) { rule in
                    HStack {
                        Text(rule).font(.callout.monospaced())
                        Spacer()
                        Button {
                            allow.removeAll { $0 == rule }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(rule)")
                        .help("Remove")
                    }
                }
                HStack {
                    TextField("/path or ?key=value", text: $newAllow)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addAllow)
                    Button("Add", action: addAllow)
                        .disabled(newAllow.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let allowError {
                    Text(allowError).font(.caption).foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Generate a new password", isOn: $resetPassword)
                Text("Applies when the share starts; the old password stops working.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Turn off password for this share", isOn: $noAuth)
                if noAuth {
                    Label("This link is open to anyone who has the URL, including wp-admin.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func seed() {
        guard !seeded else { return }
        applySaved()
        seeded = true
    }

    private func applySaved() {
        provider = share?.provider
        hostname = share?.hostname ?? ""
        allow = share?.allow.map(\.description) ?? []
        seededSnapshot = current
    }

    private func addAllow() {
        let text = newAllow.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        do {
            _ = try ShareException(parsing: text)
            if !allow.contains(text) { allow.append(text) }
            newAllow = ""
            allowError = nil
        } catch {
            allowError = "\(error)"
        }
    }

    private func request(resetPassword: Bool, noAuth: Bool) -> ShareRequest {
        let trimmedHostname = hostname.trimmingCharacters(in: .whitespaces)
        var hostnameChange: String?? = nil
        if !trimmedHostname.isEmpty {
            hostnameChange = .some(trimmedHostname)
        } else if share?.hostname != nil {
            hostnameChange = .some(nil)
        }
        return ShareRequest(provider: provider, clearProvider: provider == nil, hostname: hostnameChange, addAllow: allow,
                            clearAllow: true, resetPassword: resetPassword, noAuth: noAuth)
    }
}
