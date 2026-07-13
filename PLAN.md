# WP Container — Local WordPress Development powered by Apple Containers

A native macOS SwiftUI app for creating, maintaining, and updating local WordPress
sites, where each site runs in Apple `container` (https://apple.github.io/container/)
containers and exposes its full WordPress installation as a local folder so
developers can drop their git-managed `wp-content` projects straight in.

Visual/UX reference: WordPress Studio (https://developer.wordpress.com/docs/developer-tools/studio/) —
sidebar of sites with colored avatars, per-site detail pane with status pill,
one-click Start/Stop, "Open site" / "WP Admin" buttons, and quick access to the
site folder.

---

## 1. Environment facts (verified on this machine)

- macOS 27.0, Apple Silicon (arm64)
- `container` CLI **1.1.0** at `/usr/local/bin/container`, system service **running**
  (`container system status` → running; appRoot: `~/Library/Application Support/com.apple.container/`)
- Xcode 26.6, Swift 6.3.3
- XcodeGen available at `/opt/homebrew/bin/xcodegen`
- Relevant verified CLI capabilities:
  - `container run -d --rm --name <n> -v host:ctr -p [ip:]host:ctr -e K=V --network <net> <image> …`
  - `container list --all --format json` (also yaml/table), `container inspect <n>` (JSON)
  - `container logs [--follow] <n>`, `container exec <n> …`, `container stop/start/kill/delete`
  - `container network create/ls/delete`, `container image pull/ls --format json`
  - `container system start/stop/status`

## 2. Product decisions

- **App name:** WP Container. Repo/folder name: `wp-container`. Bundle id `com.fabiankaegy.wpcontainer`. Deployment target **macOS 27 only** — free to use the newest SwiftUI/Liquid Glass APIs, no availability checks for anything ≤ 27.
- **App Sandbox OFF** (the app shells out to `/usr/local/bin/container` and manages
  arbitrary site folders). Ad-hoc code signing (`CODE_SIGN_IDENTITY=-`) for local use.
- **Per-site layout on disk** (default root `~/WP Container Sites/<slug>/`, user-overridable
  at creation time):
  - `wordpress/` → bind-mounted to `/var/www/html` in the WP container. The official
    `wordpress` image auto-populates WP core into an empty mounted dir on first run,
    so the full installation (incl. `wp-content/`) is host-visible and git-friendly.
  - `database/` → bind-mounted to `/var/lib/mysql` in the MariaDB container.
- **Containers are ephemeral, state lives on the host.** Start = `container run -d --rm`,
  Stop = `container stop`. This sidesteps container-IP churn across restarts and makes
  the host folder the single source of truth.
  - DB container: `wpc-<slug>-db`, image `mariadb:11` (env: MARIADB_DATABASE=wordpress,
    MARIADB_USER=wordpress, MARIADB_PASSWORD=wordpress, MARIADB_ROOT_PASSWORD=root).
  - WP container: `wpc-<slug>-wp`, image `wordpress:latest` (or a pinned
    PHP-version variant chosen in the Add Site sheet, e.g. `wordpress:php8.3-apache`),
    `-p 127.0.0.1:<port>:80`, env WORDPRESS_DB_HOST/USER/PASSWORD/NAME.
  - **DB host resolution:** start DB first, `container inspect` it, read its IP, pass as
    `WORDPRESS_DB_HOST`. (Fallback if a per-site `container network create wpc-<slug>`
    plus container-name DNS proves reliable — the validation agent will confirm which
    to use; IP-from-inspect is the guaranteed path.)
  - **Readiness:** poll the DB port / `container exec <db> healthcheck.sh --connect`
    (mariadb image ships it) before starting WP; poll `http://127.0.0.1:<port>` for WP.
- **Auto-provisioning (Studio-like, no install wizard):** after first start, run
  `wp core install` via a one-shot `wordpress:cli` container sharing the same
  `wordpress/` mount + DB env — site title = site name, admin user `admin`,
  password `password`, email `admin@localhost.local`. Store provisioned flag.
- **Port allocation:** first free localhost port starting at **8881**, persisted per site.
- **Persistence:** `~/Library/Application Support/WPContainer/sites.json` (Codable store).
  Reconciled at launch and on a timer/poll against `container list --all --format json`
  (label `dev.wpcontainer.site=<slug>` stamped on every container we create).
- **WP-CLI support:** "Open in Terminal" and a lightweight one-shot exec runner
  (`wordpress:cli` container) power maintenance actions (update core/plugins later).

## 2b. Git worktree environments (first-class feature)

Target user: AI coding agents (and humans) developing a git-managed repo that lives
inside a site's `wp-content` (plugin or theme). They must be able to spin up an
isolated, verifiable environment for any branch in seconds, without touching the
primary site.

**Concept.** A `WorktreeEnv` is a disposable clone of a parent site bound to a git
worktree of one repo inside it:
- `id, parentSiteID, envSlug` (`<site-slug>-wt-<branch-slug>`), `repoRelPath`
  (e.g. `wp-content/plugins/my-plugin`), `branch`, `worktreePath`, `port`, `createdAt`.
- On disk: `~/WP Container Sites/<site>/.envs/<branch-slug>/{wordpress,database}` plus
  `~/WP Container Sites/<site>/.worktrees/<branch-slug>/` for the git worktree itself.
  `.envs`/`.worktrees` are hidden from the primary install (never inside `wordpress/`).

**Creation flow (speed is the point — APFS makes cloning ~instant):**
1. `git -C <repo> worktree add [-b] <worktreePath> <branch>` (create branch if new).
2. Clone site files: `cp -Rc wordpress/ .envs/<b>/wordpress/` (APFS copy-on-write).
3. Clone database:
   - Fast path (parent stopped): `cp -Rc database/ .envs/<b>/database/`.
   - Live path (parent running): one-shot `wordpress:cli` → `wp db export`, import
     into the env's fresh MariaDB. (Default to whichever the parent's state allows.)
4. Start env containers (same recipe as a site, names `wpc-<envSlug>-{wp,db}`,
   labels `dev.wpcontainer.site=<site-slug>` + `dev.wpcontainer.env=<envSlug>`), with ONE
   extra mount that shadows the repo path:
   `-v <worktreePath>:/var/www/html/<repoRelPath>` — the worktree checkout replaces
   the primary checkout inside the env container only. (Nested-mount shadowing is
   verified in Phase V.)
5. Fix URLs for the new port: one-shot wp-cli `wp option update home/siteurl` (+
   `wp cache flush`). Admin creds are inherited from the parent (cloned DB).
6. Emit a machine-readable descriptor: `{url, port, path, worktreePath, branch, containers}`.

**Deletion:** stop containers → `git worktree remove` (or leave with `--keep-worktree`)
→ delete `.envs/<b>` → update store.

**Automation API — the `wp-container` CLI.** Agents need a scriptable surface, so the
core moves into a shared framework and a CLI executable (binary `wp-container`, convenience symlink `wpc`) ships alongside the app:
- Targets: `WPContainerKit` (all models + services), `WPContainer.app` (SwiftUI), `wp-container`
  (ArgumentParser CLI, installable via `make install-cli` → /usr/local/bin/wp-container, plus `wpc` symlink).
- Commands (all support `--json` for agent consumption):
  - `wp-container list` — sites + envs with status/url/port
  - `wp-container start|stop|delete <site|env>`
  - `wp-container create <name> [--path …] [--php …]`
  - `wp-container worktree create --site <slug> --repo <rel-path> --branch <name> [--from <ref>]`
    → prints the descriptor JSON (url/port/paths) on success
  - `wp-container worktree list|delete [--keep-branch] [--keep-worktree]`
  - `wp-container wp <site|env> -- <wp-cli args>` — proxied one-shot wp-cli
- Store coordination: app and CLI share `sites.json`; writes go through an
  `NSFileCoordinator`-style lock (or lockfile + atomic replace), and the app watches
  the file (DispatchSource) to live-reload CLI-made changes; container labels remain
  the reconciliation ground truth.

**UI (nested design):** worktree envs are shown differently from sites and are
first-class in the sidebar:
- Env rows render INDENTED under their parent site row in a collapsible
  disclosure (chevron on the parent row, default expanded, collapse state
  persisted per site). Env rows are visually distinct: smaller height, a
  branch glyph (`arrow.triangle.branch`) instead of an avatar, branch name as
  title, port subtitle, and the same interactive status dot as sites.
- A site with ≥1 env gets a "layer" badge (`square.3.layers.3d`) overlaid on
  its avatar corner (favicon/initials avatar stays underneath).
- Env rows are selectable and show a compact detail pane (header +
  Open/WP Admin/Copy URL/Finder, overview, live logs, delete with keep-branch
  semantics + keep-worktree checkbox), plus a context menu (Open, WP Admin,
  Copy URL, Start/Stop, Reveal in Finder, Delete Environment…).
- **Coupled lifecycle:** starting a site also starts all its worktree envs and
  stopping it stops them (kit-level `startSiteWithEnvs`/`stopSiteWithEnvs`, so
  app, CLI `wp-container start|stop <site>` and MCP behave identically; the
  parent is sequenced first and per-env failures surface individually without
  aborting the rest). Envs remain individually start/stoppable.
- The menu bar extra nests running envs under their parent site row (small
  indent + branch glyph).
- Each site's detail view keeps its "Branches" card, plus the "New branch
  environment…" sheet (repo picker auto-detected from git repos found under
  `wp-content`, branch field with existing-branch autocomplete).

