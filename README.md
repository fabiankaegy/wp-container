<p align="center">
  <img src="docs/assets/icon-source.png" width="160" alt="WP Container icon">
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
  everywhere: `list`, `create`, `start`, `stop`, `delete`, `worktree …`, `wp …`
  (wp-cli proxy). Install with `make install-cli` (adds a `wpc` shortcut).
- **Ephemeral containers, durable sites** — containers are disposable (`--rm`);
  all state lives in the site folder. Sites survive app restarts and reconcile
  against real container state via labels.
- **Studio-style dark-frame UI** — dark window shell with a light inset content
  panel, Overview / Logs / Settings tabs, collapsible **site groups** with
  drag & drop, and a **menu bar extra** for one-glance status and start/stop of
  every site.

- **MCP agent tools** — `wp-container agent-tools enable <site>` writes `.mcp.json`
  (+ Cursor/VS Code configs and a `CLAUDE.md`) into the site folder; the bundled
  MCP stdio server (`wp-container mcp --site <slug>`) exposes 16 tools in the
  spirit of [10up/localwp-agent-tools](https://github.com/10up/localwp-agent-tools):
  `wp_cli`, log readers, `wp-config` editing, site info/health, start/stop/status,
  `list_sites` — plus `worktree_create` / `worktree_list` / `worktree_delete`.
- **Trusted HTTPS** — mkcert-style local CA with one-time keychain trust;
  `https://<site>.localhost` served by a host-side TLS reverse proxy (port 443,
  Host-header routing). Toggle per site in Settings → Integrations.
- **wp-cli everywhere** — `wp-container wp <site> -- …`, a `./wp` shim in every
  site folder, an interactive WP-CLI Terminal button, and the MCP `wp_cli` tool.

## In progress

Being built right now (tracked in [PLAN.md](PLAN.md)):

- **Xdebug & Elasticsearch toggles** — per-site, one click; recipes already
  validated on Apple container (see `scripts/validate-addons.sh`).
- **Custom domains** (`mysite.local`) with managed /etc/hosts entries, **multisite**
  networks (subdirectory & subdomain), and a **WP × PHP version matrix** in the
  new-site setup guide.

## Requirements

- macOS 27 (Apple Silicon)
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

## Development

- `PLAN.md` — full architecture and product spec.
- `scripts/validate-container-workflow.sh` — end-to-end proof of the container
  recipe (site lifecycle, persistence, worktree cloning).
- `scripts/validate-addons.sh` — Xdebug image build + Elasticsearch validation.
- Targets: `WPContainerKit` (models + services), `WPContainer` (SwiftUI app),
  `wp-container` (CLI). Swift 6 strict concurrency throughout.
