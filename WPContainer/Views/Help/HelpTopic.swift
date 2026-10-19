import Foundation

/// A single entry in the in-app Help browser: an SF Symbol icon, a title, a
/// one-line summary shown in the sidebar list, a short intro paragraph, and a
/// few skimmable sub-sections. Content is entirely static so `HelpView` needs
/// no environment objects and can be hosted in its own `Window` scene.
struct HelpTopic: Identifiable {
    let id: String
    let icon: String
    let title: String
    /// Short subtitle shown under the title in the sidebar list.
    let summary: String
    /// One or two sentences that open the detail pane.
    let intro: String
    let sections: [HelpSection]
}

/// A sub-section of a topic. Any of the content slots may be empty; the detail
/// view renders only the ones that are populated, in order.
struct HelpSection: Identifiable {
    let id = UUID()
    let title: String
    /// Optional prose paragraph shown under the section title.
    var body: String? = nil
    /// Numbered steps (rendered 1, 2, 3…).
    var steps: [String] = []
    /// Unordered bullet points.
    var bullets: [String] = []
    /// A highlighted "tip" callout at the end of the section.
    var tip: String? = nil
}

extension HelpTopic {
    /// The full, ordered set of help topics. The first entry is selected by
    /// default in `HelpView`.
    static let all: [HelpTopic] = [
        gettingStarted,
        sites,
        branchEnvironments,
        httpsAndDomains,
        xdebug,
        elasticsearch,
        mailpit,
        redis,
        databaseImport,
        wpCLI,
    ]

    // MARK: - 1. Welcome / Getting Started

    static let gettingStarted = HelpTopic(
        id: "getting-started",
        icon: "sparkles",
        title: "Welcome to WP Container",
        summary: "What it is and the 3-step path",
        intro: "WP Container runs local WordPress sites on Apple's built-in `container` runtime — no Docker Desktop required. Each site is a real, isolated WordPress install (Apache + PHP + MariaDB) you can open in your browser in seconds.",
        sections: [
            HelpSection(
                title: "Get going in three steps",
                steps: [
                    "Create a site — click New Site (⌘N), give it a name, and pick a WordPress × PHP version.",
                    "Start it — press Start (⌘R). The first start pulls the images and provisions WordPress; later starts take a second or two.",
                    "Open it — use Open in Browser (⌘O) to view the site, or Open WP Admin to sign in to `/wp-admin` (default login `admin` / `password`).",
                ]
            ),
            HelpSection(
                title: "What you get out of the box",
                bullets: [
                    "Each site runs in its own containers on its own `127.0.0.1` port, with a separate MariaDB database.",
                    "Media uploads are raised from PHP's stock 2 MB to **50 MB** automatically.",
                    "No Docker Desktop — WP Container uses Apple's native `container` runtime, so it's light on CPU and battery.",
                    "First-class WP-CLI, trusted HTTPS, Xdebug, Elasticsearch, Mailpit, Redis, and one-command database import.",
                ]
            ),
            HelpSection(
                title: "The menu-bar icon",
                body: "WP Container lives in your menu bar. Click it to start or stop any site without opening the main window.",
                bullets: [
                    "Closing the window keeps the app running in the menu bar, so your sites stay up.",
                    "Fully quitting the app (⌘Q) stops all running sites, so nothing is left running in the background.",
                ]
            ),
            HelpSection(
                title: "Where to next",
                body: "Browse the topics on the left to learn about branch environments, HTTPS and custom domains, Xdebug, Elasticsearch, Mailpit, Redis, database import, and WP-CLI.",
                tip: "Everything here is local and private — sites run entirely on your Mac, and you can select and copy any text in this window."
            ),
        ]
    )

    // MARK: - 2. Sites

