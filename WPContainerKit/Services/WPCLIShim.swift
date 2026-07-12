import Foundation

/// Generates the per-site `wp` shim and the interactive wp-cli Terminal command
/// (PLAN.md §2e). The shim resolves the site's live database container IP at
/// runtime (containers are ephemeral, so the IP changes every start) and execs a
/// one-shot `wordpress:cli` container sharing the site's `wordpress/` mount.
public enum WPCLIShim {
    public static let containerBinary = ContainerCLI.defaultBinaryPath

    /// Body of the executable `<site>/wp` shim.
    public static func shimScript(slug: String) -> String {
        """
        #!/bin/bash
        # WP Container wp-cli shim for site "\(slug)". Auto-generated — do not edit.
        # Runs any wp-cli command against this site via a one-shot wordpress:cli
        # container that shares the site's wordpress/ mount and DB env.
        set -euo pipefail

        CONTAINER_BIN="\(containerBinary)"
        SITE_SLUG="\(slug)"
        DB_NAME="wpc-${SITE_SLUG}-db"
        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        WP_DIR="${SCRIPT_DIR}/wordpress"

        if [ ! -x "$CONTAINER_BIN" ]; then
          echo "wp: Apple container CLI not found at $CONTAINER_BIN" >&2
          exit 1
        fi

        # Resolve the DB container's current IP (strip any CIDR suffix).
        DB_IP="$("$CONTAINER_BIN" inspect "$DB_NAME" 2>/dev/null \\
          | sed -n 's/.*"ipv4Address"[^"]*"\\([0-9.]*\\).*/\\1/p' | head -n1)"
        if [ -z "$DB_IP" ]; then
          echo "wp: database container '$DB_NAME' is not running." >&2
          echo "    Start the site first (e.g. wp-container start $SITE_SLUG)." >&2
          exit 1
        fi

        exec "$CONTAINER_BIN" run --rm -i \\
          -v "$WP_DIR:/var/www/html" \\
          -e "WORDPRESS_DB_HOST=$DB_IP" \\
          -e "WORDPRESS_DB_USER=\(SiteRecipe.dbUser)" \\
          -e "WORDPRESS_DB_PASSWORD=\(SiteRecipe.dbPassword)" \\
          -e "WORDPRESS_DB_NAME=\(SiteRecipe.dbName)" \\
          "\(SiteRecipe.wpCLIImage)" wp "$@"
        """
    }

    /// Write the shim to `<siteRoot>/wp` (0755). Idempotent.
    @discardableResult
    public static func writeShim(slug: String, siteRoot: URL) throws -> URL {
        let url = siteRoot.appendingPathComponent("wp")
        try FileManager.default.createDirectory(at: siteRoot, withIntermediateDirectories: true)
        try shimScript(slug: slug).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A single shell command (for `Terminal.app`) that opens an interactive
    /// wp-cli shell inside a `wordpress:cli` container cd'd to /var/www/html.
    public static func interactiveTerminalCommand(slug: String, wordpressFolder: URL) -> String {
        let wp = wordpressFolder.path
        let db = "wpc-\(slug)-db"
        // Kept to one line so Terminal's `do script` runs it cleanly.
        return """
        DB_IP=$(\(containerBinary) inspect \(shellQuote(db)) 2>/dev/null | sed -n 's/.*\"ipv4Address\"[^\"]*\"\\([0-9.]*\\).*/\\1/p' | head -n1); \
        if [ -z "$DB_IP" ]; then echo 'Site \(slug) is not running — start it first.'; else \
        \(containerBinary) run -it --rm -w /var/www/html -v \(shellQuote(wp)):/var/www/html \
        -e WORDPRESS_DB_HOST=$DB_IP -e WORDPRESS_DB_USER=\(SiteRecipe.dbUser) \
        -e WORDPRESS_DB_PASSWORD=\(SiteRecipe.dbPassword) -e WORDPRESS_DB_NAME=\(SiteRecipe.dbName) \
        \(SiteRecipe.wpCLIImage) bash; fi
        """
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
