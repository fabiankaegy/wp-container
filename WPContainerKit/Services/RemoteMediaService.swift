import Foundation

/// Manages the WordPress side of the Database Importer's "Load from source
/// site" media option (PLAN.md §2m): a small marker-headed handler that
/// rewrites upload URLs to the dump's source host whenever the local file is
/// missing (BE-Media-from-Production style), so an imported site doesn't show
/// broken images without copying/downloading the full uploads folder.
///
/// Modeled on `MailpitService`: it used to live in
/// `wp-content/mu-plugins/wpc-remote-media.php`, but that path can sit inside a
/// user's tracked git repo and get committed by accident (issue #13). It now
/// lives at `php/prepend.d/wpc-remote-media.php`, loaded by the shared master
/// auto_prepend loader (`PrependService`) at `muplugins_loaded` — entirely
/// OUTSIDE any project repo. Written when the user picks this option, removed
/// when they disable it or pick a different one. The marker header makes both
/// idempotent and lets us tell our file apart from a user's own. Unlike Mailpit's
/// static file, the source base URL varies per import, so the contents are
/// templated at write time.
public enum RemoteMediaService {
    /// The handler filename inside `php/prepend.d/`.
    public static let handlerFileName = "wpc-remote-media.php"

    /// Legacy in-tree mu-plugin path (pre-#13), cleaned up on next start.
    public static let legacyMuPluginRelPath = "wp-content/mu-plugins/wpc-remote-media.php"

    /// Unique marker in the file header, used to detect/remove only our file.
    static let marker = "WP Container: Remote media from production (managed — do not edit)"

    /// Whether our managed handler is present in `php/prepend.d/` (marker match).
    public static func isHandlerPresent(phpConfFolder: URL) -> Bool {
        PrependService.isHandlerPresent(phpConfFolder: phpConfFolder, name: handlerFileName, marker: marker)
    }

    /// Write the handler into `php/prepend.d/` (creating it as needed), templating
    /// `sourceBaseURL` (e.g. `https://staging.example.com`) into it. Idempotent —
    /// a re-run (a later import from a different source) overwrites our own copy.
    public static func writeHandler(phpConfFolder: URL, sourceBaseURL: String) throws {
        try PrependService.writeHandler(phpConfFolder: phpConfFolder, name: handlerFileName,
                                        contents: pluginContents(sourceBaseURL: sourceBaseURL))
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

    /// PHP single-quoted string escape for templating the source URL in — the
    /// same escaping `WPConfigService` uses for constant values.
    static func phpEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    /// The handler body. No PHP namespace (keeps templating/escaping simple and
    /// avoids `\`-heavy namespace-qualified callback strings); functions are
    /// prefixed `wpc_remote_media_` instead to stay out of the way of a site's
    /// own code, and `function_exists`/`defined` guards make repeated loads
    /// harmless. Runs at `muplugins_loaded` via the master loader; the filters it
    /// registers fire during rendering, so plain-hook style is correct.
    static func pluginContents(sourceBaseURL: String) -> String {
        let escaped = phpEscape(sourceBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        return """
        <?php
        /*
         * \(marker)
         * When a locally imported database references uploads that don't exist
         * on disk, redirect those URLs to the source site instead of showing a
         * broken image (BE-Media-from-Production style). Added by the Database
         * Importer when "Load from source site" is chosen; removed when
         * disabled or replaced. Loaded via the master auto_prepend loader
         * (php/prepend.d). The source base URL is templated in at write time by
         * WP Container — this file is otherwise static.
         */

        if ( ! defined( 'WPC_REMOTE_MEDIA_SOURCE_BASE_URL' ) ) {
            define( 'WPC_REMOTE_MEDIA_SOURCE_BASE_URL', '\(escaped)' );
        }

        if ( ! function_exists( 'wpc_remote_media_is_missing_locally' ) ) {
            function wpc_remote_media_is_missing_locally( $relative_path ) {
                $upload_dir = wp_upload_dir();
                $local_path = $upload_dir['basedir'] . '/' . ltrim( $relative_path, '/' );
                return ! file_exists( $local_path );
            }
        }

        if ( ! function_exists( 'wpc_remote_media_maybe_rewrite_url' ) ) {
            function wpc_remote_media_maybe_rewrite_url( $url ) {
                if ( empty( $url ) || ! is_string( $url ) ) {
                    return $url;
                }
                $upload_dir = wp_upload_dir();
                $base_url = $upload_dir['baseurl'];
                if ( 0 !== strpos( $url, $base_url ) ) {
                    return $url;
                }
                $relative = substr( $url, strlen( $base_url ) );
                if ( ! wpc_remote_media_is_missing_locally( $relative ) ) {
                    return $url;
                }
                return rtrim( WPC_REMOTE_MEDIA_SOURCE_BASE_URL, '/' ) . '/wp-content/uploads' . $relative;
            }
        }

        add_filter( 'wp_get_attachment_url', 'wpc_remote_media_maybe_rewrite_url' );

        add_filter( 'wp_get_attachment_image_src', function ( $image ) {
            if ( is_array( $image ) && isset( $image[0] ) ) {
                $image[0] = wpc_remote_media_maybe_rewrite_url( $image[0] );
            }
            return $image;
        } );

        add_filter( 'wp_calculate_image_srcset', function ( $sources ) {
            if ( ! is_array( $sources ) ) {
                return $sources;
            }
            foreach ( $sources as $width => $source ) {
                if ( isset( $source['url'] ) ) {
                    $sources[ $width ]['url'] = wpc_remote_media_maybe_rewrite_url( $source['url'] );
                }
            }
            return $sources;
        } );

        // Best-effort: rewrite uploads URLs hardcoded into post content (older
        // or migrated content often hardcodes <img src="..."> rather than
        // resolving through an attachment ID). Only matches double-quoted or
        // bare (CSS url()-style) occurrences — single-quoted src attributes are
        // uncommon enough in rendered WordPress content to skip for simplicity.
        add_filter( 'the_content', function ( $content ) {
            $upload_dir = wp_upload_dir();
            $base_url = $upload_dir['baseurl'];
            if ( false === strpos( $content, $base_url ) ) {
                return $content;
            }
            return preg_replace_callback(
                '#' . preg_quote( $base_url, '#' ) . '([^"\\s)]+)#',
                function ( $matches ) use ( $base_url ) {
                    return wpc_remote_media_maybe_rewrite_url( $base_url . $matches[1] );
                },
                $content
            );
        } );
        """
    }
}
