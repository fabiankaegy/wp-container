import Foundation

/// Generates the per-site `wp` shim, the interactive wp-cli Terminal command
/// (PLAN.md §2e), and the global `wp` smart router (§2e follow-up: plain `wp`
/// anywhere inside a site's `wordpress/` tree runs the containerized wp-cli).
///
/// All three share one containerized invocation: a one-shot `wordpress:cli`
/// container sharing the site's `wordpress/` mount + DB env, with the current
/// directory mapped to a matching `-w /var/www/html/<subpath>` workdir so
/// path-relative commands (scaffold, `plugin`, …) land where the user expects.
/// TTY is added only when stdout is a terminal; stdin is always attached so
/// piping works.
public enum WPCLIShim {
    public static let containerBinary = ContainerCLI.defaultBinaryPath
    public static let cliPath = "/usr/local/bin/wp-container"
    /// Dedicated dir the global router lives in. Under the app's per-user data
    /// dir (`~/Library/Application Support/WPContainer/bin`) — NOT `/usr/local/bin`
    /// — so the unsandboxed GUI app, running as the user, can write it without
    /// root (writing into root-owned `/usr/local/bin` failed with EACCES). Kept
    /// as its own dir so a single PATH prepend exposes only our `wp`, never
    /// shadowing other tools.
    public static var routerDir: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("WPContainer", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .path
    }
    public static var routerPath: String { "\(routerDir)/wp" }

    /// Bumped whenever the shim body format changes so stale shims auto-refresh
    /// (PLAN.md scope addition). Written into the shim header. v3 bakes in the
    /// site's PHP-matched cli image (was hardcoded `wordpress:cli`); v4 bakes in
    /// the real DB CONTAINER and SCHEMA instead of deriving them from the slug,
    /// so a shared-database worktree env resolves the parent's container and its
    /// own `wpc_*` schema (issue #17).
    public static let shimVersion = 4
    private static let versionMarker = "# wpc-shim-version:"

    // MARK: - Per-site shim

    /// Body of the executable `wp` shim. `wordpressFolder` is baked in as an
    /// ABSOLUTE path so the shim works from any placement root and any cwd.
    /// `cliImage` is the PHP-matched one-shot wp-cli image for the site.
    ///
    /// `dbContainer` and `databaseName` are baked in rather than derived from the
    /// slug (issue #17): they differ for a shared-database env, which talks to its
    /// PARENT's container and its own schema. Both default to the classic
    /// per-site values.
    public static func shimScript(slug: String, wordpressFolder: URL, cliImage: String,
                                  dbContainer: String? = nil,
                                  databaseName: String = SiteRecipe.dbName) -> String {
        """
        #!/bin/bash
        \(versionMarker) \(shimVersion)
        # WP Container wp-cli shim for site "\(slug)". Auto-generated — do not edit.
        # Runs any wp-cli command against this site via a one-shot \(cliImage)
        # container. Tip: `wp` from Homebrew (/opt/homebrew/bin/wp) will shadow this
        # on PATH — call it as ./wp from the site root, or install the global router
        # with `wp-container setup wp`.
        set -euo pipefail

        CONTAINER_BIN="\(containerBinary)"
        SITE_SLUG="\(slug)"
        DB_CONTAINER="\(dbContainer ?? "wpc-\(slug)-db")"
        WP_DIR="\(wordpressFolder.path)"

        if [ ! -x "$CONTAINER_BIN" ]; then
          echo "wp: Apple container CLI not found at $CONTAINER_BIN" >&2
          exit 1
        fi

        # Map the current directory to a container workdir when inside wordpress/.
        WORKDIR="/var/www/html"
        CUR="$(pwd -P)"
        WP_REAL="$(cd "$WP_DIR" 2>/dev/null && pwd -P || echo "$WP_DIR")"
        if [ "$CUR" = "$WP_REAL" ]; then
          WORKDIR="/var/www/html"
        elif [ "${CUR#"$WP_REAL"/}" != "$CUR" ]; then
          WORKDIR="/var/www/html/${CUR#"$WP_REAL"/}"
        fi

        DB_IP="$("$CONTAINER_BIN" inspect "$DB_CONTAINER" 2>/dev/null \\
          | sed -n 's/.*"ipv4Address"[^"]*"\\([0-9.]*\\).*/\\1/p' | head -n1)"
        if [ -z "$DB_IP" ]; then
          echo "wp: database container '$DB_CONTAINER' is not running." >&2
          echo "    Start the site first (e.g. wp-container start $SITE_SLUG)." >&2
          exit 1
        fi

        TTY=""
        [ -t 1 ] && TTY="-t"
        exec "$CONTAINER_BIN" run --rm -i $TTY -w "$WORKDIR" \\
          -v "$WP_DIR:/var/www/html" \\
          -e "WORDPRESS_DB_HOST=$DB_IP" \\
          -e "WORDPRESS_DB_USER=\(SiteRecipe.dbUser)" \\
          -e "WORDPRESS_DB_PASSWORD=\(SiteRecipe.dbPassword)" \\
          -e "WORDPRESS_DB_NAME=\(databaseName)" \\
          "\(cliImage)" wp "$@"
        """
    }

