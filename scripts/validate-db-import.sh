#!/usr/bin/env bash
#
# validate-db-import.sh
#
# Empirically proves the Database Importer pipeline (PLAN.md §2m:
# DatabaseImportService + `wp-container db import` + MCP `db_import`) end to
# end against the built CLI binary and real containers on this machine.
# Mirrors the style/structure of scripts/validate-container-workflow.sh.
#
# Creates a disposable site, imports a synthetic "production" dump into it
# (crafted from the site's own fresh export, so every pipeline stage — URL
# migration, scrub, media, admin, rollback — has real work to do), asserts
# the result, then does the same for a deliberately corrupted dump (rollback
# path) and a couple of fast argument-validation cases. Always cleans up the
# disposable site (containers + folder) on exit.
#
# Usage: ./validate-db-import.sh [--keep-site]
#   --keep-site   Do not delete the disposable site on exit (for debugging).

set -euo pipefail

# ----------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${WPC_BIN:-$REPO_ROOT/build/Build/Products/Debug/wp-container}"
SLUG="wpc-dbimport-test"
PROD_URL="https://staging.example-prod.com"
ALLOWED_DOMAIN="keepme.com"

SCRATCH_ROOT="${TMPDIR:-/tmp}/wp-container-validate-dbimport-$$"

KEEP_SITE=0
[[ "${1:-}" == "--keep-site" ]] && KEEP_SITE=1

