import Foundation

/// Manages the WordPress side of the Elasticsearch add-on: a handler that defines
/// the `EP_HOST` constant ElasticPress reads its host from.
///
/// ElasticPress reads only the `EP_HOST` constant or the `ep_host` option, never
/// the environment, so the injected `EP_HOST` env var alone leaves it unconfigured.
/// The handler lives at `php/prepend.d/wpc-elasticpress.php`, loaded by the master
/// auto_prepend loader (`PrependService`) at `muplugins_loaded`, outside any
/// project repo. The file is static: it reads the sidecar URL from the `EP_HOST`
/// env var, which the lifecycle re-injects at each start (container IPs churn per
/// restart). Written on enable, removed on disable; the marker header makes both
/// idempotent and tells our file apart from a user's own.
public enum ElasticsearchService {
    /// The handler filename inside `php/prepend.d/`.
    public static let handlerFileName = "wpc-elasticpress.php"

    /// Unique marker in the file header, used to detect/remove only our file.
    static let marker = "WP Container: ElasticPress host (managed — do not edit)"

    /// The handler body. A project that defines `EP_HOST` in wp-config.php keeps
    /// its own value: wp-config loads before `muplugins_loaded`, so the guard
    /// sees it first. Defining the constant also locks the host field on the
    /// ElasticPress settings screen.
    static let handlerContents = """
    <?php
    /*
     * \(marker)
     * Points ElasticPress at the site's Elasticsearch sidecar by defining EP_HOST.
     * Added when Elasticsearch is enabled, removed when disabled. Loaded via the
     * master auto_prepend loader (php/prepend.d). The host comes from the EP_HOST
     * environment variable (the sidecar's URL, re-injected by WP Container at
     * every start).
     */
    if ( ! defined( 'EP_HOST' ) ) {
        $wpc_ep_host = getenv( 'EP_HOST' );
        if ( empty( $wpc_ep_host ) && isset( $_SERVER['EP_HOST'] ) ) {
            $wpc_ep_host = $_SERVER['EP_HOST'];
        }
        if ( ! empty( $wpc_ep_host ) ) {
            define( 'EP_HOST', $wpc_ep_host );
        }
        unset( $wpc_ep_host );
    }
    """

    /// Whether our managed handler is present in `php/prepend.d/` (marker match).
    public static func isHandlerPresent(phpConfFolder: URL) -> Bool {
        PrependService.isHandlerPresent(phpConfFolder: phpConfFolder, name: handlerFileName, marker: marker)
    }

    /// Write the handler into `php/prepend.d/` (creating it as needed). Idempotent.
    public static func writeHandler(phpConfFolder: URL) throws {
        try PrependService.writeHandler(phpConfFolder: phpConfFolder, name: handlerFileName, contents: handlerContents)
    }

    /// Remove the handler, but only when it is ours (marker match). Idempotent.
    public static func removeHandler(phpConfFolder: URL) {
        PrependService.removeHandler(phpConfFolder: phpConfFolder, name: handlerFileName, marker: marker)
    }
}
