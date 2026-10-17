import Foundation

/// Writes (and removes) the per-site AI-agent integration files (PLAN.md §2d):
/// `.mcp.json` (Claude Code), `.cursor/mcp.json`, `.vscode/mcp.json`, a marked
/// block in an `AGENTS.md` (or `CLAUDE.md`) doc, `.gitignore` entries, and the
/// `wp` shim — all at a chosen **placement root** (the site folder by default,
/// or a git repo under `wp-content` where the user actually opens their IDE).
///
/// The doc block is wrapped in `<!-- BEGIN:wp-container:<slug> -->` /
/// `<!-- END:wp-container:<slug> -->` markers (AGENTS.md convention) and is
/// appended/updated NON-destructively: existing user content is always
/// preserved; only our block is replaced or removed.
public enum AgentToolsService {
    /// Installed CLI path the generated configs invoke.
    public static let cliPath = "/usr/local/bin/wp-container"

    /// Canonical MCP tool names (single source of truth shared with the server
    /// and the doc so they never drift). 20 tools (issue #13 added two).
    public static let mcpToolNames: [String] = [
        "wp_cli", "read_error_log", "read_access_log", "wp_debug_toggle",
        "read_wp_config", "edit_wp_config", "get_site_info", "site_health_check",
        "site_start", "site_stop", "site_restart", "site_status", "list_sites",
        "worktree_create", "worktree_list", "worktree_delete",
        "xdebug_toggle", "elasticsearch_toggle", "redis_toggle",
        "login_link", "create_user",
    ]

    public static let defaultDocName = "AGENTS.md"
    public static let alternateDocName = "CLAUDE.md"

    private static let configFiles = [".mcp.json", ".cursor/mcp.json", ".vscode/mcp.json"]
    private static let gitignoreBegin = "# BEGIN wp-container agent tools"
    private static let gitignoreEnd = "# END wp-container agent tools"

    public struct Result: Sendable {
        public let written: [String]
        public let root: String
        public let docName: String
    }

    private static func beginMarker(_ slug: String) -> String { "<!-- BEGIN:wp-container:\(slug) -->" }
    private static func endMarker(_ slug: String) -> String { "<!-- END:wp-container:\(slug) -->" }

    // MARK: - Placement

