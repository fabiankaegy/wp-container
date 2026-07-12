# Phase I — Integration & End-to-End Acceptance Report

Driven against the real product (built from source, run from
`build/Build/Products/Debug/{WPContainer.app,wp-container}`) using disposable
test sites prefixed `itest-`. The user's own site (`demo-environment`, group
"Personal") and the running GUI app instance were left untouched throughout —
only read via `list`/`container list` to confirm no interference. All `itest-*`
sites, containers, folders and store entries were deleted before finishing.

## Summary

- **13 / 13** acceptance-script items PASS after fixes (numbered to match the
  acceptance script; the MCP server itself separately exposes 18 tools, all
  verified — see row 6).
- **1 real bug found and fixed**: `wp-container wp <target> -- <wp args>`
  literally passed a stray `--` token to wp-cli, breaking the exact syntax
  documented in the README/PLAN.
- **1 documentation gap found and fixed**: `--json` is swallowed into the
  wp-cli passthrough args if placed after `<target>` (an inherent
  `.captureForPassthrough` limitation in swift-argument-parser) — now called
  out in `wp-container wp --help`.
- **1 architectural gap found and fixed**: the HTTPS local CA's leaf
  certificate SAN list (`~/Library/Application Support/WPContainer/ca/sans.json`)
  only ever grew — deleting a site/env or disabling its HTTPS never pruned its
  hostname from the trusted leaf. Added `CertificateAuthority.removeLeafCoverage(_:)`
  and wired it into `https disable`, site delete, and worktree-env delete (both
  CLI and GUI paths). Verified end-to-end: enabling then disabling HTTPS for a
  fresh test site now removes its hostname from `sans.json` immediately. A
  handful of hostnames from sites deleted *before* this fix landed
  (`itest-alpha.localhost`, `itest-alpha-wt-feature-x.localhost`) remain in the
  SAN set as a harmless, pre-existing artifact — see "Known limitations".
- **3 GUI bugs reported mid-pass (user-visible on the real `demo-environment`
  site), investigated read-only against it, fixed in source:**
  1. **"AI Agent Tools" Settings toggle stuck stale after relaunch/external
     changes — root cause confirmed and fixed.** `IntegrationsCard` cached its
     enabled/disabled state in `@State private var agentToolsOn`, seeded only
     once from `.onAppear`. `MainWindow` mounts the detail pane with
     `SiteDetailView(site: site).id(site.id)` — that `.id()` keys view
     *identity* to the site's UUID only, so `.onAppear` fires exactly once per
     site selection and never again while the same site stays selected, even
     though the `site` value itself keeps getting freshly passed in on every
     render. Any state seeded that way freezes at whatever was true at first
     mount. Fixed by making it a plain computed property (`vm.agentToolsEnabled(site)`,
     recomputed every render) — the same pattern the adjacent, unaffected
     "Trusted HTTPS" toggle already used correctly.
  2. **"Trusted HTTPS" toggle reported showing OFF while its own caption said
     "Serving …" — investigated, could not reproduce in current source.**
     Read through `IntegrationsCard.httpsRow`: both the caption and the
     `Toggle`'s binding read the identical `site.httpsEnabled` value computed
     fresh in the same `body` evaluation, with no separate cached state (unlike
     bug 1) — they cannot diverge from each other given this code. Most likely
     explanation: the user's currently-running app process is a build from
     before this pass (or before an earlier fix already in HEAD) rather than a
     bug in the code as it stands today. No source change made for this
     specific symptom; flagging for the user to re-check once they rebuild
     from HEAD and relaunch.
  3. **Sidebar showing a stale/deleted group until relaunch — investigated,
     defensive fix applied.** `SiteStore` watches `sites.json` with a
     `DispatchSourceFileSystemObject`, re-opening its fd on every `.rename`/
     `.delete` event (every external write is an atomic temp-file+rename, so
     this fires on *every* external mutation). Wrote an isolated repro
     (`SiteStore` + `StorePersistence` linked directly against the built
     `WPContainerKit.swiftmodule`, no app UI involved) that fired a burst of 6
     rapid external writes ending in a group deletion — the watcher actually
     picked up the deletion correctly within 2s in this test, so I could not
     force a deterministic repro of a *lost* watch. However `startWatching()`'s
     `open()` call had no retry path at all (`guard fd >= 0 else { return }`
     silently abandoned the watcher forever on any failure, e.g. a transient
     race), and the app had no independent backstop. Hardened both: `open()`
     failure now retries after 500ms instead of giving up permanently, and
     `AppViewModel`'s existing 5s container-status reconcile loop now also
     calls `store.reload()` — so any store change (including a deleted group)
     surfaces within 5s even if the file-watcher ever misses an event, without
     needing a relaunch.