    static let sites = HelpTopic(
        id: "sites",
        icon: "globe",
        title: "Sites",
        summary: "Isolated WordPress installs",
        intro: "A site is a self-contained WordPress install — its own Apache + PHP container, its own MariaDB database, and its own `127.0.0.1` port. Create as many as you like; they never interfere with each other.",
        sections: [
            HelpSection(
                title: "Creating a site",
                body: "Choose New Site (⌘N), name it, and pick the WordPress and PHP versions. The first time you start it, WP Container provisions a fresh WordPress and a MariaDB database for you.",
                bullets: [
                    "Files live on disk in the site folder — `wordpress/` holds the install, `database/` holds MariaDB's data.",
                    "The admin user defaults to `admin` / `password` — fine for local, never for production.",
                ]
            ),
            HelpSection(
                title: "New-site defaults",
                body: "The Add Site sheet is pre-filled from your defaults in Settings → Sites, so every new site starts the way you like it.",
                bullets: [
                    "Enable HTTPS at `https://<slug>.localhost` through the trusted local proxy.",
                    "`WP_DEBUG` and `SCRIPT_DEBUG` for full error reporting and unminified core assets.",
                    "Install the global `wp` router so plain `wp` works in any site folder.",
                ],
                tip: "Change any of these per-site in the Add Site sheet, or change the defaults in Settings → Sites."
            ),
            HelpSection(
                title: "Everyday actions",
                bullets: [
                    "Start (⌘R) and Stop (⌘.) the site's containers.",
                    "Open in Browser (⌘O) to view the front end.",
                    "Open WP Admin to jump straight to `/wp-admin`.",
                    "Reveal in Finder to open the site's files on disk.",
                ]
            ),
            HelpSection(
                title: "PHP settings",
                body: "Every site mounts a `php/` folder scanned via `PHP_INI_SCAN_DIR`. WP Container manages `php/wpc-defaults.ini` there (the 50 MB upload limits — `upload_max_filesize = 50M`, `post_max_size = 64M`).",
                tip: "Need custom PHP settings? Delete the marker line at the top of `wpc-defaults.ini` to take ownership, or drop your own `.ini` file into `php/` — both are loaded on the next start."
            ),
        ]
    )

    // MARK: - 3. Branch Environments

    static let branchEnvironments = HelpTopic(
        id: "branch-environments",
        icon: "arrow.triangle.branch",
        title: "Branch Environments",
        summary: "Isolated copies on a git branch",
        intro: "A branch environment is an isolated copy of a site running on a git branch, on its own port. Spin one up to reproduce or verify a fix without touching your main site — then throw it away.",
        sections: [
            HelpSection(
                title: "Creating an environment",
                body: "Choose New Branch Environment (⇧⌘N), pick a git repo found under the site's `wp-content`, and name a branch (new or existing).",
                bullets: [
                    "Files are cloned instantly with an APFS copy-on-write clone — no waiting, no wasted disk.",
                    "The database is cloned from the parent too: a live copy if the parent is running, or a fast on-disk clone if it's stopped.",
                    "The env gets its own port and its own containers; URLs are rewritten to the new port automatically.",
                ]
            ),
            HelpSection(
                title: "Auto-provisioning",
                body: "The branch checkout is seeded with the parent's gitignored runtime dependencies — Composer `vendor/`, built assets like `dist/`, and provisioned `mu-plugins`/`plugins` — so the environment boots into a working site instead of 500-ing on missing autoloaders.",
                bullets: [
                    "No manual `composer install` or `npm run build` needed to get running.",
                    "Branch-tracked files are never overwritten — only gitignored runtime deps are copied in.",
                    "Prefer a bare checkout? Turn off Seed runtime dependencies when creating (or pass `--no-provision` on the CLI).",
                ]
            ),
            HelpSection(
                title: "Cleaning up",
                body: "Delete an environment when you're done. Its containers and cloned files are removed — but the git branch is always kept.",
                tip: "Deleting an environment never deletes your branch or your work."
            ),
        ]
    )

    // MARK: - 4. HTTPS & Custom Domains

    static let httpsAndDomains = HelpTopic(
        id: "https-domains",
        icon: "lock.shield",
        title: "HTTPS & Custom Domains",
        summary: "Trusted local SSL and a domain",
        intro: "WP Container runs a built-in reverse proxy on port 443 (falling back to 8443) that terminates TLS with a locally-trusted certificate, so you can develop against HTTPS exactly like production.",
        sections: [
            HelpSection(
                title: "Trusted local SSL",
                body: "The app runs its own certificate authority and issues a wildcard cert for your sites. Once the CA is trusted, HTTPS sites load with a green padlock — no browser warnings.",
                bullets: [
                    "Enable HTTPS per site to serve it at `https://<slug>.localhost`.",
                    "The proxy listens on 443, or 8443 if another app already holds 443.",
                ]
            ),
            HelpSection(
                title: "Custom domains",
                body: "Give a site a custom domain to reach it at a friendly address over HTTPS instead of a localhost port. WP Container adds the mapping to `/etc/hosts` for you (with one admin prompt).",
            ),
            HelpSection(
                title: "Choosing a TLD",
                body: "Use the `.test` TLD for local domains — for example `myproject.test`.",
                tip: "Avoid `.local`: macOS and many networks claim it for Bonjour/mDNS service discovery, which breaks resolution in Safari."
            ),
        ]
    )

