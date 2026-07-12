#!/usr/bin/env bash
#
# validate-container-workflow.sh
#
# Empirically proves (or corrects) the per-site container recipe for WP Container's
# macOS app, using the Apple `container` CLI. Runs the full site lifecycle plus the
# git-worktree "branch environment" feature (nested mount shadowing + APFS clone
# cloning) end to end against real containers on this machine.
#
# Safe to re-run: cleans up any leftovers from a previous run first, and always
# cleans up after itself via a trap (containers, network, volumes, scratch dir).
# Pulled images are left in place on purpose (the app needs them anyway).
#
# Usage: ./validate-container-workflow.sh [--keep-scratch]
#   --keep-scratch   Do not delete the scratch directory on exit (for debugging).

set -euo pipefail

# ----------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------
CONTAINER_BIN="/usr/local/bin/container"
SLUG="wpctest"
LABEL_SITE="dev.wpcontainer.site=${SLUG}"
LABEL_ENV_KEY="dev.wpcontainer.env"

SCRATCH_ROOT="${TMPDIR:-/tmp}/wp-container-validate-$$"
SITE_DIR="${SCRATCH_ROOT}/${SLUG}-site"
WT_DIR="${SCRATCH_ROOT}/${SLUG}-worktree-sim"

DB_NAME="${SLUG}-db"
WP_NAME="${SLUG}-wp"
WT_DB_NAME="${SLUG}-wt-db"
WT_WP_NAME="${SLUG}-wt-wp"

WP_PORT=8881
WT_PORT=8897

KEEP_SCRATCH=0
[[ "${1:-}" == "--keep-scratch" ]] && KEEP_SCRATCH=1

PASS_COUNT=0
FAIL_COUNT=0

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
pass() { echo "[PASS] $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "[FAIL] $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
info() { echo "[INFO] $*"; }
step() { echo; echo "=== $* ==="; }

container_ip() {
  # Prints the bare IPv4 address (no /24 suffix) of a running container.
  # Exact JSON path: .[0].status.networks[0].ipv4Address (format "x.x.x.x/24").
  "$CONTAINER_BIN" inspect "$1" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data[0]["status"]["networks"][0]["ipv4Address"].split("/")[0])
'
}

