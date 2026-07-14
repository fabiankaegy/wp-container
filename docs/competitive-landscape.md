# Competitive landscape & roadmap input

Two sources, July 2026: (1) a web survey of current local-WP-dev tools,
(2) a Slack audit of real user pain with LocalWP, wp-local-docker, wp-env,
and VIP dev-env. This doc feeds roadmap prioritization; it is not a spec.

## Where WP Container already wins

- **No Docker Desktop** — the single loudest cross-cutting complaint ("updates
  break everything", slow on Macs, people fleeing to OrbStack/Colima). Apple
  `container` sidesteps the whole category. Lead with this in positioning.
- **SSL that just works** — LocalWP's macOS "Trust" button is broken for users
  (Keychain permission failures). Our user-domain CA trust (§2f-bis) needs no
  admin and is Touch-ID friendly.
- **First-class WP-CLI** — LocalWP's shell wp-cli is flaky (socket errors on
  `wp db dump`, `wp i18n make-pot`); ours is one-shot containers on every
  surface (UI/CLI/MCP/shim).
- **Elasticsearch toggle** — manual ES/ElasticPress setup fails for LocalWP
  users; VIP dev-env's bundled ES is repeatedly praised. We have it.
- **Uploads proxy to production media** — explicitly wished for in Slack;
  shipping as part of the database importer (§2m remote-media mu-plugin).
- **Agent plumbing** — MCP tools, worktree branch envs, per-site resource
  limits. No competitor has the combination; Slack shows emerging demand
  (localwp-agent-tools, wp-snapshot-tools MCP threads).

## Validated priority gaps (survey × Slack pain)

1. **Good data locally** — "the biggest friction" (Slack, verbatim). Huge DB
   imports fail in LocalWP (mysqladmin ping timeouts, hand-editing internals);
   wpsnapshots suffers AWS credential pain. The §2m importer addresses the
   core; it must treat multi-GB dumps as first-class (streamed staging,
   file-based backup export, no short timeouts).
2. **Snapshots & rollback** — DDEV `snapshot`, MAMP snapshots, InstaWP
   templates; wp-local-docker's snapshots were the confusing/broken part
   people still wanted. Local zstd DB dump + APFS-clone of files; also the
   substrate for MCP agent checkpoints (`snapshot`/`diff`/`rollback` — a
   transactional try/catch around a site that no competitor offers).
3. **Full-site export/import/clone** — table stakes everywhere (LocalWP zip,
   `.wpress`, Studio import/export). Also the wished-for "migrate off
   wp-local-docker / LocalWP" story: import their archive formats directly.
4. **Editor/IDE config emit** — VIP's `--vscode` flag is the single
   most-praised feature in the audit; LocalWP's Xdebug path-mapping conflicts
   with wp-scaffold's wp-content-rooted `.vscode`. Extend `agent-tools enable`
   to also write a correct Xdebug `launch.json` (mapping `<site>/wordpress` ↔
   `/var/www/html`, works with any workspace root) — cheap, high goodwill.
5. **Redis object cache toggle** — LocalWP users hand-compile the extension
   per PHP version, with build failures. Mirrors our ES toggle: sidecar +
   drop-in + `WP_REDIS_*` env.
6. **Share/tunnel links** — LocalWP Live Links, `ddev share`, Herd/Expose,
   Studio Preview Sites. cloudflared sidecar behind our reverse proxy.
7. **Declarative in-repo config** — `.ddev/`, `.lando.yml`, `.wp-env.json`;
   Slack theme: "standardized paths/config so setup docs just work". A
   detected `wpcontainer.json` (or honoring `.wp-env.json`) the app
   materializes; also the artifact agents author. Env vars without `.env`
   files were explicitly requested — fold per-site env vars into this.
8. **Host-agnostic push/pull** — every competitor syncs only with its captive
   host (WPE/Kinsta/WordPress.com/Pantheon). Generic SSH + WP-CLI-alias
   driver (rsync + db export/import + search-replace), pairing with the
   scrubbing importer for "pull from production".
9. **Unified log/error UX + PHPUnit story** — Herd Pro log viewer; wp-env's
   PHPUnit setup is its #1 complaint (unclear bootstrap, activation
   confusion). A per-site "run PHPUnit in a one-shot container" recipe +
   one filterable log stream (php error log, debug.log, proxy, MariaDB),
   also exposed as MCP `tail_logs`.
10. **Profiling toggle** — DDEV xhprof/XHGui, Herd Pro profiler. Same shape
    as the Xdebug toggle.

## Sleeper differentiators (agent-first, nobody has them)

- **Agent checkpoints**: auto-snapshot before destructive MCP calls,
  `diff_since_snapshot`, `rollback`.
- **PHP/WP version-matrix runs**: clone one site across PHP × WP versions in
  parallel containers, report fatals/deprecations per cell.
- **Verification harness**: headless-browser sidecar + MCP
  `screenshot`/`assert_no_php_errors` so agents prove changes against a
  worktree env end-to-end.

## Competitor capsules (survey, July 2026)

- **LocalWP 9.x** — MagicSync push/pull (WPE/Flywheel), Blueprints, Live
  Links, add-ons (Cloud Backups, Instant Reload, Atlas headless), Adminer,
  Mailpit. Slack pain: slow multisite, broken macOS cert trust, flaky
  shell WP-CLI, large-DB start failures, random php-fpm 502s, one-way
  localhost:PORT trap, Xdebug root conflicts.
- **WordPress Studio** — Playground-based + new native PHP runtime; Studio
  Sync (WordPress.com), free hosted preview sites, embedded AI agent
  (Studio Code), MCP server, `.wpress` import.
- **DevKinsta** — Kinsta pull/push round-trip; otherwise static.
- **Laravel Herd** — native, per-site PHP pinning, Pro profiler/log/mail
  viewers, services (Redis, Meilisearch, MinIO), Expose sharing.
- **MAMP PRO 7** — snapshots (files+DB), MAMP Cloud encrypted backups,
  blueprints, host cloning.
- **wp-env / Playground** — in-repo `.wp-env.json`, zero-Docker Playground
  runtime, Blueprints v2 JSON spec + public gallery (AI-authorable — a
  candidate native template format for us). Slack pain: PHPUnit setup, an
  upstream mariadb image update broke everyone, CI port exposure.
- **DDEV** — snapshots, 176+ add-ons, xhprof/XHGui + Blackfire, DB GUI
  launchers, `ddev share`, in-repo config; owns the pro segment.
- **Lando** — recipes, Pantheon/Acquia pull/push/switch.
- **InstaWP** (cloud) — per-PR ephemeral sites with URL commented on the PR,
  templates, 40+ MCP tools, git auto-deploy.
- **VIP dev-env** — praised: `--vscode`, `--xdebug`, bundled mu-plugins/ES.
  Pain: Docker Desktop breakage, sync sql errors, node version issues.

## Suggested sequence after §2m ships

Snapshots → full-site import/export/clone (incl. LocalWP-zip import as the
migration story) → IDE config emit (small, do anytime) → Redis toggle →
share links → in-repo config → host-agnostic pull.
