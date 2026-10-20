#!/usr/bin/env bash
#
# validate-share.sh
#
# End-to-end proof of site sharing: the password gate, header handling and the
# PHP write handlers that swap the share origin back to the local origin.
# Companion to validate-addons.sh.
#
# A disposable site (itest-share) is shared through a fixture provider whose
# "public URL" is the loopback listener itself, so curl drives the share
# directly. Asserts:
#   - 401 without credentials, 200 with them
#   - `?wc-api` reachable without credentials only after `share --allow '?wc-api'`
#   - X-Robots-Tag: noindex, nofollow on responses
#   - page bodies carry the share origin and not the local host
#   - `/wp-admin` redirects stay on the share origin
#   - posts, options and post meta (including serialized arrays) saved through
#     the share are stored with the local origin
#   - saving Settings > General leaves home/siteurl unchanged
#   - gzip, binary and attachment responses pass through unchanged
#   - direct requests to the local origin are unaffected
#
# Preconditions (checked, never performed):
#   - A proxy host running THIS build serves shares, for example
#       build/Build/Products/Debug/wp-container proxy serve
#     in another terminal, with any older WP Container app quit.
#   - The container system service is running.
#
# Exit codes: 0 all passed, 1 at least one FAIL, 2 precondition not met.
#
# Usage: ./validate-share.sh [--keep-scratch]
#   --keep-scratch   Do not delete the scratch directory on exit (for debugging).
#
# Environment:
#   WPC_BIN   Path to the wp-container CLI
#             (default: build/Build/Products/Debug/wp-container).

set -euo pipefail

# ----------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${WPC_BIN:-${REPO_ROOT}/build/Build/Products/Debug/wp-container}"
SLUG="itest-share"

SCRATCH_ROOT="${TMPDIR:-/tmp}"
SCRATCH_ROOT="${SCRATCH_ROOT%/}/wp-container-validate-share-$$"
SITES_DIR="${SCRATCH_ROOT}/sites"
COOKIES="${SCRATCH_ROOT}/cookies.txt"
FORM_PY="${SCRATCH_ROOT}/form_fields.py"

PROVIDER="wpc-e2e-fixture-$$"
PROVIDERS_DIR="${HOME}/Library/Application Support/WPContainer/share-providers"
PROVIDER_FILE="${PROVIDERS_DIR}/${PROVIDER}"

KEEP_SCRATCH=0
[[ "${1:-}" == "--keep-scratch" ]] && KEEP_SCRATCH=1

PASS_COUNT=0
FAIL_COUNT=0

SITE_CREATED=0
PROVIDER_INSTALLED=0
SHARE_STARTED=0

SITE_DIR=""
WP_DIR=""
LOCAL_ORIGIN=""
LOCAL_HOST=""
LOCAL_SITEURL=""
ORIGIN=""
SHARE_USER=""
SHARE_PASS=""

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
pass() { echo "[PASS] $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "[FAIL] $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
info() { echo "[INFO] $*"; }
step() { echo; echo "=== $* ==="; }

# Runs a wp-cli command in the site; prints stdout only.
wpcli() {
  "$BIN" wp "$SLUG" -- "$@" 2>/dev/null
}

# Authenticated request to the share listener.
share_curl() {
  curl -sS -m 60 -u "${SHARE_USER}:${SHARE_PASS}" "$@"
}

# Prints the HTTP status of a request (000 on a transport error); extra
# arguments go to curl.
http_code() {
  local code
  code="$(curl -s -m 60 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true)"
  printf '%s' "${code:-000}"
}

# Prints the value of response header $2 from the dump file $1, CR stripped.
header_value() {
  awk -v want="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" '
    { sub(/\r$/, "") }
    {
      i = index($0, ":")
      if (i > 0 && tolower(substr($0, 1, i - 1)) == want) {
        v = substr($0, i + 1); sub(/^[ \t]+/, "", v); print v
      }
    }' "$1" | tail -n 1
}

# Compares two strings, reporting PASS/FAIL with the given label.
expect_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label (expected '$expected', got '$actual')"
  fi
}

# Passes when $2 contains $3 as a substring.
expect_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label (missing '$needle' in '${haystack:0:200}')"
  fi
}

# Passes when $2 does not contain $3.
expect_lacks() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label (found '$needle' in '${haystack:0:200}')"
  fi
}

precondition_exit() {
  echo
  echo "[PRECONDITION] $*" >&2
  exit 2
}

