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

**UI:** each site's detail view gets a "Branches" section listing its worktree envs
(branch name, status dot, port, Open/Start/Stop/Trash), plus a "New branch
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