    // MARK: - 5. Xdebug

    static let xdebug = HelpTopic(
        id: "xdebug",
        icon: "ant",
        title: "Xdebug",
        summary: "Step-debugging for your IDE",
        intro: "Toggle Xdebug per site to enable PHP step-debugging. WP Container builds a derived image with Xdebug and points it back at your Mac, so your editor can catch breakpoints as requests run.",
        sections: [
            HelpSection(
                title: "How it works",
                body: "When enabled, Xdebug runs in `debug` mode and connects to your host on the standard port **9003**. Your IDE listens on that port and pauses on breakpoints.",
                bullets: [
                    "Client port: `9003` (Xdebug 3 default). Client host: your Mac, injected as the container's gateway IP.",
                    "Works with VS Code (PHP Debug extension) and PhpStorm — just start listening for debug connections.",
                    "Map the server path `/var/www/html` to your local site's `wordpress/` folder in your IDE.",
                ],
                tip: "Toggle Xdebug on only while debugging — it adds overhead to every request. Turning it on or off restarts the site to apply."
            ),
        ]
    )

    // MARK: - 6. Elasticsearch

    static let elasticsearch = HelpTopic(
        id: "elasticsearch",
        icon: "magnifyingglass",
        title: "Elasticsearch",
        summary: "Optional search sidecar",
        intro: "Add an optional Elasticsearch sidecar to a site to power search with ElasticPress — ideal for testing search features that depend on it.",
        sections: [
            HelpSection(
                title: "How it runs",
                body: "Enabling Elasticsearch starts a per-site sidecar container alongside WordPress and wires it in automatically.",
                bullets: [
                    "Single-node cluster, security disabled, with a modest 512 MB heap — tuned for local dev.",
                    "Listens on port **9200** on the container network; the `EP_HOST` constant ElasticPress reads is defined automatically to point at it.",
                    "Health is reported from `http://<es-host>:9200/_cluster/health` (green or yellow means ready).",
                ]
            ),
            HelpSection(
                title: "Using it with ElasticPress",
                body: "Install and activate ElasticPress in the site, then run a sync so it indexes your content into the sidecar.",
                tip: "It's optional and per-site — leave it off for sites that don't need search, and enabling/disabling it restarts the site."
            ),
        ]
    )

    // MARK: - 7. Mailpit

    static let mailpit = HelpTopic(
        id: "mailpit",
        icon: "envelope",
        title: "Mailpit",
        summary: "Catch outgoing email safely",
        intro: "Mailpit captures every email your site tries to send, so nothing is ever delivered to a real inbox. Perfect for testing password resets, order receipts, and notifications.",
        sections: [
            HelpSection(
                title: "How it works",
                body: "Enabling Mailpit installs a small `wpc-mailpit` mu-plugin and starts a Mailpit container. All outgoing WordPress mail is routed to Mailpit over SMTP instead of being sent.",
                bullets: [
                    "SMTP is captured on port **1025** on the container network — mail never leaves your Mac.",
                    "The web UI runs on Mailpit's port **8025**, published to a `127.0.0.1` port that WP Container assigns.",
                ]
            ),
            HelpSection(
                title: "Reviewing captured mail",
                body: "Open Mailpit's web UI (the mailbox URL shown for the site) to browse captured messages with full HTML previews. You can also read it programmatically.",
                bullets: [
                    "Web UI: browse, search, and preview every captured message.",
                    "REST API: `GET <mailboxUrl>/api/v1/messages` returns the captured mail as JSON.",
                ],
                tip: "No email leaves your Mac — test password resets and receipts freely without spamming anyone."
            ),
        ]
    )

    // MARK: - Redis