## Acceptance table

| # | Criterion | Result | Evidence / notes |
|---|---|---|---|
| 1 | `create itest-alpha --json`: folder layout, store entry, dev constants, port ≥8881 | **PASS** | `wordpress/`, `database/`, `wp` shim created; port `8882` (next free after the real site's `8881`); `WP_ENVIRONMENT_TYPE=local` + `WP_DEVELOPMENT_MODE=all` present in `wp-config.php` after first start. Create was near-instant (~0.02s to write the store entry; folder/shim creation is synchronous). |
| 2 | Start → HTTP 200, no install wizard, admin/password works; Stop → containers gone (`--rm`), files persist; Restart → content intact | **PASS** | `curl` → 200; wp-login.php POST → 200; `wp user list` shows `admin`/administrator; created a post (ID 5), `container stop`'d, containers absent from `container list --all`, `wp-content/` still on disk; restarted, post still present alongside the default "Hello world!". First start (incl. provisioning) ≈ **10.9s**. |
| 3 | Worktree create/delete: git repo in `wp-content/plugins/itest-plugin`, descriptor serves, WORKTREE checkout shadows parent, parent untouched, clean deletion | **PASS** | `worktree create` → descriptor JSON, env served 200 on port 8883. Verified true mount-shadowing: edited `MARKER.txt` only inside the worktree checkout — env container immediately reflected the new content (`container exec … cat …` → `MARKER-FEATURE-X-BRANCH`) while the parent container still showed `MARKER-MAIN-BRANCH`. `worktree delete` removed both containers, `.envs/`, `.worktrees/`, and the store entry; `git worktree list` in the plugin repo showed only `main` afterward — no stray dirs left in `wp-content/plugins/`. **Timing: create ≈ 12.7s** (parent was running, so DB clone used the live `wp db export`/import path per PLAN §2b). |
| 4 | `./wp core version` from site root and from `wp-content/plugins/<dir>` (subpath mapping); router binary containerizes inside a site, defers outside, exit codes/piping pass through | **PASS** | Both shim invocations return `7.0.1`; verified true subpath mapping via `wp eval 'echo getcwd();'` from inside the plugin dir → `/var/www/html/wp-content/plugins/itest-plugin`. Router script (reproduced faithfully from `WPCLIShim.routerScript()`, pointed at the built CLI binary since `/usr/local/bin/wp-container` isn't installed in this sandboxed run) correctly containerized when cwd was inside the site and transparently exec'd `/opt/homebrew/bin/wp` when cwd was `/tmp`. Exit codes (`1` for a bad wp-cli subcommand) and pipe output (`wc -l`) passed through correctly. |
| 5 | HTTPS enable/disable round-trip: `curl https://itest-alpha.localhost` (system trust, no `--cacert`) → 200, home/siteurl updated, `list --json` reflects https; disable reverts cleanly; wp-config X-Forwarded-Proto snippet add/remove | **PASS** | The user's own running app instance already owns the port-443 proxy (`https status` → `proxyRunning: true`, `caTrusted: true`) — `https enable` just added a route, no proxy process started by this session. `curl https://itest-alpha.localhost/` → 200 with system trust (no flags); `option get home/siteurl` → `https://itest-alpha.localhost`; `list --json` URL updated. `disable` reverted siteurl/home to `http://127.0.0.1:8882` and removed the injected 4-line X-Forwarded-Proto snippet from the top of `wp-config.php`. **Enable ≈ 1.5s.** Minor cosmetic note: the official `wordpress` Docker image's `wp-config-docker.php` template already ships its *own* X-Forwarded-Proto snippet lower in the file (lines ~129-133) — our injected snippet at the top is functionally redundant but harmless (idempotent same check twice). |
| 6 | MCP stdio: initialize, tools/list (18), call get_site_info / wp_cli / site_health_check / wp_debug_toggle (on→off) / worktree_list | **PASS** | Drove the real `wp-container mcp --site itest-alpha` process over stdio with a small JSON-RPC test harness (newline-delimited framing). `tools/list` → exactly **18** tools matching the README list. All six `tools/call` invocations returned well-formed JSON in the `content[0].text` field, no crashes; `wp_debug_toggle` on then off was verified via a `read_wp_config` call in between showing `WP_DEBUG: true`. |
| 7 | agent-tools enable/re-enable/disable at `--root <plugin repo>`; append-not-clobber AGENTS.md; single block on re-enable; clean disable | **PASS** | Pre-seeded `AGENTS.md` with unrelated content. `enable` appended a single `<!-- BEGIN:wp-container:itest-alpha -->…<!-- END -->` block below it (unrelated content untouched); wrote `.mcp.json`, `.cursor/mcp.json`, `.vscode/mcp.json`, the `wp` shim, and a `.gitignore` block. Re-`enable` left exactly **1** BEGIN marker (`grep -c` → `1`). `disable` removed the block and all generated files, leaving only the original unrelated content in `AGENTS.md`. |
| 8 | Xdebug on/off (derived image, php -m, XDEBUG_CLIENT_HOST); Elasticsearch on/off (green, ELASTICSEARCH_URL) | **PASS** | `xdebug on` built/reused `wpc-wordpress-xdebug:latest`, WP container ran from it, `php -m` listed `Xdebug`, env had `XDEBUG_CLIENT_HOST=192.168.64.1` (host gateway, matching the container's own `ipv4Gateway`). `off` reverted to `docker.io/library/wordpress:latest`, module gone. `elasticsearch on` started `wpc-itest-alpha-es` (`elasticsearch:8.15.0`), cluster health → `"status":"green"`; WP container env had both `ELASTICSEARCH_URL` and `EP_HOST` pointing at the ES container's IP. `off` removed the ES container entirely. Timings: xdebug toggle ≈ 6.7s, elasticsearch toggle ≈ 13.3s. |
| 9 | Multisite subdirectory: `is_multisite()` true, `wp site list` works, `DOMAIN_CURRENT_SITE` includes port | **PASS** | `create itest-net --multisite subdirectory` → started in ≈10.8s; `wp eval 'echo is_multisite();'` → `true`; `wp site list --format=json` → one network site; `wp-config.php` had `MULTISITE=true`, `SUBDOMAIN_INSTALL=false`, `DOMAIN_CURRENT_SITE='127.0.0.1:8883'` (port included, as specced). |
| 10 | `create itest-ver --wp 6.7 --php-version 8.2`: correct image tag, `wp core version` reports 6.7.x | **PASS** | Container image `docker.io/library/wordpress:6.7-php8.2-apache`; `wp core version` → `6.7.2`; `php -v` inside the container confirmed `PHP 8.2.28`. |
| 11 | Groups/CLI: `list --json` shows `group` + envs correctly across all itest sites | **PASS** | `itest-alpha` (created with `--group ITest`) showed `"group": "ITest"`; ungrouped `itest-net`/`itest-ver` correctly omitted the `group` key; the real `demo-environment` still showed `"group": "Personal"`, confirming per-site group scoping doesn't bleed across sites. |
| 12 | Store/concurrency: parallel create+delete, store stays valid; `list` reconciles after an out-of-band `container stop` | **PASS** | Ran `create itest-conc-new` and `delete itest-conc-del` concurrently (backgrounded, `wait`'d both) — `sites.json` remained valid JSON afterward, `itest-conc-del` gone, `itest-conc-new` present with a distinct port (`8886`, no collision with the concurrently-freed `8885`) — the lockfile (`sites.json.lock`) serialized the two writers correctly. Then ran `container stop wpc-itest-net-wp` directly (bypassing the CLI) — the next `list --json` immediately reported `"status": "stopped"` for `itest-net`, confirming live reconciliation against container-list reality rather than stale cached state. |
| 13 | Full teardown of all itest-* sites: containers, store entries, folders gone; report anything left behind | **PASS, with one documented leftover** | All itest sites created across the run (`itest-alpha`, `itest-net`, `itest-ver`, `itest-conc-new`, `itest-conc-del`, `itest-san-test`, plus a couple of throwaway recreate cycles used to retroactively exercise the SAN-cleanup fix — see below) deleted; `sites.json` afterward contains only the real `demo-environment`; `~/WP Container Sites/` contains only `demo-environment/`; no `itest-*` containers remain (`container list --all` shows only the real site's 2 containers, the shared `buildkit` container, and one pre-existing interactive `wordpress:cli` container that predates this session and was not touched). **Left behind, intentionally:** the derived `wpc-wordpress-xdebug:latest` image (shared, per-tag cache — not itest-specific, removing it would defeat its whole purpose of being reused across sites) and 2 stale hostnames (`itest-alpha.localhost`, `itest-alpha-wt-feature-x.localhost`) in `ca/sans.json`, both predating the SAN-cleanup fix below — see "Known limitations". |

## Bugs found and fixed

1. **`wp-container wp <target> -- <args>` broke on the literal `--` separator.**
   `WPCommand.wpArgs` uses `.captureForPassthrough` parsing, which (per
   swift-argument-parser semantics) retains a literal `--` token typed by the
   caller instead of treating it purely as a parser-mode switch. Every
   invocation using the exact syntax documented in the README/PLAN
   (`wp-container wp itest-alpha -- core version`) failed with
   `Error: '--' is not a registered wp command`. **Fix:** strip a single
   leading `"--"` from `wpArgs` before building the wp-cli invocation.
   File: `CLI/WPContainerCLI.swift` (`WPCommand.run()`).
2. **`--json` silently swallowed if placed after `<target>` on `wp-container wp`.**
   Not a code bug — an inherent consequence of `.captureForPassthrough` positional
   parsing (once the parser reaches the passthrough argument, everything after
   it, including `--json`, is captured raw). Documented rather than "fixed",
   since changing the parsing strategy to work around it would risk breaking
   the documented `-- <wp args>` passthrough semantics for wp-cli's own flags.
   **Fix:** added a `discussion:` to `WPCommand`'s `CommandConfiguration` in
   `CLI/WPContainerCLI.swift` telling callers to put `--json` before `<target>`.
3. **HTTPS cert SANs never pruned on disable/delete.** `CertificateAuthority.ensureLeafCovers(_:)`
   in `WPContainerKit/Services/CertificateAuthority.swift` only ever *unions*
   new hostnames into `sans.json` and re-issues the leaf; nothing ever called
   the reverse operation. Practical effect: every site or worktree env that
   was ever live while the HTTPS proxy ran (the proxy scans *all* sites'
   `proxyHosts` every ~3s, per `HTTPSProxy.swift`, regardless of whether HTTPS
   was actually enabled for them) permanently left its `<slug>.localhost`
   hostname in the trusted leaf cert, even after the site was deleted —
   unbounded growth of a locally-trusted cert's SAN list. **Fix:** added
   `CertificateAuthority.removeLeafCoverage(_:)` (subtracts given hosts from
   the current SAN set, clamped to never drop below the `defaultSANs`
   wildcard baseline, re-issuing the leaf only if the set actually shrinks)
   and wired a call to it into: `HTTPSDisable.run()` and both `DeleteCommand`
   branches (site + env) in `CLI/WPContainerCLI.swift`/`CLI/SurfaceCommands.swift`,
   the standalone `WorktreeDelete` command, and the GUI equivalents
   (`AppViewModel.setHTTPS`, `.deleteSite`, `.deleteEnv` in
   `WPContainer/ViewModels/AppViewModel.swift`) for parity. All calls are
   best-effort (`try?`) so a cert re-issue failure never blocks the actual
   disable/delete. **Verified live:** created a fresh `itest-san-test` site,
   enabled HTTPS (hostname appeared in `sans.json`), disabled HTTPS (hostname
   removed from `sans.json` immediately) — see acceptance row 13 for the
   pre-existing-leftover caveat (two hostnames from sites deleted *before*
   this fix was written remain, harmlessly, in the SAN set).
4. **"AI Agent Tools" Settings toggle frozen stale (user-reported, confirmed
   root cause).** `WPContainer/Views/Detail/IntegrationsCard.swift` cached
   enabled/disabled state in `@State private var agentToolsOn`, set exactly
   once via `.onAppear`. Because `MainWindow.swift` mounts the detail pane as
   `SiteDetailView(site: site).id(site.id)`, SwiftUI keys view *identity* to
   the site's UUID only — `.onAppear` fires once per site selection and never
   again while that identity persists, even though `site` (a plain, non-`@State`
   parameter) keeps arriving with fresh values on every re-render. Any state
   seeded only in `.onAppear` freezes at whatever was true at first mount and
   silently ignores every later reality change (an app-launch race against the
   store's async disk load, an external CLI `agent-tools enable/disable` while
   the site stays selected, a reconcile-loop-triggered reload — all of these
   leave `agentToolsOn` stuck). **Fix:** replaced the cached `@State` with a
   plain computed property (`private var agentToolsOn: Bool { vm.agentToolsEnabled(site) }`),
   mirroring the adjacent "Trusted HTTPS" row, which was already correct
   because it never cached at all — it reads `site.httpsEnabled` fresh in
   `body` every render. Also removed the now-invalid manual
   `agentToolsOn = true` optimistic-set in the `.fileImporter` callback (no
   longer needed/possible once it's a computed var).
5. **"Trusted HTTPS" toggle reported showing OFF alongside a caption that said
   "Serving …" — investigated, not reproduced in current source.** Read
   `IntegrationsCard.httpsRow` end to end: the caption and the `Toggle`'s
   `Binding` both read the identical `site.httpsEnabled`, computed fresh in
   the same `body` pass, with no intermediate cached state (unlike bug 4) —
   they structurally cannot disagree with each other under this code. No fix
   applied for this specific report; most likely the user's running app
   process predates this pass (or an earlier fix already on `main`). Flagging
   for a manual recheck once the user relaunches from a build of current HEAD.
6. **Sidebar could show a stale/deleted group until relaunch (user-reported)
   — investigated, hardened defensively.** `SiteStore`'s `DispatchSourceFileSystemObject`
   watcher re-opens its fd on every `.rename`/`.delete` kqueue event, which
   fires on *every* external write (`StorePersistence` always does an atomic
   temp-file+rename). Built an isolated repro directly against the built
   `WPContainerKit.swiftmodule` (a standalone Swift script — `SiteStore` +
   a second `StorePersistence` instance simulating an external writer — see
   `/tmp` scratch `watcher_test.swift`, not part of the repo): fired a burst of
   6 rapid external writes ending in a group deletion. The watcher actually
   picked up the deletion correctly within 2s in this test, so a deterministic
   "lost watch" repro wasn't achieved. However, `startWatching()`'s `open()`
   call had **no retry path** at all — `guard fd >= 0 else { return }` silently
   abandoned the watcher forever on any failure (e.g. a transient race), with
   nothing to ever recover it short of an app relaunch, and there was no
   independent backstop if the watcher ever did wedge. **Fix (defensive, not a
   proven root-cause fix):** `open()` failure now retries after 500ms instead
   of giving up permanently (`WPContainerKit/Services/SiteStore.swift`), and
   `AppViewModel`'s existing 5s container-status reconcile loop now also calls
   `store.reload()` first (`WPContainer/ViewModels/AppViewModel.swift`) — so
   any external store change, including a deleted group, surfaces within 5s
   even if the file-watcher ever misses an event, without needing a relaunch.

## Known limitations (not fixed — documented for follow-up)

- **`/etc/hosts` custom-domain writes still need an admin prompt** (PLAN §2f-bis
  already tracks this as a TODO for a privileged `SMAppService` helper; not
  re-verified in this pass since it needs a real custom domain + admin
  interaction, which is out of scope for a non-interactive acceptance run).
- **GUI-only surfaces deferred to the user**, since a second GUI instance
  must not be launched per the hard rules of this pass: the "New branch
  environment…" sheet, the menu bar extra's inline controls, the Settings →
  Development live-toggle switches, "Open in Terminal"/interactive WP-CLI
  Terminal button, and the "Trust HTTPS certificates…" onboarding button.
  These share the same underlying services already exercised via the CLI/MCP
  paths above (`SiteLifecycle`, `WPConfigService`, `CertificateAuthority`),
  but the SwiftUI wiring itself was not clicked through. Recommend a quick
  manual pass in the running app.
- **wp-config X-Forwarded-Proto duplication** (cosmetic, see acceptance row 5):
  our injected snippet doesn't check whether the official Docker image's own
  equivalent snippet is already present later in the file. Harmless (same
  idempotent condition, twice) but could be deduplicated.

## Timings summary

| Operation | Time |
|---|---|
| `create` (site, unstarted) | ~0.02s |
| First `start` (incl. provisioning) | ~10.9s |
| `worktree create` (parent running, live DB clone path) | ~12.7s |
| `https enable` | ~1.5s |
| `xdebug on` (image already built) | ~6.7s |
| `elasticsearch on` | ~13.3s |
| `create --multisite subdirectory` + `start` | ~10.8s |

## Environment notes

- Built via `make build` (xcodegen + `xcodebuild` for both the `WPContainer`
  and `wp-container` schemes) — **BUILD SUCCEEDED** for both, no
  `install-cli` run (binary invoked directly from
  `build/Build/Products/Debug/wp-container`, per instructions).
- The user's `demo-environment` site and the already-running GUI app instance
  were never stopped, started, or modified — only read via `list --json` /
  `container list` to confirm they were unaffected by the itest-* activity
  running alongside them. The app's own HTTPS proxy (already running,
  port 443) was reused as-is for the HTTPS test rather than starting a second
  proxy process.

---

## Review findings (Phase R — adversarial code review)

Full-codebase adversarial pass across the eight review dimensions. Build stayed
green (`xcodegen && make build`, both schemes) after each fix.

### CONFIRMED + fixed

- **Process safety — no Task-cancellation propagation** (`ProcessRunner.run`).
  The launcher blocked inside a continuation with no way to observe cancellation,
  so a stalled `container image pull`/`run` (or any hung child) could never be
  interrupted, and cancelling a SwiftUI `Task` mid-call leaked the child. This
  also defeated the `Task.checkCancellation()` calls already present in
  `SiteLifecycle`'s readiness loops while blocked in a `cli.run` pull/seed step.
  Fixed by wrapping the launch in `withTaskCancellationHandler`; on cancel the
  child is sent `SIGTERM`, closing its pipes, unblocking the drains, and resuming
  the continuation. (commit `f0254b4`)
- **Injection/robustness — unvalidated wp-config constant name**
  (`WPConfigService.setConstant`). The name was interpolated into
  `define( '<name>', … )` verbatim; the MCP `edit_wp_config` tool takes an
  agent-controlled name, so a stray quote/paren/newline could inject PHP into or
  corrupt `wp-config.php` and white-screen the site. Now rejected unless it is a
  valid PHP identifier (`[A-Za-z_][A-Za-z0-9_]*`). (commit `00e62f4`)

### CONFIRMED sound (investigated, no defect)

- **"Trusted HTTPS toggle OFF after relaunch."** The `httpsRow` toggle binds
  directly to the persisted `site.httpsEnabled` (no `@State` caching), and
  `Site`'s decoder defaults a missing key correctly (`try? … ?? false`) — so the
  displayed state survives relaunch. The residual real risk is the proxy not
  *actually serving* (see stale-pidfile below), which is independent of what the
  toggle shows. Matches the acceptance agent's binding conclusion.
- **Large-output pipe drain** (`ProcessRunner`). stdout/stderr are drained on
  separate threads; Foundation closes the parent write-end after spawn so the
  drains hit EOF. Corroborated by the 13/13 acceptance run over large output.
- **Slug / domain injection surfaces.** `Slug.make` restricts to `[a-z0-9-]`
  and `DomainService.normalize` enforces strict DNS labels, so slug/domain values
  flowing into container args, `/etc/hosts` lines, cert SANs and URLs cannot
  carry spaces/newlines/quotes. `/etc/hosts` writes stay inside the
  `# wp-container` marker block; osascript/`cp` args are shell-quoted.

### PLAUSIBLE (documented, not fixed)

- **Port-allocation TOCTOU (app ↔ CLI, and rapid in-app creation).**
  `PortAllocator.firstFreePort` reads `takenPorts` then the store is written
  later, so two concurrent creators can pick the same port. *Mitigated:* the
  loser fails at `container run` bind time (not silent data loss). *Would prove
  it:* create two sites near-simultaneously from app + CLI and start both — the
  second errors on `-p 127.0.0.1:<port>:80`. *Proper fix:* allocate the port
  inside the `persistence.mutate` closure.
- **Stale pidfile with reused PID** (`ProxyControl.current`). The app never
  `release()`s the proxy pidfile on quit; relaunch relies on the dead PID
  failing `kill(pid,0)` (the normal case). If the OS reused that exact PID for a
  live process, `current()` false-positives → the app skips starting its proxy →
  HTTPS silently not served until the pidfile is cleared. Rare. *Would prove it:*
  hand-write `proxy.pid` with a live unrelated PID and relaunch. *Proper fix:*
  probe that the recorded port is actually accepting connections.
- **Re-entrancy: double-start / rapid toggle spam.** Lifecycle actions spawn
  undeduped detached `Task`s; a fast double Start (or add-on toggle) runs two
  `startContainers`, the second failing on the `--name` collision. Self-heals via
  the 5s reconcile; surfaces a transient error, no corruption. *Proper fix:* an
  in-flight guard keyed by instance id.
- **Proxy: routed-but-stopped site.** When a host maps to a known site whose
  container is down, the upstream connect fails and both sockets are cancelled —
  the client sees a connection reset rather than a friendly 502 (the 502 page is
  only produced for wholly-unmapped hosts).
- **`ContainerCLI.logs` pid-reuse on termination.** `onTermination` SIGTERMs the
  recorded pid even after natural finish; a microsecond-window pid reuse could
  signal an unrelated process. Extremely low probability.
- **Worktree `repoRelPath` container-path traversal** (`SiteRecipe.shadowMount`).
  Only leading/trailing `/` are trimmed, so a `..`-laden rel path would resolve
  outside `/var/www/html` *inside the container*; the host side stays the user's
  own worktree, and rel paths come from real on-disk repo directory names (which
  cannot be literally `..`), so it is not realistically reachable.

### Overall robustness verdict

Solid. The architecture is disciplined: argument-array process invocations
(no shell string interpolation), strict slug/domain sanitization, a
cross-process `flock` + atomic-write store with sound migration defaults, and a
proxy that is deliberately simple. Confirmed defects were narrow and are fixed;
the remainder are low-frequency edge cases that self-heal or fail safe.

### Top 3 to harden next

1. Allocate ports inside the locked `persistence.mutate` (kill the TOCTOU).
2. Make `ProxyControl` liveness a real listen-probe, not just `kill(pid,0)`, and
   `release()` on app termination.
3. Add an in-flight guard for per-instance lifecycle actions to make
   double-start / rapid-toggle a no-op instead of a transient error.