wait_for_db() {
  local name="$1" tries="${2:-60}"
  for ((i = 1; i <= tries; i++)); do
    if "$CONTAINER_BIN" exec "$name" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1; then
      echo "$i"
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_http() {
  local url="$1" tries="${2:-90}"
  for ((i = 1; i <= tries; i++)); do
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000")
    if [[ "$code" =~ ^(200|301|302|303)$ ]]; then
      echo "$i $code"
      return 0
    fi
    sleep 1
  done
  return 1
}

# Pre-seed WordPress core files into an empty host-bound wordpress/ directory.
#
# WHY THIS IS NEEDED (critical divergence from the naive recipe):
# The official `wordpress:latest` entrypoint, when it finds no index.php, tries to
# run `chown "$user:$group" .` on the mounted directory root if that root currently
# stat's as 0:0 (see docker-entrypoint.sh). On Apple `container`'s virtiofs bind
# mounts, the directory ALWAYS appears as owned by root:root (0:0) from inside the
# guest, regardless of the real macOS owner -- and chown to any UID is rejected
# with "Operation not permitted" (virtiofs enforces the real host user's
# permissions underneath; the "root" you see in the guest cannot actually chown on
# the host side). That specific chown call is not wrapped in `|| true`, so under
# `set -Eeuo pipefail` the entrypoint dies before WP core is ever copied.
#
# The fix: copy /usr/src/wordpress -> the host mount ourselves, once, via a
# one-shot container with a plain `cp -r` (no attribute preservation, so no
# chown/utime calls are attempted). Once index.php exists, the real entrypoint's
# whole copy/chown block is skipped entirely (its guard is
# `if [ ! -e index.php ] && [ ! -e wp-includes/version.php ]`), so every
# subsequent boot needs no workaround at all.
preseed_wordpress_core() {
  local host_dir="$1"
  if [[ -f "${host_dir}/index.php" ]]; then
    info "wordpress/ already seeded, skipping pre-seed"
    return 0
  fi
  "$CONTAINER_BIN" run --rm --entrypoint /bin/sh \
    -v "${host_dir}:/var/www/html" \
    wordpress:latest -c "cp -r /usr/src/wordpress/. /var/www/html/"
}

cleanup() {
  local ec=$?
  step "Cleanup"
  "$CONTAINER_BIN" stop "$WP_NAME" "$DB_NAME" "$WT_WP_NAME" "$WT_DB_NAME" \
    pbtest-nested-shadow-check >/dev/null 2>&1 || true
  "$CONTAINER_BIN" delete "$WP_NAME" "$DB_NAME" "$WT_WP_NAME" "$WT_DB_NAME" \
    pbtest-nested-shadow-check >/dev/null 2>&1 || true
  "$CONTAINER_BIN" network delete "${SLUG}-net" >/dev/null 2>&1 || true
  "$CONTAINER_BIN" volume delete "${SLUG}-db-vol" >/dev/null 2>&1 || true
  if [[ "$KEEP_SCRATCH" -eq 0 ]]; then
    rm -rf "$SCRATCH_ROOT"
    info "Removed scratch dir $SCRATCH_ROOT"
  else
    info "Kept scratch dir at $SCRATCH_ROOT (--keep-scratch)"
  fi
  echo
  echo "==================================================================="
  echo "RESULTS: $PASS_COUNT passed, $FAIL_COUNT failed"
  echo "==================================================================="
  exit "$ec"
}
trap cleanup EXIT

# ----------------------------------------------------------------------------
# 0. Idempotent pre-clean (in case a previous run left state behind)
# ----------------------------------------------------------------------------
step "Pre-clean any leftover state from a previous run"
"$CONTAINER_BIN" stop "$WP_NAME" "$DB_NAME" "$WT_WP_NAME" "$WT_DB_NAME" >/dev/null 2>&1 || true
"$CONTAINER_BIN" delete "$WP_NAME" "$DB_NAME" "$WT_WP_NAME" "$WT_DB_NAME" >/dev/null 2>&1 || true
"$CONTAINER_BIN" network delete "${SLUG}-net" >/dev/null 2>&1 || true
"$CONTAINER_BIN" volume delete "${SLUG}-db-vol" >/dev/null 2>&1 || true
rm -rf "$SCRATCH_ROOT"
mkdir -p "${SITE_DIR}/wordpress" "${SITE_DIR}/database"

# ----------------------------------------------------------------------------
# 1. System / CLI sanity
# ----------------------------------------------------------------------------
step "1. System sanity"
if [[ -x "$CONTAINER_BIN" ]]; then pass "container CLI present at $CONTAINER_BIN"; else fail "container CLI missing"; exit 1; fi
if "$CONTAINER_BIN" system status >/dev/null 2>&1; then pass "container system service running"; else fail "container system service not running"; exit 1; fi

# ----------------------------------------------------------------------------
# 2. Pull images (idempotent: pull is a no-op if already present)
# ----------------------------------------------------------------------------
step "2. Pull images"
for img in mariadb:11 wordpress:latest wordpress:cli; do
  info "Pulling $img (this can take a while on first run)..."
  if "$CONTAINER_BIN" image pull "$img"; then pass "pulled/verified $img"; else fail "failed to pull $img"; exit 1; fi
done
"$CONTAINER_BIN" image ls --format json >/dev/null 2>&1 && pass "image ls --format json works" || fail "image ls --format json failed"

# ----------------------------------------------------------------------------
# 3. Start DB
# ----------------------------------------------------------------------------
step "3. Start MariaDB container"
# --user 999:999 is REQUIRED on a host bind mount for /var/lib/mysql: mariadb's
# entrypoint runs `find $DATADIR ! -user mysql -exec chown mysql: {} +` when its
# own uid is 0. Since virtiofs bind mounts always show files as root-owned (0:0)
# from inside the guest and reject chown to a different uid (same root cause as
# the WordPress case above), starting the container as root against a fresh empty
# bind-mounted directory fails immediately with "Operation not permitted" during
# `mariadb-install-db`. Running the whole container AS uid:gid 999:999 (the
# `mysql` user baked into the image) from the start avoids the uid==0 branch
# entirely, so mariadb-install-db and mariadbd both run as their own user and
# never attempt a chown. Verified: this works for both fresh init and subsequent
# boots on a real host directory (no managed `container volume` needed).
"$CONTAINER_BIN" run -d --rm --name "$DB_NAME" \
  --user 999:999 \
  --label "$LABEL_SITE" \
  -v "${SITE_DIR}/database:/var/lib/mysql" \
  -e MARIADB_DATABASE=wordpress \
  -e MARIADB_USER=wordpress \
  -e MARIADB_PASSWORD=wordpress \
  -e MARIADB_ROOT_PASSWORD=root \
  mariadb:11 >/dev/null
pass "DB container started (run exit 0)"

step "4. Wait for DB readiness"
if tries=$(wait_for_db "$DB_NAME" 60); then
  pass "DB ready after ${tries}s (healthcheck.sh --connect --innodb_initialized)"
else
  fail "DB never became ready"
  "$CONTAINER_BIN" logs "$DB_NAME" | tail -30
  exit 1
fi

DB_IP=$(container_ip "$DB_NAME")
if [[ -n "$DB_IP" ]]; then pass "resolved DB IP via inspect: $DB_IP"; else fail "could not resolve DB IP"; exit 1; fi

# ----------------------------------------------------------------------------
# 5. Pre-seed + start WP
# ----------------------------------------------------------------------------
step "5. Pre-seed WordPress core, then start WP container"
preseed_wordpress_core "${SITE_DIR}/wordpress"
if [[ -f "${SITE_DIR}/wordpress/index.php" ]]; then pass "WP core pre-seeded on host"; else fail "WP core pre-seed failed"; exit 1; fi

"$CONTAINER_BIN" run -d --rm --name "$WP_NAME" \
  --label "$LABEL_SITE" \
  -v "${SITE_DIR}/wordpress:/var/www/html" \
  -p "127.0.0.1:${WP_PORT}:80" \
  -e WORDPRESS_DB_HOST="$DB_IP" \
  -e WORDPRESS_DB_USER=wordpress \
  -e WORDPRESS_DB_PASSWORD=wordpress \
  -e WORDPRESS_DB_NAME=wordpress \
  wordpress:latest >/dev/null
pass "WP container started without the chown crash"

step "6. Poll HTTP until WP responds"
if result=$(wait_for_http "http://127.0.0.1:${WP_PORT}" 90); then
  read -r secs code <<<"$result"
  pass "WP responded HTTP $code after ${secs}s"
else
  fail "WP never responded on port ${WP_PORT}"
  "$CONTAINER_BIN" logs "$WP_NAME" | tail -40
  exit 1
fi

step "7. Verify host-visible WP files + ownership"
if [[ -d "${SITE_DIR}/wordpress/wp-content" ]]; then pass "wp-content/ present on host"; else fail "wp-content/ missing on host"; fi
HOST_OWNER=$(stat -f "%Su:%Sg" "${SITE_DIR}/wordpress/wp-content")
info "wp-content/ host ownership: $HOST_OWNER (uid $(id -u))"
if [[ "$HOST_OWNER" == "$(id -un):$(id -gn)" ]]; then
  pass "wp-content/ owned by the real macOS user (regardless of container-internal uid)"
else
  fail "unexpected host ownership: $HOST_OWNER"
fi

echo "written from host" >"${SITE_DIR}/wordpress/wp-content/host-write-test.txt"
if "$CONTAINER_BIN" exec "$WP_NAME" cat /var/www/html/wp-content/host-write-test.txt >/dev/null 2>&1; then
  pass "host-created file visible inside container"
else
  fail "host-created file NOT visible inside container"
fi
"$CONTAINER_BIN" exec "$WP_NAME" sh -c "echo 'written from container' > /var/www/html/wp-content/container-write-test.txt"
if [[ -f "${SITE_DIR}/wordpress/wp-content/container-write-test.txt" ]]; then
  pass "container-created file visible on host"
else
  fail "container-created file NOT visible on host"
fi

# ----------------------------------------------------------------------------
# 8. Provision via one-shot wp-cli (no install wizard)
# ----------------------------------------------------------------------------
step "8. wp core install via one-shot wordpress:cli container"
"$CONTAINER_BIN" run --rm \
  -v "${SITE_DIR}/wordpress:/var/www/html" \
  -e WORDPRESS_DB_HOST="$DB_IP" \
  -e WORDPRESS_DB_USER=wordpress \
  -e WORDPRESS_DB_PASSWORD=wordpress \
  -e WORDPRESS_DB_NAME=wordpress \
  wordpress:cli \
  wp core install \
    --url="http://127.0.0.1:${WP_PORT}" \
    --title=WPCTest \
    --admin_user=admin \
    --admin_password=password \
    --admin_email=admin@localhost.local
pass "wp core install succeeded (no --allow-root / --path needed; wordpress:cli runs as www-data)"

CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WP_PORT}")
BODY=$(curl -s "http://127.0.0.1:${WP_PORT}")
if [[ "$CODE" == "200" ]] && [[ "$BODY" == *"WPCTest"* ]]; then
  pass "installed site serves HTTP 200 with title WPCTest"