## 2c. Per-site add-ons: Xdebug & Elasticsearch (one-click toggles)

Each site gets two independent toggles, persisted on `Site` and applied on (re)start;
toggling while running offers "Restart now".

**Xdebug**
- The official wordpress image has no Xdebug → we build a derived image once per
  base tag with `container build`: `wpc-wordpress-xdebug:<tag>` from a generated
  Dockerfile (`FROM wordpress:<tag>` + `pecl install xdebug` + docker-php-ext-enable
  + xdebug.ini: mode=debug,develop; start_with_request=yes; client_port=9003;
  client_host=<host gateway IP as seen from the container — validated empirically>).
  Built lazily on first enable (with progress UI), cached in the image store.
- Enabled site starts its WP container from the xdebug image (+`-e XDEBUG_MODE`).
  Disabled = plain image; no other change. UI shows IDE hint (path mapping:
  `<site>/wordpress` ↔ `/var/www/html`, port 9003).

**Elasticsearch**
- Toggle starts a third per-site container `wpc-<slug>-es` (image `elasticsearch:8.x`,
  single-node, security off, modest heap; exact image/flags + virtiofs/uid handling
  validated empirically — data in `<site>/elasticsearch/` bind mount if the image
  tolerates it, else a named managed volume as fallback).
- Site start order becomes: db → es (if enabled) → wp. WP container gets
  `-e ELASTICSEARCH_URL=http://<es-ip>:9200` (+ `EP_HOST` for ElasticPress).
  UI shows the ES endpoint + a "works with ElasticPress" hint. Worktree envs
  inherit the parent's toggles (their own es container).

