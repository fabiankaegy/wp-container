import Foundation

/// THE single source of truth for the literal `container` command recipes used
/// to run a WordPress dev site or worktree environment.
///
/// Everything here is pure string/array construction — no process execution.
/// A later integration phase (Phase I) will reconcile these against the
/// empirically-validated commands from Phase V, and the nested-mount shadowing
/// used by worktree environments (`shadowMount`) is being verified in parallel;
/// keeping it all here means those adjustments touch exactly one file.
public enum SiteRecipe {
    // MARK: Images
    public static let databaseImage = "mariadb:11"
    public static let wpCLIImage = "wordpress:cli"
    public static let defaultWordPressImage = "wordpress:latest"
    /// Elasticsearch image (validated in `scripts/validate-addons.sh`, §2c).
    public static let elasticsearchImage = "elasticsearch:8.15.0"

    /// PHP-version image options offered in the Add Site sheet.
    public static let wordPressImageOptions: [(label: String, tag: String)] = [
        ("Latest", "wordpress:latest"),
        ("PHP 8.3", "wordpress:php8.3-apache"),
        ("PHP 8.2", "wordpress:php8.2-apache"),
        ("PHP 8.1", "wordpress:php8.1-apache"),
    ]

    // MARK: Database credentials
    public static let dbName = "wordpress"
    public static let dbUser = "wordpress"
    public static let dbPassword = "wordpress"
    public static let dbRootPassword = "root"

    // MARK: Admin credentials (auto-provisioning)
    public static let adminUser = "admin"
    public static let adminPassword = "password"
    public static let adminEmail = "admin@localhost.local"

    // MARK: Labels
    public static let siteLabelKey = "dev.wpcontainer.site"
    public static let envLabelKey = "dev.wpcontainer.env"

    /// `["--label", "dev.wpcontainer.site=<slug>", ("--label", "dev.wpcontainer.env=<envSlug>")]`
    static func labelArgs(for inst: any RunnableInstance) -> [String] {
        var args = ["--label", "\(siteLabelKey)=\(inst.siteSlug)"]
        if let env = inst.envLabel {
            args += ["--label", "\(envLabelKey)=\(env)"]
        }
        return args
    }

    // MARK: - Images
    public static func pullImageArgs(_ image: String) -> [String] {
        ["image", "pull", image]
    }

    // MARK: - Pre-seed (VALIDATED, Phase V)
    /// The `wordpress` image's auto-populate-into-empty-mount does NOT work on
    /// Apple `container`: virtiofs mounts appear as root:root in-guest and reject
    /// chown, so the entrypoint dies. Before a site's FIRST ever start we seed
    /// the mount by copying WordPress core in ourselves. MUST be plain `cp -r`
    /// (NOT `cp -a`). ~2s; after this, normal starts work with no workarounds.
    /// Gate on absence of `<wordpress>/index.php`.
    public static func seedWordPressArgs(_ inst: any RunnableInstance) -> [String] {
        [
            "run", "--rm", "--entrypoint", "/bin/sh",
            "-v", "\(inst.wordpressFolder.path):/var/www/html",
            inst.imageTag,
            "-c", "cp -r /usr/src/wordpress/. /var/www/html/",
        ]
    }

    // MARK: - Database container
    public static func runDatabaseArgs(_ inst: any RunnableInstance) -> [String] {
        // VALIDATED: mariadb must run as 999:999 when bind-mounting database/,
        // otherwise the same virtiofs chown restriction kills its entrypoint
        // (holds for both fresh init and restarts).
        var args = ["run", "-d", "--rm", "--name", inst.dbContainerName, "--user", "999:999"]
        args += labelArgs(for: inst)
        args += [
            "-v", "\(inst.databaseFolder.path):/var/lib/mysql",
            "-e", "MARIADB_DATABASE=\(dbName)",
            "-e", "MARIADB_USER=\(dbUser)",
            "-e", "MARIADB_PASSWORD=\(dbPassword)",
            "-e", "MARIADB_ROOT_PASSWORD=\(dbRootPassword)",
            databaseImage,
        ]
        return args
    }

    /// mariadb ships `healthcheck.sh`; exit 0 means the server accepts connections.
    public static func databaseHealthcheckArgs(_ inst: any RunnableInstance) -> [String] {
        ["exec", inst.dbContainerName, "healthcheck.sh", "--connect", "--innodb_initialized"]
    }