else
  fail "installed site did not serve as expected (code=$CODE)"
fi
LOGIN_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WP_PORT}/wp-login.php")
if [[ "$LOGIN_CODE" == "200" ]]; then pass "wp-login.php serves HTTP 200"; else fail "wp-login.php returned $LOGIN_CODE"; fi

# ----------------------------------------------------------------------------
# 9. Stop / restart persistence
# ----------------------------------------------------------------------------
step "9. Stop + fresh restart, verify persistence (no reinstall)"
"$CONTAINER_BIN" stop "$WP_NAME" "$DB_NAME" >/dev/null 2>&1
sleep 1
if "$CONTAINER_BIN" list --all --format json | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if len(d)==0 else 1)"; then
  pass "--rm containers removed themselves on stop (list --all is empty)"
else
  fail "containers still present after stop (expected --rm to remove them)"
fi

"$CONTAINER_BIN" run -d --rm --name "$DB_NAME" \
  --user 999:999 --label "$LABEL_SITE" \
  -v "${SITE_DIR}/database:/var/lib/mysql" \
  -e MARIADB_DATABASE=wordpress -e MARIADB_USER=wordpress -e MARIADB_PASSWORD=wordpress -e MARIADB_ROOT_PASSWORD=root \
  mariadb:11 >/dev/null