## 2c-bis. Development constants & debug controls

- Every site provisioned by the tool automatically gets `WP_DEVELOPMENT_MODE`
  set to `"all"` and `WP_ENVIRONMENT_TYPE` set to `"local"` in wp-config.php
  (injected during provisioning via WPConfigService; existing sites get them
  on next start if absent).
- Settings → Development card exposes switches for the debug constants:
  `WP_DEBUG`, `WP_DEBUG_LOG`, `WP_DEBUG_DISPLAY`, `SCRIPT_DEBUG`,
  `SAVEQUERIES` — read live from wp-config, toggled via WPConfigService
  (immediate effect, no restart needed for constants), plus a
  `WP_DEVELOPMENT_MODE` picker (all/core/plugin/theme/off). "Open debug.log"
  button when WP_DEBUG_LOG is on.

## 2d. Agent tools — MCP server (replicating 10up/localwp-agent-tools)

Reference: https://github.com/10up/localwp-agent-tools (LocalWP add-on exposing an
MCP server per site + auto-generated agent configs). We replicate the abilities,
adapted to our stack:

- **Server:** `wp-container mcp --site <slug>` — an MCP **stdio** server subcommand
  in the existing CLI binary (Swift MCP SDK: modelcontextprotocol/swift-sdk via SPM).
  stdio > embedded HTTP for us: no daemon, works with the app closed, one process
  per agent session, trivial `.mcp.json`. (Optional later: `wp-container mcp serve`
  streamable-HTTP for parity.)