    // MARK: - WordPress container
    /// Build the `container run` args for the WP container.
    ///
    /// - `imageOverride`: run a different image than `inst.imageTag` (the Xdebug
    ///   derived image, §2c).
    /// - `xdebugClientHost`: when non-nil, pass `-e XDEBUG_CLIENT_HOST=<gateway>`
    ///   so Xdebug's `client_host` ini substitution resolves to the host (§2c).
    /// - `elasticsearchURL`: when non-nil, pass `ELASTICSEARCH_URL` + `EP_HOST`
    ///   for ElasticPress (§2c).
    public static func runWordPressArgs(_ inst: any RunnableInstance, dbHost: String,
                                        imageOverride: String? = nil,
                                        xdebugClientHost: String? = nil,
                                        elasticsearchURL: String? = nil) -> [String] {
        var args = ["run", "-d", "--rm", "--name", inst.wpContainerName]
        args += labelArgs(for: inst)
        args += [
            "-p", "127.0.0.1:\(inst.port):80",
            "-v", "\(inst.wordpressFolder.path):/var/www/html",
        ]
        // Worktree environments add a shadowing mount over the repo path.
        for mount in inst.extraMounts {
            args += ["-v", "\(mount.hostPath):\(mount.containerPath)"]
        }
        args += [
            "-e", "WORDPRESS_DB_HOST=\(dbHost)",
            "-e", "WORDPRESS_DB_USER=\(dbUser)",
            "-e", "WORDPRESS_DB_PASSWORD=\(dbPassword)",
            "-e", "WORDPRESS_DB_NAME=\(dbName)",
        ]
        if let xdebugClientHost {
            args += ["-e", "XDEBUG_CLIENT_HOST=\(xdebugClientHost)"]
        }
        if let elasticsearchURL {
            args += ["-e", "ELASTICSEARCH_URL=\(elasticsearchURL)",
                     "-e", "EP_HOST=\(elasticsearchURL)"]
        }
        args.append(imageOverride ?? inst.imageTag)
        return args
    }

    // MARK: - Elasticsearch sidecar (§2c, validated)
    /// `container run` args for a site's Elasticsearch sidecar. No `--user`
    /// override (the image already runs as a non-root user), bind-mounts a data
    /// dir, single-node with security off and a modest heap.
    public static func runElasticsearchArgs(_ inst: any RunnableInstance) -> [String] {
        var args = ["run", "-d", "--rm", "--name", inst.esContainerName]
        args += labelArgs(for: inst)
        args += [
            "-v", "\(inst.elasticsearchFolder.path):/usr/share/elasticsearch/data",
            "-e", "discovery.type=single-node",
            "-e", "xpack.security.enabled=false",
            "-e", "ES_JAVA_OPTS=-Xms512m -Xmx512m",
            elasticsearchImage,
        ]
        return args
    }

    /// Probe ES cluster health (green/yellow ⇒ ready) from a one-shot curl.
    public static func elasticsearchHealthURL(esHost: String) -> String {
        "http://\(esHost):9200/_cluster/health"
    }

    /// The nested shadowing mount for a worktree env's repo. Isolated here so
    /// Phase V/I can adjust the container-path convention.
    public static func shadowMount(worktreePath: URL, repoRelPath: String) -> Mount {
        let clean = repoRelPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return Mount(hostPath: worktreePath.path, containerPath: "/var/www/html/\(clean)")
    }

    // MARK: - One-shot wp-cli
    private static func wpCLIBaseArgs(_ inst: any RunnableInstance, dbHost: String) -> [String] {
        var args = ["run", "--rm"]
        args += labelArgs(for: inst)
        args += [
            "-v", "\(inst.wordpressFolder.path):/var/www/html",
            "-e", "WORDPRESS_DB_HOST=\(dbHost)",
            "-e", "WORDPRESS_DB_USER=\(dbUser)",
            "-e", "WORDPRESS_DB_PASSWORD=\(dbPassword)",
            "-e", "WORDPRESS_DB_NAME=\(dbName)",
        ]
        return args
    }

    /// `wp core install` for first-run provisioning.
    public static func wpCoreInstallArgs(_ inst: any RunnableInstance, dbHost: String) -> [String] {
        var args = wpCLIBaseArgs(inst, dbHost: dbHost)
        args += [
            wpCLIImage,
            "wp", "core", "install",
            "--url=http://127.0.0.1:\(inst.port)",
            "--title=\(inst.displayName)",
            "--admin_user=\(adminUser)",
            "--admin_password=\(adminPassword)",
            "--admin_email=\(adminEmail)",
            "--skip-email",
        ]
        return args
    }

