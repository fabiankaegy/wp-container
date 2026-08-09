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
             description: "Full site descriptor: paths, URL, port, status, image, DB credentials, provisioned flag, a loginHint (prefer login_link over the wp-login form), the auto-stop-when-idle timeout (idleStopMinutes / effectiveIdleStopMinutes, where 0 means never), plus active plugins & theme when running.",
             inputSchema: obj([:])),
        Tool(name: "login_link",
             description: "Mint a one-time browser login link (magic link) for the scoped site. Opening the returned URL in a browser starts a logged-in wp-admin session — no wp-login.php form, no credentials to type. The link is single-use and expires in 15 minutes. Prefer this over driving the login form.",
             inputSchema: obj([
                "user": str("WordPress user login to log in as (default: admin)."),
             ])),
        Tool(name: "create_user",
             description: "Create a WordPress user via wp-cli. Returns {user, email, role, password} — a generated password is returned when none is provided. Errors clearly if the user already exists.",
             inputSchema: obj([
                "user": str("New user login."),
                "email": str("New user email."),
                "role": str("Role (default administrator)."),
                "password": str("Password; a strong random one is generated when omitted."),
             ], required: ["user", "email"])),
        Tool(name: "site_health_check",
             description: "Health snapshot: container states, DB healthcheck, HTTP status code, WP_DEBUG state, and folder sizes.",
             inputSchema: obj([:])),
        Tool(name: "site_start",
             description: "Start the scoped site (provisioning WordPress on first run). Starts ONLY the site by default — pass with_envs to also start every worktree environment created from it.",
             inputSchema: obj([
                "with_envs": bool("Also start all worktree environments of the site (default false)."),
                "no_pull": bool("Never contact the registry; fail clearly if an image isn't already local (default false)."),
                "refresh_images": bool("Force a registry pull even for images that already exist locally; falls back to the local image with a warning if the pull fails (default false)."),
             ])),
        Tool(name: "site_stop", description: "Stop the scoped site's containers.", inputSchema: obj([:])),
        Tool(name: "site_restart", description: "Restart the scoped site.", inputSchema: obj([:])),
        Tool(name: "site_status", description: "Current status/url/port of the scoped site.", inputSchema: obj([:])),
        Tool(name: "list_sites",
             description: "List every site and worktree environment with status/url/port.",
             inputSchema: obj([:])),
        Tool(name: "worktree_create",
             description: "Create a git-worktree branch environment for a repo under a site's wp-content. By default the checkout is auto-provisioned — the parent's gitignored runtime deps (Composer vendor/, built assets like dist/, provisioned mu-plugins/plugins) are copied in so the env boots into a working site with no manual composer install / npm build (branch-tracked files are never overwritten) — and the environment's database is a schema on the parent site's existing MariaDB container, so it runs one container instead of two. The returned `url` is served by the WP Container reverse proxy (the environment's container publishes no port of its own), so it needs the app running or `wp-container proxy serve`; a `warnings` entry says so when none is. The environment auto-stops after 180 idle minutes (3 hours) by default and is woken by the next request to that same URL — a freshly created environment still on that default gets a further 6-hour grace period during which it is never auto-stopped regardless of use (an explicit timeout set via set_idle_stop skips the grace period and applies immediately) — use set_idle_stop to change or disable it. Returns a descriptor {url, port, path, worktreePath, branch, envSlug, containers, database}.",
             inputSchema: obj([
                "site": str("Parent site slug (defaults to the scoped site)."),
                "repo": str("Repo path relative to wordpress/, e.g. wp-content/plugins/my-plugin."),
                "branch": str("Branch name (created if missing)."),
                "from": str("Base ref when creating a new branch."),
                "provision": bool("Seed the worktree with the parent's gitignored runtime deps so it's runnable out of the box (default true). Pass false for a bare checkout."),
                "isolated_db": bool("Give the environment its own MariaDB container instead of a schema on the parent site's server (default false). Costs ~470 MB of memory; worth it only for a very large database, where cloning the parent's data directory beats a logical dump+restore."),
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
        Tool(name: "xdebug_toggle",
             description: "Enable or disable Xdebug for the scoped site. Uses a derived Xdebug WordPress image (built lazily) and points client_host at the host gateway; restarts the site to apply when running.",
             inputSchema: obj(["enabled": bool("Turn Xdebug on (true) or off (false).")], required: ["enabled"])),
        Tool(name: "elasticsearch_toggle",
             description: "Enable or disable the per-site Elasticsearch sidecar (single-node, security off). Wires ELASTICSEARCH_URL/EP_HOST into WordPress; restarts the site to apply when running.",
             inputSchema: obj(["enabled": bool("Turn Elasticsearch on (true) or off (false).")], required: ["enabled"])),
        Tool(name: "mailpit_toggle",
             description: "Enable or disable the per-site Mailpit email catcher. When on, all outgoing WordPress mail is captured by Mailpit (SMTP) instead of being sent; browse or read it via its web UI + REST API (GET <mailboxUrl>/api/v1/messages). Writes/removes a managed mail-routing handler (in the site's private php/ folder, never the project tree) and restarts the site to apply when running. The mailbox URL is returned here and in get_site_info.",
             inputSchema: obj(["enabled": bool("Turn Mailpit on (true) or off (false).")], required: ["enabled"])),
        Tool(name: "set_idle_stop",
             description: "Set how long a site or worktree environment may sit unused before the reverse proxy stops it to free its VM's memory; the next request starts it again behind a page that refreshes into the live site. ENVIRONMENTS default to 180 minutes (3 hours), with a further 6-hour grace period right after creation during which an environment STILL ON THAT DEFAULT is never auto-stopped regardless of use: the proxy owns an environment's http://127.0.0.1:<port> URL, so every request to it counts as activity and wakes it — as do wp-cli, MCP tool calls and magic-login. Passing an explicit `minutes` value (including 0) always wins over both the default and its grace period — it takes effect immediately, not after 6 hours. Pass 0 while you are mid-task on an environment you will leave idle for longer than that. SITES default to never: a site publishes its own port, so requests to http://127.0.0.1:<port> bypass the proxy and are invisible to the idle clock (its <slug>.localhost / custom-domain URLs are not). Omit `minutes` to restore the default (and its grace period).",
             inputSchema: obj([
                "minutes": int("Auto-stop after this many idle minutes; 0 = never. Omit to restore the built-in default (environments 180 min, sites never)."),
                "slug": str("Site or environment slug (defaults to the scoped site)."),
             ])),
        Tool(name: "db_import",
             description: "Import a .sql/.sql.gz dump into a site's database: safety backup (one command away from undone) → import → URL migration (source detected from the dump's `home` option, or source_url) → optional scrub of personal data (users/comments/admin email) → media handling (remote proxy handler, folder copy, or skip) → optional local admin/password login. Auto-starts the site if it isn't running. On failure the pre-import backup is automatically re-imported (rollback) before the error is returned. Sites only (not worktree environments) in this version. No streaming progress — returns the final summary.",
             inputSchema: obj([
                "site": str("Site slug (defaults to the scoped site)."),
                "file": str("Absolute path to a .sql or .sql.gz dump file."),
                "scrub": bool("Scrub personal data after import (default true)."),
                "allowed_emails": strArray("Email addresses to preserve as-is when scrubbing."),
                "allowed_domains": strArray("Email domains to preserve as-is when scrubbing."),
                "media": str("Media handling: \"remote\" (default), \"skip\", or \"copy\" (requires media_path)."),
                "media_path": str("Local uploads folder to copy from; required when media=\"copy\"."),
                "create_admin": bool("Create/reset the local admin/password login after import (default true)."),
                "source_url": str("Trust this URL as the dump's source instead of the detected `home` option."),
             ], required: ["file"])),
    ]
}
