import Foundation

/// Writes (and removes) the per-site AI-agent integration files (PLAN.md §2d):
/// `.mcp.json` (Claude Code), `.cursor/mcp.json`, `.vscode/mcp.json`, a generated
/// `CLAUDE.md` project-context file, `.gitignore` entries, and the `wp` shim.
///
/// All operations are idempotent. `enable` overwrites the generated files;
/// `disable` removes them (leaving the `wp` shim, which is a §2e site fixture).
public enum AgentToolsService {
    /// Installed CLI path the generated configs invoke.
    public static let cliPath = "/usr/local/bin/wp-container"

    /// Canonical MCP tool names (single source of truth shared with the server
    /// and CLAUDE.md so they never drift).
    public static let mcpToolNames: [String] = [
        "wp_cli", "read_error_log", "read_access_log", "wp_debug_toggle",
        "read_wp_config", "edit_wp_config", "get_site_info", "site_health_check",
        "site_start", "site_stop", "site_restart", "site_status", "list_sites",
        "worktree_create", "worktree_list", "worktree_delete",
    ]

    private static let gitignoreBegin = "# BEGIN WP Container agent tools"
    private static let gitignoreEnd = "# END WP Container agent tools"
    private static let generatedFiles = [".mcp.json", ".cursor/mcp.json", ".vscode/mcp.json", "CLAUDE.md"]

    public struct Result: Sendable {
        public let written: [String]
    }

    // MARK: - Enable

    @discardableResult
    public static func enable(site: Site) throws -> Result {
        let root = site.path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var written: [String] = []

        // .mcp.json (Claude Code) + .cursor/mcp.json share the `mcpServers` shape.
        let mcpServers = mcpServersJSON(slug: site.slug)
        try write(mcpServers, to: root.appendingPathComponent(".mcp.json"))
        written.append(".mcp.json")

        try FileManager.default.createDirectory(at: root.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        try write(mcpServers, to: root.appendingPathComponent(".cursor/mcp.json"))
        written.append(".cursor/mcp.json")

        // VS Code uses a top-level `servers` key.
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".vscode"), withIntermediateDirectories: true)
        try write(vscodeJSON(slug: site.slug), to: root.appendingPathComponent(".vscode/mcp.json"))
        written.append(".vscode/mcp.json")

        // Generated project context.
        try claudeMarkdown(site: site).write(to: root.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        written.append("CLAUDE.md")

        // wp shim (also a §2e fixture — harmless to (re)write here).
        _ = try? WPCLIShim.writeShim(slug: site.slug, siteRoot: root)
        written.append("wp")

        try updateGitignore(root: root, enabled: true)
        written.append(".gitignore")

        return Result(written: written)
    }

    // MARK: - Disable

    public static func disable(site: Site) throws {
        let root = site.path
        for rel in generatedFiles {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(rel))
        }
        // Remove now-empty .cursor/.vscode dirs if we created them.
        for dir in [".cursor", ".vscode"] {
            let url = root.appendingPathComponent(dir)
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path), contents.isEmpty {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try updateGitignore(root: root, enabled: false)
    }

    /// True when the marker config files are present.
    public static func isEnabled(site: Site) -> Bool {
        FileManager.default.fileExists(atPath: site.path.appendingPathComponent(".mcp.json").path)
    }

    // MARK: - JSON payloads

    private static func mcpServersJSON(slug: String) -> String {
        """
        {
          "mcpServers": {
            "wp-container": {
              "command": "\(cliPath)",
              "args": ["mcp", "--site", "\(slug)"]
            }
          }
        }
        """
    }

    private static func vscodeJSON(slug: String) -> String {
        """
        {
          "servers": {
            "wp-container": {
              "command": "\(cliPath)",
              "args": ["mcp", "--site", "\(slug)"]
            }
          }
        }
        """
    }

    // MARK: - CLAUDE.md

    private static func claudeMarkdown(site: Site) -> String {
        let toolList = mcpToolNames.map { "- `\($0)`" }.joined(separator: "\n")
        return """
        # \(site.name) — WP Container project context

        This WordPress site runs on Apple `container` via **WP Container**. It is managed
        by the `wp-container` CLI and exposes an MCP server (already registered in
        `.mcp.json`) so you can operate it with structured tools.

        ## Site facts

        | Key | Value |
        | --- | --- |
        | Slug | `\(site.slug)` |
        | Local URL | \(site.localURL.absoluteString) |
        | HTTPS URL | \(site.secureURL.absoluteString)\(site.httpsEnabled ? "" : " (enable HTTPS first)") |
        | Port | \(site.port) |
        | Site folder | `\(site.path.path)` |
        | WordPress root | `\(site.wordpressFolder.path)` |
        | Database dir | `\(site.databaseFolder.path)` |
        | Image | `\(site.imageTag)` |
        | Admin user | `\(SiteRecipe.adminUser)` |
        | Admin password | `\(SiteRecipe.adminPassword)` |

        ## WP-CLI

        Every wp-cli command works through the site's `wp` shim (resolves the DB
        container automatically):

        ```bash
        cd "\(site.path.path)"
        ./wp plugin list
        ./wp option get siteurl
        ```

        Or through the CLI proxy from anywhere: `wp-container wp \(site.slug) -- plugin list`.

        ## Branch environments (git worktrees)

        Spin up an isolated clone of this site bound to a git branch of a repo under
        `wp-content` — the parent site keeps running untouched:

        ```bash
        # Create (prints a JSON descriptor with url/port/paths):
        wp-container worktree create --site \(site.slug) --repo wp-content/plugins/my-plugin --branch feature-x --json
        # List / delete:
        wp-container worktree list --site \(site.slug) --json
        wp-container worktree delete \(site.slug)-wt-feature-x
        ```

        The same actions are available as the `worktree_create` / `worktree_list` /
        `worktree_delete` MCP tools.

        ## MCP tools available

        \(toolList)

        Prefer these tools over ad-hoc shell commands: they return structured JSON and
        keep the site's state consistent.
        """
    }

    // MARK: - .gitignore

    private static func updateGitignore(root: URL, enabled: Bool) throws {
        let url = root.appendingPathComponent(".gitignore")
        var lines: [String] = []
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            lines = existing.components(separatedBy: "\n")
        }
        // Strip any prior managed block.
        if let start = lines.firstIndex(of: gitignoreBegin), let end = lines.firstIndex(of: gitignoreEnd), end >= start {
            lines.removeSubrange(start...end)
            while lines.last == "" { lines.removeLast() }
        }
        if enabled {
            if !lines.isEmpty && lines.last != "" { lines.append("") }
            lines.append(contentsOf: [
                gitignoreBegin,
                ".mcp.json",
                ".cursor/mcp.json",
                ".vscode/mcp.json",
                "CLAUDE.md",
                "/wp",
                gitignoreEnd,
            ])
        }
        let output = lines.joined(separator: "\n")
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try (output.hasSuffix("\n") ? output : output + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
