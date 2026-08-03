# Resource handling — memory, CPU, disk, and limits

How WP Container uses your Mac's resources, what the defaults are, and the
limitations worth knowing. Numbers below were measured live on a 64 GB
Apple Silicon machine running several sites (see "Measured reality").

## The mental model: one lightweight VM per container

Apple `container` differs fundamentally from Docker Desktop: there is **no
single big always-on VM**. Every container runs in its own lightweight
virtual machine (Virtualization.framework), visible in Activity Monitor as a
`com.apple.Virtualization.VirtualMachine` process.

For WP Container that means each **running** site is 2+ VMs:

| Container | When | Configured default |
|---|---|---|
| `wpc-<slug>-db` (MariaDB) | always | 4 CPUs, 1 GB |
| `wpc-<slug>-wp` (WordPress/Apache) | always | 4 CPUs, 1 GB |
| `wpc-<slug>-es` (Elasticsearch) | if enabled | 4 CPUs, 1 GB (512 MB Java heap) |
| one-shot `wordpress:cli` | during provisioning/wp-cli calls | seconds-lived |
| `buildkit` builder | only while building the Xdebug image | 2 CPUs, 2 GB |

Branch environments (worktree clones) run their own wp/(es) containers, but
**not** their own MariaDB: by default an env is an extra schema on the parent
site's existing db container, so a running env costs one VM rather than two.
Measured on a 4-env site, that reclaimed ~1.9 GB — the DB VMs were ~490 MB each
to serve a 1.2 MB database at a peak of 2 connections, because the memory is VM
baseline plus guest page cache and almost entirely decoupled from the workload
(see below). `--isolated-db` opts an env back into its own container.

The shared server is started with `--max-connections=300` (up from the stock 151)
since it now serves a whole family of environments.

## Memory

- **The 1 GB per container is a cap (guest RAM size), not an upfront
  reservation.** Host memory is committed as the guest actually touches
  pages. Measured RSS per VM ranged from **~100 MB** (idle MariaDB) to
  **~1.5 GB** (busy WordPress under load) — and can transiently exceed the
  guest cap because the VM process itself, virtiofs caching, and guest page
  cache all count against the host process.
- **Guest page cache is the main gotcha**: Linux inside the VM happily uses
  free guest RAM as disk cache, and macOS can't reclaim it as aggressively as
  its own file cache. Long-running busy containers therefore drift toward
  their cap and stay there. Restarting a site resets this completely.
- **Stopped sites cost zero.** Containers are ephemeral (`--rm`): stopping a
  site tears the VMs down entirely — no idle daemon, no background VM. This
  is the single most effective lever: **stop sites you're not working on** —
  one click in the menu bar, or opt into having it done for you (see below).
