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
        databaseImport,
        wpCLI,
    ]

    // MARK: - 1. Welcome / Getting Started

    static let gettingStarted = HelpTopic(
        id: "getting-started",
        icon: "sparkles",
        title: "Welcome to WP Container",
        summary: "What it is and the 3-step path",
        intro: "WP Container runs local WordPress sites on Apple's built-in `container` runtime — no Docker Desktop required. Each site is a real, isolated WordPress install you can open in your browser in seconds.",
        sections: [
            HelpSection(
                title: "Get going in three steps",
                steps: [
                    "Create a site — click New Site (⌘N) and give it a name.",
                    "Start it — press Start (⌘R). The first start provisions WordPress; later starts are quick.",
                    "Open it — use Open in Browser (⌘O) to view the site, or Open WP Admin to sign in to the dashboard.",
                ]
            ),
            HelpSection(
                title: "The menu-bar icon",
                body: "WP Container lives in your menu bar. Click it to start or stop any site without opening the main window.",
                bullets: [
                    "Closing the window keeps the app running in the menu bar, so your sites stay up.",
                    "Fully quitting the app now stops all running sites, so nothing is left running in the background.",
                ]
            ),
            HelpSection(
                title: "Where to next",
                body: "Browse the topics on the left to learn about branch environments, HTTPS and custom domains, Xdebug, Elasticsearch, Mailpit, database import, and WP-CLI.",
                tip: "Everything here is local and private — sites run entirely on your Mac."
            ),
        ]
    )

    // MARK: - 2. Sites

    static let sites = HelpTopic(
        id: "sites",
        icon: "globe",
        title: "Sites",
        summary: "Isolated WordPress installs",
        intro: "A site is a self-contained WordPress install with its own database and its own localhost port. Create as many as you like — they never interfere with each other.",
        sections: [
            HelpSection(
                title: "Creating a site",
                body: "Choose New Site (⌘N), name it, and create. The first time you start it, WP Container provisions a fresh WordPress for you.",
                tip: "Each site gets its own database and its own localhost port automatically."
            ),
            HelpSection(
                title: "Everyday actions",
                bullets: [
                    "Start (⌘R) and Stop (⌘.) the site's containers.",
                    "Open in Browser (⌘O) to view the front end.",
                    "Open WP Admin to jump straight to /wp-admin.",
                    "Reveal in Finder to open the site's files on disk.",
                ]
            ),
        ]
    )

    // MARK: - 3. Branch Environments

    static let branchEnvironments = HelpTopic(
        id: "branch-environments",
        icon: "arrow.triangle.branch",
        title: "Branch Environments",
        summary: "Isolated copies on a git branch",
        intro: "A branch environment is an isolated copy of a site running on a git branch, on its own port. Spin one up to reproduce or verify a fix without touching your main site.",
        sections: [
            HelpSection(
                title: "Creating an environment",
                body: "Choose New Branch Environment (⇧⌘N), pick a repo found under the site, and name a branch. WP Container clones the site's files and database from the parent onto that branch.",
            ),
            HelpSection(
                title: "Auto-provisioning",
                body: "The worktree checkout is seeded with the parent's gitignored runtime dependencies — Composer `vendor/`, built assets like `dist/`, and provisioned `mu-plugins`/`plugins` — so the environment boots into a working site.",
                bullets: [
                    "No manual `composer install` or `npm run build` needed to get running.",
                    "Branch-tracked files are never overwritten — only gitignored runtime deps are seeded.",
                    "Prefer a bare checkout? Turn off Seed runtime dependencies when creating.",
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
        intro: "WP Container includes a built-in reverse proxy on port 443 that serves your sites over trusted local SSL, so you can develop against HTTPS just like production.",
        sections: [
            HelpSection(
                title: "Custom domains",
                body: "Give a site a custom domain to reach it at a friendly, memorable address over HTTPS instead of a localhost port.",
            ),
            HelpSection(
                title: "Choosing a TLD",
                body: "Use the `.test` TLD for local domains — for example `myproject.test`.",
                tip: "Avoid `.local`: some networks claim it for service discovery, which can break resolution."
            ),
        ]
    )

    // MARK: - 5. Xdebug

    static let xdebug = HelpTopic(
        id: "xdebug",
        icon: "ant",
        title: "Xdebug",
        summary: "Step-debugging for your IDE",
        intro: "Toggle Xdebug per site to enable PHP step-debugging. It's configured to reach your host, so your editor can catch breakpoints as requests run.",
        sections: [
            HelpSection(
                title: "How it works",
                body: "When enabled, Xdebug points back at your Mac so your IDE can connect and pause on breakpoints.",
                bullets: [
                    "Works with VS Code and PhpStorm.",
                    "Toggle it on only while debugging — it adds overhead to every request.",
                ]
            ),
        ]
    )

    // MARK: - 6. Elasticsearch

    static let elasticsearch = HelpTopic(
        id: "elasticsearch",
        icon: "magnifyingglass",
        title: "Elasticsearch",
        summary: "Optional search sidecar",
        intro: "Add an optional Elasticsearch sidecar to a site to power search with ElasticPress — great for testing search features that rely on it.",
        sections: [
            HelpSection(
                title: "When to enable it",
                body: "Turn on Elasticsearch per site when you're working with ElasticPress-powered search and want it running alongside WordPress.",
                tip: "It's optional and per-site — leave it off for sites that don't need it."
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
                title: "Reviewing captured mail",
                body: "All outgoing email is intercepted and collected. Open Mailpit's web UI to browse the captured messages, including HTML previews.",
                tip: "No email leaves your Mac — you can test freely without spamming anyone."
            ),
        ]
    )

    // MARK: - 8. Database Import

    static let databaseImport = HelpTopic(
        id: "database-import",
        icon: "square.and.arrow.down",
        title: "Database Import",
        summary: "Import a .sql / .sql.gz dump",
        intro: "Import a database dump (`.sql` or `.sql.gz`) into a site. WP Container handles the tricky parts of moving a production database to your local setup.",
        sections: [
            HelpSection(
                title: "What the importer handles",
                bullets: [
                    "Automatic URL migration so links point at your local domain.",
                    "Optional scrub of personal data during import.",
                    "Media handling so your imported content resolves correctly.",
                ]
            ),
            HelpSection(
                title: "Safety",
                body: "Before importing, a backup of the current database is taken. If the import fails, WP Container automatically rolls back to that backup.",
                tip: "A failed import leaves your existing database untouched."
            ),
        ]
    )

    // MARK: - 9. WP-CLI & the global wp router

    static let wpCLI = HelpTopic(
        id: "wp-cli",
        icon: "terminal",
        title: "WP-CLI & the global wp",
        summary: "First-class command line access",
        intro: "WP Container has first-class WP-CLI support, so you can run WordPress commands against any site from the command line.",
        sections: [
            HelpSection(
                title: "The global `wp` router",
                body: "Enable the global `wp` router to run plain `wp …` commands in any site's directory in Terminal — the router figures out which site you're in and runs the command against it.",
                steps: [
                    "Enable the global `wp` router from Settings.",
                    "In Terminal, `cd` into a site's directory.",
                    "Run any command, e.g. `wp plugin list` or `wp user list`.",
                ]
            ),
        ]
    )
}
