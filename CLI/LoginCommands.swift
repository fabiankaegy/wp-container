import ArgumentParser
import Foundation
import WPContainerKit

// MARK: - login (one-time browser magic link, issue #13)

struct LoginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Print a one-time browser login link (magic link) for a site.",
        discussion: """
        Mints a single-use token whose SHA-256 hash is stored in the \
        `wpc_magic_login` option; a private PHP auto_prepend handler (kept in the \
        site's mounted php/ folder, never in the project tree) validates it. \
        Opening the printed URL in a browser starts a logged-in wp-admin session \
        — no wp-login.php form. The link expires in 15 minutes and works exactly \
        once. A site started before magic-login support needs one restart.
        """
    )
    @Argument(help: "Site slug or env slug.") var target: String
    @Option(name: .long, help: "WordPress user login to log in as (default: admin).") var user: String = SiteRecipe.adminUser
    @Flag(name: .long, help: "Also open the link in the default browser.") var open = false
    @OptionGroup var output: JSONOptions

    func run() async throws {
        let ctx = CLIContext()
        do {
            let envelope = try await ctx.load()
            guard let resolved = resolveTarget(target, in: envelope) else { throw CLIErrorJSON("not_found", detail: target) }
            let inst = resolved.instance
            guard let dbHost = try await ctx.cli.ipAddress(of: inst.dbContainerName) else {
                throw CLIErrorJSON("not_running", detail: "start \(target) first")
            }
            let publicURL: URL
            switch resolved {
            case .site(let s): publicURL = s.url
            case .env(let e): publicURL = e.localURL
            }
            var mailHost: String? = nil
            if inst.mailpitEnabled { mailHost = (try? await ctx.cli.ipAddress(of: inst.mailContainerName)) ?? nil }

            // The site is running (dbHost resolved). Capture whether the handler
            // was already active BEFORE ensuring; if not, this running container
            // predates it and needs a restart for the link to work.
            let alreadyActive = MagicLoginService.isLoginActive(for: inst)
            try PrependService.ensure(for: inst)
            try MagicLoginService.ensureLoginHandler(for: inst)
            let warning = alreadyActive ? nil :
                "This site was started before magic-login support; restart it for the link to work: wp-container stop \(target) && wp-container start \(target)"
            let link = try await MagicLoginService.issueLoginLink(for: inst, publicURL: publicURL, dbHost: dbHost,
                                                                 cli: ctx.cli, user: user, mailpitHost: mailHost)
            if output.json {
                emitLine(CLIJSON.string(LoginLinkOutput(url: link.url.absoluteString, user: link.user,
                                                        expiresAt: link.expiresAt, warning: warning)))
            } else {
                emitLine(link.url.absoluteString)
                emitLine("One-time link for \(link.user); expires in 15 minutes. Open it in a browser for a logged-in wp-admin session.")
                if let warning { emitLine("warning: \(warning)") }
            }
            if open {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = [link.url.absoluteString]
                try? p.run()
                p.waitUntilExit()
            }
        } catch {
            throw failCommand(error, json: output.json)
        }
    }
}

/// `wp-container login --json` payload: the link plus an optional stale-container
/// warning (omitted when the handler was already active).
private struct LoginLinkOutput: Encodable {
    let url: String
    let user: String
    let expiresAt: Date
    let warning: String?
}