# Prints how to start a proxy host for this build, then exits 2.
proxy_hint_exit() {
  cat >&2 <<EOF

[PRECONDITION] The share did not go live: $1

A proxy host running THIS build must be serving. In another terminal run:

  ${BIN} proxy serve

and quit any older WP Container app first (it owns the proxy and answers share
requests with an older build). Then re-run this script.
EOF
  exit 2
}

# Writes the helper that lists a page form's fields as "name<TAB>value" lines.
write_form_helper() {
  cat > "$FORM_PY" <<'PYEOF'
import html
import re
import sys

page = sys.stdin.read()
open_re = sys.argv[1]
exclude = set(sys.argv[2:])

found = re.search(open_re, page)
if not found:
    sys.exit(3)
end = page.find("</form>", found.start())
block = page[found.start():end if end != -1 else len(page)]

attr_re = re.compile(r'([\w:-]+)\s*=\s*(?:"([^"]*)"|\'([^\']*)\')')


def attrs(tag):
    out = {}
    for m in attr_re.finditer(tag):
        value = m.group(2) if m.group(2) is not None else m.group(3)
        out[m.group(1).lower()] = html.unescape(value)
    return out


def has_flag(tag, flag):
    bare = re.sub(r'"[^"]*"|\'[^\']*\'', '""', tag)
    return re.search(r'\b' + flag + r'\b', bare, re.I) is not None


def emit(name, value):
    if not name or name in exclude:
        return
    print(name + "\t" + value.replace("\n", " ").replace("\t", " "))


for tag in re.findall(r'<input\b[^>]*>', block, re.I):
    a = attrs(tag)
    kind = a.get("type", "text").lower()
    if kind in ("submit", "button", "file", "image", "password", "reset"):
        continue
    if has_flag(tag, "disabled"):
        continue
    if kind in ("checkbox", "radio") and not has_flag(tag, "checked"):
        continue
    emit(a.get("name", ""), a.get("value", ""))

for m in re.finditer(r'<select\b([^>]*)>(.*?)</select>', block, re.I | re.S):
    a = attrs(m.group(1))
    chosen = None
    first = None
    for opt in re.findall(r'<option\b[^>]*>', m.group(2), re.I):
        value = attrs(opt).get("value", "")
        if first is None:
            first = value
        if has_flag(opt, "selected"):
            chosen = value
    value = chosen if chosen is not None else (first or "")
    emit(a.get("name", ""), value)
PYEOF
}

# Fills FORM_ARGS with --data-urlencode pairs for the form on the page file $1
# whose opening tag matches the regex $2; remaining arguments are field names
# the caller overrides.
form_args() {
  local page="$1" open_re="$2" key value
  shift 2
  FORM_ARGS=()
  while IFS=$'\t' read -r key value; do
    FORM_ARGS+=(--data-urlencode "${key}=${value}")
  done < <(python3 -I "$FORM_PY" "$open_re" "$@" < "$page" || true)
}

cleanup() {
  local ec=$?
  set +e
  step "Cleanup"
  if [[ "$SHARE_STARTED" -eq 1 ]]; then
    "$BIN" share stop "$SLUG" >/dev/null 2>&1
  fi
  if [[ "$SITE_CREATED" -eq 1 ]]; then
    if "$BIN" delete "$SLUG" --keep-folder >/dev/null 2>&1; then
      info "Deleted site $SLUG"
    else
      echo "[WARN] Could not delete site $SLUG. Remove it manually: $BIN delete $SLUG" >&2
    fi
  fi
  if [[ "$PROVIDER_INSTALLED" -eq 1 ]]; then
    rm -f "$PROVIDER_FILE" && info "Removed fixture provider $PROVIDER"
  fi
  if [[ "$KEEP_SCRATCH" -eq 0 ]]; then
    rm -rf "$SCRATCH_ROOT"
    info "Removed scratch dir $SCRATCH_ROOT"
  else
    info "Kept scratch dir at $SCRATCH_ROOT (--keep-scratch)"
  fi
  if [[ "$ec" -eq 0 && "$FAIL_COUNT" -gt 0 ]]; then
    ec=1
  fi
  echo
  echo "==================================================================="
  echo "RESULTS: $PASS_COUNT passed, $FAIL_COUNT failed"
  echo "==================================================================="
  exit "$ec"
}
trap cleanup EXIT