- **Tools (superset of localwp-agent-tools' 12):**
  - `wp_cli` (arbitrary wp-cli via one-shot wordpress:cli container),
  - `read_error_log` (PHP/apache error log via `container logs` + debug.log file),
    `read_access_log` (apache access log), `wp_debug_toggle` (WP_DEBUG/LOG/SCRIPT_DEBUG
    via wp-cli config set),
  - `read_wp_config`, `edit_wp_config` (constants, with timestamped backup),
  - `get_site_info`, `site_health_check` (db connectivity, http probe, disk, versions),
  - `site_start`, `site_stop`, `site_restart`, `site_status`, `list_sites`,
  - **ours:** `worktree_create`, `worktree_list`, `worktree_delete` (branch envs —
    the killer tool for coding agents), `xdebug_toggle`, `elasticsearch_toggle`.
- **Per-site "Enable agent tools" action** (UI toggle + `wp-container agent-tools
  enable <slug>`): writes into the site folder — `.mcp.json` (Claude Code),
  `.cursor/mcp.json`, `.vscode/mcp.json` (all pointing at
  `wp-container mcp --site <slug>`), plus a generated `CLAUDE.md` project-context
  file (site URL/port/paths/credentials, wp-content repo hints, worktree workflow
  how-to) and `.gitignore` entries for the generated files.

## 2e. Full WP-CLI support (every site, every surface)

wp-cli is a first-class citizen on all four surfaces (implementation: one-shot
`wordpress:cli` containers sharing the site's mounts + DB env — already validated):
1. `wp-container wp <site|env> -- <args…>` CLI proxy (done in kit).
2. MCP `wp_cli` tool (§2d).
3. UI: "WP-CLI" button per site → opens Terminal.app running an interactive
   wp-cli shell container (`container run -it --rm … wordpress:cli bash`) cd'd to
   /var/www/html, so `wp plugin list` etc. just work.
4. A per-site executable shim written at `<site>/wp` (and into env dirs) so
   `cd "~/WP Container Sites/my-blog" && ./wp plugin list` works from any shell
   or agent without the app — the shim resolves its own site by location.

## 2f. Trusted HTTPS for every site (mkcert-style, one click)

- **Local CA:** `CertificateAuthority` service generates a "WP Container Local CA"
  once (key + cert in `~/Library/Application Support/WPContainer/ca/`). One-time
  "Trust HTTPS certificates…" button installs it as trusted root
  (`security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain`
  via an osascript admin-privileges prompt — exactly mkcert's mechanism).
- **One wildcard leaf** signed by the CA: SANs `*.localhost`, `localhost`,
  `127.0.0.1` — `*.localhost` is a valid single-level wildcard, and every
  `<slug>.localhost` name resolves to 127.0.0.1 on macOS automatically (no
  /etc/hosts edits ever).
- **HTTPS termination on the host, not in containers:** the app runs a lightweight
  TLS-terminating reverse proxy (Network.framework listener, port 443 — unprivileged
  on modern macOS — with 8443 fallback) that routes by Host header:
  `https://my-blog.localhost` → `127.0.0.1:8881`. Containers stay untouched.
  The CLI gains `wp-container proxy serve` (daemonizable) so HTTPS works app-closed;
  app and CLI negotiate who owns the listener via a pidfile.
- **Proxy liveness is a correctness concern, not an option** (user-reported bug:
  after an app relaunch nothing listened on 443 → every HTTPS/custom-domain site
  showed "Safari Can't Connect"). The "start proxy at launch" setting is opt-OUT
  (registered default true), and regardless of it the app starts the proxy at
  launch whenever any site has HTTPS/custom domain AND on every start of such a
  site. The per-site Integrations card only claims "Serving https://…" when the
  proxy is actually listening (else it flags it and offers "Start Proxy").
- **WordPress correctness:** enabling HTTPS for a site sets home/siteurl to
  `https://<slug>.localhost` (wp-cli) and injects the standard
  `HTTP_X_FORWARDED_PROTO` snippet into wp-config.php (backed up first).
  Toggling off reverts. Worktree envs get `https://<envSlug>.localhost`.
- UI: per-site HTTPS toggle + global "Trust CA" onboarding step; URL displays and
  Open/WP Admin buttons use the https URL when enabled.

## 2g. Site groups

Sidebar organization: sites can be grouped (e.g. "Clients", "Personal", "Experiments").
- Model: `SiteGroup {id, name, sortOrder}`; `Site.groupID: UUID?` (nil = ungrouped,
  shown in a default section). Store envelope gains `groups: []`.
- Sidebar: collapsible group sections (group name header + site rows), ungrouped
  sites at top level. Context menus: New Group, Rename, Delete (sites become
  ungrouped, never deleted), Move to Group ▸. Drag & drop sites between groups.
- AddSiteSheet gets an optional group picker; CLI: `wp-container create --group <name>`
  (creates the group if missing), `list --json` includes `group` per site.

## 2h. Menu bar extra

`MenuBarExtra` (window style) with the app glyph: one clear list of ALL sites (and
running worktree envs) — status dot + name + port, with an inline start/stop
toggle/button per row; clicking a row opens the main window focused on that site.
Footer: "Open WP Container" + Quit. Transitional states show a small spinner on the
row. The list mirrors sidebar grouping order but flat/compact. App keeps running
(and menu bar item alive) when the main window closes.

## 2i. Custom domains

- Default remains `http(s)://<slug>.localhost` (zero-config resolution). Optionally,
  a site can set a **custom domain** (e.g. `mysite.local`, `client.test`) in
  Settings or at creation.
- Resolution: custom domains get a `127.0.0.1 <domain>` line in `/etc/hosts`,
  managed inside clearly-delimited `# wp-container begin/end` markers (added/removed
  via one osascript admin prompt; batch edits). LocalWP-style.
- Routing: the HTTPS/HTTP reverse proxy routes custom domains by Host header just
  like `.localhost` names. HTTP-only sites with custom domains route through a
  plain HTTP listener (port 80, fallback 8080) the same way.
- Certs: the single wildcard `*.localhost` leaf is replaced by ONE combined leaf
  whose SANs include `*.localhost`, `localhost`, `127.0.0.1` plus every custom
  domain (and multisite wildcards `*.<domain>`); the leaf is re-issued and the
  proxy listener reloaded whenever domains change (cheap, CA unchanged, no re-trust).
- wp-cli updates home/siteurl on domain change; wp-config gets the proxy-header
  snippet (shared with §2f).

## 2f-bis. Privileged actions & Touch ID (shipped decisions + TODO)

- **CA trust — no admin, Touch-ID-capable (shipped).** Empirically verified that
  `security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db
  ca.pem` (USER trust domain, no `-d`) trusts the CA **without** administrator
  privileges and `security verify-cert` then passes; user-domain root trust is
  honored by Safari/Chrome. The SecurityAgent confirmation dialog it may show
  supports Touch ID. `CertificateAuthority.trustCA()` uses this path (was: an
  osascript System-keychain admin prompt); `untrustCA()` is the documented undo.
- **/etc/hosts (custom domains) — Touch ID helper (shipped, issue #2), osascript
  fallback.** Writing `/etc/hosts` genuinely needs root.
  - **Preferred path (shipped):** `wpc-hosts-helper`, a tiny privileged daemon
    embedded at `WPContainer.app/Contents/MacOS/wpc-hosts-helper` with its
    launchd plist at `Contents/Library/LaunchDaemons/`, registered via
    `SMAppService.daemon(plistName:)`. It vends exactly `writeHostsBlock(entries)`
    / `removeHostsBlock()` over an XPC mach service. The app calls
    `AuthorizationCreate` + `AuthorizationCopyRights(kAuthorizationFlagInteractionAllowed)`
    against a custom right (`com.fabiankaegy.wpcontainer.modify-hosts`, rule
    `authenticate-admin`) → the Touch-ID-capable system dialog → passes the
    `AuthorizationExternalForm` over XPC; the helper re-verifies it WITHOUT
    interaction before acting. Security boundary (`HostsBlockRewriter`, duplicated
    in the helper, never trusting the app): only `127.0.0.1 <strict-DNS-host>`
    lines, only the `# wp-container` marker block, atomic `0644 root:wheel` write
    with fsync. The helper pins the connecting client's code signature (team +
    bundle id) via `SecCodeCopyGuestWithAttributes` on the audit token. Enabled
    from Settings › General › Custom Domains (needs one-time Login-Items approval).
    Requires a Developer-ID signed build (the helper UI is hidden on ad-hoc Debug
    builds, which `SMAppService` won't register).
  - **Fallback (unchanged):** when the helper is not registered/approved,
    `HostsFileService.apply` stages the rewritten file and copies it over via one
    `osascript … with administrator privileges` prompt.

## 2j. Multisite support

- Add Site setup offers Network type: **Single site** (default) / **Multisite —
  subdirectories** / **Multisite — subdomains**. Provisioning uses
  `wp core multisite-install` (+ MULTISITE constants via wp-config injection and
  the standard htaccess rules written into the mounted folder).
- Subdomain networks work zero-config on `.localhost` base domains
  (`site2.my-net.localhost` auto-resolves; cert SAN `*.<slug>.localhost` added).
  On custom domains, subdomain mode requires a hosts entry per subsite — the UI
  offers "Register subsite domain…" (batched into the managed hosts block);
  subdirectory mode recommended for custom domains.
- Site detail shows network subsites (wp-cli `wp site list`) with open buttons.

## 2k. Granular PHP & WordPress versions

- The Add Site sheet becomes a small **setup guide**: name + group → versions →
  options (multisite, domain, add-ons). Version step: WordPress picker (latest,
  6.8, 6.7, 6.6, …) × PHP picker (8.4, 8.3, 8.2, 8.1) → maps to official image tag
  `wordpress:<wp>-php<php>-apache` (curated known-good matrix in code, "custom
  image tag" escape hatch, availability pre-checked via `container image pull`
  dry attempt with clear error).
- Site Settings shows current WP/PHP (live via wp-cli/php -v when running) and
  allows changing PHP later = image tag swap + restart (files/db untouched).
  WP core updates happen inside WP or via wp-cli (button: "Update WordPress core").
- Xdebug derived images (§2c) are built per base tag automatically.

## 2l. App settings & sidebar quick actions (UI polish)

- **Empty-state centering.** `MainWindow.panel` pins its content to `.topLeading`
  (correct for the scrolling site detail). The "No Site Selected"
  `ContentUnavailableView` therefore needs its own `.frame(maxWidth/​maxHeight:
  .infinity)` so it owns the panel and centers; the onboarding view already did.
- **Menu bar icon.** The `MenuBarExtra` label (and the popover header) render the
  real app icon (`Image(nsImage: NSApp.applicationIconImage)`, resizable, high
  interpolation, 18pt) rather than a monochrome template glyph — a deliberate
  break from the platform norm because the user wants the colored mark.
- **App Settings window (⌘,).** A SwiftUI `Settings` scene (free ⌘, + "Settings…"
  menu item), a `TabView` of three panes reusing the in-app card/row design
  language, fixed 520pt wide. Panes:
  - *General:* one "Show Dock icon" toggle (off = menu-bar-first via
    `NSApp.setActivationPolicy(.accessory)`), applied at launch in `App.init`
    (no Dock flicker) and re-activating the app on a live flip so the settings
    window stays up; "Launch at login" via `SMAppService.mainApp` with error
    surfacing and true-state read-back.
  - *Sites:* default sites-root folder picker + default WordPress×PHP pickers
    that prefill the Add Site guide.
  - *Proxy:* "Start HTTPS proxy at launch" (wired to `ensureProxyRunning`) + a
    live proxy status line.
  - All persisted via `@AppStorage`/`UserDefaults` through a central
    `AppSettings` key registry. `SiteFolders.defaultSitesRoot` and
    `AddSiteSheet` read the same keys (kit reads `UserDefaults.standard`). Per-
    site settings stay in the site detail Settings tab.
- **Sidebar context menu.** Each site row gets Start/Stop (state-dependent),
  Open Site, WP Admin, Reveal in Finder, Open in Terminal, Copy URL, New Branch
  Environment…, Move to Group ▸, and Delete Site… (confirmation offering
  keep-or-trash-folder). All reuse existing `AppViewModel`/`SystemActions` — no
  new logic. Worktree envs ARE sidebar rows now (nested under their parent per
  §2b) with their own context menu (Open, WP Admin, Copy URL, Start/Stop,
  Reveal in Finder, Delete Environment…).
- **Clickable status dot.** In the sidebar the status dot is a start/stop
  control (`InteractiveStatusDot`): hover swaps the dot for a play/stop glyph in
  a fixed 16pt hit area (no layout shift), click toggles run state, transitional
  states keep the pulse and are non-interactive, `.help()` gives tooltips. The
  inner `Button` consumes clicks so row selection is unaffected; the dot is only
  interactive where a toggle closure is passed (not in the drag preview).
- **Favicon avatars.** `FaviconLocator` (kit, pure FS) finds a site's favicon —
  web-root `favicon.{png,ico}`, else the largest WordPress Site Icon crop under
  `uploads` (bounded depth-4 scan), else a theme `favicon.*`. SVG is skipped
  (ImageIO rasterizes it unreliably at avatar size). `FaviconImageCache` (app)
  loads off-main, downsamples via ImageIO capped at 128px, and caches per folder
  keyed by the file's mtime. `SiteAvatar` shows the favicon (aspect-fill) and
  falls back to the initials gradient, re-checking on a reload token (site
  status) so an icon added while running appears without relaunch. Worktree envs
  reuse `SiteAvatar` nowhere today, so parent inheritance is moot.
- **Custom-domain registration UX.** The blocking `/etc/hosts` admin prompt is a
  dedicated, honestly-labelled ("Waiting for admin approval to register
  <domain>…"), skippable step in the Add Site flow — not folded into
  `createAndStartSite`. The app activates before prompting so the dialog is
  visible; a Skip button appears after 10s and a 2-minute timeout auto-skips
  (both cancel the Task, which SIGTERMs `osascript`). A dismissed dialog
  (osascript -128 → `HostsError.cancelled`) or a skip resolves the site as
  created-with-unregistered-domain, and the Domain card flags it with "Register
  now". Note: the create+start hints (seed/db/install) remain time-based
  approximations — lifecycle emits no sub-step events, so fully honest labels for
  the xdebug-image build / ES boot would need a lifecycle event refactor (future).

## 3. App architecture (MVVM, Swift 6 concurrency)

```
WPContainer/
  project.yml                     # XcodeGen
  WPContainer/
    WPContainerApp.swift             # @main, AppState injection
    Models/
      Site.swift                  # id, name, slug, path, port, phpVersion/image tag,
                                  # createdAt, provisioned, status (derived, not persisted)
      SiteStatus.swift            # stopped/starting/running/stopping/error(String)
      ContainerRecord.swift       # decodes `container list --format json`
    Services/
      ContainerCLI.swift          # actor; async Process wrapper (arg array, no shell),
                                  # stdout/stderr capture, JSON decode, streaming lines
                                  # for logs, typed ContainerCLIError
      SiteStore.swift             # @MainActor ObservableObject; load/save sites.json
      SiteLifecycle.swift         # start/stop/provision/delete orchestration per site;
                                  # emits status transitions
      PortAllocator.swift         # free-port scan from 8881, respects taken set
      SystemCheck.swift           # container binary present? system service running?
                                  # offers `container system start`
    ViewModels/
      AppViewModel.swift          # site list, selection, global status polling
      SiteDetailViewModel.swift   # per-site actions, log streaming
    Views/
      MainWindow.swift            # NavigationSplitView
      Sidebar/ (SiteRow, avatar circle w/ initials + status dot, AddSiteButton)
      Detail/  (SiteHeader w/ status pill + Start/Stop, ActionBar: Open Site /
                WP Admin / Open in Finder / Terminal, OverviewSection: URL, path,
                WP + PHP + DB versions, admin credentials; LogsView; SettingsView)
      AddSiteSheet.swift          # name, folder picker, PHP version picker
      OnboardingView.swift        # shown when SystemCheck fails (install/start service)
    Design/
      Theme.swift                 # Studio-inspired tokens: clean white/dark cards,
                                  # rounded 10pt corners, blue accent, SF Symbols
  scripts/validate-container-workflow.sh   # headless end-to-end proof (from Phase V)
```

Key implementation rules:
- All `container` invocations go through `ContainerCLI` (an `actor`) using `Process`
  with argument arrays — never `sh -c` string interpolation. Slugs sanitized to
  `[a-z0-9-]`.
- UI never blocks: every lifecycle action is `Task`-based with status streamed back
  through `@Published` state; errors surface as inline banners, not modal alerts.
- Deleting a site: stop + `container delete` its containers, remove from store,
  optional "Also move site folder to Trash" checkbox (uses `NSWorkspace.recycle`).

## 4. Implementation phases & agent assignments

Fable (this session) orchestrates only. All implementation by subagents.

| Phase | Agent / model | Scope | Depends on |
|-------|---------------|-------|------------|
| V — Container workflow validation | Sonnet 5 | Write + run `scripts/validate-container-workflow.sh`: pull mariadb/wordpress, run the exact per-site container recipe (mounts, port, IP-based DB host, wp-cli install), assert HTTP 200 + files on host, then clean up. Report any CLI behavior that differs from §2 so later phases adapt. | — (parallel with C) |
| C — Core: scaffold + services | Opus 4.8 | XcodeGen project, Models, Services (ContainerCLI, SiteStore, SiteLifecycle, PortAllocator, SystemCheck), minimal placeholder UI; must `xcodebuild` clean. | — (parallel with V) |
| U — UI: Studio-style interface | Opus 4.8 | Full SwiftUI UI per §3 Views/Design on top of C's services; must `xcodebuild` clean. | C (+ V findings) |
| I — Integration & hardening | Sonnet 5 | Wire V's verified recipe into SiteLifecycle if it diverged, end-to-end run (create site → running WP → stop → delete), fix build/runtime issues, README. | V, C, U |
| R — Review | Sonnet 5 | Adversarial pass: concurrency misuse, Process deadlocks (pipe draining), path escaping, port races, state reconciliation bugs. Findings fixed in-place. | I |

## 5. Acceptance criteria

1. App builds with `xcodebuild -project WPContainer.xcodeproj -scheme WPContainer build` and launches.
2. Creating a site "My Blog" yields `~/WP Container Sites/my-blog/wordpress/wp-content/…` on host.
3. Site starts; `http://127.0.0.1:<port>` serves the provisioned site (no install wizard);
   "WP Admin" opens `/wp-admin` and `admin`/`password` logs in.
4. Stop/start cycles preserve content (posts survive; DB data in `database/`).
5. Sites survive app relaunch; statuses reconcile with actual container state.
6. Deleting a site removes its containers and (optionally) trashes its folder.
7. Works when the container system service is stopped: onboarding screen offers to start it.
8. With a git repo in `wp-content/plugins/`, `wp-container worktree create --site <s> --repo <r> --branch feature-x --json`
   returns a descriptor whose URL serves the cloned site with the worktree checkout
   active inside it, while the parent site keeps running untouched.
9. `wp-container list --json` and `wp-container worktree delete` behave as specced; changes
   made via CLI appear in the app without relaunch.
