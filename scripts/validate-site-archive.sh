#!/usr/bin/env bash
#
# validate-site-archive.sh
#
# Proves the site export/import pipeline (SiteArchiveService +
# `wp-container export` / `wp-container import`) end to end against the
# built CLI binary and real containers on this machine.
#
# Creates a disposable single site, exports it, imports the archive as a
# second site, and checks the copy's content, URLs, login, and HTTP response.
# Repeats the round trip for a subdirectory multisite network, then checks
# that a corrupt archive is refused without creating a site. No site gets a
# custom domain, so /etc/hosts is never touched. Always deletes the
# disposable sites (containers + folders) on exit.
#
# Usage: ./validate-site-archive.sh [--keep-sites]
#   --keep-sites   Do not delete the disposable sites on exit (for debugging).

set -euo pipefail

# ----------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${WPC_BIN:-$REPO_ROOT/build/Build/Products/Debug/wp-container}"
SLUG_A="wpcarchive-a"
SLUG_B="wpcarchive-b"
SLUG_MS="wpcarchive-ms"
SLUG_MS_B="wpcarchive-ms-b"
ALL_SLUGS=("$SLUG_A" "$SLUG_B" "$SLUG_MS" "$SLUG_MS_B")
SLUG_PREFIX="wpcarchive-"
POST_TITLE="Archive Probe"

TMP_ROOT="${TMPDIR:-/tmp}"
TMP="${TMP_ROOT%/}/wp-container-validate-archive-$$"

KEEP_SITES=0
[[ "${1:-}" == "--keep-sites" ]] && KEEP_SITES=1

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
  # prints ONLY its stdout.
  local site="$1"; shift
  "$BIN" wp "$site" -- "$@" 2>/dev/null
}

json_field() {
  # json_field <key path, dot separated>  — reads one field from JSON on stdin.
  python3 -c "
import json, sys
value = json.load(sys.stdin)
for key in sys.argv[1].split('.'):
    value = value[key]
print(value)
" "$1"
}

