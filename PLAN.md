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

- macOS 26.0, Apple Silicon (arm64)
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

- **App name:** WP Container. Repo/folder name: `wp-container`. Bundle id `com.fabiankaegy.wpcontainer`. Deployment target **macOS 26** (matches Apple `container`'s own minimum) — no availability checks for anything ≤ 26; APIs newer than 26 need an `if #available` gate.
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
    MARIADB_USER=wordpress, MARIADB_PASSWORD=wordpress, MARIADB_ROOT_PASSWORD=root),
    run with `--max-connections=300` because it also serves every one of the site's
    shared-database worktree envs (issue #17). `MARIADB_DATABASE` provisions the
    OWNER's primary schema only; env schemas are created separately on the same
    server. Each env's WordPress reaches its own schema purely through
    `WORDPRESS_DB_NAME` — nothing on disk differs.
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
- On disk: `~/WP Container Sites/<site>/.envs/<branch-slug>/wordpress` plus
  `~/WP Container Sites/<site>/.worktrees/<branch-slug>/` for the git worktree itself.
  `.envs`/`.worktrees` are hidden from the primary install (never inside `wordpress/`).
  A `database/` folder exists only for an `--isolated-db` env — by default the env's
  database is a schema on the PARENT's server (issue #17), so it has no data
  directory of its own.
- `sharedDatabase` + `databaseSchema` (persisted): shared mode and the `wpc_*`
  schema name it owns. Records written before issue #17 decode as isolated and
  keep their own container, so nothing existing changes behavior.

**Creation flow (speed is the point — APFS makes cloning ~instant):**
1. `git -C <repo> worktree add [-b] <worktreePath> <branch>` (create branch if new).
2. Clone site files: `cp -Rc wordpress/ .envs/<b>/wordpress/` (APFS copy-on-write).
3. Clone the database:
   - **Default — shared server (issue #17):** bring up the parent's db container
     (only *it* needs to be running, not the parent's wp container), then
     `CREATE DATABASE wpc_<env-slug>` + `GRANT` to the shared `wordpress` user and
     fill it server-side with `mariadb-dump … | mariadb …` inside one one-shot
     `mariadb:11` container. No host staging file, no dump buffered through a Swift
     `String`. Guarded by a preflight: if the project's `wp-config.php` defines
     `DB_NAME` literally instead of reading `WORDPRESS_DB_NAME`, shared mode would
     silently write into the parent's database, so creation falls back to an
     isolated container and warns.
   - `--isolated-db` (dedicated container), fast path (parent stopped):
     `cp -Rc database/ .envs/<b>/database/` — instant at any size.
   - `--isolated-db`, live path (parent running): one-shot `wordpress:cli` →
     `wp db export`, import into the env's fresh MariaDB.
4. Start env containers (same recipe as a site, names `wpc-<envSlug>-wp` and
   `wpc-<envSlug>-db` for an isolated env — a shared env talks to
   `wpc-<site-slug>-db` instead and never creates one,
   labels `dev.wpcontainer.site=<site-slug>` + `dev.wpcontainer.env=<envSlug>`), with ONE
   extra mount that shadows the repo path:
   `-v <worktreePath>:/var/www/html/<repoRelPath>` — the worktree checkout replaces
   the primary checkout inside the env container only. (Nested-mount shadowing is
   verified in Phase V.)
5. Migrate every URL onto the env's domain, `http(s)://<envSlug>.localhost`
   (scheme follows the parent's HTTPS; `EnvURLMigration`, full
   `wp search-replace`, then `home`/`siteurl` + `wp cache flush`). `.localhost`
   resolves natively, so no /etc/hosts write and no Touch ID prompt — agents
   create envs headless. The hostname comes from `WorktreeEnv.domainHost` alone
   (label capped at 63 chars with a stable hash). Envs created before this keep
   `http://127.0.0.1:<port>` (`usesDomainURL == false`) until
   `worktree fix-urls` moves them. Admin creds are inherited from the parent
   (cloned DB).
6. Emit a machine-readable descriptor: `{url, port, path, worktreePath, branch, containers}`.

**Deletion:** stop containers (never the parent's shared db container) → drop the
env's own `wpc_*` schema, behind a prefix/charset guard so a bad name can't take
out a sibling or the parent → `git worktree remove` (or leave with
`--keep-worktree`) → delete `.envs/<b>` → update store. If the server is down the
drop is skipped and the name is TOMBSTONED on the parent site
(`Site.pendingSchemaDrops`), to be dropped by the next shared-env `create` — which
drops only tombstoned names, never whatever a `SHOW DATABASES` shows minus what the
store claims (that races a concurrent create, whose schema exists before its record
does). A schema orphaned by a hard crash mid-create therefore leaks; leaking beats
destroying a live env's database.

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
- **Coupled lifecycle:** stopping a site stops all its worktree envs; starting
  a site starts only the site by default, with env fan-out opt-in via
  `--with-envs`/`with_envs`/"Start with Environments" (issue #18; kit-level
  `startSiteWithEnvs`/`stopSiteWithEnvs`, so app, CLI and MCP behave
  identically; the parent is sequenced first and per-env failures surface
  individually without aborting the rest). Envs remain individually
  start/stoppable — starting one whose database is shared brings up the parent's
  db container if needed, and stopping the last running one of a stopped site
  shuts it back down so it never lingers (issue #17).
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
  base tag with `container build`: `wpc-wordpress-xdebug:v<recipe>-<tag>` from a
  generated Dockerfile (`FROM wordpress:<tag>` + `pecl install xdebug` + docker-php-ext-enable
  + xdebug.ini: mode=debug; start_with_request=trigger — free until a debug session
  is requested via XDEBUG_SESSION/XDEBUG_TRIGGER; client_port=9003;
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
  `-e ELASTICSEARCH_URL=http://<es-ip>:9200` and `-e EP_HOST=…`. ElasticPress reads
  `EP_HOST` only as a constant, so a managed `php/prepend.d/wpc-elasticpress.php`
  handler defines it from the env var; `wp-container wp` and the MCP `wp_cli` tool
  pass the same env var to their one-shot wp-cli containers.
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
  `https://my-blog.localhost` → the site's container. SITE containers stay
  untouched — they keep publishing their own `127.0.0.1:8881` and the proxy is
  purely additive in front of them.
  The CLI gains `wp-container proxy serve` (daemonizable) so HTTPS works app-closed;
  app and CLI negotiate who owns the listener via a pidfile.
- **Amendment (issue #16 follow-through) — worktree ENVS are not untouched.** An
  env's wp container publishes NOTHING; the proxy binds `127.0.0.1:<env port>`
  itself, one loopback listener per env, and relays to the container's vmnet IP.
  The premise above held only as long as the proxy was an optional extra path, and
  for envs it can't be: `http://127.0.0.1:<port>` was then the ONLY URL an env
  was ever advertised at (app, CLI, MCP payloads, magic-login) and what WordPress
  had pinned as `home`/`siteurl` (since superseded by env domains — §2b step 5 —
  which the proxy serves by Host; the port listener stays for pre-domain envs).
  Leaving that URL on Apple's forwarder meant the idle
  clock could not see the traffic that mattered and wake-on-request could not fire
  where users actually clicked — the two halves of issue #16 — while also routing
  every env's bulk HTTP through the lossy forwarder. Owning the socket fixes all
  three at once, at the price of envs now depending on proxy liveness (the app
  ensures it; CLI/MCP warn). Env starts stay independent of it: readiness is
  probed at the container's vmnet IP rather than the port. Env MAILPIT ports stay
  published — light traffic, and never a WAKE trigger (a mailbox request does still
  stamp the idle clock, like any proxied route), so there is nothing to gain.
  TRANSITION: an env container still running from a pre-change build holds its own
  port, so the proxy logs one warning per port and retries every few seconds; that
  env keeps working through its published port and the proxy takes the socket after
  the env is restarted once. Because a port the proxy does not own is a port whose
  traffic it cannot see, such an env is also exempt from idle-stop until it is
  restarted. Ownership is not merely logged: the proxy publishes
  `proxy-env-ports.json` next to its pidfile (owned + conflicted ports, rewritten
  each reconcile, removed on clean stop) so `wp-container https status`, the
  CLI/MCP env warnings and the app can all distinguish "no proxy" from "a proxy is
  up but is not serving this env" — dropping `-p` turned a loud `container run`
  failure into an otherwise silent misroute.
- **ACCEPTED COST of proxying env traffic: no keep-alive, no HTTP upgrade.** The
  proxy forces `Connection: close` and serves one request per connection, so
  WebSockets to an env URL cannot work and every env request pays a fresh TCP
  connect. Sites are unaffected (their published port bypasses the proxy). Not
  fixed now, and deliberately so: keep-alive plus upgrade means connection pooling
  and framing state, and the response-truncation bugs that shaped the current relay
  (see `relay(from:to:)`) are a standing warning about how much care that needs.
  Revisit only with a concrete need.
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

## 2m. Database importer (drop-in .sql → scrub → media → local admin)

Bring a production/staging database into a local site in one guided flow. Kit-first
design: `DatabaseImportService` in WPContainerKit does everything; app sheet, CLI
command and MCP tool are thin surfaces over it (same as Mailpit/§2e).

**Input.** A `.sql` or `.sql.gz` dump, via drag & drop onto the site detail pane /
the import sheet's dropzone, or a file picker, or a CLI path argument. `.sql.gz`
is decompressed on the host (`gzip -dc`) first. The dump is staged INSIDE the
site's `wordpress/` mount (e.g. `wordpress/.wpc-import/dump.sql`) so the one-shot
`wordpress:cli` container can see it at `/var/www/html/.wpc-import/dump.sql`;
staged files are always cleaned up (defer), and `.wpc-import/` is transient.

**Pipeline (phases, each surfaced as progress):**
1. *Preflight* — site must be running (DB reachable); otherwise the service
   starts it (same coupled-start used elsewhere). Verify dump size vs free disk.
2. *Safety backup* — `wp db export` to `<site>/.backups/pre-import-<timestamp>.sql`
   so a failed/regretted import is one command away from undone. On any later
   phase failing, offer/perform rollback (re-import the backup).
3. *Import* — `wp db import /var/www/html/.wpc-import/dump.sql`.
4. *URL migration* — read the imported `home` option (`wp option get home`),
   that's the **source URL**; run `wp search-replace <source> <local-url>
   --all-tables --precise` (+ `wp cache flush`). Source URL is remembered on the
   site record (`lastImportSourceURL`) — it powers remote media (below).
5. *Scrub (optional, default ON)* — wp-scrubber-inspired
   (https://github.com/10up/wp-scrubber), implemented as parameterized SQL via
   `wp db query` (prefix from `wp db prefix`), no plugin installed:
   - `users`: `user_pass` → random (MD5(UUID()) — legacy hash, unusable, rehashed
     by WP if ever logged in), `user_email` → `user<ID>@example.com`,
     `display_name` → `User <ID>`, `user_activation_key` → ''.
   - `usermeta`: blank `first_name`, `last_name`, `nickname`, `description`,
     delete `session_tokens`.
   - `comments` + `commentmeta`: emptied (TRUNCATE), `posts.comment_count` → 0.
   - `options`: `admin_email` → `admin@example.com`, delete
     `new_admin_email` if present.
   - Allowlist: emails/domains to preserve (UI text field / `--allowed-emails`,
     `--allowed-domains`), matching wp-scrubber's flags.
6. *Media handling (user choice, asked in the flow):*
   - **Load from source site** (default when a source URL was detected): write a
     tiny mu-plugin `wp-content/mu-plugins/wpc-remote-media.php` that filters
     upload URLs to the source host when the file doesn't exist locally
     (BE-Media-from-Production style). Removable via the same flow/settings.
   - **Copy from folder…**: user picks a local `uploads` folder; it's copied
     (APFS clonefile) into `wp-content/uploads`.
   - **Skip**: do nothing (broken images accepted).
7. *Local admin (optional, default ON)* — after scrubbing: create-or-update
   `admin`/`password` (`wp user create admin admin@localhost.local
   --role=administrator --user_pass=password`, or `wp user update` + ensure
   administrator role if the login exists). Runs last so the scrubber can't
   touch it.
8. *Finish* — `wp cache flush`, delete staged dump, report summary (counts:
   users scrubbed, comments removed, URL pairs replaced, admin credentials).

**Surfaces.**
- *App:* "Import Database…" in the site ActionBar overflow + sidebar context
  menu + drag & drop of a .sql/.sql.gz file onto the site detail pane. Sheet =
  small wizard: file (dropzone/picker) → options (scrub toggle + allowlist,
  media choice, admin toggle, detected/overridable source URL) → live phase
  progress → summary/error with "Roll back" on failure.
- *CLI:* `wp-container db import <site> <file> [--no-scrub] [--allowed-emails …]
  [--allowed-domains …] [--media remote|skip|copy --media-path …] [--no-admin]
  [--json]` (grouped `db` subcommand leaves room for `db export`).
- *MCP:* `db_import` tool (same options, JSON summary) — agents can seed a site
  from a dump unattended.

**Non-goals (v1):** multisite-aware scrubbing beyond the base tables, dumps >2GB
(warn like wp-scrubber), media *download* from the source site (proxy mu-plugin
covers the dev need without gigabytes on disk).

**Status: shipped** (kit `258aee1`, CLI/MCP `a073393`, app `84f03f9`). Verified
end to end against the built CLI on real containers via
`scripts/validate-db-import.sh` — full pipeline (backup → import → URL
migration → scrub with an email/domain allowlist → remote-media mu-plugin →
local admin), the auto-rollback-on-failure path (a deliberately corrupted
dump), and the fast argument-validation cases. 24/24 assertions passed, no
code changes were needed. A full import of a small (~38KB) dump takes ~20s;
site create+start+auto-provision another ~10s.

## 2n. Site export / import (portable `.zip`)

Move a site between Macs as one archive. Kit-first: `SiteArchiveService` in
WPContainerKit does the work; the CLI, MCP tools and app sheets are thin surfaces
over it.

**Archive.** `<slug>-<yyyyMMdd>.zip` with `wpc-site.json` (manifest, `schemaVersion`
1), `database.sql` (`wp db export --single-transaction`) and `wordpress/` (the full
install). Built with `/usr/bin/zip -r -y -q -X` (symlinks stored as links) and read
with `unzip` / `zipinfo`. Default excludes, editable at export: `.git`, `.svn`,
`.DS_Store`, `__MACOSX`, `node_modules`, `bower_components`; `.wpc-export` and
`.wpc-import` are always excluded. Bind mounts under `/var/www/html` are inlined
into `wordpress/`; mounts elsewhere are skipped with a warning.

**Settings that travel.** `imageTag`, `phpVersion`, `networkType`, HTTPS, Xdebug,
Redis, Elasticsearch and Mailpit toggles, CPU/memory limits, `idleStopMinutes`,
`customDomain` (editable on import) and `lastImportSourceURL`. Ports, ids, group,
mounts, agent-tools state and the `database/`, `.backups/`, `php/`, `.envs/` and
`.worktrees/` folders stay behind.

**Export.** The site is started if needed (CLI `--no-start` opts out), the database
is dumped through the wp-cli one-shot container into a transient `.wpc-export/`,
and the zip is written to a temp file next to the destination and renamed into
place. Temp files are removed on every exit path. Symlinks pointing outside
`wordpress/` are reported as warnings because import drops them.

**Import order.**
1. Validate the zip: manifest present, `schemaVersion` <= 1, safe entry paths (no
   absolute paths or `..`, top level limited to `wpc-site.json`, `database.sql`,
   `wordpress/`), free disk >= 1.2x the uncompressed size.
2. Resolve a unique slug and the domain choice (keep, set or none).
3. Create the store record with `provisioned = true`.
4. Extract on the same volume, move `wordpress/` into the site folder, drop
   symlinks that resolve outside it or do not resolve, write the `wp` shim, enable
   Mailpit, start the site.
5. `wp db import`, then `EnvURLMigrator.migrate` rewrites the source URLs to the new
   site's authority (multisite, `DOMAIN_CURRENT_SITE`, `WP_HOME`/`WP_SITEURL`,
   forwarded-proto).
6. Flush caches, cover the CA leaf for HTTPS, apply the custom domain. A domain or
   hosts failure is a warning and the site stays.

**Rollback.** A failure or cancellation from step 3 through the cache flush removes
the store record, containers, cert hosts and folder, and a group the import created
once no site is left in it.
`wpc import` and `wpc export` turn Ctrl-C and SIGTERM into a cancellation and exit
130 once cleanup is done. Work folders (`.wpc-import-*`) and partial archives more
than six hours old are swept by the next import or export. Content is imported as-is: no
scrub, no admin reset. HTTPS stays on; if the wpc CA is untrusted on the importing
machine, import warns and points to the trust step.

**Surfaces.**
- *CLI:* `wpc export <slug> [-o file.zip] [--exclude p]... [--no-default-excludes]
  [--force] [--no-start] [--json]`; `wpc import <file.zip> [--name N]
  [--domain D | --no-domain] [--path DIR] [--group G] [--image TAG] [--json]`.
- *MCP:* `site_export` and `site_import`, synchronous, returning a summary.
- *App:* Export Site… in the sidebar context menu only (editable exclude list
  remembered per user, save panel, progress, Reveal in Finder). Import via File ▸
  Import Site… (⇧⌘I) or by dropping a `.zip` on the main window's panel; the sheet shows a source summary, Name
  and Domain fields and the parent folder, then per-phase progress and Open Site.

**Non-goals.** Zips from LocalWP or other tools (a zip without `wpc-site.json` fails
with "not a wpc export"); exporting worktree envs.

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
