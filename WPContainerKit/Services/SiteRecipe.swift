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
    /// Redis image for the object-cache sidecar.
    public static let redisImage = "redis:7-alpine"
    /// Redis's in-container port; WordPress connects here via the injected IP.
    public static let redisPort = 6379
    /// Memory cap for the Redis object cache, evicting least-recently-used keys.
    public static let redisMaxMemory = "256mb"

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
    /// MariaDB's port. The DB container publishes no host port; the host
    /// reaches it on the container's own IP.
    public static let dbPort = 3306

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
    // Every `container run` below passes `--progress none`: the captured
    // stderr then holds only the container's own output, so `--json`
    // results, MCP results, and error messages carry no `[n/6]` lines.
    public static func pullImageArgs(_ image: String) -> [String] {
        ["image", "pull", image]
    }

    /// The official image an instance's wp container is built on: its
    /// `imageTag` under Apache, the matching FPM tag under nginx (the base of
    /// the nginx image). nil when an nginx instance's tag has no FPM
    /// counterpart (`WordPressImageCatalog.fpmTag(for:)`).
    public static func baseImageTag(for inst: any RunnableInstance) -> String? {
        switch inst.webServer {
        case .apache: return inst.imageTag
        case .nginx:  return WordPressImageCatalog.fpmTag(for: inst.imageTag)
        }
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
            "run", "--progress", "none", "--rm", "--entrypoint", "/bin/sh",
            "-v", "\(inst.wordpressFolder.path):/var/www/html",
            baseImageTag(for: inst) ?? inst.imageTag,
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
        var args = ["run", "--progress", "none", "-d", "--rm", "--name", inst.dbContainerName, "--user", "999:999"]
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
        var args = ["run", "--progress", "none", "--rm", databaseImage, "mariadb"]
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
            "run", "--progress", "none", "--rm", "--entrypoint", "/bin/sh", databaseImage, "-c",
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
        var args = ["run", "--progress", "none", "--rm", databaseImage, "mariadb"]
        args += mariadbClientFlags(dbHost: dbHost)
        args += ["-e", "DROP DATABASE IF EXISTS `\(schema)`;"]
        return args
    }

    /// `container exec` args that ask the wp container's own web server for `/`
    /// and print the HTTP status (`000` when nothing answered). Needs no network
    /// access from the host.
    public static func wpHTTPProbeArgs(_ inst: any RunnableInstance) -> [String] {
        ["exec", inst.wpContainerName, "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
         "--max-time", "5", "http://127.0.0.1/"]
    }

    /// Whether `wpHTTPProbeArgs` output is a real HTTP status (100–599).
    public static func isHTTPStatus(_ output: String) -> Bool {
        guard let code = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return (100...599).contains(code)
    }

    /// mariadb ships `healthcheck.sh`; exit 0 means the server accepts connections.
    public static func databaseHealthcheckArgs(_ inst: any RunnableInstance) -> [String] {
        ["exec", inst.dbContainerName, "healthcheck.sh", "--connect", "--innodb_initialized"]
    }

    // MARK: - WordPress container
    /// Build the `container run` args for the WP container.
    ///
    /// - `imageOverride`: run a different image than `inst.imageTag` (the nginx
    ///   or Xdebug derived image, §2c).
    /// - `xdebugClientHost`: when non-nil, pass `-e XDEBUG_CLIENT_HOST=<gateway>`
    ///   so Xdebug's `client_host` ini substitution resolves to the host (§2c).
    /// - `sidecarEnvironment`: `KEY=value` assignments for the running sidecars
    ///   (`SidecarAddon.assignments(ip:)`), such as `EP_HOST` and
    ///   `WPC_MAILPIT_HOST`. The IPs are re-inspected each start (container IPs
    ///   churn); env-var indirection keeps the PHP handlers static.
    public static func runWordPressArgs(_ inst: any RunnableInstance, dbHost: String,
                                        imageOverride: String? = nil,
                                        xdebugClientHost: String? = nil,
                                        sidecarEnvironment: [String] = []) -> [String] {
        var args = ["run", "--progress", "none", "-d", "--rm", "--name", inst.wpContainerName]
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
            // PHP overrides (50 MB upload limits, PHPConfService): mod_php and
            // PHP-FPM read PHP_INI_SCAN_DIR from the container environment, so
            // the mounted ini applies without a derived image or a reload.
            "-v", "\(inst.phpConfFolder.path):\(phpConfContainerPath)",
            "-e", "PHP_INI_SCAN_DIR=\(phpDefaultConfDir):\(phpConfContainerPath)",
        ]
        if inst.webServer == .nginx {
            args += ["-v", "\(inst.nginxConfFolder.path):\(NginxImageService.siteConfContainerPath)"]
        }
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
        if inst.webServer == .nginx {
            args += ["-e", "\(NginxImageService.networkTypeEnvName)=\(inst.networkType.rawValue)"]
        }
        if let xdebugClientHost {
            args += ["-e", "XDEBUG_CLIENT_HOST=\(xdebugClientHost)"]
        }
        for assignment in sidecarEnvironment {
            args += ["-e", assignment]
        }
        args.append(imageOverride ?? inst.imageTag)
        return args
    }

    // MARK: - Elasticsearch sidecar (§2c, validated)
    /// `container run` args for a site's Elasticsearch sidecar. No `--user`
    /// override (the image already runs as a non-root user), bind-mounts a data
    /// dir, single-node with security off and a modest heap.
    public static func runElasticsearchArgs(_ inst: any RunnableInstance) -> [String] {
        var args = ["run", "--progress", "none", "-d", "--rm", "--name", inst.esContainerName]
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

    /// The port Elasticsearch listens on inside its container.
    public static let elasticsearchPort = 9200

    /// The sidecar's base URL as WordPress sees it, injected as `EP_HOST`.
    public static func elasticsearchURL(esHost: String) -> String {
        "http://\(esHost):\(elasticsearchPort)"
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
        var args = ["run", "--progress", "none", "-d", "--rm", "--name", inst.mailContainerName]
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

    // MARK: - Redis sidecar
    /// `container run` args for the Redis object-cache container. Ephemeral by
    /// design: no persistence, so a restart (or a fresh env) starts with an
    /// empty cache that can never be stale against an imported or cloned
    /// database. Nothing is published; WordPress reaches it on the container
    /// network.
    public static func runRedisArgs(_ inst: any RunnableInstance) -> [String] {
        var args = ["run", "--progress", "none", "-d", "--rm", "--name", SidecarAddons.redis.containerName(for: inst)]
        args += resourceArgs(for: inst)
        args += labelArgs(for: inst)
        args += [
            redisImage, "redis-server",
            "--save", "", "--appendonly", "no",
            "--maxmemory", redisMaxMemory, "--maxmemory-policy", "allkeys-lru",
        ]
        return args
    }

    /// `container exec` args that empty the instance's Redis object cache.
    public static func redisFlushArgs(_ inst: any RunnableInstance) -> [String] {
        ["exec", SidecarAddons.redis.containerName(for: inst), "redis-cli", "FLUSHALL"]
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
    /// `showProgress` keeps `container run`'s image-pull progress, for a run
    /// attached to a terminal; captured runs turn it off.
    private static func wpCLIBaseArgs(_ inst: any RunnableInstance, dbHost: String,
                                      showProgress: Bool = false) -> [String] {
        var args = showProgress ? ["run", "--rm"] : ["run", "--progress", "none", "--rm"]
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

    /// Mounts the instance's managed `php/` folder and adds it to the ini scan
    /// dir, so a one-shot container gets the same PHP settings (memory and
    /// upload limits) and auto_prepend runtime handlers as the long-lived one
    /// (issue #13): `wp eval` that sends mail still hits Mailpit, and
    /// remote-media URL rewrites apply. Empty before the folder exists, so the
    /// arguments stay deterministic before a site's first start; the login
    /// handler is naturally inert in the cli SAPI.
    private static func phpConfArgs(_ inst: any RunnableInstance) -> [String] {
        guard FileManager.default.fileExists(atPath: inst.phpConfFolder.path) else { return [] }
        return ["-v", "\(inst.phpConfFolder.path):\(phpConfContainerPath)",
                "-e", "PHP_INI_SCAN_DIR=\(phpDefaultConfDir):\(phpConfContainerPath)"]
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
        args += phpConfArgs(inst)
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
        args += phpConfArgs(inst)
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
        args += phpConfArgs(inst)
        args += [cliImage(for: inst), "wp", "site", "list", "--format=json"]
        return args
    }

    /// `wp core update` (+ database) for the "Update WordPress core" action (§2k).
    public static func wpCoreUpdateArgs(_ inst: any RunnableInstance, dbHost: String) -> [String] {
        var args = wpCLIBaseArgs(inst, dbHost: dbHost)
        args += phpConfArgs(inst)
        args += [cliImage(for: inst), "sh", "-c", "wp core update && wp core update-db"]
        return args
    }

    /// `wp core version` for the live WordPress version display (§2k).
    public static func wpCoreVersionArgs(_ inst: any RunnableInstance, dbHost: String) -> [String] {
        var args = wpCLIBaseArgs(inst, dbHost: dbHost)
        args += phpConfArgs(inst)
        args += [cliImage(for: inst), "wp", "core", "version"]
        return args
    }

    /// Set `home`/`siteurl` to an arbitrary URL + flush cache — used when
    /// toggling HTTPS on/off for a site (PLAN.md §2f) and to finish a worktree
    /// env's URL migration (`EnvURLMigrator`).
    public static func wpSetURLsArgs(_ inst: any RunnableInstance, dbHost: String, url: String) -> [String] {
        var args = wpCLIBaseArgs(inst, dbHost: dbHost)
        args += phpConfArgs(inst)
        // sh -c inside the wp-cli container chains the three commands; the host
        // side is still a plain argument array (no host shell interpolation).
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
    /// - `sidecarEnvironment`: `KEY=value` assignments for the running sidecars
    ///   (`SidecarAddons.environment(for:cli:)`), so wp-cli reaches them like the
    ///   long-lived wp container does: `wp eval` that sends mail is caught by
    ///   Mailpit (issue #10), and `wp elasticpress sync` finds Elasticsearch.
    public static func wpProxyArgs(_ inst: any RunnableInstance, dbHost: String, wpArgs: [String],
                                   sidecarEnvironment: [String] = []) -> [String] {
        var args = wpCLIBaseArgs(inst, dbHost: dbHost)
        for assignment in sidecarEnvironment {
            args += ["-e", assignment]
        }
        args += phpConfArgs(inst)
        args += [cliImage(for: inst), "wp"]
        args += wpArgs
        return args
    }

    // MARK: - Arbitrary commands (`wp-container run`)

    /// The WordPress document root inside the wp container.
    public static let wordpressContainerPath = "/var/www/html"

    /// The container path of a host directory that sits inside one of the
    /// instance's bind mounts, or nil. Extra mounts (a worktree checkout) are
    /// checked first because they shadow part of the base `wordpress/` mount.
    public static func containerPath(forHostPath hostPath: URL, in inst: any RunnableInstance) -> String? {
        let target = hostPath.resolvingSymlinksInPath().standardizedFileURL.path
        let base = Mount(hostPath: inst.wordpressFolder.path, containerPath: wordpressContainerPath)
        for mount in inst.extraMounts + [base] {
            let root = URL(fileURLWithPath: mount.hostPath).resolvingSymlinksInPath().standardizedFileURL.path
            if target == root { return mount.containerPath }
            if target.hasPrefix(root + "/") {
                return mount.containerPath + "/" + target.dropFirst(root.count + 1)
            }
        }
        return nil
    }

    /// The working directory for `wp-container run`: `requested` when given
    /// (absolute, or relative to the document root), else the container path
    /// of `hostCWD`, else the document root.
    public static func runWorkdir(requested: String?, hostCWD: URL, in inst: any RunnableInstance) -> String {
        if let requested, !requested.isEmpty {
            if requested.hasPrefix("/") { return requested }
            return wordpressContainerPath + "/" + requested
        }
        return containerPath(forHostPath: hostCWD, in: inst) ?? wordpressContainerPath
    }

    /// `container exec` args that run `command` in the instance's running wp
    /// container, which already carries the database, sidecar, and PHP
    /// override environment.
    public static func execArgs(_ inst: any RunnableInstance, command: [String], workdir: String,
                                env: [String] = [], interactive: Bool = false, tty: Bool = false) -> [String] {
        var args = ["exec"]
        args += processArgs(workdir: workdir, env: env, interactive: interactive, tty: tty)
        args.append(inst.wpContainerName)
        args += command
        return args
    }

    /// One-shot `container run` args that run `command` in `image` with the wp
    /// container's mounts and environment, for tools the WordPress image lacks
    /// (`composer:2`, `node:20`).
    public static func runImageArgs(_ inst: any RunnableInstance, image: String, dbHost: String,
                                    command: [String], workdir: String, env: [String] = [],
                                    interactive: Bool = false, tty: Bool = false,
                                    sidecarEnvironment: [String] = []) -> [String] {
        // The base args already mount a worktree env's checkout over `wordpress/`.
        // In a terminal, keep the pull progress: a first `node:20` pull otherwise
        // looks hung.
        var args = wpCLIBaseArgs(inst, dbHost: dbHost, showProgress: tty)
        args += phpConfArgs(inst)
        for assignment in sidecarEnvironment {
            args += ["-e", assignment]
        }
        // User env comes last so it overrides the defaults above.
        args += processArgs(workdir: workdir, env: env, interactive: interactive, tty: tty)
        args.append(image)
        args += command
        return args
    }

    /// The host directory behind a container path inside one of the instance's
    /// bind mounts, or nil. The inverse of `containerPath(forHostPath:in:)`;
    /// extra mounts win because they shadow part of `wordpress/`.
    public static func hostPath(forContainerPath containerPath: String, in inst: any RunnableInstance) -> URL? {
        let base = Mount(hostPath: inst.wordpressFolder.path, containerPath: wordpressContainerPath)
        for mount in inst.extraMounts + [base] {
            if containerPath == mount.containerPath { return URL(fileURLWithPath: mount.hostPath, isDirectory: true) }
            if containerPath.hasPrefix(mount.containerPath + "/") {
                let rest = String(containerPath.dropFirst(mount.containerPath.count + 1))
                return URL(fileURLWithPath: mount.hostPath, isDirectory: true).appendingPathComponent(rest, isDirectory: true)
            }
        }
        return nil
    }

    // MARK: - PHPUnit (`wp-container test`)

    /// `CREATE DATABASE IF NOT EXISTS <schema>` + grant to the `wordpress` user,
    /// run inside the instance's (running) database container.
    public static func createTestDatabaseArgs(_ inst: any RunnableInstance, schema: String) -> [String] {
        ["exec", inst.dbContainerName, "mariadb", "-uroot", "-p\(dbRootPassword)", "-e", """
        CREATE DATABASE IF NOT EXISTS `\(schema)`; \
        GRANT ALL PRIVILEGES ON `\(schema)`.* TO '\(dbUser)'@'%'; \
        FLUSH PRIVILEGES;
        """]
    }

    /// One-shot `container run` args that run PHPUnit in `workdir` on the
    /// instance's own WordPress image, against the test schema. The managed
    /// `php/` handlers are left out, so tests run on stock PHP; the test
    /// library is mounted at `TestSuite.libraryContainerPath`. `timeLimit`
    /// stops PHPUnit after that many seconds (see `timeLimited`).
    public static func runTestsArgs(_ inst: any RunnableInstance, dbHost: String, library: URL, schema: String,
                                    workdir: String, phpunitArgs: [String], polyfillsPath: String? = nil,
                                    interactive: Bool = false, tty: Bool = false,
                                    sidecarEnvironment: [String] = [], timeLimit: Int? = nil) -> [String] {
        var args = wpCLIBaseArgs(inst, dbHost: dbHost)
        args += [
            "-v", "\(library.path):\(TestSuite.libraryContainerPath)",
            "-e", "WP_TESTS_DIR=\(TestSuite.libraryContainerPath)",
            "-e", "WP_PHPUNIT__TESTS_CONFIG=\(TestSuite.libraryContainerPath)/\(TestSuite.configFileName)",
            "-e", "\(TestSuite.databaseEnvKey)=\(schema)",
            // Later `-e` wins: nothing in the run can reach the site's own schema.
            "-e", "WORDPRESS_DB_NAME=\(schema)",
        ]
        if let polyfillsPath { args += ["-e", "WP_TESTS_PHPUNIT_POLYFILLS_PATH=\(polyfillsPath)"] }
        for assignment in sidecarEnvironment {
            args += ["-e", assignment]
        }
        args += processArgs(workdir: workdir, env: [], interactive: interactive, tty: tty)
        args.append(baseImageTag(for: inst) ?? inst.imageTag)
        let phpunit = ["vendor/bin/phpunit"] + phpunitArgs
        args += timeLimit.map { timeLimited(phpunit, seconds: $0) } ?? phpunit
        return args
    }

    /// Exit status of `timeout` (coreutils and BusyBox) when the limit is hit.
    public static let timeoutExitCode: Int32 = 124

    /// Wraps `command` so the container stops it after `seconds`. The limit
    /// runs inside the container because `container` does not forward signals
    /// from a stopped client to the process. Images without `timeout` run the
    /// command unlimited.
    public static func timeLimited(_ command: [String], seconds: Int) -> [String] {
        let script = #"if command -v timeout >/dev/null 2>&1; then exec timeout "$0" "$@"; fi; exec "$@""#
        return ["sh", "-c", script, "\(seconds)"] + command
    }

    /// Process flags shared by `exec` and `run`: stdin, TTY, workdir, env.
    private static func processArgs(workdir: String, env: [String], interactive: Bool, tty: Bool) -> [String] {
        var args: [String] = []
        if interactive { args.append("-i") }
        if tty { args.append("-t") }
        args += ["-w", workdir]
        for entry in env { args += ["-e", entry] }
        return args
    }

    /// `wp db export` to stdout inside a one-shot wp-cli container (live DB clone).
    public static func wpDBExportArgs(_ inst: any RunnableInstance, dbHost: String) -> [String] {
        var args = wpCLIBaseArgs(inst, dbHost: dbHost)
        args += phpConfArgs(inst)
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
