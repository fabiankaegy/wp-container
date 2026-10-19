import Foundation

/// Manages the WordPress side of the Redis add-on: an early handler that
/// defines the `WP_REDIS_HOST` and `WP_REDIS_PORT` constants that object-cache
/// drop-ins such as Redis Object Cache read.
///
/// The drop-in connects in `wp_start_object_cache()`, before `muplugins_loaded`,
/// so the handler loads at prepend time (`php/prepend.d/early/`). It registers a
/// pre-initialized `enable_loading_object_cache_dropin` filter, which WordPress
/// applies after wp-config.php and right before it loads the drop-in: a project
/// that defines the constants itself keeps its own values. The file is static:
/// it reads the container's IP from the `WPC_REDIS_HOST` env var, which the
/// lifecycle re-injects at each start.
public enum RedisService {
    /// The handler filename inside `php/prepend.d/early/`.
    public static let handlerFileName = "wpc-redis.php"

    /// Unique marker in the file header, used to detect/remove only our file.
    static let marker = "WP Container: Redis object cache host (managed — do not edit)"

    static let handlerContents = """
    <?php
    /*
     * \(marker)
     * Points the object-cache drop-in at the site's Redis container by defining
     * WP_REDIS_HOST and WP_REDIS_PORT. Added when Redis is enabled, removed when
     * disabled. Loaded at prepend time via the master auto_prepend loader
     * (php/prepend.d/early). The host comes from the WPC_REDIS_HOST environment
     * variable (the container's IP, re-injected by WP Container at every start).
     */
    $GLOBALS['wp_filter']['enable_loading_object_cache_dropin'][0]['wpc_redis'] = array(
        'function'      => function ( $enabled ) {
            $host = getenv( 'WPC_REDIS_HOST' );
            if ( empty( $host ) && isset( $_SERVER['WPC_REDIS_HOST'] ) ) {
                $host = $_SERVER['WPC_REDIS_HOST'];
            }
            if ( ! empty( $host ) ) {
                if ( ! defined( 'WP_REDIS_HOST' ) ) {
                    define( 'WP_REDIS_HOST', $host );
                }
                if ( ! defined( 'WP_REDIS_PORT' ) ) {
                    define( 'WP_REDIS_PORT', \(SiteRecipe.redisPort) );
                }
            }
            return $enabled;
        },
        'accepted_args' => 1,
    );
    """

    /// Empties `inst`'s Redis cache after one-shot wp-cli changed its database
    /// in bulk (import, URL migration, clone). Those runs don't get
    /// `WPC_REDIS_HOST`, so the drop-in can't invalidate what they change.
    /// Best effort: a disabled or stopped Redis has nothing to flush.
    public static func flush(_ inst: any RunnableInstance, cli: ContainerCLI) async {
        guard inst.redisEnabled else { return }
        _ = try? await cli.runCapturing(SiteRecipe.redisFlushArgs(inst))
    }

    /// The handler as the Redis sidecar addon registers it.
    public static let handler = PrependHandler(fileName: handlerFileName, marker: marker,
                                               contents: handlerContents, isEarly: true)
}
