import Foundation

/// Manages the WordPress side of the Mailpit email-catcher add-on (issue #10):
/// a small marker-headed handler that reroutes all outgoing mail to the site's
/// Mailpit SMTP catcher via the `phpmailer_init` hook.
///
/// WordPress core speaks no SMTP natively, so we register a handler that hooks
/// `phpmailer_init`. It used to live in `wp-content/mu-plugins/wpc-mailpit.php`,
/// but that path can sit inside a user's tracked git repo and get committed by
/// accident (issue #13). It now lives at `php/prepend.d/wpc-mailpit.php`, loaded
/// by the shared master auto_prepend loader (`PrependService`) at
/// `muplugins_loaded` — entirely OUTSIDE any project repo. The file is static:
/// it reads the mail container's IP from the `WPC_MAILPIT_HOST` env var, which
/// the lifecycle re-injects at each start (container IPs churn per restart).
/// Written on enable, removed on disable — the marker header makes both
/// idempotent and lets us tell our file apart from a user's own.
public enum MailpitService {
    /// The handler filename inside `php/prepend.d/`.
    public static let handlerFileName = "wpc-mailpit.php"

    /// Legacy in-tree mu-plugin path (pre-#13), cleaned up on next start.
    public static let legacyMuPluginRelPath = "wp-content/mu-plugins/wpc-mailpit.php"

    /// Unique marker in the file header, used to detect/remove only our file.
    static let marker = "WP Container: Mailpit mail routing (managed — do not edit)"

    /// The handler body. Runs at `muplugins_loaded` via the master loader; the
    /// `phpmailer_init` hook fires far later (when mail is sent), so plain-hook
    /// style is correct. Uses env-var indirection for the host so the file itself
    /// never changes when the mail container's IP does.
    static let pluginContents = """
    <?php
    /*
     * \(marker)
     * Routes all outgoing WordPress mail to the site's Mailpit SMTP catcher.
     * Added when Mailpit is enabled, removed when disabled. Loaded via the master
     * auto_prepend loader (php/prepend.d). The host comes from the
     * WPC_MAILPIT_HOST environment variable (the mail container's IP, re-injected
     * by WP Container at every start).
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

    /// Whether our managed handler is present in `php/prepend.d/` (marker match).
    public static func isHandlerPresent(phpConfFolder: URL) -> Bool {
        PrependService.isHandlerPresent(phpConfFolder: phpConfFolder, name: handlerFileName, marker: marker)
    }

    /// Write the handler into `php/prepend.d/` (creating it as needed). Idempotent.
    public static func writeHandler(phpConfFolder: URL) throws {
        try PrependService.writeHandler(phpConfFolder: phpConfFolder, name: handlerFileName, contents: pluginContents)
    }

    /// Remove the handler, but only when it is ours (marker match). Idempotent.
    public static func removeHandler(phpConfFolder: URL) {
        PrependService.removeHandler(phpConfFolder: phpConfFolder, name: handlerFileName, marker: marker)
    }

    /// Shed the legacy in-tree mu-plugin from pre-#13 builds when it is ours
    /// (marker match) — never a user's own same-named file. Runs on every start.
    public static func cleanupLegacyMuPlugin(wordpressFolder: URL) {
        PrependService.removeIfMarked(wordpressFolder.appendingPathComponent(legacyMuPluginRelPath), marker: marker)
    }
}