# Starts or updates the share and sets ORIGIN, SHARE_USER and SHARE_PASS.
# Extra arguments are passed to `share`. Exits 2 when the proxy is not serving.
start_share() {
  local out_file="${SCRATCH_ROOT}/share.json" err_file="${SCRATCH_ROOT}/share.err" state
  SHARE_STARTED=1
  if ! "$BIN" share "$SLUG" --provider "$PROVIDER" --json "$@" > "$out_file" 2> "$err_file"; then
    proxy_hint_exit "$(tr '\n' ' ' < "$err_file")"
  fi
  state="$(jq -r '.state' "$out_file")"
  if [[ "$state" != "live" ]]; then
    proxy_hint_exit "share state is '${state}'"
  fi
  ORIGIN="$(jq -r '.url' "$out_file")"
  ORIGIN="${ORIGIN%/}"
  SHARE_USER="$(jq -r '.username' "$out_file")"
  SHARE_PASS="$(jq -r '.password' "$out_file")"
}

# ----------------------------------------------------------------------------
# 0. Preconditions
# ----------------------------------------------------------------------------
step "0. Preconditions"
[[ -x "$BIN" ]] || precondition_exit "wp-container CLI not found at $BIN (run 'make build' or set WPC_BIN)"
for tool in curl jq python3 gzip cmp; do
  command -v "$tool" >/dev/null 2>&1 || precondition_exit "required tool missing: $tool"
done
if "$BIN" share list --json >/dev/null 2>&1; then
  pass "share list --json succeeds"
else
  precondition_exit "'$BIN share list --json' failed; is the app store readable?"
fi
if ! LIST_JSON="$("$BIN" list --json 2>/dev/null)"; then
  precondition_exit "'$BIN list --json' failed; cannot check for an existing '$SLUG' site"
fi
if printf '%s' "$LIST_JSON" | jq -e --arg slug "$SLUG" '[.. | objects | select(.slug? == $slug)] | length > 0' >/dev/null 2>&1; then
  precondition_exit "a site named '$SLUG' already exists; delete it with '$BIN delete $SLUG' and re-run"
fi
if [[ -e "$PROVIDER_FILE" ]]; then
  precondition_exit "provider file $PROVIDER_FILE already exists; refusing to overwrite it"
fi

rm -rf "$SCRATCH_ROOT"
mkdir -p "$SITES_DIR"
write_form_helper

# ----------------------------------------------------------------------------
# 1. Fixture provider and disposable site
# ----------------------------------------------------------------------------
step "1. Install fixture provider ($PROVIDER)"
mkdir -p "$PROVIDERS_DIR"
cat > "$PROVIDER_FILE" <<'SH'
#!/bin/sh
echo "$WPC_SHARE_UPSTREAM"
exec sleep 3600
SH
chmod +x "$PROVIDER_FILE"
PROVIDER_INSTALLED=1
pass "fixture provider installed"

step "2. Create and start the disposable site ($SLUG)"
CREATE_JSON="$("$BIN" create "$SLUG" --path "$SITES_DIR" --json)" || { fail "site creation failed"; exit 1; }
CREATED_SLUG="$(printf '%s' "$CREATE_JSON" | jq -r '.slug // empty')"
if [[ "$CREATED_SLUG" != "$SLUG" ]]; then
  fail "create returned slug '${CREATED_SLUG}', expected '${SLUG}'; not touching it"
  exit 1
fi
SITE_CREATED=1
SITE_DIR="$(printf '%s' "$CREATE_JSON" | jq -r '.path')"
WP_DIR="${SITE_DIR}/wordpress"
pass "site created at $SITE_DIR"

# The first wp-cli call starts and provisions the site.
if ! LOCAL_ORIGIN="$(wpcli option get home)" || [[ -z "$LOCAL_ORIGIN" ]]; then
  fail "wp-cli could not read the home option; the site did not start or provision ('$BIN wp $SLUG -- option get home' shows the error)"
  exit 1
fi
LOCAL_ORIGIN="${LOCAL_ORIGIN%/}"
LOCAL_SITEURL="$(wpcli option get siteurl || true)"
LOCAL_HOST="${LOCAL_ORIGIN#*://}"
pass "site provisioned; local origin $LOCAL_ORIGIN"

info "waiting for the site to answer on its local origin"
for ((i = 1; i <= 90; i++)); do
  code="$(http_code -k -L "${LOCAL_ORIGIN}/")"
  [[ "$code" == "200" ]] && break
  sleep 1
