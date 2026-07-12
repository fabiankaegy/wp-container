import Foundation
import MCP
import WPContainerKit

/// The MCP tool catalog (schemas). Behaviors live in `MCPToolDispatch`.
enum MCPTools {
    private static func obj(_ properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }
    private static func str(_ desc: String) -> Value { ["type": "string", "description": .string(desc)] }
    private static func int(_ desc: String) -> Value { ["type": "integer", "description": .string(desc)] }
    private static func bool(_ desc: String) -> Value { ["type": "boolean", "description": .string(desc)] }
    private static func strArray(_ desc: String) -> Value {
        ["type": "array", "items": ["type": "string"], "description": .string(desc)]
    }

    static let all: [Tool] = [
        Tool(name: "wp_cli",
             description: "Run an arbitrary wp-cli command against the scoped site via a one-shot wordpress:cli container. Returns {stdout, stderr, exitCode}.",
             inputSchema: obj([
                "args": strArray("wp-cli arguments, e.g. [\"plugin\",\"list\"] (no leading 'wp')."),
                "command": str("Alternative to args: a single command string, e.g. \"plugin list\"."),
             ])),
        Tool(name: "read_error_log",
             description: "Read the site's error output: the WordPress container log plus a tail of wp-content/debug.log if present.",
             inputSchema: obj(["lines": int("Number of trailing lines (default 100).")])),
        Tool(name: "read_access_log",
             description: "Read the Apache access log (served on the container's stdout via `container logs`).",
             inputSchema: obj(["lines": int("Number of trailing lines (default 100).")])),
        Tool(name: "wp_debug_toggle",
             description: "Enable or disable WP_DEBUG, WP_DEBUG_LOG and SCRIPT_DEBUG via wp-cli config set.",
             inputSchema: obj([
                "enabled": bool("Turn all three debug constants on (true) or off (false)."),
                "wpDebug": bool("Override WP_DEBUG specifically."),
                "wpDebugLog": bool("Override WP_DEBUG_LOG specifically."),
                "scriptDebug": bool("Override SCRIPT_DEBUG specifically."),
             ], required: ["enabled"])),
        Tool(name: "read_wp_config",
             description: "Parse wp-config.php and return its define() constants and $table_prefix.",
             inputSchema: obj([:])),
        Tool(name: "edit_wp_config",
             description: "Set or add a wp-config.php constant (timestamped .bak backup first).",
             inputSchema: obj([
                "name": str("Constant name, e.g. WP_MEMORY_LIMIT."),
                "value": str("Value. String unless raw=true."),
                "raw": bool("Emit the value verbatim (for booleans/numbers) instead of a quoted string."),
             ], required: ["name", "value"])),
        Tool(name: "get_site_info",
             description: "Full site descriptor: paths, URL, port, status, image, DB credentials, provisioned flag, plus active plugins & theme when running.",
             inputSchema: obj([:])),
        Tool(name: "site_health_check",
             description: "Health snapshot: container states, DB healthcheck, HTTP status code, WP_DEBUG state, and folder sizes.",
             inputSchema: obj([:])),
        Tool(name: "site_start", description: "Start the scoped site (provisioning WordPress on first run).", inputSchema: obj([:])),
        Tool(name: "site_stop", description: "Stop the scoped site's containers.", inputSchema: obj([:])),
        Tool(name: "site_restart", description: "Restart the scoped site.", inputSchema: obj([:])),
        Tool(name: "site_status", description: "Current status/url/port of the scoped site.", inputSchema: obj([:])),
        Tool(name: "list_sites",
             description: "List every site and worktree environment with status/url/port.",
             inputSchema: obj([:])),
        Tool(name: "worktree_create",
             description: "Create a git-worktree branch environment for a repo under a site's wp-content. Returns a descriptor {url, port, path, worktreePath, branch, envSlug, containers}.",
             inputSchema: obj([
                "site": str("Parent site slug (defaults to the scoped site)."),
                "repo": str("Repo path relative to wordpress/, e.g. wp-content/plugins/my-plugin."),
                "branch": str("Branch name (created if missing)."),
                "from": str("Base ref when creating a new branch."),
             ], required: ["repo", "branch"])),
        Tool(name: "worktree_list",
             description: "List worktree environments, optionally filtered by parent site.",
             inputSchema: obj(["site": str("Filter by parent site slug (defaults to the scoped site; pass \"*\" for all).")])),
        Tool(name: "worktree_delete",
             description: "Delete a worktree environment.",
             inputSchema: obj([
                "envSlug": str("Environment slug, e.g. my-site-wt-feature-x."),
                "keepBranch": bool("Keep the git branch (default true)."),
                "keepWorktree": bool("Keep the worktree checkout on disk (default false)."),
             ], required: ["envSlug"])),
    ]
}