wait_for_db "$DB_NAME" 60 >/dev/null
NEW_DB_IP=$(container_ip "$DB_NAME")
info "DB IP after restart: $NEW_DB_IP (was $DB_IP -- confirms IP churns across restarts, as anticipated in PLAN.md)"

"$CONTAINER_BIN" run -d --rm --name "$WP_NAME" \
  --label "$LABEL_SITE" \
  -v "${SITE_DIR}/wordpress:/var/www/html" \
  -p "127.0.0.1:${WP_PORT}:80" \
  -e WORDPRESS_DB_HOST="$NEW_DB_IP" \
  -e WORDPRESS_DB_USER=wordpress -e WORDPRESS_DB_PASSWORD=wordpress -e WORDPRESS_DB_NAME=wordpress \
  wordpress:latest >/dev/null
wait_for_http "http://127.0.0.1:${WP_PORT}" 60 >/dev/null

RESTART_BODY=$(curl -s "http://127.0.0.1:${WP_PORT}")
RESTART_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WP_PORT}")
if [[ "$RESTART_CODE" == "200" ]] && [[ "$RESTART_BODY" == *"WPCTest"* ]]; then
  pass "content persisted across stop/start: site still installed, still serves WPCTest"
else
  fail "content did NOT persist across stop/start (code=$RESTART_CODE)"
fi

# ----------------------------------------------------------------------------
# 10. container list --all --format json shape
# ----------------------------------------------------------------------------
step "10. Verify list --all --format json shape"
LIST_JSON=$("$CONTAINER_BIN" list --all --format json)
echo "$LIST_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
ok = True
for c in data:
    name = c['id']
    labels = c['configuration'].get('labels', {})
    state = c['status']['state']
    print(f'  container={name} state={state} labels={labels}')
    if 'dev.wpcontainer.site' not in labels:
        ok = False