done
expect_eq "local origin answers 200" "200" "$code"

# Test fixtures: the classic editor keeps the post form scrapeable; the REST
# settings and meta cover option and meta writes; gz, bin and dl exercise the
# response passthrough rules.
mkdir -p "${WP_DIR}/wp-content/mu-plugins"
cat > "${WP_DIR}/wp-content/mu-plugins/wpc-e2e-share.php" <<'PHP'
<?php
/**
 * Plugin Name: WPC share end-to-end fixtures
 * Description: Disposable fixtures used by scripts/validate-share.sh.
 */

add_filter( 'use_block_editor_for_post', '__return_false' );
add_filter( 'use_block_editor_for_post_type', '__return_false' );

if ( isset( $_GET['gz'] ) ) {
	ob_start( 'ob_gzhandler' );
}

add_action(
	'init',
	function () {
		if ( isset( $_GET['bin'] ) ) {
			header( 'Content-Type: application/octet-stream' );
			echo "BIN\x00\x01\xff" . home_url() . "\xfe\x80END";
			exit;
		}

		if ( isset( $_GET['dl'] ) ) {
			header( 'Content-Type: text/plain' );
			header( 'Content-Disposition: attachment; filename="e2e.txt"' );
			echo 'download ' . home_url() . "\n";
			exit;
		}

		register_setting(
			'wpc_e2e',
			'wpc_e2e_opt',
			array(
				'type'         => 'string',
				'show_in_rest' => true,
			)
		);
		register_setting(
			'wpc_e2e',
			'wpc_e2e_opt_arr',
			array(
				'type'         => 'array',
				'show_in_rest' => array(
					'schema' => array(
						'type'  => 'array',
						'items' => array( 'type' => 'string' ),
					),
				),
			)
		);
		register_post_meta(
			'post',
			'wpc_e2e_meta',
			array(
				'type'         => 'string',
				'single'       => true,
				'show_in_rest' => true,
			)
		);
		register_post_meta(
			'post',
			'wpc_e2e_list',
			array(
				'type'         => 'array',
				'single'       => true,
				'show_in_rest' => array(
					'schema' => array(
						'type'  => 'array',
						'items' => array( 'type' => 'string' ),
					),
				),
			)
		);
	}
);
PHP
pass "test mu-plugin written"

# ----------------------------------------------------------------------------
# 3. Share and the password gate
# ----------------------------------------------------------------------------
step "3. Share via the fixture provider"
start_share
pass "share is live at $ORIGIN"
if "$BIN" share list --json | jq -e --arg slug "$SLUG" '.[] | select(.instance == $slug and .state == "live")' >/dev/null 2>&1; then
  pass "share list reports the share as live"
else
  fail "share list does not report the share as live"
fi

step "4. Password gate"
expect_eq "401 without credentials" "401" "$(http_code "${ORIGIN}/")"
expect_eq "200 with credentials" "200" "$(http_code -u "${SHARE_USER}:${SHARE_PASS}" "${ORIGIN}/")"
expect_eq "401 for ?wc-api before --allow" "401" "$(http_code "${ORIGIN}/?wc-api=probe")"

step "5. Allow exception: ?wc-api"
start_share --allow '?wc-api'
ALLOW_JSON="$(jq -c '.allow' "${SCRATCH_ROOT}/share.json")"
expect_contains "share --allow echoes the exception" "$ALLOW_JSON" "wc-api"
wc_code="$(http_code "${ORIGIN}/?wc-api=probe")"
if [[ "$wc_code" != "401" && "$wc_code" != "000" ]]; then
  pass "?wc-api=probe reachable without credentials after --allow (HTTP $wc_code)"
else
  fail "?wc-api=probe not reachable without credentials after --allow (HTTP $wc_code)"
fi
expect_eq "401 for / without credentials after --allow" "401" "$(http_code "${ORIGIN}/")"
expect_eq "401 for ?other=1 without credentials after --allow" "401" "$(http_code "${ORIGIN}/?other=1")"