    static let redis = HelpTopic(
        id: "redis",
        icon: "memorychip",
        title: "Redis",
        summary: "Persistent object cache",
        intro: "Redis gives a site a persistent object cache, so you can develop against the same caching layer production uses.",
        sections: [
            HelpSection(
                title: "How it works",
                body: "Enabling Redis starts a Redis container and defines `WP_REDIS_HOST` and `WP_REDIS_PORT` for the site. An object-cache drop-in reads them; WP Container doesn't install one.",
                bullets: [
                    "Install and activate a drop-in plugin such as **Redis Object Cache**, then run `wp redis enable`.",
                    "Constants you define in `wp-config.php` take precedence.",
                    "The cache is empty after every restart, so it never holds data from before an import or a clone.",
                ],
                tip: "Toggling Redis restarts a running site."
            ),
        ]
    )

    // MARK: - 8. Database Import

    static let databaseImport = HelpTopic(
        id: "database-import",
        icon: "square.and.arrow.down",
        title: "Database Import",
        summary: "Import a .sql / .sql.gz dump",
        intro: "Import a database dump (`.sql` or `.sql.gz`) into a site — drag it onto the site or use the importer. WP Container handles the tricky parts of moving a production database to your local setup, and auto-starts the site if it isn't running.",
        sections: [
            HelpSection(
                title: "What the importer handles",
                bullets: [
                    "URL migration: the source URL is detected from the dump's `home` option (or you supply it) and rewritten to your local domain.",
                    "Optional scrub of personal data — users, comments, and the admin email — so you're not sitting on real customer data.",
                    "Media handling: proxy remote media with a mu-plugin, copy a media folder, or skip it.",
                    "Optional local admin login so you can sign in right after import.",
                ]
            ),
            HelpSection(
                title: "Safety & rollback",
                body: "Before importing, WP Container takes a backup of the current database. If the import fails, it automatically re-imports that backup — so a failed import leaves your existing database untouched.",
                tip: "The pre-import backup means an import is always one step from undone."
            ),
            HelpSection(
                title: "Importing into a branch environment",
                body: "A branch environment starts with a copy of its site's database. To test a branch against different data, import a dump into the environment itself: `wp-container db import <env-slug> dump.sql`.",
                bullets: [
                    "Only the environment's own database is replaced; the site and other environments are untouched.",
                    "URLs are migrated to the environment's URL.",
                    "A dump that switches databases (`USE`, `CREATE DATABASE`, as `mysqldump --databases` writes) is refused for an environment that shares its site's database server. Export with `wp db export` instead.",
                ]
            ),
        ]
    )

    // MARK: - 9. WP-CLI & the global wp router

    static let wpCLI = HelpTopic(
        id: "wp-cli",
        icon: "terminal",
        title: "WP-CLI & the global wp",
        summary: "First-class command line access",
        intro: "WP Container has first-class WP-CLI support: every command runs inside the site's container against its real database, so `wp` behaves exactly like it would on a server.",
        sections: [
            HelpSection(
                title: "The global `wp` router",
                body: "Enable the global `wp` router to run plain `wp …` in any site's directory in Terminal — it detects which site you're in and runs the command in that container.",
                steps: [
                    "Enable the global `wp` router (Settings → Sites, a site's Integrations, or run `wp-container setup wp`).",
                    "Open a new Terminal, then `cd` into a site's directory.",
                    "Run any command, e.g. `wp plugin list`, `wp user list`, or `wp search-replace`.",
                ],
                tip: "The router adds a small PATH block to `~/.zshrc`; remove it anytime from a site's Integrations settings."
            ),
            HelpSection(
                title: "The wp-container CLI",
                body: "Beyond `wp`, the `wp-container` binary (aliased `wpc`) scripts the app itself — create and start sites, manage branch environments, import databases, and more. It also exposes an MCP server so AI agents can drive it.",
                bullets: [
                    "`wp-container list` — show every site and branch environment with status, URL, and port.",
                    "`wp-container worktree create` — create a branch environment (auto-provisioned by default).",
                    "`wp-container run <site> -- <command>` — run any command in the site's container (`php`, `vendor/bin/phpunit`); add `--image composer:2` for tools the WordPress image lacks.",
                ]
            ),
        ]
    )
}
