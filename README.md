<p align="center">
  <img src="docs/assets/icon.png" width="160" alt="WP Container icon">
</p>

<h1 align="center">WP Container</h1>

<p align="center">
  Local WordPress development for macOS, powered by
  <a href="https://github.com/apple/container">Apple containers</a>.<br>
  A native SwiftUI app in the spirit of WordPress Studio — plus a CLI and MCP server built for AI coding agents.
</p>

---

## What it does

WP Container creates and manages local WordPress sites, each running in lightweight
Apple `container` VMs (WordPress + MariaDB per site). Every site's **full WordPress
installation lives in a normal folder on your Mac** — drop your git-managed
`wp-content` plugin or theme repos straight in and they're live immediately.

```
~/WP Container Sites/my-blog/
├── wordpress/        ← the entire WP install, host-visible (mounted to /var/www/html)
│   └── wp-content/   ← your git repos go here
├── database/         ← MariaDB data, survives restarts
└── wp                ← per-site wp-cli shim
```

Sites are provisioned automatically (no install wizard) and log in with
`admin` / `password`.

<p align="center">
  <img src="docs/assets/screenshot-main.png" alt="WP Container — site overview with branch environments" width="850">
</p>

<p align="center">
  <img src="docs/assets/screenshot-settings.png" alt="Settings — trusted HTTPS, AI agent tools, Xdebug, Elasticsearch, and WP_DEBUG controls" width="850">
</p>

<p align="center">
  <img src="docs/assets/screenshot-menubar.png" alt="Menu bar extra with per-site status and start/stop" width="420">
</p>

## Highlights

- **One-click sites** — create, start, stop, delete from a Studio-style UI; sidebar
  with live status, per-site overview, streaming container logs.
- **Branch environments (git worktrees)** — spin up an isolated, fully-running clone
  of a site for any branch of a repo inside `wp-content`, in ~5 seconds (APFS
  copy-on-write + a bind mount that shadows the repo path with the worktree
  checkout). The parent site keeps running untouched. Built for AI agents:
  ```bash
  wp-container worktree create --site my-blog \
    --repo wp-content/plugins/my-plugin --branch feature-x --json
  # → {"url": "http://127.0.0.1:8882", "path": …, "worktreePath": …}
  ```
- **`wp-container` CLI** — everything the app does, scriptable, with `--json`
  everywhere: `list`, `create` (`--wp/--php/--multisite/--domain/--group`),
  `start`, `stop`, `delete`, `worktree …`, `wp …` (wp-cli proxy), `xdebug`,
  `elasticsearch`, `domain`, `https`, `resolve-site`, `setup wp`. Install with
  `make install-cli` (adds a `wpc` shortcut + the global `wp` router binary).
- **Ephemeral containers, durable sites** — containers are disposable (`--rm`);
  all state lives in the site folder. Sites survive app restarts and reconcile
  against real container state via labels.
- **Studio-style dark-frame UI** — dark window shell with a light inset content
  panel, Overview / Logs / Settings tabs, collapsible **site groups** with
  drag & drop, and a **menu bar extra** for one-glance status and start/stop of
  every site. Sites with a favicon or WordPress Site Icon show it as their
  avatar; sidebar rows get right-click quick actions and a clickable
  start/stop status dot.
- **Menu-bar-first option** — app settings (⌘,) cover hiding the Dock icon,
  launch at login, default sites folder and WP×PHP versions, HTTPS-proxy
  autostart, and notifications. Native macOS notifications fire for background
  start/stops, site creation, branch environments coming up (click to open),
  core updates, and proxy failures.

- **Xdebug & Elasticsearch** — per-site one-click toggles in Settings → Development.
  Xdebug builds a derived image once per base tag and points `client_host` at the
  host gateway (port 9003); Elasticsearch runs a single-node sidecar wired into
  WordPress (ElasticPress-ready). Recipes validated in `scripts/validate-addons.sh`.
- **Custom domains** — give a site `mysite.local`; a managed `/etc/hosts` block plus
  the host proxy route it (HTTP and HTTPS), the local cert re-issues to cover it,
  and WordPress URLs update automatically.
- **Multisite** — create subdirectory or subdomain networks from the setup guide
  (`wp core multisite-install` + MULTISITE constants + network `.htaccess`); the
  Overview tab lists network subsites.