# ----------------------------------------------------------------------------
# 6. Headers and body rewriting
# ----------------------------------------------------------------------------
step "6. Headers and body rewriting"
share_curl -D "${SCRATCH_ROOT}/home.hdr" -o "${SCRATCH_ROOT}/home.html" "${ORIGIN}/"
robots="$(header_value "${SCRATCH_ROOT}/home.hdr" "X-Robots-Tag")"
expect_eq "X-Robots-Tag on a 200 response" "noindex, nofollow" "$robots"
curl -s -m 60 -D "${SCRATCH_ROOT}/401.hdr" -o /dev/null "${ORIGIN}/" || true
robots_401="$(header_value "${SCRATCH_ROOT}/401.hdr" "X-Robots-Tag")"
info "X-Robots-Tag on the 401 response: '${robots_401}'"

HOME_BODY="$(cat "${SCRATCH_ROOT}/home.html")"
expect_contains "/ body contains the share origin" "$HOME_BODY" "$ORIGIN"
expect_lacks "/ body does not contain the local host ($LOCAL_HOST)" "$HOME_BODY" "$LOCAL_HOST"

share_curl -D "${SCRATCH_ROOT}/admin.hdr" -o /dev/null "${ORIGIN}/wp-admin"
admin_location="$(header_value "${SCRATCH_ROOT}/admin.hdr" "Location")"
if [[ "$admin_location" == "${ORIGIN}/"* ]]; then
  pass "GET /wp-admin redirects to the share origin ($admin_location)"
else
  fail "GET /wp-admin Location is not on the share origin (got '$admin_location')"
fi

# ----------------------------------------------------------------------------
# 7. Login and writes through the share
# ----------------------------------------------------------------------------
step "7. Log in through the share"
: > "$COOKIES"
share_curl -b "$COOKIES" -c "$COOKIES" -o /dev/null "${ORIGIN}/wp-login.php"
share_curl -b "$COOKIES" -c "$COOKIES" -o /dev/null \
  --data-urlencode "log=admin" \
  --data-urlencode "pwd=password" \
  --data-urlencode "wp-submit=Log In" \
  --data-urlencode "redirect_to=${ORIGIN}/wp-admin/" \
  --data-urlencode "testcookie=1" \
  "${ORIGIN}/wp-login.php"
if grep -q 'wordpress_logged_in' "$COOKIES"; then
  pass "logged in through the share (wordpress_logged_in cookie set)"
  LOGGED_IN=1
else
  fail "login through the share did not set a wordpress_logged_in cookie"
  LOGGED_IN=0
fi

