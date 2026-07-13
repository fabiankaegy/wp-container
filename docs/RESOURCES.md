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

Branch environments (worktree clones) run their **own** db/wp/(es) containers,
so a running env costs the same as its parent site.

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
  is the single most effective lever: **stop sites you're not working on**
  (one click in the menu bar).

### Practical sizing

| Machine RAM | Comfortable concurrently-running sites |
|---|---|
| 16 GB | 1–2 (avoid Elasticsearch on both) |
| 32 GB | 3–5 |
| 64 GB+ | as many as you realistically need |

Rule of thumb: a plain running site settles around **0.5–1.5 GB** of real
host memory; add ~0.7–1 GB for Elasticsearch.

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

1. **No per-site resource knobs in the UI yet** — everything uses the
   `container` CLI defaults (4 CPU / 1 GB). The CLI supports `--cpus`/
   `--memory` per container; exposing this per site is tracked in the issue
   queue.
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
   breakdowns and the ongoing start-latency optimization (issue #9).
5. **IPs are dynamic**: every container start gets a fresh IP on the
   `192.168.64.0/24` bridge. The app re-discovers them on every start —
   anything you hardcode against a container IP will break on restart. Use
   the published localhost ports or `<slug>.localhost` names instead.
6. **Ports**: each site publishes on `127.0.0.1:<port>` (8881+). Localhost
   only — other devices on your network can't reach sites directly (the
   HTTPS proxy also binds locally). LAN sharing would need an explicit
   opt-in feature.

## Inspecting usage yourself

```bash
container ls                 # running containers + configured CPU/RAM caps
container stats              # live resource usage per container
ps axo rss,comm | grep Virtualization   # real host memory per VM
```
