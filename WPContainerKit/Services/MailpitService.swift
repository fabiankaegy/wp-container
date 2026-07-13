import Foundation

/// Manages the WordPress side of the Mailpit email-catcher add-on (issue #10):
/// a small marker-headed mu-plugin that reroutes all outgoing mail to the site's
/// Mailpit SMTP catcher via the `phpmailer_init` hook.
///
/// WordPress core speaks no SMTP natively, so we drop a must-use plugin into
/// `wp-content/mu-plugins/wpc-mailpit.php`. The plugin is static: it reads the
/// mail container's IP from the `WPC_MAILPIT_HOST` env var, which the lifecycle
/// re-injects at each start (container IPs churn per restart). Written on enable,
/// removed on disable — the marker header makes both idempotent and lets us tell
/// our file apart from a user's own mu-plugin.
public enum MailpitService {
    /// Path of the managed mu-plugin, relative to a site's `wordpress/` folder.
    public static let muPluginRelPath = "wp-content/mu-plugins/wpc-mailpit.php"

    /// Unique marker in the file header, used to detect/remove only our file.
    static let marker = "WP Container: Mailpit mail routing (managed — do not edit)"

    /// The mu-plugin body. Uses env-var indirection for the host so the file
    /// itself never changes when the mail container's IP does.
    static let pluginContents = """
    <?php
    /*
     * \(marker)
     * Routes all outgoing WordPress mail to the site's Mailpit SMTP catcher.
     * Added when Mailpit is enabled, removed when disabled. The host comes from
     * the WPC_MAILPIT_HOST environment variable (the mail container's IP,
     * re-injected by WP Container at every start).
     */
    add_action( 'phpmailer_init', function ( $phpmailer ) {
        $host = getenv( 'WPC_MAILPIT_HOST' );
        if ( empty( $host ) && isset( $_SERVER['WPC_MAILPIT_HOST'] ) ) {
            $host = $_SERVER['WPC_MAILPIT_HOST'];
        }
        if ( empty( $host ) ) {
            return; // Mailpit not wired up this run — fall back to WP default.
        }
        $phpmailer->isSMTP();
        $phpmailer->Host        = $host;
        $phpmailer->Port        = \(SiteRecipe.mailpitSMTPPort);
        $phpmailer->SMTPAuth    = false;
        $phpmailer->SMTPSecure  = '';
        $phpmailer->SMTPAutoTLS = false;
    } );
    """

    public static func muPluginURL(wordpressFolder: URL) -> URL {
        wordpressFolder.appendingPathComponent(muPluginRelPath)
    }

    /// Whether our managed mu-plugin is present (matched by marker, so a
    /// same-named user file is not misread as ours).
    public static func isMuPluginPresent(wordpressFolder: URL) -> Bool {
        let url = muPluginURL(wordpressFolder: wordpressFolder)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    /// Write the mu-plugin (creating `mu-plugins/` as needed). Idempotent.
    public static func writeMuPlugin(wordpressFolder: URL) throws {
        let url = muPluginURL(wordpressFolder: wordpressFolder)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try pluginContents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Remove the mu-plugin, but only when it is ours (marker match). Idempotent;
    /// a missing file or a user's own same-named file is left untouched.
    public static func removeMuPlugin(wordpressFolder: URL) throws {
        let url = muPluginURL(wordpressFolder: wordpressFolder)
        guard isMuPluginPresent(wordpressFolder: wordpressFolder) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
