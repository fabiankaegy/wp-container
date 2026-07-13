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
    /// Mailpit email-catcher image (issue #10). Multi-arch, tiny (~40 MB). Runs
    /// as root under Apple `container`, so its `/data` bind mount on virtiofs
    /// works without the mariadb-style uid workaround (validated empirically).
    public static let mailpitImage = "docker.io/axllent/mailpit"
    /// Mailpit's in-container SMTP port; WordPress connects here (issue #10).
    public static let mailpitSMTPPort = 1025
    /// Mailpit's in-container web-UI/REST port, published to a localhost port.
    public static let mailpitWebPort = 8025

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

    // MARK: Resource limits (issue #11)
    /// `--cpus`/`--memory` flags for a long-lived container run, from the
    /// instance's optional per-site caps. nil fields emit nothing, so the
    /// `container` defaults (4 CPUs / 1 GB) apply. Memory uses the documented
    /// `M` (MiByte) suffix. NEVER applied to one-shot wp-cli containers.
    static func resourceArgs(for inst: any RunnableInstance) -> [String] {
        var args: [String] = []
        if let cpus = inst.cpuLimit, cpus > 0 { args += ["--cpus", "\(cpus)"] }
        if let mb = inst.memoryLimitMB, mb > 0 { args += ["--memory", "\(mb)M"] }
        return args
    }

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
        args += resourceArgs(for: inst)
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
    /// - `mailpitHost`: when non-nil, inject `WPC_MAILPIT_HOST=<mail-ip>` so the
    ///   `wpc-mailpit` mu-plugin routes PHPMailer to Mailpit's SMTP (issue #10).
    ///   The IP is re-inspected each start (container IPs churn); env-var
    ///   indirection keeps the mu-plugin file static.
    public static func runWordPressArgs(_ inst: any RunnableInstance, dbHost: String,
                                        imageOverride: String? = nil,
                                        xdebugClientHost: String? = nil,
                                        elasticsearchURL: String? = nil,
                                        mailpitHost: String? = nil) -> [String] {
        var args = ["run", "-d", "--rm", "--name", inst.wpContainerName]
        args += resourceArgs(for: inst)
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
        if let mailpitHost {
            args += ["-e", "WPC_MAILPIT_HOST=\(mailpitHost)"]
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
        args += resourceArgs(for: inst)
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

    // MARK: - Mailpit email catcher (issue #10, validated)
    /// `container run` args for a site's Mailpit container. Runs as root (Apple
    /// `container` default), so the persistent `/data` bind mount on virtiofs
    /// works without a uid override. SMTP stays on the container network (port
    /// 1025, reached by WordPress via the injected IP); only the web UI (8025)
    /// is published to `webPort` on localhost.
    public static func runMailpitArgs(_ inst: any RunnableInstance, webPort: Int) -> [String] {
        var args = ["run", "-d", "--rm", "--name", inst.mailContainerName]
        args += resourceArgs(for: inst)
        args += labelArgs(for: inst)
        args += [
            "-p", "127.0.0.1:\(webPort):\(mailpitWebPort)",
            "-v", "\(inst.mailpitFolder.path):/data",
            "-e", "MP_DATABASE=/data/mailpit.db",
            mailpitImage,
        ]
        return args
    }

    /// The nested shadowing mount for a worktree env's repo. Isolated here so
    /// Phase V/I can adjust the container-path convention.
    ///
    /// Defense-in-depth (#8): `.`/`..`/empty components are dropped so the
    /// container path can never resolve outside `/var/www/html`, even for a
    /// hand-edited store record with a traversal-laden rel path (creation
    /// already rejects those via `WorktreeEnvService.isValidRepoRelPath`).
    public static func shadowMount(worktreePath: URL, repoRelPath: String) -> Mount {
        let clean = repoRelPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != ".." && $0 != "." }
            .joined(separator: "/")
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

    /// The one-shot wp-cli image whose PHP version matches this instance's site
    /// image. NEVER hardcode `wordpress:cli` at a call site — a php8.4 site must
    /// run wp-cli on `wordpress:cli-php8.4` (see WordPressImageCatalog.cliImage).
    public static func cliImage(for inst: any RunnableInstance) -> String {
        WordPressImageCatalog.cliImage(for: inst.imageTag)
    }

    /// `wp core install` for first-run provisioning.
    public static func wpCoreInstallArgs(_ inst: any RunnableInstance, dbHost: String) -> [String] {
        var args = wpCLIBaseArgs(inst, dbHost: dbHost)
        args += [
            cliImage(for: inst),
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
            cliImage(for: inst),
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
        args += [cliImage(for: inst), "wp", "site", "list", "--format=json"]
        return args
    }

    /// `wp core update` (+ database) for the "Update WordPress core" action (§2k).
    public static func wpCoreUpdateArgs(_ inst: any RunnableInstance, dbHost: String) -> [String] {
        var args = wpCLIBaseArgs(inst, dbHost: dbHost)
        args += [cliImage(for: inst), "sh", "-c", "wp core update && wp core update-db"]
        return args
    }

    /// `wp core version` for the live WordPress version display (§2k).
    public static func wpCoreVersionArgs(_ inst: any RunnableInstance, dbHost: String) -> [String] {
        var args = wpCLIBaseArgs(inst, dbHost: dbHost)
        args += [cliImage(for: inst), "wp", "core", "version"]
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
            cliImage(for: inst),
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
            cliImage(for: inst),
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
    ///
    /// - `mailpitHost`: when non-nil, inject `WPC_MAILPIT_HOST` so `wp_mail`
    ///   invoked from wp-cli (e.g. `wp eval 'wp_mail(...)'`, or an agent
    ///   verifying an email) is caught by Mailpit too — the wp-cli one-shot
    ///   container otherwise lacks the env the long-lived wp container gets
    ///   (issue #10).
    public static func wpProxyArgs(_ inst: any RunnableInstance, dbHost: String, wpArgs: [String],
                                   mailpitHost: String? = nil) -> [String] {
        var args = wpCLIBaseArgs(inst, dbHost: dbHost)
        if let mailpitHost { args += ["-e", "WPC_MAILPIT_HOST=\(mailpitHost)"] }
        args += [cliImage(for: inst), "wp"]
        args += wpArgs
        return args
    }

    /// `wp db export` to stdout inside a one-shot wp-cli container (live DB clone).
    public static func wpDBExportArgs(_ inst: any RunnableInstance, dbHost: String) -> [String] {
        var args = wpCLIBaseArgs(inst, dbHost: dbHost)
        args += [cliImage(for: inst), "wp", "db", "export", "-", "--single-transaction"]
        return args
    }

    // MARK: - Stop / delete
    public static func stopArgs(_ containerName: String) -> [String] { ["stop", containerName] }
    public static func deleteArgs(_ containerName: String) -> [String] { ["delete", containerName] }
}