    /// Write the shim to `<root>/wp` (0755). `wordpressFolder` defaults to
    /// `<root>/wordpress` for the classic per-site placement. `cliImage` is the
    /// site's PHP-matched wp-cli image (default: base cli for latest/plain).
    /// Idempotent.
    @discardableResult
    public static func writeShim(slug: String, siteRoot: URL, wordpressFolder: URL? = nil,
                                 cliImage: String = WordPressImageCatalog.baseCLIImage,
                                 dbContainer: String? = nil,
                                 databaseName: String = SiteRecipe.dbName) throws -> URL {
        let url = siteRoot.appendingPathComponent("wp")
        let wp = wordpressFolder ?? siteRoot.appendingPathComponent("wordpress", isDirectory: true)
        try FileManager.default.createDirectory(at: siteRoot, withIntermediateDirectories: true)
        try shimScript(slug: slug, wordpressFolder: wp, cliImage: cliImage,
                       dbContainer: dbContainer, databaseName: databaseName)
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Write the shim for a runnable instance — the overload to prefer, since it
    /// can't get the DB container or schema wrong (issue #17). Sites place it at
    /// their root; a shared-database env's shim resolves the PARENT's container
    /// and the env's own schema.
    @discardableResult
    public static func writeShim(for inst: any RunnableInstance, siteRoot: URL,
                                 slug: String, wordpressFolder: URL? = nil) throws -> URL {
        try writeShim(slug: slug, siteRoot: siteRoot,
                      wordpressFolder: wordpressFolder ?? inst.wordpressFolder,
                      cliImage: SiteRecipe.cliImage(for: inst),
                      dbContainer: inst.dbContainerName,
                      databaseName: inst.databaseName)
    }

    /// Whether the shim at `<siteRoot>/wp` is missing or older than the current
    /// format version (so the app can auto-refresh it on launch).
    public static func shimNeedsRefresh(siteRoot: URL) -> Bool {
        let url = siteRoot.appendingPathComponent("wp")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return true }
        guard let line = text.split(separator: "\n").first(where: { $0.contains(versionMarker) }),
              let v = Int(line.replacingOccurrences(of: versionMarker, with: "").trimmingCharacters(in: .whitespaces))
        else { return true }
        return v < shimVersion
    }

    // MARK: - Global router (§2e follow-up)

    /// Body of the `\(routerPath)` global router. Invoked as `wp`: if the cwd is
    /// inside a WP Container site's `wordpress/` tree it runs the containerized
    /// wp-cli (cwd mapped to a workdir); otherwise it transparently execs the
    /// user's real `wp` (the next one on PATH), so Homebrew workflows are
    /// unaffected.
    /// Bumped whenever the ROUTER body changes, so a stale one auto-refreshes
    /// (the app does it on launch, and `resolve-site` — which the router itself
    /// calls on every invocation — does it for CLI-only users). v2 passes the
    /// resolved schema through as `WORDPRESS_DB_NAME`, which a shared-database
    /// worktree env needs to avoid operating on its PARENT's data (issue #17).
    public static let routerVersion = 2
    private static let routerVersionMarker = "# wpc-router-version:"
    /// The flag the router announces its own body version with. `resolve-site`
    /// REFUSES to resolve a shared-database env for a router too old to honor
    /// `dbName` (issue #17) — a self-heal alone can't help the already-running
    /// old body, which would silently run wp-cli against the PARENT's schema.
    public static let routerVersionFlag = "--router-version"