POST_ID=""
if [[ "$LOGGED_IN" -eq 1 ]]; then
  step "8. Create a post through wp-admin/post.php"
  share_curl -b "$COOKIES" -c "$COOKIES" -o "${SCRATCH_ROOT}/post-new.html" "${ORIGIN}/wp-admin/post-new.php"
  form_args "${SCRATCH_ROOT}/post-new.html" '<form[^>]*\bid="post"' post_title content post_status
  if [[ "${#FORM_ARGS[@]}" -eq 0 ]]; then
    fail "could not read the post form from post-new.php"
  else
    share_curl -b "$COOKIES" -c "$COOKIES" -o /dev/null \
      "${FORM_ARGS[@]}" \
      --data-urlencode "post_title=Share E2E Post" \
      --data-urlencode "content=<p>Read more at ${ORIGIN}/sample-page/</p>" \
      --data-urlencode "post_status=publish" \
      --data-urlencode "publish=Publish" \
      "${ORIGIN}/wp-admin/post.php"
    POST_ID="$(wpcli post list --post_type=post --post_status=publish --title="Share E2E Post" --field=ID | head -n 1 || true)"
    if [[ -z "$POST_ID" ]]; then
      fail "post saved through the share was not found"
    else
      pass "post $POST_ID created through the share"
      stored="$(wpcli post get "$POST_ID" --field=post_content || true)"
      expect_contains "post_content stores the local origin" "$stored" "${LOCAL_ORIGIN}/sample-page/"
      expect_lacks "post_content has no share origin" "$stored" "$ORIGIN"
    fi
  fi

  step "9. Option and post meta through the REST API"
  NONCE="$(share_curl -b "$COOKIES" -c "$COOKIES" "${ORIGIN}/wp-admin/admin-ajax.php?action=rest-nonce")"
  if [[ -z "$NONCE" || "$NONCE" == "0" || "$NONCE" == "-1" ]]; then
    fail "could not obtain a REST nonce through the share"
  else
    opt_body="$(jq -n --arg a "See ${ORIGIN}/option-page/" --arg b "Item ${ORIGIN}/a/" --arg c "${ORIGIN}/b/?x=1" \
      '{wpc_e2e_opt: $a, wpc_e2e_opt_arr: [$b, $c]}')"
    share_curl -b "$COOKIES" -c "$COOKIES" -o /dev/null -X POST \
      -H "X-WP-Nonce: ${NONCE}" -H 'Content-Type: application/json' \
      -d "$opt_body" "${ORIGIN}/?rest_route=/wp/v2/settings"

    opt="$(wpcli option get wpc_e2e_opt || true)"
    expect_eq "option stores the local origin" "See ${LOCAL_ORIGIN}/option-page/" "$opt"
    opt_arr="$(wpcli option get wpc_e2e_opt_arr --format=json || true)"
    expect_eq "serialized array option: first item local" "Item ${LOCAL_ORIGIN}/a/" "$(printf '%s' "$opt_arr" | jq -r '.[0]')"
    expect_eq "serialized array option: second item local" "${LOCAL_ORIGIN}/b/?x=1" "$(printf '%s' "$opt_arr" | jq -r '.[1]')"
    raw_opt="$(wpcli eval 'global $wpdb; echo $wpdb->get_var( "SELECT option_value FROM {$wpdb->options} WHERE option_name = '"'"'wpc_e2e_opt_arr'"'"'" );' || true)"
    if [[ "$raw_opt" == a:2:* ]]; then
      pass "array option is stored serialized"
      expect_lacks "serialized option has no share origin" "$raw_opt" "$ORIGIN"
    else
      fail "array option is not stored as a serialized array (got '${raw_opt:0:80}')"
    fi

    if [[ -n "$POST_ID" ]]; then
      meta_body="$(jq -n --arg a "Meta ${ORIGIN}/meta/" --arg b "Entry ${ORIGIN}/m1/" --arg c "${ORIGIN}/m2/" \
        '{meta: {wpc_e2e_meta: $a, wpc_e2e_list: [$b, $c]}}')"
      share_curl -b "$COOKIES" -c "$COOKIES" -o /dev/null -X POST \
        -H "X-WP-Nonce: ${NONCE}" -H 'Content-Type: application/json' \
        -d "$meta_body" "${ORIGIN}/?rest_route=/wp/v2/posts/${POST_ID}"

      meta="$(wpcli post meta get "$POST_ID" wpc_e2e_meta || true)"
      expect_eq "post meta stores the local origin" "Meta ${LOCAL_ORIGIN}/meta/" "$meta"
      meta_list="$(wpcli post meta get "$POST_ID" wpc_e2e_list --format=json || true)"
      expect_eq "serialized array meta: first item local" "Entry ${LOCAL_ORIGIN}/m1/" "$(printf '%s' "$meta_list" | jq -r '.[0]')"
      expect_eq "serialized array meta: second item local" "${LOCAL_ORIGIN}/m2/" "$(printf '%s' "$meta_list" | jq -r '.[1]')"
      raw_meta="$(wpcli eval 'global $wpdb; echo $wpdb->get_var( $wpdb->prepare( "SELECT meta_value FROM {$wpdb->postmeta} WHERE post_id = %d AND meta_key = %s", '"$POST_ID"', "wpc_e2e_list" ) );' || true)"
      if [[ "$raw_meta" == a:2:* ]]; then
        pass "array meta is stored serialized"
        expect_lacks "serialized meta has no share origin" "$raw_meta" "$ORIGIN"
      else
        fail "array meta is not stored as a serialized array (got '${raw_meta:0:80}')"
      fi
    else
      info "skipping post meta checks (no post)"
    fi
  fi

  step "10. Settings > General leaves home/siteurl unchanged"
  share_curl -b "$COOKIES" -c "$COOKIES" -o "${SCRATCH_ROOT}/general.html" "${ORIGIN}/wp-admin/options-general.php"
  form_args "${SCRATCH_ROOT}/general.html" '<form[^>]*action="options\.php"' blogname
  if [[ "${#FORM_ARGS[@]}" -eq 0 ]]; then
    fail "could not read the General settings form"
  else
    share_curl -b "$COOKIES" -c "$COOKIES" -o /dev/null \
      "${FORM_ARGS[@]}" \
      --data-urlencode "blogname=ACME Share E2E" \
      --data-urlencode "siteurl=${ORIGIN}" \
      --data-urlencode "home=${ORIGIN}" \
      "${ORIGIN}/wp-admin/options.php"
    expect_eq "blogname saved (the form submit took effect)" "ACME Share E2E" "$(wpcli option get blogname || true)"
    expect_eq "home unchanged" "$LOCAL_ORIGIN" "$(wpcli option get home || true)"
    expect_eq "siteurl unchanged" "$LOCAL_SITEURL" "$(wpcli option get siteurl || true)"
  fi