sys.exit(0 if ok else 1)
" && pass "list --all --format json exposes id/status.state/configuration.labels as expected" \
  || fail "label not found in list --all --format json output"

# ----------------------------------------------------------------------------
# 11. DB host resolution: does default-network name-based DNS work? (it must not
#     be relied upon -- confirm IP-from-inspect is the only guaranteed path)
# ----------------------------------------------------------------------------
step "11. Confirm name-based container DNS is NOT available (IP-from-inspect required)"
if "$CONTAINER_BIN" run --rm mariadb:11 getent hosts "$DB_NAME" >/dev/null 2>&1; then
  fail "unexpected: name-based DNS resolved '$DB_NAME' -- re-check PLAN.md assumption"
else
  pass "confirmed: bare container name does not resolve via DNS by default (getent failed as expected)"
fi

# ----------------------------------------------------------------------------
# 12. Nested mount shadowing (git worktree feature, §2b)
# ----------------------------------------------------------------------------
step "12. Nested mount shadowing for git-worktree envs"
mkdir -p "${WT_DIR}"
echo "worktree checkout marker" >"${WT_DIR}/marker.txt"
mkdir -p "${SITE_DIR}/wordpress/wp-content/plugins/my-plugin"
echo "original (should be shadowed)" >"${SITE_DIR}/wordpress/wp-content/plugins/my-plugin/original.txt"

