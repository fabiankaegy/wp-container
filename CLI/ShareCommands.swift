import ArgumentParser
import Foundation
import WPContainerKit

// MARK: - share

struct ShareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "share",
        abstract: "Share a site or env on a public URL behind a password.",
        discussion: """
        `share <site>` starts the target when it is stopped, then opens a public tunnel \
        through the configured provider (ngrok, cloudflared, or an executable in the \
        share-providers directory). Visitors sign in with the printed username and \
        password. The proxy host (`wp-container proxy serve` or the app) must be running.
        """,
        subcommands: [ShareStart.self, ShareStop.self, ShareList.self, ShareDefault.self],
        defaultSubcommand: ShareStart.self
    )
}

struct ShareStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start sharing a site or env (the default `share` action)."
    )
    @Argument(help: "Site slug or env slug.") var target: String
    @Option(name: .long, help: "Provider: ngrok, cloudflared, or a custom provider name.") var provider: String?
    @Option(name: .long, help: "Fixed public hostname, when the provider supports one.") var hostname: String?
    @Flag(name: .long, help: "Forget the fixed hostname.") var clearHostname = false
    @Option(name: .long, help: "Request that bypasses the password: /path-prefix or ?query-key[=value]. Repeatable.") var allow: [String] = []
    @Flag(name: .long, help: "Remove all saved password exceptions before applying --allow.") var clearAllow = false
    @Flag(name: .long, help: "Generate a new password.") var resetPassword = false
    @Flag(name: .long, help: "Turn the password gate off for this share.") var noAuth = false
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            if hostname != nil && clearHostname {
                throw CLIErrorJSON("bad_args", detail: "--hostname and --clear-hostname cannot be combined")
            }
            let envelope = try await ctx.load()
            guard let resolved = resolveTarget(target, in: envelope) else { throw CLIErrorJSON("not_found", detail: target) }
            let inst = resolved.instance
            await ctx.persistence.recordActivity(instanceID: inst.instanceID)
            try await ctx.ensureRunning(resolved, envelope: envelope)

            var hostnameChange: String?? = nil
            if clearHostname {
                hostnameChange = .some(nil)
            } else if let hostname {
                hostnameChange = .some(hostname)
            }
            let request = ShareRequest(provider: provider, hostname: hostnameChange, addAllow: allow,
                                       clearAllow: clearAllow, resetPassword: resetPassword, noAuth: noAuth)
            let control = ShareControl(persistence: ctx.persistence)
            let settings = try await control.request(instanceID: inst.instanceID, request)
            let status = try await control.waitForStatus(instanceID: inst.instanceID, requestID: settings.requestID)

            if status.state == .down {
                throw CLIErrorJSON("share_failed", detail: status.error ?? "the share could not start")
            }
            let url = status.url ?? ""
            let allowList = settings.allow.map(\.description)
            if output.json {
                emitLine(CLIJSON.string(ShareStartOutput(url: url, temporary: status.temporary, provider: status.provider,
                                                         username: settings.username, password: settings.password,
                                                         instance: status.slug, allow: allowList,
                                                         state: status.state.rawValue)))
            } else {
                emitLine(url)
                emitLine(status.temporary ? "temporary" : "permanent")
                emitLine("username: \(settings.username)")
                emitLine("password: \(settings.password)")
                if !allowList.isEmpty {
                    emitLine("allowed without password: \(allowList.joined(separator: ", "))")
                }
                if noAuth {
                    emitLine("This link is open to anyone who has the URL, including wp-admin.")
                }
            }
        } catch {
            throw failCommand(error, json: output.json)
        }
    }
}

struct ShareStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop sharing a site or env; its credentials and exceptions are kept."
    )
    @Argument(help: "Site slug or env slug.") var target: String
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let envelope = try await ctx.load()
            guard let resolved = resolveTarget(target, in: envelope) else { throw CLIErrorJSON("not_found", detail: target) }
            let instanceID = resolved.instance.instanceID
            try await ShareControl(persistence: ctx.persistence).stop(instanceID: instanceID)
            if output.json {
                emitLine(CLIJSON.string(ShareStopOutput(ok: true, instance: target)))
            } else {
                emitLine("Stopped sharing \(target).")
            }
        } catch {
            throw failCommand(error, json: output.json)
        }
    }
}

struct ShareList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List sites and envs that have share settings."
    )
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let envelope = try await ctx.load()
            let rows = try await ShareControl(persistence: ctx.persistence).list().map { entry -> ShareListRow in
                let status = entry.status
                let state: String
                switch (entry.settings.active, status?.state) {
                case (false, _): state = "inactive"
                case (true, .some(let s)): state = s.rawValue
                case (true, nil): state = "starting"
                }
                return ShareListRow(instance: entry.instance.containerSlug, state: state,
                                    url: status?.url,
                                    provider: status?.provider ?? envelope.effectiveProvider(for: entry.settings),
                                    temporary: status?.temporary,
                                    error: status?.error)
            }
            if output.json {
                emitLine(CLIJSON.string(rows))
            } else if rows.isEmpty {
                emitLine("No shares.")
            } else {
                for row in rows {
                    var line = "\(row.instance)  \(row.state)  \(row.provider)"
                    if let url = row.url { line += "  \(url)" }
                    if let temporary = row.temporary { line += temporary ? " (temporary)" : " (permanent)" }
                    if let error = row.error { line += "  error: \(error)" }
                    emitLine(line)
                }
            }
        } catch {
            throw failCommand(error, json: output.json)
        }
    }
}

struct ShareDefault: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "default",
        abstract: "Show or set the provider used by shares that name none."
    )
    @Argument(help: "Provider to use by default; omit to show the current one.") var provider: String?
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            if let provider {
                try await ShareControl(persistence: ctx.persistence).setDefaultProvider(provider)
            }
            let envelope = try await ctx.load()
            let effective = envelope.effectiveProvider(for: nil)
            if output.json {
                emitLine(CLIJSON.string(ShareDefaultOutput(provider: effective)))
            } else {
                emitLine(effective)
            }
        } catch {
            throw failCommand(error, json: output.json)
        }
    }
}

private struct ShareStartOutput: Encodable {
    let url: String
    let temporary: Bool
    let provider: String
    let username: String
    let password: String
    let instance: String
    let allow: [String]
    let state: String
}

private struct ShareStopOutput: Encodable {
    let ok: Bool
    let instance: String
}

private struct ShareListRow: Encodable {
    let instance: String
    let state: String
    let url: String?
    let provider: String
    let temporary: Bool?
    let error: String?
}

private struct ShareDefaultOutput: Encodable {
    let provider: String
}
