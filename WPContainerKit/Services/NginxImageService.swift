import Foundation

/// Builds (once per base tag) the nginx image used by sites whose web server
/// is nginx: `FROM wordpress:<ref>-fpm` plus nginx, both running in the one wp
/// container.
///
/// The image keeps the official entrypoint, so `wp-config.php` is still
/// generated from the `WORDPRESS_DB_*` env on first start. `wpc-entrypoint`
/// wraps it: it starts nginx once PHP-FPM accepts connections on :9000 (so the
/// readiness probe never mistakes an early 502 for a running site), then execs
/// the official entrypoint with `php-fpm`.
///
/// The site's own `nginx/*.conf` files (`RunnableInstance.nginxConfFolder`)
/// are mounted at `siteConfContainerPath` and included inside the server
/// block, ahead of wp-container's locations. When they fail `nginx -t`, the
/// site starts without them and the error goes to the container log.
///
/// `WPC_NETWORK_TYPE=subdirectory` (set per container by
/// `SiteRecipe.runWordPressArgs`) turns on the subdirectory-multisite
/// rewrites, the nginx counterpart of the network `.htaccess`. Subdomain
/// networks need no extra rules.
public actor NginxImageService {
    private let cli: ContainerCLI
    /// One build per derived tag at a time: a site and its envs starting
    /// together share it.
    private var inFlight: [String: Task<String, Error>] = [:]

    public init(cli: ContainerCLI = ContainerCLI()) {
        self.cli = cli
    }

    /// Bump whenever `buildContext()` changes: the version is part of the
    /// derived tag, so images built from an older recipe are rebuilt.
    static let recipeVersion = 2

    /// The env var that selects the multisite rewrites inside the container.
    public static let networkTypeEnvName = "WPC_NETWORK_TYPE"

    /// Where the site's nginx config folder is mounted.
    public static let siteConfContainerPath = "/etc/nginx/wpc/site.d"

    /// Where the entrypoint links the site's `*.conf` files that nginx includes.
    static let siteConfActivePath = "/etc/nginx/wpc/site"

    /// The derived image tag for an FPM base tag, e.g.
    /// `wordpress:6.8-php8.3-fpm` → `wpc-wordpress-nginx:v1-6.8-php8.3-fpm`.
    public static func derivedTag(forBase baseTag: String) -> String {
        let ref = baseTag.hasPrefix("wordpress:")
            ? String(baseTag.dropFirst("wordpress:".count))
            : baseTag.replacingOccurrences(of: ":", with: "-")
        let safe = ref.isEmpty ? "fpm" : ref
        return "wpc-wordpress-nginx:v\(recipeVersion)-\(safe)"
    }

    /// Ensure the nginx image for `baseTag` (an FPM tag) exists, building it
    /// if missing. Returns the derived image tag.
    @discardableResult
    public func ensureImage(forBaseTag baseTag: String,
                            progress: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let derived = Self.derivedTag(forBase: baseTag)
        if let existing = inFlight[derived] { return try await existing.value }
        let cli = self.cli
        let task = Task<String, Error> {
            if await cli.localImageExists(derived) { return derived }
            if !(await cli.localImageExists(baseTag)) {
                progress?("Pulling base image \(baseTag)…")
                _ = try? await cli.run(["image", "pull", baseTag])
            }
            progress?("Building nginx image (first time)…")
            try await DerivedImageBuilder(cli: cli).build(
                tag: derived, files: Self.buildContext(baseTag: baseTag),
                displayName: "nginx", progress: progress)
            return derived
        }
        inFlight[derived] = task
        defer { inFlight[derived] = nil }
        return try await task.value
    }

    /// Every build-context file, keyed by its path in the context.
    static func buildContext(baseTag: String) -> [String: String] {
        [
            "Dockerfile": dockerfile(baseTag: baseTag),
            "wpc-site.conf": siteConf,
            "wpc-fastcgi.conf": fastcgiConf,
            "wpc-multisite-subdirectory.conf": subdirectoryMultisiteConf,
            "zz-wpc.conf": fpmPoolConf,
            "wpc-entrypoint": entrypoint,
        ]
    }

    static func dockerfile(baseTag: String) -> String {
        """
        FROM \(baseTag)

        RUN apt-get update \\
            && apt-get install -y --no-install-recommends nginx \\
            && rm -rf /var/lib/apt/lists/* /etc/nginx/sites-enabled/default

        COPY wpc-site.conf /etc/nginx/conf.d/wpc-site.conf
        COPY wpc-fastcgi.conf /etc/nginx/wpc/fastcgi.conf
        COPY wpc-multisite-subdirectory.conf /etc/nginx/wpc/multisite-subdirectory.conf
        COPY zz-wpc.conf /usr/local/etc/php-fpm.d/zz-wpc.conf
        COPY wpc-entrypoint /usr/local/bin/wpc-entrypoint
        RUN chmod 755 /usr/local/bin/wpc-entrypoint

        ENTRYPOINT ["wpc-entrypoint"]
        CMD ["php-fpm"]
        """
    }

    /// `absolute_redirect off` keeps nginx's own redirects (`/wp-admin` →
    /// `/wp-admin/`) relative, so they hold behind the published port and the
    /// HTTPS proxy. `client_max_body_size 0` leaves upload limits to PHP's
    /// `upload_max_filesize`/`post_max_size` (`PHPConfService`).
    static let siteConf = """
    server {
        listen 80 default_server;
        server_name _;
        root /var/www/html;
        index index.php index.html;

        absolute_redirect off;
        client_max_body_size 0;

        access_log /dev/stdout;
        error_log /dev/stderr;

        include /etc/nginx/wpc/active/*.conf;
        include \(siteConfActivePath)/*.conf;

        location / {
            try_files $uri $uri/ /index.php?$args;
        }

        location ~ \\.php$ {
            try_files $uri =404;
            include /etc/nginx/wpc/fastcgi.conf;
            fastcgi_pass 127.0.0.1:9000;
            fastcgi_read_timeout 300s;
        }
    }
    """

    /// Debian's stock `fastcgi_params` passes `HTTP_HOST` as `$host`, which
    /// drops the port, so WordPress on `127.0.0.1:<port>` would build URLs
    /// without it. These params pass the Host header as sent, like Apache.
    static let fastcgiConf = """
    fastcgi_param  SCRIPT_FILENAME    $document_root$fastcgi_script_name;
    fastcgi_param  QUERY_STRING       $query_string;
    fastcgi_param  REQUEST_METHOD     $request_method;
    fastcgi_param  CONTENT_TYPE       $content_type;
    fastcgi_param  CONTENT_LENGTH     $content_length;
    fastcgi_param  SCRIPT_NAME        $fastcgi_script_name;
    fastcgi_param  REQUEST_URI        $request_uri;
    fastcgi_param  DOCUMENT_URI       $document_uri;
    fastcgi_param  DOCUMENT_ROOT      $document_root;
    fastcgi_param  SERVER_PROTOCOL    $server_protocol;
    fastcgi_param  REQUEST_SCHEME     $scheme;
    fastcgi_param  HTTPS              $https if_not_empty;
    fastcgi_param  GATEWAY_INTERFACE  CGI/1.1;
    fastcgi_param  SERVER_SOFTWARE    nginx/$nginx_version;
    fastcgi_param  REMOTE_ADDR        $remote_addr;
    fastcgi_param  REMOTE_PORT        $remote_port;
    fastcgi_param  SERVER_ADDR        $server_addr;
    fastcgi_param  SERVER_PORT        $server_port;
    fastcgi_param  SERVER_NAME        $host;
    fastcgi_param  REDIRECT_STATUS    200;
    fastcgi_param  HTTP_HOST          $http_host;
    """

    /// WordPress's subdirectory-network rules for nginx. A request for a file
    /// that doesn't exist under a site prefix (`/site2/wp-admin/…`) is served
    /// from the shared core path.
    static let subdirectoryMultisiteConf = """
    if (!-e $request_filename) {
        rewrite /wp-admin$ $uri/ permanent;
        rewrite ^(/[^/]+)?(/wp-.*) $2 last;
        rewrite ^(/[^/]+)?(/.*\\.php) $2 last;
    }
    """

    /// nginx already logs every request to stdout, so the pool's own access log
    /// is dropped. The stock pool allows 5 workers, which the block editor's
    /// parallel REST requests can exhaust.
    static let fpmPoolConf = """
    [www]
    access.log = /dev/null
    pm.max_children = 10
    """

    static let entrypoint = """
    #!/bin/bash
    set -e
    mkdir -p /etc/nginx/wpc/active \(siteConfActivePath)
    rm -f /etc/nginx/wpc/active/*.conf \(siteConfActivePath)/*.conf
    if [ "$\(networkTypeEnvName)" = subdirectory ]; then
        ln -s /etc/nginx/wpc/multisite-subdirectory.conf /etc/nginx/wpc/active/multisite.conf
    fi
    for conf in \(siteConfContainerPath)/*.conf; do
        if [ -f "$conf" ]; then
            ln -s "$conf" \(siteConfActivePath)/
        fi
    done
    if ls \(siteConfActivePath)/*.conf >/dev/null 2>&1 && ! nginx -t 2>/tmp/wpc-nginx-test; then
        echo "wpc: the site's nginx config fails nginx -t, so the site starts without it:" >&2
        cat /tmp/wpc-nginx-test >&2
        rm -f \(siteConfActivePath)/*.conf
    fi
    (
        until (exec 3<>/dev/tcp/127.0.0.1/9000) 2>/dev/null; do sleep 0.1; done
        exec nginx -g 'daemon off;'
    ) &
    exec docker-entrypoint.sh "$@"

    """
}