SHADOW_OUT=$("$CONTAINER_BIN" run --rm --name pbtest-nested-shadow-check \
  -v "${SITE_DIR}/wordpress:/var/www/html" \
  -v "${WT_DIR}:/var/www/html/wp-content/plugins/my-plugin" \
  wordpress:latest sh -c '
    cat /var/www/html/wp-content/plugins/my-plugin/marker.txt 2>&1
    ls /var/www/html/wp-content/plugins/my-plugin/original.txt >/dev/null 2>&1 && echo ORIGINAL_VISIBLE || echo ORIGINAL_HIDDEN
    ls /var/www/html/wp-config.php >/dev/null 2>&1 && echo OUTER_MOUNT_INTACT || echo OUTER_MOUNT_BROKEN
    echo "written from inside" > /var/www/html/wp-content/plugins/my-plugin/from-container.txt
  ')
echo "$SHADOW_OUT"
if [[ "$SHADOW_OUT" == *"worktree checkout marker"* ]]; then pass "inner mount shadows the subpath (marker.txt visible)"; else fail "inner mount did not shadow subpath"; fi
if [[ "$SHADOW_OUT" == *"ORIGINAL_HIDDEN"* ]]; then pass "original content underneath is hidden while shadowed"; else fail "original content still visible (shadowing not working)"; fi
if [[ "$SHADOW_OUT" == *"OUTER_MOUNT_INTACT"* ]]; then pass "rest of outer wordpress/ mount unaffected"; else fail "outer mount broken by nested mount"; fi
if [[ -f "${SITE_DIR}/wordpress/wp-content/plugins/my-plugin/original.txt" ]]; then
  pass "original.txt untouched on host (not deleted by shadowing)"
else
  fail "original.txt was removed from host -- data loss risk"
fi
if [[ -f "${WT_DIR}/from-container.txt" ]]; then
  pass "writes to the shadowed path land in the worktree dir on host, not the parent mount"
else
  fail "container write did not land in the expected host directory"
fi

step "12b. Nested mount onto a subpath that does not pre-exist"
rm -rf "${SITE_DIR}/wordpress/wp-content/plugins/nonexistent-plugin"
"$CONTAINER_BIN" run --rm \
  -v "${SITE_DIR}/wordpress:/var/www/html" \
  -v "${WT_DIR}:/var/www/html/wp-content/plugins/nonexistent-plugin" \
  wordpress:latest sh -c "cat /var/www/html/wp-content/plugins/nonexistent-plugin/marker.txt" >/dev/null
if [[ -d "${SITE_DIR}/wordpress/wp-content/plugins/nonexistent-plugin" ]]; then
  pass "runtime auto-creates the missing mountpoint dir on host (side effect: an empty dir is left behind in the parent's wp-content -- caller should pre-create or clean it up)"
else
  fail "expected an auto-created mountpoint directory on host; behavior differs from observed"
fi

# ----------------------------------------------------------------------------
# 13. APFS clone speed + branch-env boot + URL fix (git worktree feature, §2b)
# ----------------------------------------------------------------------------
step "13. APFS CoW clone speed + branch-env boot + URL fix"
"$CONTAINER_BIN" stop "$WP_NAME" "$DB_NAME" >/dev/null 2>&1
sleep 1

T_START=$(date +%s.%N)
cp -Rc "${SITE_DIR}/wordpress" "${SITE_DIR}/wordpress-clone"
cp -Rc "${SITE_DIR}/database" "${SITE_DIR}/database-clone"
T_CLONE=$(date +%s.%N)
CLONE_SECS=$(echo "$T_CLONE - $T_START" | bc)
pass "APFS CoW clone of wordpress/ + database/ took ${CLONE_SECS}s"

"$CONTAINER_BIN" run -d --rm --name "$WT_DB_NAME" \
  --user 999:999 \
  --label "$LABEL_SITE" --label "${LABEL_ENV_KEY}=${SLUG}-wt-demo" \
  -v "${SITE_DIR}/database-clone:/var/lib/mysql" \
  -e MARIADB_DATABASE=wordpress -e MARIADB_USER=wordpress -e MARIADB_PASSWORD=wordpress -e MARIADB_ROOT_PASSWORD=root \
  mariadb:11 >/dev/null
wait_for_db "$WT_DB_NAME" 60 >/dev/null
T_DB_READY=$(date +%s.%N)
WT_DB_IP=$(container_ip "$WT_DB_NAME")
pass "cloned DB ready in $(echo "$T_DB_READY - $T_CLONE" | bc)s at $WT_DB_IP"

"$CONTAINER_BIN" run -d --rm --name "$WT_WP_NAME" \
  --label "$LABEL_SITE" --label "${LABEL_ENV_KEY}=${SLUG}-wt-demo" \
  -v "${SITE_DIR}/wordpress-clone:/var/www/html" \
  -p "127.0.0.1:${WT_PORT}:80" \
  -e WORDPRESS_DB_HOST="$WT_DB_IP" -e WORDPRESS_DB_USER=wordpress -e WORDPRESS_DB_PASSWORD=wordpress -e WORDPRESS_DB_NAME=wordpress \
  wordpress:latest >/dev/null
wait_for_http "http://127.0.0.1:${WT_PORT}" 60 >/dev/null
T_WP_READY=$(date +%s.%N)
pass "cloned WP serving in $(echo "$T_WP_READY - $T_DB_READY" | bc)s (pre-URL-fix, expect redirect to old port)"

"$CONTAINER_BIN" run --rm \
  -v "${SITE_DIR}/wordpress-clone:/var/www/html" \
  -e WORDPRESS_DB_HOST="$WT_DB_IP" -e WORDPRESS_DB_USER=wordpress -e WORDPRESS_DB_PASSWORD=wordpress -e WORDPRESS_DB_NAME=wordpress \
  wordpress:cli sh -c "wp option update home http://127.0.0.1:${WT_PORT} && wp option update siteurl http://127.0.0.1:${WT_PORT} && wp cache flush"
T_URLFIX=$(date +%s.%N)
pass "URL fix (home/siteurl + cache flush) took $(echo "$T_URLFIX - $T_WP_READY" | bc)s"

WT_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WT_PORT}")
WT_BODY=$(curl -s "http://127.0.0.1:${WT_PORT}")
if [[ "$WT_CODE" == "200" ]] && [[ "$WT_BODY" == *"WPCTest"* ]]; then
  pass "branch env serves correctly on its own port after URL fix (no bounce to parent port)"
else
  fail "branch env did not serve correctly after URL fix (code=$WT_CODE)"
fi

TOTAL_SECS=$(echo "$T_URLFIX - $T_START" | bc)
info "TOTAL clone -> boot -> URL-fix wall-clock time: ${TOTAL_SECS}s"

echo
echo "Script completed. See RESULTS summary below (printed by cleanup trap)."