else
  info "skipping steps 8-10 (not logged in)"
fi

# ----------------------------------------------------------------------------
# 11. Passthrough rules
# ----------------------------------------------------------------------------
step "11. gzip passthrough"
share_curl -H 'Accept-Encoding: gzip' -D "${SCRATCH_ROOT}/gz.hdr" -o "${SCRATCH_ROOT}/gz.bin" "${ORIGIN}/?gz=1"
gz_encoding="$(header_value "${SCRATCH_ROOT}/gz.hdr" "Content-Encoding")"
expect_eq "Content-Encoding: gzip preserved" "gzip" "$gz_encoding"
if gzip -dc "${SCRATCH_ROOT}/gz.bin" > "${SCRATCH_ROOT}/gz.html" 2>/dev/null && grep -qi '</html>' "${SCRATCH_ROOT}/gz.html"; then
  pass "gzip response decompresses to valid HTML"
else
  fail "gzip response does not decompress to valid HTML"
fi

step "12. Binary and attachment passthrough"
# The share path reports its scheme to PHP; direct requests carry the same
# scheme hint when the local origin is https so both responses embed an
# identical home URL.
DIRECT_PROTO=()
if [[ "$LOCAL_ORIGIN" == https://* ]]; then
  DIRECT_PROTO=(-H 'X-Forwarded-Proto: https')
fi
share_curl -D "${SCRATCH_ROOT}/bin.hdr" -o "${SCRATCH_ROOT}/bin.share" "${ORIGIN}/?bin=1"
curl -sS -k -m 60 ${DIRECT_PROTO[@]+"${DIRECT_PROTO[@]}"} -o "${SCRATCH_ROOT}/bin.direct" "${LOCAL_ORIGIN}/?bin=1"
expect_eq "binary Content-Type preserved" "application/octet-stream" "$(header_value "${SCRATCH_ROOT}/bin.hdr" "Content-Type")"
if grep -aqF "$LOCAL_ORIGIN" "${SCRATCH_ROOT}/bin.share"; then
  pass "binary body still contains the local origin"
else
  fail "binary body does not contain the local origin"
fi
if cmp -s "${SCRATCH_ROOT}/bin.share" "${SCRATCH_ROOT}/bin.direct"; then
  pass "binary bytes identical through the share and directly"
else
  fail "binary bytes differ between the share and a direct request"
fi

share_curl -D "${SCRATCH_ROOT}/dl.hdr" -o "${SCRATCH_ROOT}/dl.share" "${ORIGIN}/?dl=1"
curl -sS -k -m 60 ${DIRECT_PROTO[@]+"${DIRECT_PROTO[@]}"} -o "${SCRATCH_ROOT}/dl.direct" "${LOCAL_ORIGIN}/?dl=1"
if cmp -s "${SCRATCH_ROOT}/dl.share" "${SCRATCH_ROOT}/dl.direct" && grep -qF "$LOCAL_ORIGIN" "${SCRATCH_ROOT}/dl.share"; then
  pass "attachment body unchanged through the share"
else
  fail "attachment body differs between the share and a direct request"
fi

# ----------------------------------------------------------------------------
# 13. Direct requests are unaffected
# ----------------------------------------------------------------------------
step "13. Direct request to the local origin"
curl -sS -k -L -m 60 -D "${SCRATCH_ROOT}/direct.hdr" -o "${SCRATCH_ROOT}/direct.html" "${LOCAL_ORIGIN}/"
DIRECT_BODY="$(cat "${SCRATCH_ROOT}/direct.html")"
expect_contains "direct body shows the local host" "$DIRECT_BODY" "$LOCAL_HOST"
expect_lacks "direct body has no share origin" "$DIRECT_BODY" "$ORIGIN"
direct_robots="$(header_value "${SCRATCH_ROOT}/direct.hdr" "X-Robots-Tag")"
expect_eq "direct response has no X-Robots-Tag" "" "$direct_robots"

echo
echo "Script completed. See RESULTS summary below (printed by cleanup trap)."
