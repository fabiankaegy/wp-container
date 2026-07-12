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
        if let env = inst.envSlug {
            args += ["--label", "\(envLabelKey)=\(env)"]
        }
        return args
    }

    // MARK: - Images
    public static func pullImageArgs(_ image: String) -> [String] {
        ["image", "pull", image]
    }

    // MARK: - Database container
    public static func runDatabaseArgs(_ inst: any RunnableInstance) -> [String] {
        var args = ["run", "-d", "--rm", "--name", inst.dbContainerName]
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
    public static func runWordPressArgs(_ inst: any RunnableInstance, dbHost: String) -> [String] {
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
            inst.imageTag,
        ]
        return args
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