    public static func routerScript() -> String {
        """
        #!/bin/bash
        \(routerVersionMarker) \(routerVersion)
        # WP Container global `wp` router. Auto-generated by `wp-container setup wp`.
        # Inside a WP Container site's wordpress/ tree → containerized wp-cli;
        # everywhere else → your normal wp-cli. Remove with `wp-container setup wp --remove`.
        set -euo pipefail

        SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)/$(basename "$0")"
        CLI="\(cliPath)"
        CONTAINER_BIN="\(containerBinary)"

        RESOLVED=""
        if [ -x "$CLI" ]; then
          RESOLVED="$("$CLI" resolve-site --path "$PWD" \(routerVersionFlag) \(routerVersion) --json 2>/dev/null || true)"
        fi

        if printf '%s' "$RESOLVED" | grep -q '"matched"[[:space:]]*:[[:space:]]*true'; then
          eval "$(printf '%s' "$RESOLVED" | /usr/bin/env python3 -c '
        import json, sys, shlex
        d = json.load(sys.stdin)
        print("WPC_WP=" + shlex.quote(d["wordpressPath"]))
        print("WPC_DB=" + shlex.quote(d["dbContainer"]))
        print("WPC_SUB=" + shlex.quote(d.get("subpath", "")))
        print("WPC_CLI=" + shlex.quote(d.get("cliImage", "wordpress:cli")))
        print("WPC_DBNAME=" + shlex.quote(d.get("dbName", "\(SiteRecipe.dbName)")))
        ')"
          DB_IP="$("$CONTAINER_BIN" inspect "$WPC_DB" 2>/dev/null \\
            | sed -n 's/.*"ipv4Address"[^"]*"\\([0-9.]*\\).*/\\1/p' | head -n1)"
          if [ -z "$DB_IP" ]; then
            echo "wp: this WP Container site is not running (start it first)." >&2
            exit 1
          fi
          WORKDIR="/var/www/html"
          [ -n "$WPC_SUB" ] && WORKDIR="/var/www/html/$WPC_SUB"
          TTY=""
          [ -t 1 ] && TTY="-t"
          exec "$CONTAINER_BIN" run --rm -i $TTY -w "$WORKDIR" \\
            -v "$WPC_WP:/var/www/html" \\
            -e "WORDPRESS_DB_HOST=$DB_IP" \\
            -e "WORDPRESS_DB_USER=\(SiteRecipe.dbUser)" \\
            -e "WORDPRESS_DB_PASSWORD=\(SiteRecipe.dbPassword)" \\
            -e "WORDPRESS_DB_NAME=${WPC_DBNAME:-\(SiteRecipe.dbName)}" \\
            "${WPC_CLI:-\(WordPressImageCatalog.baseCLIImage)}" wp "$@"
        fi

        # Not inside a WP Container site → transparently exec the real wp-cli.
        while IFS= read -r cand; do
          [ -z "$cand" ] && continue
          cr="$(realpath "$cand" 2>/dev/null || echo "$cand")"
          [ "$cr" = "$SELF" ] && continue
          exec "$cand" "$@"
        done < <(which -a wp 2>/dev/null)

        echo "wp: no wp-cli found on PATH, and not inside a WP Container site." >&2
        exit 127
        """
    }

    /// Write the router binary to `\(routerPath)` (0755), creating its dir.
    @discardableResult
    public static func writeRouter() throws -> URL {
        let dir = URL(fileURLWithPath: routerDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("wp")
        try routerScript().write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Remove the router binary + its dir (best effort).
    public static func removeRouter() {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: routerDir))
    }

    public static var routerInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: routerPath)
    }

    /// Whether an INSTALLED router predates the current body format. False when
    /// no router is installed (there is nothing to refresh).
    public static var routerNeedsRefresh: Bool {
        guard routerInstalled else { return false }
        guard let text = try? String(contentsOfFile: routerPath, encoding: .utf8) else { return true }
        guard let line = text.split(separator: "\n").first(where: { $0.contains(routerVersionMarker) }),
              let v = Int(line.replacingOccurrences(of: routerVersionMarker, with: "").trimmingCharacters(in: .whitespaces))
        else { return true }
        return v < routerVersion
    }

    /// Rewrite the installed router if its format is stale. Cheap enough to call
    /// from `resolve-site`, which the router invokes on every `wp` — so a router
    /// installed by an older build heals itself on first use.
    public static func refreshRouterIfStale() {
        guard routerNeedsRefresh else { return }
        _ = try? writeRouter()
    }

    // MARK: - Interactive Terminal command (§2e)

    /// A single shell command (for `Terminal.app`) that opens an interactive
    /// wp-cli shell inside a `wordpress:cli` container cd'd to /var/www/html.
    ///
    /// `dbContainer`/`databaseName` are passed in rather than derived from the
    /// slug (issue #17) so an interactive shell for a shared-database env lands
    /// in the env's schema on the parent's server. Prefer
    /// `interactiveTerminalCommand(for:)`.
    public static func interactiveTerminalCommand(slug: String, wordpressFolder: URL,
                                                  cliImage: String = WordPressImageCatalog.baseCLIImage,
                                                  dbContainer: String? = nil,
                                                  databaseName: String = SiteRecipe.dbName) -> String {
        let wp = wordpressFolder.path
        let db = dbContainer ?? "wpc-\(slug)-db"
        return """
        DB_IP=$(\(containerBinary) inspect \(shellQuote(db)) 2>/dev/null | sed -n 's/.*\"ipv4Address\"[^\"]*\"\\([0-9.]*\\).*/\\1/p' | head -n1); \
        if [ -z "$DB_IP" ]; then echo 'Site \(slug) is not running — start it first.'; else \
        \(containerBinary) run -it --rm -w /var/www/html -v \(shellQuote(wp)):/var/www/html \
        -e WORDPRESS_DB_HOST=$DB_IP -e WORDPRESS_DB_USER=\(SiteRecipe.dbUser) \
        -e WORDPRESS_DB_PASSWORD=\(SiteRecipe.dbPassword) -e WORDPRESS_DB_NAME=\(databaseName) \
        \(cliImage) bash; fi
        """
    }

    /// The interactive Terminal command for a runnable instance — can't get the
    /// DB container or schema wrong (issue #17).
    public static func interactiveTerminalCommand(for inst: any RunnableInstance, slug: String) -> String {
        interactiveTerminalCommand(slug: slug, wordpressFolder: inst.wordpressFolder,
                                   cliImage: SiteRecipe.cliImage(for: inst),
                                   dbContainer: inst.dbContainerName,
                                   databaseName: inst.databaseName)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