PASS_COUNT=0
FAIL_COUNT=0

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
pass() { echo "[PASS] $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "[FAIL] $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
info() { echo "[INFO] $*"; }
step() { echo; echo "=== $* ==="; }

wp_out() {
  # wp_out <site> <wp-cli args...>  — runs a one-shot wp-cli command and
  # prints ONLY its stdout (the container-pull progress noise goes to
  # stderr, kept out of assertions).
  local site="$1"; shift
  "$BIN" wp "$site" -- "$@" 2>/dev/null
}

wait_for_http() {
  local url="$1" tries="${2:-90}"
  for ((i = 1; i <= tries; i++)); do
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000")
    if [[ "$code" == "200" ]]; then
      echo "$i"
      return 0
    fi
    sleep 1
  done
  return 1
}

STORE_JSON="$HOME/Library/Application Support/WPContainer/sites.json"

cleanup() {
  local ec=$?
  step "Cleanup"
  if [[ "$KEEP_SITE" -eq 1 ]]; then
    info "Kept site '$SLUG' (--keep-site)"
  else
    "$BIN" delete "$SLUG" >/dev/null 2>&1 || true
    info "Deleted site '$SLUG' (containers + folder)"
  fi
  rm -rf "$SCRATCH_ROOT"
  echo
  echo "==================================================================="
  echo "RESULTS: $PASS_COUNT passed, $FAIL_COUNT failed"
  echo "==================================================================="
  exit "$ec"
}
trap cleanup EXIT

mkdir -p "$SCRATCH_ROOT"

# ----------------------------------------------------------------------------
# 1. Sanity
# ----------------------------------------------------------------------------
step "1. Sanity"
if [[ -x "$BIN" ]]; then pass "wp-container CLI present at $BIN"; else fail "CLI binary missing — run make build first"; exit 1; fi
if /usr/local/bin/container system status >/dev/null 2>&1; then pass "container system service running"; else fail "container system service not running"; exit 1; fi

if "$BIN" list --json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
slugs = [s['slug'] for s in d['sites']] + [e['envSlug'] for e in d['envs']]
sys.exit(1 if '$SLUG' in slugs else 0)
"; then
  pass "slug '$SLUG' is free"
else
  fail "slug '$SLUG' already exists — pick a different slug or remove it first"
  exit 1
fi

# ----------------------------------------------------------------------------
# 2. Create + start the disposable site
# ----------------------------------------------------------------------------
step "2. Create + start disposable site '$SLUG'"
CREATE_JSON=$("$BIN" create "$SLUG" --json)
echo "$CREATE_JSON"
SITE_URL=$(echo "$CREATE_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['url'])")
pass "created site '$SLUG' (url: $SITE_URL)"

T_START=$(date +%s)
"$BIN" start "$SLUG" --json >/dev/null
T_STARTED=$(date +%s)
pass "site started + auto-provisioned in $((T_STARTED - T_START))s"

if tries=$(wait_for_http "$SITE_URL" 60); then
  pass "site responds HTTP 200 after ${tries}s"
else
  fail "site never responded on $SITE_URL"
  exit 1
fi

# ----------------------------------------------------------------------------
# 3. Craft a synthetic "production" dump from the site's own fresh export
# ----------------------------------------------------------------------------
step "3. Craft a synthetic production dump (different URL, extra users incl. an allowlisted domain, extra comments)"
FRESH_DUMP="$SCRATCH_ROOT/fresh.sql"
PROD_DUMP="$SCRATCH_ROOT/prod.sql"

"$BIN" wp "$SLUG" -- db export - >"$FRESH_DUMP" 2>/dev/null
if [[ -s "$FRESH_DUMP" ]]; then pass "exported fresh dump ($(wc -c <"$FRESH_DUMP") bytes)"; else fail "fresh export is empty"; exit 1; fi

python3 - "$SITE_URL" "$PROD_URL" "$FRESH_DUMP" "$PROD_DUMP" <<'PYEOF'
import sys

local_url, prod_url, src_path, dst_path = sys.argv[1:5]

with open(src_path, "r", encoding="utf-8") as f:
    sql = f.read()

# Simulate a production dump: swap every occurrence of the local URL for a
# fake prod host (options table, GUIDs, hardcoded content links, ...).
sql = sql.replace(local_url, prod_url)

extra_users = """
INSERT INTO `wp_users` (`ID`,`user_login`,`user_pass`,`user_nicename`,`user_email`,`user_url`,`user_registered`,`user_activation_key`,`user_status`,`display_name`) VALUES
(101,'jsmith','$P$Bexampleexampleexampleexampleexam.','jsmith','jane.smith@example-prod.com','','2025-01-01 00:00:00','',0,'Jane Smith'),
(102,'bwayne','$P$Bexampleexampleexampleexampleexam.','bwayne','bruce.wayne@example-prod.com','','2025-01-02 00:00:00','',0,'Bruce Wayne'),
(103,'agencydev','$P$Bexampleexampleexampleexampleexam.','agencydev','dev@keepme.com','','2025-01-03 00:00:00','',0,'Agency Dev');
"""

extra_usermeta = """
INSERT INTO `wp_usermeta` (`umeta_id`,`user_id`,`meta_key`,`meta_value`) VALUES
(9001,101,'first_name','Jane'),
(9002,101,'last_name','Smith'),
(9003,101,'nickname','jsmith'),
(9004,101,'wp_capabilities','a:1:{s:10:\\"subscriber\\";b:1;}'),
(9005,102,'first_name','Bruce'),
(9006,102,'last_name','Wayne'),
(9007,102,'wp_capabilities','a:1:{s:10:\\"subscriber\\";b:1;}'),
(9008,103,'first_name','Agency'),
(9009,103,'last_name','Dev'),
(9010,103,'wp_capabilities','a:1:{s:13:\\"administrator\\";b:1;}');
"""

extra_comments = """
INSERT INTO `wp_comments` (`comment_ID`,`comment_post_ID`,`comment_author`,`comment_author_email`,`comment_author_url`,`comment_author_IP`,`comment_date`,`comment_date_gmt`,`comment_content`,`comment_karma`,`comment_approved`,`comment_agent`,`comment_type`,`comment_parent`,`user_id`) VALUES
(201,1,'Jane Smith','jane.smith@example-prod.com','','203.0.113.5','2025-01-05 10:00:00','2025-01-05 10:00:00','Great post, thanks for sharing!',0,'1','','comment',0,101),
(202,1,'Bruce Wayne','bruce.wayne@example-prod.com','','203.0.113.6','2025-01-06 11:00:00','2025-01-06 11:00:00','Interesting perspective on this.',0,'1','','comment',0,102),
(203,2,'Spam Bot','spammer@example-prod.com','http://spam.example','203.0.113.7','2025-01-07 12:00:00','2025-01-07 12:00:00','Buy cheap watches now!!!',0,'0','','comment',0,0);
"""

update_comment_count = "UPDATE `wp_posts` SET `comment_count` = 2 WHERE `ID` = 1;\n"

marker = "-- Dump completed"
extra = extra_users + extra_usermeta + extra_comments + update_comment_count
if marker in sql:
    idx = sql.index(marker)
    sql = sql[:idx] + extra + sql[idx:]
else:
    sql += extra

with open(dst_path, "w", encoding="utf-8") as f:
    f.write(sql)
PYEOF

if grep -q "$PROD_URL" "$PROD_DUMP" && grep -q "keepme.com" "$PROD_DUMP"; then
  pass "crafted production dump: URL swapped to $PROD_URL, extra users incl. keepme.com, extra comments"
else
  fail "crafted dump missing expected content"
  exit 1
fi

# ----------------------------------------------------------------------------
# 4. Import the production dump
# ----------------------------------------------------------------------------
step "4. wp-container db import (scrub + remote media + local admin)"
T0=$(date +%s)
IMPORT_JSON=$("$BIN" db import "$SLUG" "$PROD_DUMP" \
  --allowed-domains "$ALLOWED_DOMAIN" --media remote --source-url "$PROD_URL" --json)
T1=$(date +%s)
echo "$IMPORT_JSON"
info "import took $((T1 - T0))s"

if echo "$IMPORT_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['sourceURL'] == '$PROD_URL', d
assert d['localURL'] == '$SITE_URL', d
assert d['mediaMode'] == 'remote', d
assert d['adminUser'] == 'admin' and d['adminPassword'] == 'password', d
assert d['usersScrubbed'] >= 2, d
assert d['usersPreserved'] >= 1, d
assert d['commentsRemoved'] >= 3, d
"; then
  pass "import summary JSON has expected shape (source/local URL, media mode, admin, scrub/comment counts)"
else
  fail "import summary JSON did not match expectations"
fi

# --- home/siteurl rewritten to the local URL --------------------------------
HOME_OPT=$(wp_out "$SLUG" option get home)
SITEURL_OPT=$(wp_out "$SLUG" option get siteurl)
if [[ "$HOME_OPT" == "$SITE_URL" && "$SITEURL_OPT" == "$SITE_URL" ]]; then
  pass "home ($HOME_OPT) and siteurl ($SITEURL_OPT) rewritten to the local URL"
else
  fail "home/siteurl not rewritten correctly (home=$HOME_OPT siteurl=$SITEURL_OPT, expected $SITE_URL)"
fi

# --- scrubbed users have @example.com emails; keepme.com user preserved ------
USER_LIST=$(wp_out "$SLUG" user list --fields=user_login,user_email --format=csv)
echo "$USER_LIST"
if echo "$USER_LIST" | grep -q "dev@keepme.com"; then
  pass "allowlisted keepme.com user preserved with original email"
else
  fail "keepme.com user was NOT preserved"
fi
if echo "$USER_LIST" | grep -q "jane.smith@example-prod.com"; then
  fail "jsmith's original email was NOT scrubbed"
else
  pass "jsmith's original email was scrubbed"
fi
if echo "$USER_LIST" | grep -qE "user(101|102)@example\.com"; then
  pass "scrubbed users renamed to user<ID>@example.com"
else
  fail "scrubbed users do not show the expected user<ID>@example.com pattern"
fi

# --- comments emptied --------------------------------------------------------
COMMENT_COUNT=$(wp_out "$SLUG" comment list --format=count)
if [[ "$COMMENT_COUNT" == "0" ]]; then
  pass "comment count is 0 after scrub"
else
  fail "expected 0 comments, got $COMMENT_COUNT"
fi

# --- admin/password login viable ---------------------------------------------
if "$BIN" wp "$SLUG" -- user check-password admin password >/dev/null 2>&1; then
  pass "admin/password login viable (wp user check-password)"
else
  fail "admin/password login check failed"
fi

# --- mu-plugin present --------------------------------------------------------
MUPLUGIN="$HOME/WP Container Sites/$SLUG/wordpress/wp-content/mu-plugins/wpc-remote-media.php"
if [[ -f "$MUPLUGIN" ]] && grep -q "$PROD_URL" "$MUPLUGIN"; then
  pass "remote-media mu-plugin present and templated with the source URL"
else
  fail "remote-media mu-plugin missing or not templated correctly at $MUPLUGIN"
fi

# --- pre-import backup present ------------------------------------------------
BACKUPS_DIR="$HOME/WP Container Sites/$SLUG/.backups"
if compgen -G "$BACKUPS_DIR/pre-import-*.sql" >/dev/null; then
  pass "pre-import safety backup present under .backups/"
else
  fail "no pre-import-*.sql backup found under $BACKUPS_DIR"
fi

# --- staging dir cleaned up ---------------------------------------------------
WPC_IMPORT_DIR="$HOME/WP Container Sites/$SLUG/wordpress/.wpc-import"
if [[ ! -d "$WPC_IMPORT_DIR" ]]; then
  pass ".wpc-import/ staging directory cleaned up"
else
  fail ".wpc-import/ staging directory still present at $WPC_IMPORT_DIR"
fi

# --- lastImportSourceURL persisted on the site record -------------------------
# Not exposed via `list --json` (SiteJSON has no such field) — read the
# persisted store file directly instead of skipping the assertion outright.
if [[ -f "$STORE_JSON" ]]; then
  if python3 -c "
import json, sys
with open('$STORE_JSON') as f:
    d = json.load(f)
site = next((s for s in d['sites'] if s['slug'] == '$SLUG'), None)
sys.exit(0 if site and site.get('lastImportSourceURL') == '$PROD_URL' else 1)
"; then
    pass "lastImportSourceURL persisted on the site record (sites.json; not exposed via list --json)"
  else
    fail "lastImportSourceURL missing/incorrect in $STORE_JSON"
  fi
else
  fail "could not find persisted store at $STORE_JSON to check lastImportSourceURL"
fi

# ----------------------------------------------------------------------------
# 5. Rollback test: deliberately corrupt dump
# ----------------------------------------------------------------------------
step "5. Rollback test: import a deliberately corrupted dump"

# Snapshot state right before the corrupt import so we can prove it's unchanged after.
PRE_HOME=$(wp_out "$SLUG" option get home)
PRE_USERS=$(wp_out "$SLUG" user list --fields=user_login --format=csv)

# A dump with a VALID header (real CREATE TABLE / INSERT statements from a
# real export) followed by raw binary garbage mid-file — simulates a dump
# truncated/corrupted in transfer. wp-cli's `db import` tolerates malformed
# SQL TEXT (logs per-statement errors but still exits 0), but a NUL byte in
# the byte stream trips mysql's own safety check and makes the whole `wp db
# import` invocation exit non-zero — a genuine phase failure worth testing.
CORRUPT_DUMP="$SCRATCH_ROOT/corrupt.sql"
head -c 2000 "$PROD_DUMP" >"$CORRUPT_DUMP"
printf '\x00\x00\x00RANDOM-BINARY-GARBAGE\xff\xfe\x01\x02' >>"$CORRUPT_DUMP"
head -c 2000 /dev/urandom >>"$CORRUPT_DUMP"
info "crafted corrupt dump: $(wc -c <"$CORRUPT_DUMP") bytes (valid header + binary garbage mid-file)"

set +e
CORRUPT_ERR=$("$BIN" db import "$SLUG" "$CORRUPT_DUMP" --media skip --source-url "$PROD_URL" --json 2>&1 1>/dev/null)
CORRUPT_EXIT=$?
set -e
echo "$CORRUPT_ERR"

if [[ "$CORRUPT_EXIT" -ne 0 ]]; then
  pass "corrupt-dump import failed (exit $CORRUPT_EXIT) as expected"
else
  fail "corrupt-dump import unexpectedly succeeded"
fi

if echo "$CORRUPT_ERR" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['error'] == 'import_failed', d
assert d['phase'] == 'importing', d
assert d['rolledBack'] is True, d
"; then
  pass "failure reported as phase=importing, rolledBack=true"
else
  fail "failure JSON did not report phase=importing/rolledBack=true as expected"
fi

if tries=$(wait_for_http "$SITE_URL" 60); then
  pass "site still serves HTTP 200 after rollback (${tries}s)"
else
  fail "site did not serve HTTP 200 after rollback"
fi

POST_HOME=$(wp_out "$SLUG" option get home)
POST_USERS=$(wp_out "$SLUG" user list --fields=user_login --format=csv)
if [[ "$POST_HOME" == "$PRE_HOME" && "$POST_USERS" == "$PRE_USERS" ]]; then
  pass "site content matches pre-corrupt-import state (rollback restored the pre-import backup)"
else
  fail "site content changed after a rolled-back import (home: $PRE_HOME -> $POST_HOME)"
fi

# ----------------------------------------------------------------------------
# 6. Bad-args + unsupported-target fast-fail cases
# ----------------------------------------------------------------------------
step "6. Bad-args + env-rejection fast-fail cases"

set +e
BADARGS_ERR=$("$BIN" db import "$SLUG" "$PROD_DUMP" --media copy --json 2>&1 1>/dev/null)
BADARGS_EXIT=$?
set -e
echo "$BADARGS_ERR"
if [[ "$BADARGS_EXIT" -ne 0 ]] && echo "$BADARGS_ERR" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['error'] == 'bad_args', d
"; then
  pass "--media copy without --media-path fails fast with bad_args"
else
  fail "--media copy without --media-path did not fail with bad_args as expected"
fi

ENV_SLUG=$("$BIN" worktree list --json 2>/dev/null | python3 -c "
import json, sys
envs = json.load(sys.stdin)
print(envs[0]['envSlug'] if envs else '')
")
if [[ -n "$ENV_SLUG" ]]; then
  set +e
  ENV_ERR=$("$BIN" db import "$ENV_SLUG" "$PROD_DUMP" --json 2>&1 1>/dev/null)
  ENV_EXIT=$?
  set -e
  echo "$ENV_ERR"
  if [[ "$ENV_EXIT" -ne 0 ]] && echo "$ENV_ERR" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['error'] == 'unsupported_target', d
"; then
    pass "db import against worktree env '$ENV_SLUG' fails with unsupported_target"
  else
    fail "db import against worktree env '$ENV_SLUG' did not fail with unsupported_target"
  fi
else
  info "SKIPPED: no worktree environment exists on this machine to test env rejection against"
fi

echo
echo "Script completed. See RESULTS summary below (printed by cleanup trap)."
