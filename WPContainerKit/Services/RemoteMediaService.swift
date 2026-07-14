import Foundation

/// Manages the WordPress side of the Database Importer's "Load from source
/// site" media option (PLAN.md §2m): a small marker-headed mu-plugin that
/// rewrites upload URLs to the dump's source host whenever the local file is
/// missing (BE-Media-from-Production style), so an imported site doesn't show
/// broken images without copying/downloading the full uploads folder.
///
/// Modeled exactly on `MailpitService`: written into
/// `wp-content/mu-plugins/wpc-remote-media.php` when the user picks this
/// option, removed when they disable it or pick a different one. The marker
/// header makes both idempotent and lets us tell our file apart from a user's
/// own mu-plugin. Unlike Mailpit's static file, the source base URL varies per
/// import, so the contents are templated at write time (no env-var
/// indirection needed — remote media doesn't need to react to a churning
/// per-start IP the way the mail container does).
public enum RemoteMediaService {
    /// Path of the managed mu-plugin, relative to a site's `wordpress/` folder.
    public static let muPluginRelPath = "wp-content/mu-plugins/wpc-remote-media.php"

    /// Unique marker in the file header, used to detect/remove only our file.
    static let marker = "WP Container: Remote media from production (managed — do not edit)"

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

    /// Write the mu-plugin (creating `mu-plugins/` as needed), templating
    /// `sourceBaseURL` (e.g. `https://staging.example.com`) into it.
    /// Idempotent — a re-run (e.g. a later import from a different source)
    /// simply overwrites our own previous copy with the new base URL.
    public static func writeMuPlugin(wordpressFolder: URL, sourceBaseURL: String) throws {
        let url = muPluginURL(wordpressFolder: wordpressFolder)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try pluginContents(sourceBaseURL: sourceBaseURL).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Remove the mu-plugin, but only when it is ours (marker match). Idempotent;
    /// a missing file or a user's own same-named file is left untouched.
    public static func removeMuPlugin(wordpressFolder: URL) throws {
        let url = muPluginURL(wordpressFolder: wordpressFolder)
        guard isMuPluginPresent(wordpressFolder: wordpressFolder) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// PHP single-quoted string escape for templating the source URL in — the
    /// same escaping `WPConfigService` uses for constant values.
    static func phpEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    /// The mu-plugin body. No PHP namespace (keeps templating/escaping simple
    /// and avoids `\`-heavy namespace-qualified callback strings); functions
    /// are prefixed `wpc_remote_media_` instead to stay out of the way of a
    /// site's own code, and `function_exists`/`defined` guards make repeated
    /// loads (e.g. from a `wp-cli` one-shot container reusing the same mount)
    /// harmless.
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
         * disabled or replaced. The source base URL is templated in at write
         * time by WP Container — this file is otherwise static.
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