    /// Choose the doc filename for a root: keep an existing AGENTS.md; else if a
    /// CLAUDE.md already exists (and no AGENTS.md), append to it; else AGENTS.md.
    public static func preferredDocName(inRoot root: URL) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent(defaultDocName).path) { return defaultDocName }
        if fm.fileExists(atPath: root.appendingPathComponent(alternateDocName).path) { return alternateDocName }
        return defaultDocName
    }

    // MARK: - Enable

    /// Enable agent tools at `root`. `repoRelPath` (relative to `wordpress/`)
    /// prefills the worktree commands when the root IS a repo under wp-content.
    @discardableResult
    public static func enable(site: Site, root: URL, docName: String? = nil, repoRelPath: String? = nil) throws -> Result {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let doc = docName ?? preferredDocName(inRoot: root)
        var written: [String] = []

        let mcpServers = mcpServersJSON(slug: site.slug)
        try write(mcpServers, to: root.appendingPathComponent(".mcp.json")); written.append(".mcp.json")

        try fm.createDirectory(at: root.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        try write(mcpServers, to: root.appendingPathComponent(".cursor/mcp.json")); written.append(".cursor/mcp.json")

        try fm.createDirectory(at: root.appendingPathComponent(".vscode"), withIntermediateDirectories: true)
        try write(vscodeJSON(slug: site.slug), to: root.appendingPathComponent(".vscode/mcp.json")); written.append(".vscode/mcp.json")

        // Marked doc block (append/update, never clobber).
        let docURL = root.appendingPathComponent(doc)
        let existing = (try? String(contentsOf: docURL, encoding: .utf8)) ?? ""
        let block = docBlock(site: site, root: root, repoRelPath: repoRelPath)
        try upsertBlock(in: existing, slug: site.slug, block: block).write(to: docURL, atomically: true, encoding: .utf8)
        written.append(doc)

        // wp shim at the root, pointing at the site's absolute wordpress path.
        _ = try? WPCLIShim.writeShim(for: site, siteRoot: root, slug: site.slug)
        written.append("wp")

        try updateGitignore(root: root, docName: doc, enabled: true); written.append(".gitignore")

        return Result(written: written, root: root.path, docName: doc)
    }

    // MARK: - Disable

    public static func disable(site: Site, root: URL, docName: String? = nil) throws {
        let fm = FileManager.default
        for rel in configFiles { try? fm.removeItem(at: root.appendingPathComponent(rel)) }
        for dir in [".cursor", ".vscode"] {
            let url = root.appendingPathComponent(dir)
            if let contents = try? fm.contentsOfDirectory(atPath: url.path), contents.isEmpty {
                try? fm.removeItem(at: url)
            }
        }
        // Remove only our block from the doc; leave the rest of the file intact.
        let doc = docName ?? preferredDocName(inRoot: root)
        let docURL = root.appendingPathComponent(doc)
        if let existing = try? String(contentsOf: docURL, encoding: .utf8) {
            let stripped = removeBlock(in: existing, slug: site.slug)
            if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? fm.removeItem(at: docURL)
            } else {
                try? stripped.write(to: docURL, atomically: true, encoding: .utf8)
            }
        }
        try updateGitignore(root: root, docName: doc, enabled: false)
    }

    /// True when the marker `.mcp.json` is present at the site's recorded root
    /// (or the site folder default).
    public static func isEnabled(site: Site) -> Bool {
        let root = site.agentToolsRoot.map { URL(fileURLWithPath: $0) } ?? site.path
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(".mcp.json").path)
    }

    // MARK: - Marked-block upsert (pure, testable)

    /// Insert or replace our `<!-- BEGIN:wp-container:<slug> -->…END` block in
    /// `contents`. Appends when absent, replaces in place when present.
    public static func upsertBlock(in contents: String, slug: String, block: String) -> String {
        let begin = beginMarker(slug), end = endMarker(slug)
        let wrapped = "\(begin)\n\(block)\n\(end)"
        var lines = contents.components(separatedBy: "\n")
        if let b = lines.firstIndex(of: begin), let e = lines[b...].firstIndex(of: end) {
            lines.replaceSubrange(b...e, with: wrapped.components(separatedBy: "\n"))
            return lines.joined(separator: "\n")
        }
        var out = contents
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        if !out.isEmpty { out += "\n" }
        return out + wrapped + "\n"
    }

    /// Remove our block (marker-to-marker) from `contents`, tidying blank runs.
    public static func removeBlock(in contents: String, slug: String) -> String {
        let begin = beginMarker(slug), end = endMarker(slug)
        var lines = contents.components(separatedBy: "\n")
        if let b = lines.firstIndex(of: begin), let e = lines[b...].firstIndex(of: end) {
            lines.removeSubrange(b...e)
            // Drop a single leading blank the append left behind.
            if b > 0, b - 1 < lines.count, lines[b - 1].isEmpty { lines.remove(at: b - 1) }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
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

    // MARK: - Doc block content (concise, absolute paths)

    private static func docBlock(site: Site, root: URL, repoRelPath: String?) -> String {
        let shim = root.appendingPathComponent("wp").path
        let repoArg = repoRelPath ?? "wp-content/plugins/your-plugin"
        let toolList = mcpToolNames.map { "`\($0)`" }.joined(separator: ", ")
        let repoLine = repoRelPath.map { "\nThis repo lives at `wp-content/\($0.hasPrefix("wp-content/") ? String($0.dropFirst("wp-content/".count)) : $0)` inside the site." } ?? ""
        return """
        # \(site.name) — WP Container

        This directory is part of the local WordPress site **\(site.name)** (`\(site.slug)`),
        running on Apple `container` via WP Container.\(repoLine)

        - **Site URL:** \(site.url.absoluteString)
        - **WP Admin:** \(site.wpAdminURL.absoluteString) — user `\(SiteRecipe.adminUser)`, password `\(SiteRecipe.adminPassword)`
        - **Browser login:** run `wpc login \(site.slug)` for a one-time magic login link (or the `login_link` MCP tool) — avoids the wp-login form.
        - **WordPress root:** `\(site.wordpressFolder.path)`

        ## Running wp-cli

        Use the site's shim (containerized wp-cli), by ABSOLUTE path so it works from any cwd:

        ```bash
        \(shim) plugin list
        ```

        ⚠️ Plain `wp` typed in a shell usually resolves to Homebrew's wp-cli
        (`/opt/homebrew/bin/wp`), which does NOT know this container and will fail with
        "not a WordPress installation". Either call the shim above, or install the global
        router once with `wp-container setup wp` so plain `wp` inside this site works.

        ## Branch environments (git worktrees)

        ```bash
        wp-container worktree create --site \(site.slug) --repo \(repoArg) --branch feature-x --json
        wp-container worktree delete \(site.slug)-wt-feature-x
        ```

        ## MCP tools

        An MCP server is registered in `.mcp.json` (this directory). Tools: \(toolList).
        Prefer them over ad-hoc shell — they return structured JSON and keep state consistent.
        """
    }

    // MARK: - .gitignore

    private static func updateGitignore(root: URL, docName: String, enabled: Bool) throws {
        let url = root.appendingPathComponent(".gitignore")
        var lines: [String] = []
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            lines = existing.components(separatedBy: "\n")
        }
        if let start = lines.firstIndex(of: gitignoreBegin), let end = lines.firstIndex(of: gitignoreEnd), end >= start {
            lines.removeSubrange(start...end)
            while lines.last == "" { lines.removeLast() }
        }
        if enabled {
            if !lines.isEmpty && lines.last != "" { lines.append("") }
            lines.append(contentsOf: [
                gitignoreBegin,
                ".mcp.json", ".cursor/mcp.json", ".vscode/mcp.json",
                docName, "/wp",
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