site_slugs() {
  # Prints every site slug in the store, one per line.
  "$BIN" list --json 2>/dev/null | python3 -c "
import json, sys
for site in json.load(sys.stdin)['sites']:
    print(site['slug'])
"
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

replacement_count() {
  # replacement_count <site> <search>  — the number of matches a dry-run
  # search-replace finds across all tables.
  local out
  out=$(wp_out "$1" search-replace "$2" x --all-tables --dry-run || true)
  echo "$out" | sed -nE 's/.*Success: ([0-9]+) replacements? to be made.*/\1/p' | tail -n 1
}

assert_no_staging() {
  # assert_no_staging <site folder>  — the export leaves no .wpc-export behind.
  local folder="$1"
  if [[ ! -e "$folder/.wpc-export" && ! -e "$folder/wordpress/.wpc-export" ]]; then
    pass "no .wpc-export folder left under $folder or its wordpress/"
  else
    fail ".wpc-export left behind under $folder"
  fi
}

assert_zip_has_dump() {
  # assert_zip_has_dump <zip>  — the archive holds the container-written dump.
  local zip="$1"
  local tables
  tables=$(unzip -p "$zip" database.sql 2>/dev/null | grep -c "CREATE TABLE" || true)
  if [[ "${tables:-0}" -gt 0 ]]; then
    pass "archive holds database.sql written by the wp-cli container ($tables tables)"
  else
    fail "archive has no usable database.sql"
  fi
}

assert_round_trip() {
  # assert_round_trip <dest slug> <dest url> <source url> <source local url>
  local slug="$1" url="$2" src_url="$3" src_local="$4"

  local home
  home=$(wp_out "$slug" option get home)
  if [[ "$home" == "$url" ]]; then
    pass "$slug home is its own URL ($home)"
  else
    fail "$slug home is '$home', expected '$url'"
  fi

  local posts
  posts=$(wp_out "$slug" post list --title="$POST_TITLE" --format=count)
  if [[ "$posts" == "1" ]]; then
    pass "$slug has the '$POST_TITLE' post"
  else
    fail "$slug has $posts '$POST_TITLE' posts, expected 1"
  fi

  local count
  count=$(replacement_count "$slug" "$src_url")
  if [[ "$count" == "0" ]]; then
    pass "$slug database has no reference to $src_url"
  else
    fail "$slug database still references $src_url ($count matches)"
  fi
  if [[ "$src_local" != "$src_url" ]]; then
    count=$(replacement_count "$slug" "$src_local")
    if [[ "$count" == "0" ]]; then
      pass "$slug database has no reference to $src_local"
    else
      fail "$slug database still references $src_local ($count matches)"
    fi
  fi

  if tries=$(wait_for_http "$url" 60); then
    pass "$slug serves HTTP 200 at $url (${tries}s)"
  else
    fail "$slug never served HTTP 200 at $url"
  fi

  if "$BIN" wp "$slug" -- user check-password admin password >/dev/null 2>&1; then
    pass "$slug keeps the admin/password login"
  else
    fail "$slug admin/password login check failed"
  fi
}

create_and_start() {
  # create_and_start <slug> [create args...]  — prints the site's create JSON.
  local slug="$1"; shift
  local created
  created=$("$BIN" create "$slug" "$@" --json)
  "$BIN" start "$slug" --json >/dev/null
  echo "$created"
}

cleanup() {
  local ec=$?
  step "Cleanup"
  if [[ "$KEEP_SITES" -eq 1 ]]; then
    info "Kept sites (--keep-sites): ${ALL_SLUGS[*]}"
  else
    local slug
    for slug in "${ALL_SLUGS[@]}"; do
      "$BIN" delete "$slug" >/dev/null 2>&1 || true
    done
    # A site this run created under another wpcarchive- slug (e.g. a `-2` suffix).
    for slug in $(site_slugs | grep "^$SLUG_PREFIX" || true); do
      "$BIN" delete "$slug" >/dev/null 2>&1 || true
    done
    info "Deleted disposable sites (containers + folders)"
  fi
  rm -rf "$TMP"
  echo
  echo "==================================================================="
  echo "RESULTS: $PASS_COUNT passed, $FAIL_COUNT failed"
  echo "==================================================================="
  if [[ "$ec" -eq 0 && "$FAIL_COUNT" -eq 0 ]]; then
    echo "ALL CHECKS PASSED"
  else
    [[ "$ec" -eq 0 ]] && ec=1
  fi
  exit "$ec"
}

# ----------------------------------------------------------------------------
# 1. Sanity
# ----------------------------------------------------------------------------
step "1. Sanity"
if [[ -x "$BIN" ]]; then pass "wp-container CLI present at $BIN"; else fail "CLI binary missing — run make build-cli first"; exit 1; fi
if /usr/local/bin/container system status >/dev/null 2>&1; then pass "container system service running"; else fail "container system service not running"; exit 1; fi

EXISTING=$(site_slugs | grep "^$SLUG_PREFIX" || true)
if [[ -z "$EXISTING" ]]; then
  pass "no $SLUG_PREFIX* site exists yet"
else
  fail "sites already exist: $(echo "$EXISTING" | tr '\n' ' ')— delete them first"
  exit 1
fi
for slug in "${ALL_SLUGS[@]}"; do
  if [[ -e "$HOME/WP Container Sites/$slug" ]]; then
    fail "folder $HOME/WP Container Sites/$slug exists — remove it first"
    exit 1
  fi
done
pass "no leftover site folders for the disposable slugs"

trap cleanup EXIT
mkdir -p "$TMP"

# ----------------------------------------------------------------------------
# 2. Single site: create, seed, export
# ----------------------------------------------------------------------------
step "2. Create + seed '$SLUG_A', then export it"
A_JSON=$(create_and_start "$SLUG_A")
A_URL=$(echo "$A_JSON" | json_field url)
A_PATH=$(echo "$A_JSON" | json_field path)
A_LOCAL="http://127.0.0.1:$(echo "$A_JSON" | json_field port)"
pass "created + started $SLUG_A ($A_URL)"

wp_out "$SLUG_A" post create --post_title="$POST_TITLE" --post_status=publish >/dev/null
pass "seeded the '$POST_TITLE' post"
mkdir -p "$A_PATH/wordpress/wp-content/plugins/probe/node_modules" "$A_PATH/wordpress/wp-content/plugins/probe/.git"
echo "module.exports = 1;" >"$A_PATH/wordpress/wp-content/plugins/probe/node_modules/x.js"
echo "ref: refs/heads/main" >"$A_PATH/wordpress/wp-content/plugins/probe/.git/HEAD"
echo "<?php // Probe plugin." >"$A_PATH/wordpress/wp-content/plugins/probe/probe.php"
pass "added probe plugin with node_modules/ and .git/"

EXPORT_OUT=$("$BIN" export "$SLUG_A" -o "$TMP/a.zip")
echo "$EXPORT_OUT"
if [[ -f "$TMP/a.zip" ]] && echo "$EXPORT_OUT" | grep -q "^Exported $SLUG_A to $TMP/a.zip ("; then
  pass "export wrote $TMP/a.zip and reported it"
else
  fail "export did not write or report $TMP/a.zip"
  exit 1
fi

ENTRIES=$(zipinfo -1 "$TMP/a.zip")
if echo "$ENTRIES" | grep -qE '(^|/)node_modules(/|$)|(^|/)\.git(/|$)|\.wpc-'; then
  fail "archive contains excluded entries: $(echo "$ENTRIES" | grep -E '(^|/)node_modules(/|$)|(^|/)\.git(/|$)|\.wpc-' | head -n 3 | tr '\n' ' ')"
else
  pass "archive has no node_modules, .git, or .wpc- entries"
fi
if echo "$ENTRIES" | grep -qx "wordpress/wp-content/plugins/probe/probe.php"; then
  pass "archive keeps the probe plugin's own files"
else
  fail "archive is missing wordpress/wp-content/plugins/probe/probe.php"
fi
assert_zip_has_dump "$TMP/a.zip"
assert_no_staging "$A_PATH"

set +e
AGAIN_ERR=$("$BIN" export "$SLUG_A" -o "$TMP/a.zip" --json 2>&1 1>/dev/null)
AGAIN_EXIT=$?
set -e
if [[ "$AGAIN_EXIT" -ne 0 ]] && [[ "$(echo "$AGAIN_ERR" | json_field error)" == "output_exists" ]]; then
  pass "second export without --force fails with output_exists"
else
  fail "second export without --force did not fail with output_exists (exit $AGAIN_EXIT: $AGAIN_ERR)"
fi

FORCE_JSON=$("$BIN" export "$SLUG_A" -o "$TMP/a.zip" --force --json)
if [[ "$(echo "$FORCE_JSON" | json_field manifest.source.slug)" == "$SLUG_A" ]]; then
  pass "export --force --json overwrites and reports the manifest"
else
  fail "export --force --json output unexpected: $FORCE_JSON"
fi

# ----------------------------------------------------------------------------
# 3. Single site: import as '$SLUG_B'
# ----------------------------------------------------------------------------
step "3. Import the archive as '$SLUG_B'"
set +e
BAD_DOMAIN_ERR=$("$BIN" import "$TMP/a.zip" --name "$SLUG_B" --domain x.local --no-domain --json 2>&1 1>/dev/null)
BAD_DOMAIN_EXIT=$?
set -e
if [[ "$BAD_DOMAIN_EXIT" -ne 0 ]] && [[ "$(echo "$BAD_DOMAIN_ERR" | json_field error)" == "bad_args" ]]; then
  pass "--domain with --no-domain fails with bad_args"
else
  fail "--domain with --no-domain did not fail with bad_args (exit $BAD_DOMAIN_EXIT: $BAD_DOMAIN_ERR)"
fi

B_JSON=$("$BIN" import "$TMP/a.zip" --name "$SLUG_B" --no-domain --json)
echo "$B_JSON"
B_URL=$(echo "$B_JSON" | json_field site.url)
if [[ "$(echo "$B_JSON" | json_field site.slug)" == "$SLUG_B" ]]; then
  pass "imported as $SLUG_B ($B_URL)"
else
  fail "import created slug $(echo "$B_JSON" | json_field site.slug), expected $SLUG_B"
  exit 1
fi
assert_round_trip "$SLUG_B" "$B_URL" "$A_URL" "$A_LOCAL"

# ----------------------------------------------------------------------------
# 4. Multisite: create, seed, export, import as '$SLUG_MS_B'
# ----------------------------------------------------------------------------
step "4. Multisite round trip: '$SLUG_MS' -> '$SLUG_MS_B'"
MS_JSON=$(create_and_start "$SLUG_MS" --multisite subdirectory)
MS_URL=$(echo "$MS_JSON" | json_field url)
MS_PATH=$(echo "$MS_JSON" | json_field path)
MS_LOCAL="http://127.0.0.1:$(echo "$MS_JSON" | json_field port)"
pass "created + started multisite $SLUG_MS ($MS_URL)"
wp_out "$SLUG_MS" post create --post_title="$POST_TITLE" --post_status=publish >/dev/null
pass "seeded the '$POST_TITLE' post"

"$BIN" export "$SLUG_MS" -o "$TMP/ms.zip"
if [[ -f "$TMP/ms.zip" ]]; then pass "exported $SLUG_MS"; else fail "multisite export wrote no archive"; exit 1; fi
assert_zip_has_dump "$TMP/ms.zip"
assert_no_staging "$MS_PATH"

MS_B_JSON=$("$BIN" import "$TMP/ms.zip" --name "$SLUG_MS_B" --no-domain --json)
echo "$MS_B_JSON"
MS_B_URL=$(echo "$MS_B_JSON" | json_field site.url)
if [[ "$(echo "$MS_B_JSON" | json_field site.slug)" == "$SLUG_MS_B" ]]; then
  pass "imported as $SLUG_MS_B ($MS_B_URL)"
else
  fail "import created slug $(echo "$MS_B_JSON" | json_field site.slug), expected $SLUG_MS_B"
  exit 1
fi
assert_round_trip "$SLUG_MS_B" "$MS_B_URL" "$MS_URL" "$MS_LOCAL"

SITE_URLS=$(wp_out "$SLUG_MS_B" site list --field=url)
echo "$SITE_URLS"
if [[ -n "$SITE_URLS" ]] && ! echo "$SITE_URLS" | grep -qv "^$MS_B_URL/"; then
  pass "every network site URL is under $MS_B_URL"
else
  fail "network site URLs are not all under $MS_B_URL"
fi

MS_B_AUTHORITY=$(python3 -c "import sys, urllib.parse; print(urllib.parse.urlsplit(sys.argv[1]).netloc)" "$MS_B_URL")
DOMAIN_CURRENT=$(wp_out "$SLUG_MS_B" config get DOMAIN_CURRENT_SITE)
if [[ "$DOMAIN_CURRENT" == "$MS_B_AUTHORITY" ]]; then
  pass "DOMAIN_CURRENT_SITE is $MS_B_AUTHORITY"
else
  fail "DOMAIN_CURRENT_SITE is '$DOMAIN_CURRENT', expected '$MS_B_AUTHORITY'"
fi

# ----------------------------------------------------------------------------
# 5. Corrupt archive
# ----------------------------------------------------------------------------
step "5. A corrupt archive is refused without creating a site"
head -c 100 "$TMP/a.zip" >"$TMP/bad.zip"
BEFORE=$(site_slugs | sort)
set +e
BAD_ERR=$("$BIN" import "$TMP/bad.zip" --name "$SLUG_B" --no-domain --json 2>&1 1>/dev/null)
BAD_EXIT=$?
set -e
echo "$BAD_ERR"
if [[ "$BAD_EXIT" -ne 0 ]] && [[ "$(echo "$BAD_ERR" | json_field error)" == "not_a_wpc_export" ]]; then
  pass "corrupt archive import fails with not_a_wpc_export"
else
  fail "corrupt archive import did not fail with not_a_wpc_export (exit $BAD_EXIT)"
fi
AFTER=$(site_slugs | sort)
if [[ "$BEFORE" == "$AFTER" ]]; then
  pass "no site was added by the failed import"
else
  fail "the failed import changed the site list: $(diff <(echo "$BEFORE") <(echo "$AFTER") | tr '\n' ' ')"
fi

echo
echo "Script completed. See RESULTS summary below (printed by cleanup trap)."
