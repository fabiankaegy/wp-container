import Foundation

/// Ships the managed PHP that makes a shared site work for visitors who reach
/// it through a public origin.
///
/// The proxy forwards each share request with the instance's local `Host` and an
/// `X-WPC-Share-Origin` header carrying the public origin. WordPress therefore
/// renders with local URLs, and two handlers in the instance's `php/` folder
/// translate between the two:
///
///   php/prepend.d/early/wpc-share.php — runs at prepend time. For requests that
///       carry the matching header it swaps local origins for the public one in
///       the response body and `Location` header.
///   php/prepend.d/wpc-share-save.php  — runs at `muplugins_loaded`. Swaps the
///       public origin back to the local one in everything WordPress stores, and
///       refuses changes to the site addresses.
///
/// `php/wpc-share.json` holds the origins both handlers read. Requests without
/// the matching header, and CLI runs, are untouched.
public enum SharePHPService {
    public static let originFileName = "wpc-share.json"

    static let earlyHandlerName = "\(PrependService.earlyDirName)/wpc-share.php"
    static let saveHandlerName = "wpc-share-save.php"

    static let earlyMarker = "WP Container: share link rewriting (managed — do not edit)"
    static let saveMarker = "WP Container: share link save handling (managed — do not edit)"

    /// Write the handlers and the origin file for `inst`. Idempotent; a new
    /// `publicOrigin` replaces the previous one.
    public static func activate(for inst: any RunnableInstance, publicOrigin: String) throws {
        try PrependService.ensure(for: inst)
        let folder = inst.phpConfFolder
        try PrependService.writeHandler(phpConfFolder: folder, name: earlyHandlerName, contents: earlyContents)
        try PrependService.writeHandler(phpConfFolder: folder, name: saveHandlerName, contents: saveContents)

        let config: [String: Any] = [
            "origin": publicOrigin,
            "local": inst.sharePrimaryOrigin,
            "locals": inst.shareLocalOrigins,
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])
        try data.write(to: folder.appendingPathComponent(originFileName), options: .atomic)
    }

    /// Remove the origin file and the handlers (only when they carry our marker).
    public static func deactivate(for inst: any RunnableInstance) {
        let folder = inst.phpConfFolder
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(originFileName))
        PrependService.removeHandler(phpConfFolder: folder, name: earlyHandlerName, marker: earlyMarker)
        PrependService.removeHandler(phpConfFolder: folder, name: saveHandlerName, marker: saveMarker)
    }

    // MARK: - Handlers

    static let earlyContents = #"""
    <?php
    /*
     * \#(earlyMarker)
     * Loaded at prepend time, before wp-config.php, so only plain PHP is
     * available. For requests whose X-WPC-Share-Origin header matches the origin
     * in ../../wpc-share.json, rewrites local origins to the public origin in the
     * response body and Location header. Added when a share starts, removed when
     * it stops.
     */
    if ( 'cli' === PHP_SAPI ) {
        return;
    }

    if ( ! function_exists( 'wpc_share_is_origin' ) ) {
        function wpc_share_is_origin( $value ) {
            return is_string( $value ) && 1 === preg_match( '~^https?://[A-Za-z0-9._-]+(:[0-9]+)?$~', $value );
        }
    }

    if ( ! function_exists( 'wpc_share_load_config' ) ) {
        function wpc_share_load_config() {
            $file = dirname( __DIR__, 2 ) . '/wpc-share.json';
            if ( ! is_file( $file ) ) {
                return null;
            }

            $header = isset( $_SERVER['HTTP_X_WPC_SHARE_ORIGIN'] ) ? $_SERVER['HTTP_X_WPC_SHARE_ORIGIN'] : '';
            if ( ! is_string( $header ) || '' === $header ) {
                return null;
            }

            $json   = file_get_contents( $file );
            $config = is_string( $json ) ? json_decode( $json, true ) : null;
            if ( ! is_array( $config ) || ! isset( $config['origin'], $config['local'], $config['locals'] ) ) {
                return null;
            }
            if ( ! wpc_share_is_origin( $config['origin'] ) || ! wpc_share_is_origin( $config['local'] ) || ! is_array( $config['locals'] ) ) {
                return null;
            }
            foreach ( $config['locals'] as $local ) {
                if ( ! wpc_share_is_origin( $local ) ) {
                    return null;
                }
            }

            if ( ! hash_equals( $config['origin'], $header ) ) {
                return null;
            }

            return $config;
        }
    }

    if ( ! function_exists( 'wpc_share_escape_slashes' ) ) {
        function wpc_share_escape_slashes( $value ) {
            return str_replace( '/', '\/', $value );
        }
    }

    if ( ! function_exists( 'wpc_share_origin_map' ) ) {
        /**
         * Map each origin in $froms, and its slash-escaped form, to $to.
         */
        function wpc_share_origin_map( $froms, $to ) {
            $map = array();
            foreach ( $froms as $from ) {
                $map[ $from ]                             = $to;
                $map[ wpc_share_escape_slashes( $from ) ] = wpc_share_escape_slashes( $to );
            }
            return $map;
        }
    }

    if ( ! function_exists( 'wpc_share_to_public_map' ) ) {
        function wpc_share_to_public_map() {
            static $map = null;
            if ( null === $map ) {
                $map = wpc_share_origin_map( WPC_SHARE_LOCALS, WPC_SHARE_ORIGIN );
            }
            return $map;
        }
    }

    if ( ! function_exists( 'wpc_share_replace_origins' ) ) {
        /**
         * Replace each key of $map found in $text with its value. An origin only
         * matches when followed by a boundary, so a longer host that starts with
         * it is left alone.
         */
        function wpc_share_replace_origins( $text, $map ) {
            if ( ! is_string( $text ) || '' === $text || empty( $map ) ) {
                return $text;
            }

            static $patterns = array();
            $keys = array_keys( $map );
            $id   = md5( implode( "\n", $keys ) );
            if ( ! isset( $patterns[ $id ] ) ) {
                usort( $keys, 'wpc_share_compare_length' );
                $quoted = array();
                foreach ( $keys as $key ) {
                    $quoted[] = preg_quote( $key, '~' );
                }
                $patterns[ $id ] = '~(' . implode( '|', $quoted ) . ')(?=[/"\'\\\\?#<&\s),;]|\z)~';
            }

            $result = preg_replace_callback(
                $patterns[ $id ],
                function ( $match ) use ( $map ) {
                    return $map[ $match[1] ];
                },
                $text
            );

            return null === $result ? $text : $result;
        }
    }

    if ( ! function_exists( 'wpc_share_compare_length' ) ) {
        function wpc_share_compare_length( $a, $b ) {
            return strlen( $b ) - strlen( $a );
        }
    }

    if ( ! function_exists( 'wpc_share_filter_output' ) ) {
        function wpc_share_filter_output( $buffer ) {
            $type = '';
            foreach ( headers_list() as $header ) {
                $lower = strtolower( $header );
                if ( 0 === strpos( $lower, 'content-encoding:' ) ) {
                    return $buffer;
                }
                if ( 0 === strpos( $lower, 'content-type:' ) ) {
                    $type = trim( (string) strtok( substr( $lower, 13 ), ';' ) );
                }
            }

            $allowed = array(
                'application/json',
                'application/javascript',
                'application/xml',
                'application/rss+xml',
                'application/atom+xml',
            );
            if ( '' !== $type && 0 !== strpos( $type, 'text/' ) && ! in_array( $type, $allowed, true ) ) {
                return $buffer;
            }

            return wpc_share_replace_origins( $buffer, wpc_share_to_public_map() );
        }
    }

    if ( ! function_exists( 'wpc_share_rewrite_location' ) ) {
        function wpc_share_rewrite_location() {
            foreach ( headers_list() as $header ) {
                if ( 0 !== stripos( $header, 'location:' ) ) {
                    continue;
                }
                $value   = ltrim( substr( $header, 9 ) );
                $rewrote = wpc_share_replace_origins( $value, wpc_share_to_public_map() );
                if ( $rewrote !== $value ) {
                    header( 'Location: ' . $rewrote, true );
                }
                return;
            }
        }
    }

    if ( ! function_exists( 'wpc_share_boot' ) ) {
        function wpc_share_boot() {
            $config = wpc_share_load_config();
            if ( null === $config || defined( 'WPC_SHARE_ORIGIN' ) ) {
                return;
            }

            define( 'WPC_SHARE_ORIGIN', $config['origin'] );
            define( 'WPC_SHARE_LOCAL', $config['local'] );
            define( 'WPC_SHARE_LOCALS', $config['locals'] );

            if ( 0 === strpos( $config['origin'], 'https://' ) ) {
                $_SERVER['HTTPS'] = 'on';
            }

            ob_start( 'wpc_share_filter_output' );
            header_register_callback( 'wpc_share_rewrite_location' );
        }
    }

    wpc_share_boot();
    """#

    static let saveContents = #"""
    <?php
    /*
     * \#(saveMarker)
     * Loaded at muplugins_loaded. For share requests (WPC_SHARE_ORIGIN is
     * defined by the early handler), swaps the public origin back to the local
     * one in content before WordPress stores it, so saved content keeps working
     * after the share closes, and refuses changes to the site addresses.
     */
    if ( ! defined( 'WPC_SHARE_ORIGIN' ) || ! function_exists( 'wpc_share_replace_origins' ) ) {
        return;
    }

    if ( ! function_exists( 'wpc_share_to_local_map' ) ) {
        function wpc_share_to_local_map() {
            static $map = null;
            if ( null === $map ) {
                $map = wpc_share_origin_map( array( WPC_SHARE_ORIGIN ), WPC_SHARE_LOCAL );
            }
            return $map;
        }
    }

    if ( ! function_exists( 'wpc_share_contains_incomplete_class' ) ) {
        function wpc_share_contains_incomplete_class( $value, $depth = 0 ) {
            if ( $value instanceof __PHP_Incomplete_Class ) {
                return true;
            }
            if ( $depth > 32 || ( ! is_array( $value ) && ! is_object( $value ) ) ) {
                return false;
            }
            foreach ( $value as $item ) {
                if ( wpc_share_contains_incomplete_class( $item, $depth + 1 ) ) {
                    return true;
                }
            }
            return false;
        }
    }

    if ( ! function_exists( 'wpc_share_swap_back' ) ) {
        /**
         * Replace the public origin with the local one in strings, arrays,
         * objects and serialized strings.
         */
        function wpc_share_swap_back( $value, $depth = 0 ) {
            if ( $depth > 32 ) {
                return $value;
            }

            if ( is_string( $value ) ) {
                $swapped = wpc_share_replace_origins( $value, wpc_share_to_local_map() );
                if ( $swapped === $value || ! is_serialized( $value ) ) {
                    return $swapped;
                }

                $data = @unserialize( $value, array( 'allowed_classes' => false ) );
                if ( ( false === $data && 'b:0;' !== trim( $value ) ) || wpc_share_contains_incomplete_class( $data ) ) {
                    return $value;
                }
                return serialize( wpc_share_swap_back( $data, $depth + 1 ) );
            }

            if ( is_array( $value ) ) {
                foreach ( $value as $key => $item ) {
                    $value[ $key ] = wpc_share_swap_back( $item, $depth + 1 );
                }
                return $value;
            }

            if ( is_object( $value ) && ! ( $value instanceof __PHP_Incomplete_Class ) ) {
                if ( ! ( new ReflectionObject( $value ) )->isCloneable() ) {
                    return $value;
                }
                $copy = clone $value;
                foreach ( get_object_vars( $copy ) as $key => $item ) {
                    $copy->$key = wpc_share_swap_back( $item, $depth + 1 );
                }
                return $copy;
            }

            return $value;
        }
    }

    if ( ! function_exists( 'wpc_share_swap_back_slashed' ) ) {
        function wpc_share_swap_back_slashed( $value ) {
            return wp_slash( wpc_share_swap_back( wp_unslash( $value ) ) );
        }
    }

    if ( ! function_exists( 'wpc_share_filter_post_data' ) ) {
        function wpc_share_filter_post_data( $data ) {
            $fields = array( 'post_content', 'post_excerpt', 'post_content_filtered', 'post_title' );
            foreach ( $fields as $field ) {
                if ( isset( $data[ $field ] ) ) {
                    $data[ $field ] = wpc_share_swap_back_slashed( $data[ $field ] );
                }
            }
            return $data;
        }
    }

    if ( ! function_exists( 'wpc_share_filter_option' ) ) {
        function wpc_share_filter_option( $value ) {
            return wpc_share_swap_back( $value );
        }
    }

    if ( ! function_exists( 'wpc_share_filter_site_option' ) ) {
        function wpc_share_filter_site_option( $value ) {
            return wpc_share_swap_back( $value );
        }
    }

    if ( ! function_exists( 'wpc_share_filter_slashed' ) ) {
        function wpc_share_filter_slashed( $value ) {
            return wpc_share_swap_back_slashed( $value );
        }
    }

    if ( ! function_exists( 'wpc_share_filter_unslashed' ) ) {
        function wpc_share_filter_unslashed( $value ) {
            return wpc_share_swap_back( $value );
        }
    }

    if ( ! function_exists( 'wpc_share_filter_meta' ) ) {
        /**
         * Short-circuit handler for add_{type}_metadata / update_{type}_metadata.
         * When the swapped value differs it is stored through the regular
         * metadata API; otherwise WordPress proceeds untouched.
         */
        function wpc_share_filter_meta( $kind, $meta_type, $check, $object_id, $meta_key, $meta_value, $extra ) {
            static $busy = false;
            if ( $busy || null !== $check ) {
                return $check;
            }

            $swapped = wpc_share_swap_back( $meta_value );
            if ( $swapped === $meta_value ) {
                return $check;
            }

            $busy = true;
            try {
                if ( 'add' === $kind ) {
                    return add_metadata( $meta_type, $object_id, $meta_key, wp_slash( $swapped ), (bool) $extra );
                }
                return update_metadata( $meta_type, $object_id, $meta_key, wp_slash( $swapped ), $extra );
            } finally {
                $busy = false;
            }
        }
    }

    if ( ! function_exists( 'wpc_share_refuse_url_change' ) ) {
        /**
         * Keep the stored site address; report the refusal when the submitted
         * value is a different address.
         */
        function wpc_share_refuse_url_change( $value, $old_value ) {
            $submitted = wpc_share_swap_back( $value );
            if ( rtrim( (string) $submitted, '/' ) === rtrim( (string) $old_value, '/' ) ) {
                return $old_value;
            }
            if ( function_exists( 'add_settings_error' ) ) {
                add_settings_error( 'general', 'wpc_share_url', 'Site addresses can’t be changed through a share link.' );
            }
            return $old_value;
        }
    }

    if ( ! function_exists( 'wpc_share_validate_site_data' ) ) {
        function wpc_share_validate_site_data( $errors, $data, $old_site ) {
            if ( ! $old_site || ! ( $errors instanceof WP_Error ) ) {
                return;
            }
            foreach ( array( 'domain', 'path' ) as $field ) {
                if ( isset( $data[ $field ] ) && (string) $data[ $field ] !== (string) $old_site->$field ) {
                    $errors->add( 'wpc_share_url', 'Site addresses can’t be changed through a share link.' );
                    return;
                }
            }
        }
    }

    if ( ! function_exists( 'wpc_share_register_hooks' ) ) {
        function wpc_share_register_hooks() {
            add_filter( 'wp_insert_post_data', 'wpc_share_filter_post_data' );
            add_filter( 'pre_update_option', 'wpc_share_filter_option' );
            add_filter( 'preprocess_comment', 'wpc_share_filter_slashed' );
            add_filter( 'pre_term_description', 'wpc_share_filter_unslashed' );
            add_filter( 'pre_user_url', 'wpc_share_filter_unslashed' );

            foreach ( array( 'post', 'term', 'user', 'comment' ) as $type ) {
                add_filter(
                    "add_{$type}_metadata",
                    function ( $check, $object_id, $meta_key, $meta_value, $unique ) use ( $type ) {
                        return wpc_share_filter_meta( 'add', $type, $check, $object_id, $meta_key, $meta_value, $unique );
                    },
                    10,
                    5
                );
                add_filter(
                    "update_{$type}_metadata",
                    function ( $check, $object_id, $meta_key, $meta_value, $prev_value ) use ( $type ) {
                        return wpc_share_filter_meta( 'update', $type, $check, $object_id, $meta_key, $meta_value, $prev_value );
                    },
                    10,
                    5
                );
            }

            foreach ( array( 'welcome_email', 'welcome_user_email', 'first_post', 'first_page', 'first_comment', 'first_comment_url' ) as $option ) {
                add_filter( "pre_update_site_option_{$option}", 'wpc_share_filter_site_option' );
            }

            add_filter( 'pre_update_option_home', 'wpc_share_refuse_url_change', 10, 2 );
            add_filter( 'pre_update_option_siteurl', 'wpc_share_refuse_url_change', 10, 2 );
            add_action( 'wp_validate_site_data', 'wpc_share_validate_site_data', 10, 3 );
        }
    }

    wpc_share_register_hooks();
    """#
}