- **WP × PHP versions** — the new-site flow is a 3-step guide (name → WordPress ×
  PHP version with a live image-tag preview → options); change PHP later (image
  swap + restart) or update core from Settings → Software.
- **MCP agent tools** — `wp-container agent-tools enable <site> [--root …]` writes
  `.mcp.json` (+ Cursor/VS Code configs) and a marked `AGENTS.md` block into a
  chosen root (site folder, or your `wp-content` repo root for IDE discovery);
  the bundled MCP stdio server (`wp-container mcp --site <slug>`) exposes 18 tools
  in the spirit of [10up/localwp-agent-tools](https://github.com/10up/localwp-agent-tools):
  `wp_cli`, log readers, `wp-config` editing, site info/health, start/stop/status,
  `list_sites`, `worktree_*`, `xdebug_toggle` / `elasticsearch_toggle`, plus
  `login_link` / `create_user`.
- **Agent-friendly login** — `wp-container login <site>` prints a one-time magic
  login link (single-use, 15-minute expiry) that opens straight into a logged-in
  wp-admin — no `wp-login.php` form for agents to fumble. `--open` opens it, and
  the `login_link` / `create_user` MCP tools expose the same for agents.
- **Trusted HTTPS** — mkcert-style local CA trusted per-user in the login keychain
  (**no admin password — Touch ID supported**); `https://<site>.localhost` (or your
  custom domain) served by a host-side TLS reverse proxy (443, Host-header routing).
- **wp-cli everywhere** — `wp-container wp <site> -- …`; a `./wp` shim in every site
  that maps your current subdirectory into the container; an optional global `wp`
  router (`wp-container setup wp`) so plain `wp` inside a site runs containerized
  wp-cli and defers to Homebrew's `wp` elsewhere; an interactive WP-CLI Terminal
  button; and the MCP `wp_cli` tool.
- **Dev-ready by default** — every site gets `WP_DEVELOPMENT_MODE=all` /
  `WP_ENVIRONMENT_TYPE=local`, with live `WP_DEBUG`-family switches in
  Settings → Development.
- **Mailpit email catching** — per-site toggle; all outgoing mail lands in a
  local mailbox (`https://<site>-mail.localhost`, plus a REST API agents can
  read). Persistent across restarts.
- **Per-site resource limits** — cap CPU/memory per site in
  Settings → Resources or `wp-container limits <slug> --cpus 2 --memory 512`
  (see [docs/RESOURCES.md](docs/RESOURCES.md)).
- **Touch ID for privileged actions** — the optional signed hosts-helper
  makes custom-domain changes a Touch ID dialog instead of a password prompt
  (one-time enable in Settings → General).

## Requirements

- macOS 26 (Apple Silicon)
- [Apple `container`](https://github.com/apple/container) ≥ 1.1.0 (`brew install container`
  or the release installer); the app offers to start its system service
- Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) to build from source

## Building

```bash
git clone https://github.com/fabiankaegy/wp-container.git
cd wp-container
make build            # xcodegen + xcodebuild (app + CLI)
open build/Build/Products/Debug/WPContainer.app
make install-cli      # optional: /usr/local/bin/wp-container + wpc
```

## How it works

Each site runs two containers (`wpc-<slug>-wp`, `wpc-<slug>-db`) labeled
`dev.wpcontainer.site=<slug>`, with the site folder bind-mounted in. The app and
CLI share one store (`~/Library/Application Support/WPContainer/sites.json`) with
file locking, and treat container labels as ground truth. Notable Apple-container
specifics we handle for you (all empirically verified — see
`scripts/validate-container-workflow.sh`): WordPress core is pre-seeded because
virtiofs mounts reject `chown`, MariaDB runs as its own uid, and the DB's IP is
re-discovered on every start.

Each container runs in its own lightweight VM — memory/CPU defaults, real
measured usage, and the limitations to be aware of are documented in
[docs/RESOURCES.md](docs/RESOURCES.md). Short version: caps aren't
reservations, stopped sites cost zero, and stopping unused sites is the lever
that matters.

## Development

- `PLAN.md` — full architecture and product spec.
- `scripts/validate-container-workflow.sh` — end-to-end proof of the container
  recipe (site lifecycle, persistence, worktree cloning).
- `scripts/validate-addons.sh` — Xdebug image build + Elasticsearch validation.
- Targets: `WPContainerKit` (models + services), `WPContainer` (SwiftUI app),
  `wp-container` (CLI). Swift 6 strict concurrency throughout.
