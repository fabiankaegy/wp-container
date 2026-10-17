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

    // MARK: PHP overrides
    /// Where an instance's `php/` overrides folder (see `PHPConfService`) is
    /// mounted inside the wp container.
    public static let phpConfContainerPath = "/usr/local/etc/php/wpc-conf.d"
    /// The image's compiled-in ini scan dir. Setting `PHP_INI_SCAN_DIR`
    /// REPLACES the default (it does not extend it), so this must be listed
    /// explicitly — and first, so files in the overrides dir win conflicts
    /// (later scan wins, including over the Xdebug derived image's ini).
    static let phpDefaultConfDir = "/usr/local/etc/php/conf.d"

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
    /// `container run` args for the DB container OWNED by `inst`. Never call
    /// this for a shared-database env (issue #17) — pass the owning parent site
    /// instead, so the name, folders, labels and caps are all the owner's.
    public static func runDatabaseArgs(_ inst: any RunnableInstance) -> [String] {
        // VALIDATED: mariadb must run as 999:999 when bind-mounting database/,
        // otherwise the same virtiofs chown restriction kills its entrypoint
        // (holds for both fresh init and restarts).
        var args = ["run", "-d", "--rm", "--name", inst.dbContainerName, "--user", "999:999"]
        args += resourceArgs(for: inst)
        args += labelArgs(for: inst)
        args += [
            "-v", "\(inst.databaseFolder.path):/var/lib/mysql",
            // The OWNER's primary schema — deliberately the constant, not
            // `inst.databaseName`: env schemas are created separately by
            // `createEnvDatabaseArgs` on this same server (issue #17).
            "-e", "MARIADB_DATABASE=\(dbName)",
            "-e", "MARIADB_USER=\(dbUser)",
            "-e", "MARIADB_PASSWORD=\(dbPassword)",
            "-e", "MARIADB_ROOT_PASSWORD=\(dbRootPassword)",
            databaseImage,
            // mariadbd arguments (the image's entrypoint forwards a leading `-…`
            // to the server). This server now hosts a whole FAMILY of envs, each
            // with its own apache prefork pool, so the stock 151 is too tight:
            // ~10 envs × ~10 workers ≈ 100 worst case, plus wp-cli one-shots.
            "--max-connections=\(maxConnections)",
        ]
        return args
    }

    /// `max_connections` for a DB server that may host a parent site plus every
    /// one of its worktree envs (issue #17).
    public static let maxConnections = 300

    // MARK: - Shared env schemas (issue #17, empirically validated)
    //
    // All three run as a ONE-SHOT `mariadb:11` container connecting over the
    // container network to the server's IP as root. No bind mount (so no
    // 999:999 uid workaround), `--rm`, and no resource caps.

    /// Root credentials + host flags shared by the one-shot schema recipes.
    private static func mariadbClientFlags(dbHost: String) -> [String] {
        ["-h", dbHost, "-uroot", "-p\(dbRootPassword)"]
    }

    /// `CREATE DATABASE IF NOT EXISTS <schema>` + grant it to the shared
    /// `wordpress` user (no per-env users: envs of one site are already clones of
    /// each other's data with a coupled lifecycle).
    public static func createEnvDatabaseArgs(dbHost: String, schema: String) -> [String] {
        var args = ["run", "--rm", databaseImage, "mariadb"]
        args += mariadbClientFlags(dbHost: dbHost)
        args += ["-e", """
        CREATE DATABASE IF NOT EXISTS `\(schema)`; \
        GRANT ALL PRIVILEGES ON `\(schema)`.* TO '\(dbUser)'@'%'; \
        FLUSH PRIVILEGES;
        """]
        return args
    }

    /// Server-side logical clone `from` → `to` on the SAME server, staged through
    /// the one-shot container's own ephemeral `/tmp` — nothing is buffered through
    /// a Swift `String` or written into a host mount (a strict improvement on the
    /// old `liveDatabaseTransfer`).
    ///
    /// Deliberately NOT a pipeline: POSIX `sh` reports only the LAST element's
    /// exit status, so `mariadb-dump | mariadb` exits 0 even when the dump aborted
    /// mid-stream (lost connection, `max_allowed_packet`) — silently producing a
    /// truncated clone that looks like a success. `set -e` plus two sequential
    /// redirects makes a dump failure fail the whole command.
    public static func cloneDatabaseArgs(dbHost: String, from: String, to: String) -> [String] {
        let flags = mariadbClientFlags(dbHost: dbHost).joined(separator: " ")
        let dump = "/tmp/wpc-clone.sql"
        return [
            "run", "--rm", "--entrypoint", "/bin/sh", databaseImage, "-c",
            "set -e; mariadb-dump \(flags) --single-transaction --quick \(from) > \(dump); "
                + "mariadb \(flags) \(to) < \(dump)",
        ]
    }

    /// `DROP DATABASE IF EXISTS <schema>`. Callers MUST gate this on
    /// `WorktreeEnv.isManagedSchemaName` — dropping the wrong name would take
    /// out a sibling env or the parent site itself.
    ///
    /// There is deliberately NO "list the `wpc_%` schemas" counterpart: dropping
    /// whatever a listing shows minus whatever the store claims races any
    /// concurrent env creation, whose schema exists before its record does. Only
    /// names we tombstoned ourselves are ever dropped (`Site.pendingSchemaDrops`).
    public static func dropEnvDatabaseArgs(dbHost: String, schema: String) -> [String] {
        var args = ["run", "--rm", databaseImage, "mariadb"]
        args += mariadbClientFlags(dbHost: dbHost)
        args += ["-e", "DROP DATABASE IF EXISTS `\(schema)`;"]
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
        // Publish the host port ONLY for instances that own it (sites). A worktree
        // env deliberately publishes nothing: the reverse proxy binds
        // `127.0.0.1:<env port>` itself and relays to this container's vmnet IP
        // (issue #16 follow-through) — see `RunnableInstance.publishesPort`. The
        // two must never both hold the socket, hence the single switch here.
        if inst.publishesPort {
            args += ["-p", "127.0.0.1:\(inst.port):80"]
        }
        args += [
            "-v", "\(inst.wordpressFolder.path):/var/www/html",
            // PHP overrides (50 MB upload limits, PHPConfService): mod_php
            // reads PHP_INI_SCAN_DIR from the apache process environment, so
            // the mounted ini applies without a derived image or a reload.
            "-v", "\(inst.phpConfFolder.path):\(phpConfContainerPath)",
            "-e", "PHP_INI_SCAN_DIR=\(phpDefaultConfDir):\(phpConfContainerPath)",
        ]
        // Worktree environments add a shadowing mount over the repo path.
        for mount in inst.extraMounts {
            args += ["-v", "\(mount.hostPath):\(mount.containerPath)"]
        }
        args += [
            "-e", "WORDPRESS_DB_HOST=\(dbHost)",
            "-e", "WORDPRESS_DB_USER=\(dbUser)",
            "-e", "WORDPRESS_DB_PASSWORD=\(dbPassword)",
            // Per-instance, NOT the constant: a shared-database env points at
            // its own `wpc_*` schema on the parent's server (issue #17). The
            // image's wp-config template reads DB_NAME from this env var, so
            // nothing on disk needs editing.
            "-e", "WORDPRESS_DB_NAME=\(inst.databaseName)",
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

    /// The sidecar's base URL as WordPress sees it, injected as `EP_HOST`.
    public static func elasticsearchURL(esHost: String) -> String {
        "http://\(esHost):9200"
    }

    /// Probe ES cluster health (green/yellow ⇒ ready) from a one-shot curl.
    public static func elasticsearchHealthURL(esHost: String) -> String {
        "\(elasticsearchURL(esHost: esHost))/_cluster/health"
    }

    // MARK: - Mailpit email catcher (issue #10, validated)
    /// `container run` args for a site's Mailpit container. Runs as root (Apple
    /// `container` default), so the persistent `/data` bind mount on virtiofs
    /// works without a uid override. SMTP stays on the container network (port
    /// 1025, reached by WordPress via the injected IP); only the web UI (8025)
    /// is published to `webPort` on localhost.
    ///
    /// Mailpit's web port stays PUBLISHED even for a worktree env, whose wp
    /// container does not (issue #16 follow-through). Deliberate: mailbox traffic is
    /// a handful of small requests, so the forwarder's lossiness never bites, and
    /// the mailbox is never a WAKE trigger (`HTTPSProxy.resolveDownstream` returns
    /// `.mailboxUnavailable`, never `.waking`) — so a proxy-owned socket would buy
    /// nothing here.
    ///
    /// Note what this does NOT mean: a request to `<slug>-mail.localhost` DOES go
    /// through the proxy and DOES stamp the env's idle clock, because
    /// `route(forHost:)` calls `touchLocked` for every route including mailbox ones.
    /// Only the direct `127.0.0.1:<mailpitPort>` URL bypasses it.
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

    // MARK: - Loopback hosts (in-guest /etc/hosts → host gateway)
    /// `container exec` args that append an /etc/hosts line inside the running
    /// wp container mapping the instance's public hostnames to the host gateway,
    /// so WordPress loopback requests (wp-cron spawn, Site Health checks, REST
    /// self-calls) resolve in-guest and traverse the host proxy exactly like a
    /// browser. Without this the site's own hostname is unresolvable inside the
    /// container and every loopback fails. Containers are ephemeral (`--rm`), so
    /// this runs on every start; the grep guard keeps it idempotent anyway.
    /// Returns nil when there is nothing to map (wildcards can't live in a
    /// hosts file and are dropped).
    public static func injectLoopbackHostsArgs(_ inst: any RunnableInstance,
                                               gateway: String) -> [String]? {
        let hosts = inst.loopbackHosts.filter { !$0.isEmpty && !$0.contains("*") }
        guard !hosts.isEmpty else { return nil }
        let line = "\(gateway) \(hosts.joined(separator: " "))"
        return ["exec", inst.wpContainerName, "sh", "-c",
                "grep -qxF '\(line)' /etc/hosts || echo '\(line)' >> /etc/hosts"]
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
        args += ["-v", "\(inst.wordpressFolder.path):/var/www/html"]
        // A worktree env's checkout shadows the snapshot of the repo inside its
        // `wordpress/` copy, so wp-cli loads the branch's code.
        for mount in inst.extraMounts {
            args += ["-v", "\(mount.hostPath):\(mount.containerPath)"]
        }
        args += [
            "-e", "WORDPRESS_DB_HOST=\(dbHost)",
            "-e", "WORDPRESS_DB_USER=\(dbUser)",
            "-e", "WORDPRESS_DB_PASSWORD=\(dbPassword)",
            // Per-instance (issue #17): every one-shot wp-cli invocation for a
            // shared-database env must target the env's schema, never the
            // parent's `wordpress`.
            "-e", "WORDPRESS_DB_NAME=\(inst.databaseName)",
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

    /// The multisite network upload cap (`fileupload_maxk`, in KB). Defaults to
    /// 1500 KB, which would keep network sites at 1.5 MB no matter what the
    /// PHP limits say — raise it to match the 50 MB PHP limit (PHPConfService).
    public static let multisiteUploadCapKB = 51200

    /// `wp network meta update 1 fileupload_maxk <cap>` — raise the network
    /// upload cap during multisite provisioning (§2j).
    public static func wpNetworkUploadCapArgs(_ inst: any RunnableInstance, dbHost: String) -> [String] {
        wpProxyArgs(inst, dbHost: dbHost,
                    wpArgs: ["network", "meta", "update", "1", "fileupload_maxk", "\(multisiteUploadCapKB)"])
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
                                   mailpitHost: String? = nil,
                                   elasticsearchURL: String? = nil) -> [String] {
        var args = wpCLIBaseArgs(inst, dbHost: dbHost)
        if let mailpitHost { args += ["-e", "WPC_MAILPIT_HOST=\(mailpitHost)"] }
        // ElasticPress commands (`wp elasticpress sync`) need the sidecar's host;
        // the managed handler defines `EP_HOST` from this env var.
        if let elasticsearchURL { args += ["-e", "EP_HOST=\(elasticsearchURL)"] }
        // Mount the managed php/ overrides + scan dir so a one-shot wp-cli picks
        // up the same auto_prepend runtime handlers as the long-lived container
        // (issue #13) — e.g. `wp eval` that sends mail still hits Mailpit, and
        // remote-media URL rewrites apply. Conditional on the folder existing so
        // it stays deterministic before a site's first start (the folder is
        // created then); the login handler is naturally inert in the cli SAPI.
        if FileManager.default.fileExists(atPath: inst.phpConfFolder.path) {
            args += ["-v", "\(inst.phpConfFolder.path):\(phpConfContainerPath)",
                     "-e", "PHP_INI_SCAN_DIR=\(phpDefaultConfDir):\(phpConfContainerPath)"]
        }
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

    /// `wp db export <containerPath> --single-transaction` — export to a FILE
    /// inside the mount rather than stdout, so a large export is never
    /// buffered through a Swift `String` (used by the database importer's
    /// pre-import safety backup and its rollback re-stage, PLAN.md §2m).
    public static func wpDBExportToFileArgs(_ inst: any RunnableInstance, dbHost: String, containerPath: String) -> [String] {
        wpProxyArgs(inst, dbHost: dbHost, wpArgs: ["db", "export", containerPath, "--single-transaction"])
    }

    // MARK: - Database importer (PLAN.md §2m)

    /// `wp db import <containerPath>` — the import step. `containerPath` is the
    /// staged dump's path as seen INSIDE the container (under the site's
    /// `wordpress/` mount, e.g. `/var/www/html/.wpc-import/dump.sql`).
    public static func wpDBImportArgs(_ inst: any RunnableInstance, dbHost: String, containerPath: String) -> [String] {
        wpProxyArgs(inst, dbHost: dbHost, wpArgs: ["db", "import", containerPath])
    }

    /// `wp option get <option>` — used to read the imported dump's `home` URL.
    public static func wpOptionGetArgs(_ inst: any RunnableInstance, dbHost: String, option: String) -> [String] {
        wpProxyArgs(inst, dbHost: dbHost, wpArgs: ["option", "get", option])
    }

    /// `wp search-replace <source> <target> --all-tables --precise` — the URL
    /// migration step.
    ///
    /// - `network`: adds `--network`. Only ever pass true for a multisite
    ///   install; wp-cli errors out on a single site.
    /// - `dryRun`: report the counts without writing anything. The summary line
    ///   changes wording too (`… to be made`), which
    ///   `EnvURLMigration.parseReplacementCount` accounts for.
    public static func wpSearchReplaceArgs(_ inst: any RunnableInstance, dbHost: String, source: String, target: String,
                                           network: Bool = false, dryRun: Bool = false) -> [String] {
        var wpArgs = ["search-replace", source, target, "--all-tables", "--precise"]
        if network { wpArgs.append("--network") }
        if dryRun { wpArgs.append("--dry-run") }
        return wpProxyArgs(inst, dbHost: dbHost, wpArgs: wpArgs)
    }

    /// `wp db query "<sql>"` — arbitrary parameterized-by-string SQL (the scrub
    /// step). `skipColumnNames` drops the header row for scalar `COUNT(*)` reads.
    public static func wpDBQueryArgs(_ inst: any RunnableInstance, dbHost: String, sql: String,
                                     skipColumnNames: Bool = false) -> [String] {
        var wpArgs = ["db", "query", sql]
        if skipColumnNames { wpArgs.append("--skip-column-names") }
        return wpProxyArgs(inst, dbHost: dbHost, wpArgs: wpArgs)
    }

    /// `wp user get <user>` — existence check (non-zero exit ⇒ absent). Use
    /// `ContainerCLI.runCapturing` so a missing user doesn't throw.
    public static func wpUserGetArgs(_ inst: any RunnableInstance, dbHost: String, user: String) -> [String] {
        wpProxyArgs(inst, dbHost: dbHost, wpArgs: ["user", "get", user])
    }

    /// `wp user create <adminUser> <adminEmail> --role=administrator --user_pass=<adminPassword>`
    /// — the importer's "Local admin" step when the login doesn't already exist.
    public static func wpUserCreateAdminArgs(_ inst: any RunnableInstance, dbHost: String) -> [String] {
        wpProxyArgs(inst, dbHost: dbHost, wpArgs: [
            "user", "create", adminUser, adminEmail,
            "--role=administrator", "--user_pass=\(adminPassword)",
        ])
    }

    /// `wp user update <adminUser> --user_pass=<adminPassword>` — reset the
    /// local admin's password when the imported dump's login already exists.
    public static func wpUserUpdateAdminPasswordArgs(_ inst: any RunnableInstance, dbHost: String) -> [String] {
        wpProxyArgs(inst, dbHost: dbHost, wpArgs: ["user", "update", adminUser, "--user_pass=\(adminPassword)"])
    }

    /// `wp user set-role <adminUser> administrator` — ensure the role even if
    /// the imported dump's `admin` login existed with a different role.
    public static func wpUserSetRoleAdminArgs(_ inst: any RunnableInstance, dbHost: String) -> [String] {
        wpProxyArgs(inst, dbHost: dbHost, wpArgs: ["user", "set-role", adminUser, "administrator"])
    }

    /// `wp cache flush`.
    public static func wpCacheFlushArgs(_ inst: any RunnableInstance, dbHost: String) -> [String] {
        wpProxyArgs(inst, dbHost: dbHost, wpArgs: ["cache", "flush"])
    }

    // MARK: - Stop / delete
    public static func stopArgs(_ containerName: String) -> [String] { ["stop", containerName] }
    public static func deleteArgs(_ containerName: String) -> [String] { ["delete", containerName] }
}