    /// `wp core multisite-install` for first-run provisioning of a network site
    /// (PLAN.md §2j). Run instead of `wp core install`: it performs a fresh
    /// network install into the empty DB and seeds the multisite constants.
    public static func wpMultisiteInstallArgs(_ inst: any RunnableInstance, dbHost: String,
                                              url: String, subdomains: Bool) -> [String] {
        var args = wpCLIBaseArgs(inst, dbHost: dbHost)
        args += [
            wpCLIImage,
            "wp", "core", "multisite-install",
            "--url=\(url)",
            "--title=\(inst.displayName)",
            "--admin_user=\(adminUser)",
            "--admin_password=\(adminPassword)",
            "--admin_email=\(adminEmail)",
            "--skip-email",
        ]
        if subdomains { args.append("--subdomains") }
        return args
    }

    /// `wp site list --format=json` for the multisite subsites list (§2j).
    public static func wpSiteListArgs(_ inst: any RunnableInstance, dbHost: String) -> [String] {
        var args = wpCLIBaseArgs(inst, dbHost: dbHost)
        args += [wpCLIImage, "wp", "site", "list", "--format=json"]
        return args
    }

    /// `wp core update` (+ database) for the "Update WordPress core" action (§2k).
    public static func wpCoreUpdateArgs(_ inst: any RunnableInstance, dbHost: String) -> [String] {
        var args = wpCLIBaseArgs(inst, dbHost: dbHost)
        args += [wpCLIImage, "sh", "-c", "wp core update && wp core update-db"]
        return args
    }

    /// `wp core version` for the live WordPress version display (§2k).
    public static func wpCoreVersionArgs(_ inst: any RunnableInstance, dbHost: String) -> [String] {
        var args = wpCLIBaseArgs(inst, dbHost: dbHost)
        args += [wpCLIImage, "wp", "core", "version"]
        return args
    }

    /// `wp option update home/siteurl` + cache flush — used after cloning a site
    /// into a worktree env so URLs point at the env's port.
    public static func wpUpdateURLsArgs(_ inst: any RunnableInstance, dbHost: String) -> [String] {
        var args = wpCLIBaseArgs(inst, dbHost: dbHost)
        let url = "http://127.0.0.1:\(inst.port)"
        // sh -c inside the wp-cli container chains the three commands; the host
        // side is still a plain argument array (no host shell interpolation).
        args += [
            wpCLIImage,
            "sh", "-c",
            "wp option update home '\(url)' && wp option update siteurl '\(url)' && wp cache flush",
        ]
        return args
    }

    /// Set `home`/`siteurl` to an arbitrary URL + flush cache — used when
    /// toggling HTTPS on/off for a site (PLAN.md §2f).
    public static func wpSetURLsArgs(_ inst: any RunnableInstance, dbHost: String, url: String) -> [String] {
        var args = wpCLIBaseArgs(inst, dbHost: dbHost)
        args += [
            wpCLIImage,
            "sh", "-c",
            "wp option update home '\(url)' && wp option update siteurl '\(url)' && wp cache flush",
        ]
        return args
    }

    /// One-shot `container logs [<name>]` (non-follow) for log-reading tools.
    public static func logsArgs(_ containerName: String) -> [String] {
        ["logs", containerName]
    }

    /// Arbitrary proxied one-shot wp-cli invocation (`wp-container wp <site> -- …`).
    public static func wpProxyArgs(_ inst: any RunnableInstance, dbHost: String, wpArgs: [String]) -> [String] {
        var args = wpCLIBaseArgs(inst, dbHost: dbHost)
        args += [wpCLIImage, "wp"]
        args += wpArgs
        return args
    }

    /// `wp db export` to stdout inside a one-shot wp-cli container (live DB clone).
    public static func wpDBExportArgs(_ inst: any RunnableInstance, dbHost: String) -> [String] {
        var args = wpCLIBaseArgs(inst, dbHost: dbHost)
        args += [wpCLIImage, "wp", "db", "export", "-", "--single-transaction"]
        return args
    }

    // MARK: - Stop / delete
    public static func stopArgs(_ containerName: String) -> [String] { ["stop", containerName] }
    public static func deleteArgs(_ containerName: String) -> [String] { ["delete", containerName] }
}