- **A running VM cannot shrink.** Apple documents that
  [memory freed inside the container is never relinquished to the host](https://github.com/apple/container/blob/main/docs/technical-overview.md#releasing-container-memory-to-macos),
  and there is no host-side ballooning in `apple/containerization`
  ([#65](https://github.com/apple/containerization/issues/65)). So a VM's host
  footprint is its **peak** touched memory, and a full stop is the only way to
  reset it. Every stop/wake cycle resets the high-water mark for free.

## Auto-stop when idle, wake on request

Because a running idle VM can't give memory back, and because VM boot is ~1s,
WP Container stops what nobody is using and starts it again when someone asks.

**Branch environments: on by default, 15 minutes. Sites: off by default.** The
asymmetry is about what can be *observed*, not about which matters more — see
the next section.

- **Who enforces it:** the reverse proxy — it sees every request it routes, so it
  knows when each site/environment was last reached through it. It runs either
  inside the app or headless via `wp-container proxy serve`; with no proxy
  listening nothing is stopped and nothing is woken. Both the Idle stop card and
  `wp-container idle` say so when that's the case.
- **Environments need the proxy to be reachable at all.** An environment's
  container publishes no host port: the proxy binds `127.0.0.1:<env port>` itself
  and relays to the container's vmnet IP. That is what makes the one URL every
  surface advertises both trackable and wakeable. The app starts the proxy
  whenever an environment starts; the CLI and MCP print a warning if none is
  running (the environment still starts — wp-cli and MCP don't need HTTP).
- **Extra safety on sites:** a site is never auto-stopped while any of its
  branch environments are running (its MariaDB container may be serving them),
  and an idle-stop of a site stops only the site, never its environments.
- **Envs release the shared DB too:** after an env is idle-stopped, the parent's
  shared MariaDB container is retired as soon as nothing holds a lease on it, the
  parent's own wp container is down, and no sibling env is borrowing it. Without
  that, idling envs would reclaim only half the memory.
- **Waking:** hitting any stopped URL the proxy serves — an environment's
  `http://127.0.0.1:<port>` included — returns a "Waking up …" page that reloads
  every 2 seconds and lands on the live site once WordPress answers (a 503 with
  `Retry-After` for non-browser clients). Repeated requests during the wake
  trigger exactly one start. A shared-database env woken while its parent site is
  down boots the parent's DB container first.

### What counts as activity — and what doesn't

| Counted | Not counted |
|---|---|
| Requests to `https://<slug>.localhost` or a custom domain | Requests to a **site's** `http://127.0.0.1:<port>` |
| Requests to an **environment's** `http://127.0.0.1:<port>` | Anything inside the container you started yourself (`container exec`) |
| `wp-container wp …` (and the `wp` shim/router) | |
| MCP tool calls scoped to the site/env | |
| `wp-container login` / the `login_link` MCP tool | |
| An explicit start (CLI, MCP `site_start`, the app's Start button) | |

Only traffic through the proxy is visible to it; the other signals are recorded
as a `lastActivityAt` stamp in `sites.json` (at most one write a minute) so they
work across processes. The idle clock is the latest of those, plus the moment the
proxy first saw the instance running.

**Environments have no blind spot left.** Their advertised
`http://127.0.0.1:<port>` URL — the one the app, the CLI, the JSON payloads and
WordPress's own `home`/`siteurl` all use — is a socket the proxy holds, so
browsing an environment keeps it alive and reopening a parked one wakes it, at
the exact URL you already have in a tab. That is why the default is on.

**Sites still have one.** A site's container publishes its own port, so a request
to `http://127.0.0.1:<port>` goes straight to it and the proxy never sees it.
Its `<slug>.localhost` and custom-domain URLs do go through the proxy. So if you
enable idle-stop on a site, use its proxied URL.

Configure it per instance:

```bash
wp-container idle <slug>                 # report (site or env slug)
wp-container idle <slug> --minutes 15    # stop after 15 idle minutes
wp-container idle <slug> --off           # never auto-stop
wp-container idle <slug> --default       # back to the built-in default
                                         # (environments 15 min, sites off)
```

…or in the app: **Idle stop** on a site's Settings tab, and on an environment's
detail pane (Default / Never / 15 (recommended) / 5 / 30 / 60 min). The setting
is stored per instance in `sites.json`, not in app preferences, precisely so a
headless proxy enforces the same policy.

Agents: `get_site_info` and `worktree_list` report `idleStopMinutes` /
`effectiveIdleStopMinutes` (0 = never), and the **`set_idle_stop`** tool sets
them — so an agent that will leave an environment idle for longer than the
timeout while still needing it can turn it off, and back on when it's done.

### Upgrading: environments created before this change

An environment whose container is still *running* from an older build publishes
its own port, so the proxy can't take that socket. It logs one warning per port
(also on stderr for `wp-container proxy serve`), keeps everything else working —
the environment stays reachable through its own published port — and retries
every few seconds. Such an environment is also **never idle-stopped**: the proxy
can't see traffic to a port it doesn't own, so it refuses to judge it idle at all.
Stop and start that environment once and the proxy takes the socket, from which
point the timeout applies.

Expected impact once enabled across a fleet: memory cost becomes roughly
`~500 MB × environments touched in the last N minutes` instead of
`× environments that exist`.

### Verified teardown

`container stop` returning success is not proof the VM is gone: a container was
observed sitting in `container list --all` as `stopped` while its shim and
`com.apple.Virtualization.VirtualMachine` process stayed alive holding ~219 MB.
Every stop now polls for the container to actually disappear, escalates a
still-stopped survivor to `container delete`, and reports anything that outlives
both (CLI stderr, the `site_stop` MCP payload, the app's error banner) rather
than pretending the memory was reclaimed. A name that reappears *running* is
treated as concurrently restarted by another process and left alone — deleting it
would kill a container we no longer own. Quitting the app skips this pass so
shutdown isn't delayed by it.

### Practical sizing

| Machine RAM | Comfortable concurrently-running sites |
|---|---|
| 16 GB | 1–2 (avoid Elasticsearch on both) |
| 32 GB | 3–5 |
| 64 GB+ | as many as you realistically need |

Rule of thumb: a plain running site settles around **0.5–1.5 GB** of real
host memory; add ~0.7–1 GB for Elasticsearch. With auto-stop-when-idle (on by
default for branch environments), what counts toward these numbers is what you've
*touched recently* rather than what exists, so a fleet of 30 branch environments
costs whatever the handful you actually used in the last 15 minutes cost.

## CPU

- The default **4 CPUs per container is a scheduling cap, not a
  reservation** — idle containers use ~0% host CPU. Many containers can
  share the same physical cores; macOS schedules the VM threads like any
  other process.
- Startup spikes are real but short (MariaDB init, WP first request,
  Elasticsearch JVM boot). Sustained CPU only happens when the site is
  actually serving work.

## Disk

- **Images** live in `~/Library/Application Support/com.apple.container/`
  (shared across all sites): wordpress ≈ 250 MB, mariadb ≈ 120 MB,
  elasticsearch ≈ 600 MB, plus one derived `wpc-wordpress-xdebug:<tag>` per
  base tag you enable Xdebug on. Pulled once, reused everywhere.
- **Site data** lives in the site folder (`wordpress/` ≈ 90 MB fresh,
  `database/` ≈ 150 MB fresh) — normal files, Time Machine-friendly.
- **Branch environments are nearly free on disk** at creation: APFS
  copy-on-write clones (`cp -c`) share blocks with the parent until files
  diverge. A fresh env costs ~0 bytes; it grows only by what changes.

## Known limitations

1. ~~No per-site resource knobs in the UI yet~~ **Per-site CPU/memory caps
   are now configurable** (issue #11). Set them in **Settings → Resources**
   (CPU 1–8, memory 512 MB / 1 / 2 / 4 GB, each with a "Default" state), on
   the CLI via `wp-container create --cpus N --memory MB` or
   `wp-container limits <slug> [--cpus N] [--memory MB]`. Caps are passed to
   `container run` for the db/WordPress/Elasticsearch/Mailpit containers (never
   the short-lived one-shot wp-cli containers), take effect on the next start,
   and are inherited by worktree environments. A `nil`/"Default" cap uses the
   `container` defaults (4 CPUs / 1 GB). Especially useful for trimming
   Elasticsearch (its 512 MB Java heap fits a smaller VM) and for 16 GB Macs.
2. **virtiofs I/O overhead**: bind-mounted folders (your `wordpress/` and
   `database/`) go through virtiofs, which is slower than a native disk
   image — noticeable on huge `npm install`-style file storms inside the
   container, negligible for serving WordPress. (Running builds on the host
   against the mounted folder is faster and is the intended workflow.)
3. **Elasticsearch's `vm.max_map_count` warning** in logs is expected and
   non-fatal for single-node dev setups; the guest kernel default is below
   ES's production recommendation and we deliberately don't tune it.
4. **VM boot time** (~1s) is part of every container start — that's the cost
   of the stronger isolation. See docs/ACCEPTANCE.md for full start-time
   breakdowns and the ongoing start-latency optimization (issue #9). It is also
   what the auto-stop/wake trade is priced against: a woken environment costs
   that boot plus WordPress's first-request warmup, which is why the waking page
   refreshes rather than blocking the request.
5. **Idle-stop can't see every kind of use** — see the table above. The one
   remaining blind spot is a direct hit on a **site's** published
   `127.0.0.1:<port>`, which is why sites stay opt-in; an environment's port is
   the proxy's, so nothing about an environment is invisible. Nothing is stopped
   while the lifecycle has an action in flight for the instance or while a wake is
   in progress.
6. **The idle clock is per-proxy-process and in memory.** "When did I first see
   this running" is an observation, not a stored fact, so restarting the app or
   the headless proxy — or a certificate re-issue, which reloads the listener —
   reseeds every clock, and nothing can be stopped for at least one full timeout
   afterwards. An instance started while no proxy was running is first seen when
   one next comes up, and gets a fresh window rather than an immediate stop. The
   persisted `lastActivityAt` stamps do survive restarts; only the
   first-seen-running observation doesn't. Erring toward "leave it running" is
   the intended bias for a memory optimisation.
7. **IPs are dynamic**: every container start gets a fresh IP on the
   `192.168.64.0/24` bridge. The app re-discovers them on every start —
   anything you hardcode against a container IP will break on restart. Use
   the published localhost ports or `<slug>.localhost` names instead.
8. **Ports**: each site publishes on `127.0.0.1:<port>` (8881+). A branch
   environment's port on the same range is bound by the reverse proxy instead of
   by the container, so its URL only answers while a proxy is running. Localhost
   only either way — other devices on your network can't reach sites or
   environments directly. LAN sharing would need an explicit opt-in feature.

## Inspecting usage yourself

```bash
wp-container idle <slug>     # the auto-stop timeout in force for one instance
container ls                 # running containers + configured CPU/RAM caps
container stats              # live resource usage per container
ps axo rss,comm | grep Virtualization   # real host memory per VM
```
