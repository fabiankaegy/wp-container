#!/usr/bin/env bash
#
# validate-addons.sh
#
# Empirically proves (or corrects) the per-site add-on recipes described in
# PLAN.md §2c: the Xdebug derived-image build + host-gateway wiring, and the
# Elasticsearch sidecar container. Companion to validate-container-workflow.sh
# (§2, base WP+MariaDB recipe -- already validated there); this script only
# covers the two add-ons.
#
# Safe to re-run: cleans up any leftovers from a previous run first, and always
# cleans up after itself via a trap (containers + scratch dir). The built
# xdebug image and pulled elasticsearch image are left in place on purpose
# (the app needs them anyway; rebuilding/re-pulling is the expensive part).
#
# Usage: ./validate-addons.sh [--keep-scratch]
#   --keep-scratch   Do not delete the scratch directory on exit (for debugging).

set -euo pipefail

# ----------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------
CONTAINER_BIN="/usr/local/bin/container"
SLUG="wpcv2"

SCRATCH_ROOT="${TMPDIR%/}/wp-container-validate-addons-$$"
[[ "$SCRATCH_ROOT" == "/wp-container-validate-addons-$$" ]] && SCRATCH_ROOT="/tmp/wp-container-validate-addons-$$"
XDEBUG_BUILD_DIR="${SCRATCH_ROOT}/xdebug-build"
SITE_DIR="${SCRATCH_ROOT}/site"
ESDATA_DIR="${SCRATCH_ROOT}/esdata"

XDEBUG_IMAGE="wpc-wordpress-xdebug:latest"
ES_IMAGE="elasticsearch:8.15.0"

DB_NAME="${SLUG}-db"
WP_NAME="${SLUG}-wp"
NET_NAME="${SLUG}-nettest"
ES_NAME="${SLUG}-es"

WP_PORT=8899
ES_PORT=9201
XDEBUG_LISTEN_PORT=9003

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
  "$CONTAINER_BIN" inspect "$1" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data[0]["status"]["networks"][0]["ipv4Address"].split("/")[0])
'
}

container_gateway() {
  # Prints the gateway IPv4 for a running container -- this is the reliable,
  # machine-readable way to compute the "host" address for Xdebug's
  # client_host: `container inspect <name>` exposes it directly as
  # status.networks[0].ipv4Gateway. Do NOT hardcode 192.168.64.1 even though
  # that is what it resolves to on the default network on this machine --
  # read it from inspect so the recipe survives changes to Apple's subnet
  # allocation or a future custom `container network create` per site.
  "$CONTAINER_BIN" inspect "$1" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data[0]["status"]["networks"][0]["ipv4Gateway"])
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

wait_for_es_green_or_yellow() {
  local url="$1" tries="${2:-60}"
  for ((i = 1; i <= tries; i++)); do
    local status
    status=$(curl -s -m 2 "$url/_cluster/health" 2>/dev/null || true)
    if [[ "$status" == *'"status":"green"'* || "$status" == *'"status":"yellow"'* ]]; then
      echo "$i"
      return 0
    fi
    sleep 1
  done
  return 1
}

preseed_wordpress_core() {
  # See validate-container-workflow.sh for the full rationale: the official
  # wordpress entrypoint's chown-on-empty-mount call is rejected on virtiofs
  # bind mounts, so we copy WP core in ourselves once via a plain `cp -r`
  # (no attribute preservation -> no chown/utime calls attempted).
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
  "$CONTAINER_BIN" stop \
    "$WP_NAME" "$DB_NAME" "$ES_NAME" "$NET_NAME" \
    "${ES_NAME}-nouser" "${ES_NAME}-pub" \
    >/dev/null 2>&1 || true
  "$CONTAINER_BIN" delete \
    "$WP_NAME" "$DB_NAME" "$ES_NAME" "$NET_NAME" \
    "${ES_NAME}-nouser" "${ES_NAME}-pub" \
    >/dev/null 2>&1 || true
  # Kill any leftover background host listeners started for the xdebug proof.
  [[ -n "${LISTENER_PID:-}" ]] && kill "$LISTENER_PID" >/dev/null 2>&1 || true
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
# 0. Idempotent pre-clean
# ----------------------------------------------------------------------------
step "Pre-clean any leftover state from a previous run"
"$CONTAINER_BIN" stop \
  "$WP_NAME" "$DB_NAME" "$ES_NAME" "$NET_NAME" "${ES_NAME}-nouser" "${ES_NAME}-pub" \
  >/dev/null 2>&1 || true
"$CONTAINER_BIN" delete \
  "$WP_NAME" "$DB_NAME" "$ES_NAME" "$NET_NAME" "${ES_NAME}-nouser" "${ES_NAME}-pub" \
  >/dev/null 2>&1 || true
rm -rf "$SCRATCH_ROOT"
mkdir -p "$XDEBUG_BUILD_DIR" "${SITE_DIR}/wordpress" "${SITE_DIR}/database" "$ESDATA_DIR"

# ----------------------------------------------------------------------------
# 1. System sanity
# ----------------------------------------------------------------------------
step "1. System sanity"
if [[ -x "$CONTAINER_BIN" ]]; then pass "container CLI present at $CONTAINER_BIN"; else fail "container CLI missing"; exit 1; fi
if "$CONTAINER_BIN" system status >/dev/null 2>&1; then pass "container system service running"; else fail "container system service not running"; exit 1; fi

# =============================================================================
# PART A -- XDEBUG
# =============================================================================

# ----------------------------------------------------------------------------
# 2. Builder start + build the derived Xdebug image
# ----------------------------------------------------------------------------
step "2. Start the container builder (one-time, lazy)"
T0=$(date +%s)
if "$CONTAINER_BIN" builder status >/dev/null 2>&1 && "$CONTAINER_BIN" builder status 2>&1 | grep -q running; then
  info "builder already running"
else
  "$CONTAINER_BIN" builder start
fi
T1=$(date +%s)
pass "builder ready after $((T1 - T0))s"

step "3. Write the Xdebug Dockerfile"
# WHY xdebug.client_host uses \${XDEBUG_CLIENT_HOST} (literal PHP-ini env
# substitution, not a build-time value): PHP ini files support \${ENV_VAR}
# substitution at parse time, so a single image build works across every
# site/network -- the actual gateway IP is supplied per-container via
# `-e XDEBUG_CLIENT_HOST=<gateway>` at `container run` time (computed from
# `container inspect` per §4 below), no rebuild needed if it ever changes.
#
# WHY the ini settings live in their own conf.d file WITHOUT a `zend_extension`
# line: `docker-php-ext-enable xdebug` already drops
# /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini containing
# `zend_extension=xdebug`. Repeating that directive in a second file causes
# "Cannot load Xdebug - it was already loaded" on every PHP invocation
# (harmless but noisy in logs) -- verified empirically and avoided here.
cat > "${XDEBUG_BUILD_DIR}/Dockerfile" <<'DOCKERFILE'
FROM wordpress:latest

RUN pecl install xdebug \
    && docker-php-ext-enable xdebug

RUN { \
    echo 'xdebug.mode=debug,develop'; \
    echo 'xdebug.start_with_request=yes'; \
    echo 'xdebug.client_port=9003'; \
    echo 'xdebug.client_host=${XDEBUG_CLIENT_HOST}'; \
    echo 'xdebug.log_level=0'; \
    } > /usr/local/etc/php/conf.d/zzz-xdebug-settings.ini
DOCKERFILE
pass "Dockerfile written to ${XDEBUG_BUILD_DIR}/Dockerfile"

step "4. Build the Xdebug image"
T0=$(date +%s)
# `container build` is finicky about absolute -f/context path combinations
# (observed: "X is not a child of Y" when passing an absolute Dockerfile path
# alongside an absolute context dir under some TMPDIR layouts) -- cd into the
# build dir and use relative paths, exactly as a human would run it.
if (cd "$XDEBUG_BUILD_DIR" && "$CONTAINER_BIN" build -t "$XDEBUG_IMAGE" -f Dockerfile .); then
  T1=$(date +%s)
  pass "container build succeeded in $((T1 - T0))s (pecl/xdebug compiled cleanly on arm64, no install-php-extensions fallback needed)"
else
  fail "container build failed"
  exit 1
fi

# ----------------------------------------------------------------------------
# 5. Host gateway discovery
# ----------------------------------------------------------------------------
step "5. Host gateway discovery"
"$CONTAINER_BIN" run -d --rm --name "$NET_NAME" wordpress:latest >/dev/null
sleep 1
GATEWAY_IP=$(container_gateway "$NET_NAME")
if [[ -n "$GATEWAY_IP" ]]; then
  pass "resolved container's host gateway via inspect (.status.networks[0].ipv4Gateway): $GATEWAY_IP"
else
  fail "could not resolve gateway IP from inspect"
  exit 1
fi

DNS_CANDIDATES_FOUND=0
for name in host.docker.internal gateway gateway.docker.internal; do
  if "$CONTAINER_BIN" exec "$NET_NAME" getent hosts "$name" >/dev/null 2>&1; then
    info "unexpected: DNS name '$name' resolves inside the container"
    DNS_CANDIDATES_FOUND=1
  fi
done
if [[ "$DNS_CANDIDATES_FOUND" -eq 0 ]]; then
  pass "confirmed: no host.docker.internal-style DNS name resolves; ipv4Gateway from inspect is the only reliable path"
else
  fail "a DNS name resolved unexpectedly -- re-check assumption"
fi

info "starting a host TCP listener on 127.0.0.1:${XDEBUG_LISTEN_PORT} to prove container -> host reachability"
python3 - "$XDEBUG_LISTEN_PORT" > "${SCRATCH_ROOT}/gw-listener.out" 2>&1 <<'PYEOF' &
import socket, sys
port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', port))
s.listen(1)
s.settimeout(15)
try:
    conn, addr = s.accept()
    print(f"CONNECTION FROM {addr}")
    conn.close()
except socket.timeout:
    print("NO CONNECTION RECEIVED (timeout)")
PYEOF
LISTENER_PID=$!
sleep 1
"$CONTAINER_BIN" exec "$NET_NAME" bash -c "echo probe > /dev/tcp/${GATEWAY_IP}/${XDEBUG_LISTEN_PORT}" >/dev/null 2>&1 || true
wait "$LISTENER_PID" 2>/dev/null || true
if grep -q "CONNECTION FROM" "${SCRATCH_ROOT}/gw-listener.out"; then
  pass "proved reachability: container reached a listener on the host via the gateway IP ($GATEWAY_IP)"
else
  fail "container could not reach a host listener via gateway IP -- see ${SCRATCH_ROOT}/gw-listener.out"
fi
"$CONTAINER_BIN" stop "$NET_NAME" >/dev/null 2>&1 || true

# ----------------------------------------------------------------------------
# 6. Boot the xdebug image as a full WP site, verify end to end
# ----------------------------------------------------------------------------
step "6. Boot xdebug image as WP container (db + wp)"
preseed_wordpress_core "${SITE_DIR}/wordpress"
[[ -f "${SITE_DIR}/wordpress/index.php" ]] && pass "WP core pre-seeded on host" || { fail "pre-seed failed"; exit 1; }

"$CONTAINER_BIN" run -d --rm --name "$DB_NAME" \
  --user 999:999 \
  -v "${SITE_DIR}/database:/var/lib/mysql" \
  -e MARIADB_DATABASE=wordpress -e MARIADB_USER=wordpress -e MARIADB_PASSWORD=wordpress -e MARIADB_ROOT_PASSWORD=root \
  mariadb:11 >/dev/null
if tries=$(wait_for_db "$DB_NAME" 60); then pass "DB ready after ${tries}s"; else fail "DB never became ready"; exit 1; fi
DB_IP=$(container_ip "$DB_NAME")

"$CONTAINER_BIN" run -d --rm --name "$WP_NAME" \
  -v "${SITE_DIR}/wordpress:/var/www/html" \
  -p "127.0.0.1:${WP_PORT}:80" \
  -e WORDPRESS_DB_HOST="$DB_IP" -e WORDPRESS_DB_USER=wordpress -e WORDPRESS_DB_PASSWORD=wordpress -e WORDPRESS_DB_NAME=wordpress \
  -e XDEBUG_CLIENT_HOST="$GATEWAY_IP" \
  "$XDEBUG_IMAGE" >/dev/null
if result=$(wait_for_http "http://127.0.0.1:${WP_PORT}" 60); then
  read -r secs code <<<"$result"
  pass "xdebug-enabled WP responded HTTP $code after ${secs}s"
else
  fail "xdebug-enabled WP never responded"
  "$CONTAINER_BIN" logs "$WP_NAME" | tail -40
  exit 1
fi

if "$CONTAINER_BIN" exec "$WP_NAME" php -m | grep -qi '^xdebug$'; then
  pass "php -m lists xdebug as loaded"
else
  fail "xdebug not loaded in php -m"
fi

XDEBUG_INI_HOST=$("$CONTAINER_BIN" exec "$WP_NAME" php -r 'echo ini_get("xdebug.client_host");' 2>/dev/null || true)
if [[ "$XDEBUG_INI_HOST" == "$GATEWAY_IP" ]]; then
  pass "xdebug.client_host resolved to the gateway IP via \${XDEBUG_CLIENT_HOST} ini substitution: $XDEBUG_INI_HOST"
else
  fail "xdebug.client_host did not resolve as expected (got '$XDEBUG_INI_HOST')"
fi

step "7. End-to-end debug connection proof (fake IDE listener on host:${XDEBUG_LISTEN_PORT})"
python3 - "$XDEBUG_LISTEN_PORT" > "${SCRATCH_ROOT}/xdebug-listener.out" 2>&1 <<'PYEOF' &
import socket, sys
port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', port))
s.listen(1)
s.settimeout(20)
try:
    conn, addr = s.accept()
    print(f"CONNECTION FROM {addr}")
    conn.settimeout(3)
    try:
        data = conn.recv(4096)
        print("DATA:", data[:200])
    except Exception as e:
        print("recv err", e)
    conn.close()
except socket.timeout:
    print("NO CONNECTION RECEIVED (timeout)")
PYEOF
LISTENER_PID=$!
sleep 1
curl -s -o /dev/null "http://127.0.0.1:${WP_PORT}/?XDEBUG_TRIGGER=1"
wait "$LISTENER_PID" 2>/dev/null || true
if grep -q "CONNECTION FROM" "${SCRATCH_ROOT}/xdebug-listener.out" && grep -q "debugger_protocol_v1" "${SCRATCH_ROOT}/xdebug-listener.out"; then
  pass "requesting a page triggered an inbound Xdebug DBGp connection from the container to the host listener"
else
  fail "no inbound Xdebug connection observed -- see ${SCRATCH_ROOT}/xdebug-listener.out"
  cat "${SCRATCH_ROOT}/xdebug-listener.out"
fi

step "8. XDEBUG_MODE env override (disable without image swap)"
"$CONTAINER_BIN" stop "$WP_NAME" >/dev/null 2>&1
"$CONTAINER_BIN" run -d --rm --name "$WP_NAME" \
  -v "${SITE_DIR}/wordpress:/var/www/html" \
  -p "127.0.0.1:${WP_PORT}:80" \
  -e WORDPRESS_DB_HOST="$DB_IP" -e WORDPRESS_DB_USER=wordpress -e WORDPRESS_DB_PASSWORD=wordpress -e WORDPRESS_DB_NAME=wordpress \
  -e XDEBUG_CLIENT_HOST="$GATEWAY_IP" \
  -e XDEBUG_MODE=off \
  "$XDEBUG_IMAGE" >/dev/null
wait_for_http "http://127.0.0.1:${WP_PORT}" 60 >/dev/null

python3 - "$XDEBUG_LISTEN_PORT" > "${SCRATCH_ROOT}/xdebug-listener-off.out" 2>&1 <<'PYEOF' &
import socket, sys
port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', port))
s.listen(1)
s.settimeout(6)
try:
    conn, addr = s.accept()
    print(f"CONNECTION FROM {addr}")
    conn.close()
except socket.timeout:
    print("NO CONNECTION RECEIVED (timeout)")
PYEOF
LISTENER_PID=$!
sleep 1
curl -s -o /dev/null "http://127.0.0.1:${WP_PORT}/?XDEBUG_TRIGGER=1"
wait "$LISTENER_PID" 2>/dev/null || true
if grep -q "NO CONNECTION RECEIVED" "${SCRATCH_ROOT}/xdebug-listener-off.out"; then
  pass "-e XDEBUG_MODE=off disables debug connections at runtime, no image swap needed (real request path re-verified)"
else
  fail "expected no connection with XDEBUG_MODE=off, but one was observed"
fi

"$CONTAINER_BIN" stop "$WP_NAME" "$DB_NAME" >/dev/null 2>&1 || true

# =============================================================================
# PART B -- ELASTICSEARCH
# =============================================================================

step "9. Pull Elasticsearch image"
T0=$(date +%s)
if "$CONTAINER_BIN" image pull "$ES_IMAGE"; then
  T1=$(date +%s)
  pass "pulled/verified $ES_IMAGE in $((T1 - T0))s"
else
  fail "failed to pull $ES_IMAGE"
  exit 1
fi

step "10. Storage mode (a): bind mount, no --user needed"
# WHY no --user override is needed here (unlike mariadb/wordpress): the
# official elasticsearch image already declares `USER elasticsearch` (uid
# 1000, gid 0) in its own Dockerfile, so the container process never runs as
# root and never attempts the chown-as-root that breaks on virtiofs bind
# mounts for the other images. Verified empirically: booting with NO --user
# flag against a fresh empty bind-mounted data/ directory works cleanly.
T0=$(date +%s)
"$CONTAINER_BIN" run -d --rm --name "$ES_NAME" \
  -v "${ESDATA_DIR}:/usr/share/elasticsearch/data" \
  -e discovery.type=single-node \
  -e xpack.security.enabled=false \
  -e ES_JAVA_OPTS="-Xms512m -Xmx512m" \
  "$ES_IMAGE" >/dev/null

ES_IP=$(container_ip "$ES_NAME")
if tries=$(wait_for_es_green_or_yellow "http://${ES_IP}:9200" 60); then
  T1=$(date +%s)
  pass "ES reached green/yellow after ${tries}s (boot-to-green wall clock ~$((T1 - T0))s) on a bind mount, no --user flag"
else
  fail "ES never became healthy on bind mount"
  "$CONTAINER_BIN" logs "$ES_NAME" | tail -40
  exit 1
fi

VMM_WARN=$("$CONTAINER_BIN" logs "$ES_NAME" 2>&1 | grep -c "vm.max_map_count" || true)
if [[ "$VMM_WARN" -gt 0 ]]; then
  info "vm.max_map_count bootstrap WARNING present in logs (non-fatal here: discovery.type=single-node/dev config does not enforce it as a hard bootstrap check)"
fi

step "11. Elasticsearch data persists across a bind-mount restart"
curl -s -X POST "http://${ES_IP}:9200/testidx/_doc/1" -H 'Content-Type: application/json' -d '{"hello":"world"}' >/dev/null
"$CONTAINER_BIN" stop "$ES_NAME" >/dev/null 2>&1
sleep 1
"$CONTAINER_BIN" run -d --rm --name "$ES_NAME" \
  -v "${ESDATA_DIR}:/usr/share/elasticsearch/data" \
  -e discovery.type=single-node \
  -e xpack.security.enabled=false \
  -e ES_JAVA_OPTS="-Xms512m -Xmx512m" \
  "$ES_IMAGE" >/dev/null
NEW_ES_IP=$(container_ip "$ES_NAME")
wait_for_es_green_or_yellow "http://${NEW_ES_IP}:9200" 60 >/dev/null
DOC=$(curl -s "http://${NEW_ES_IP}:9200/testidx/_doc/1")
if [[ "$DOC" == *'"hello":"world"'* ]]; then
  pass "indexed document survived stop/start (bind-mounted data/ persists, no managed volume needed)"
else
  fail "document did not survive restart: $DOC"
fi

step "12. Publish Elasticsearch on a localhost port"
"$CONTAINER_BIN" stop "$ES_NAME" >/dev/null 2>&1
"$CONTAINER_BIN" run -d --rm --name "${ES_NAME}-pub" \
  -v "${ESDATA_DIR}:/usr/share/elasticsearch/data" \
  -p "127.0.0.1:${ES_PORT}:9200" \
  -e discovery.type=single-node \
  -e xpack.security.enabled=false \
  -e ES_JAVA_OPTS="-Xms512m -Xmx512m" \
  "$ES_IMAGE" >/dev/null
if wait_for_es_green_or_yellow "http://127.0.0.1:${ES_PORT}" 60 >/dev/null; then
  pass "ES reachable via published port 127.0.0.1:${ES_PORT}"
else
  fail "ES not reachable via published port"
fi

step "13. WP-container -> ES connectivity"
ES_PUB_IP=$(container_ip "${ES_NAME}-pub")
WP_ES_CURL=$("$CONTAINER_BIN" run --rm wordpress:cli sh -c "curl -s http://${ES_PUB_IP}:9200" || true)
if [[ "$WP_ES_CURL" == *"You Know, for Search"* ]]; then
  pass "wordpress:cli container reached ES over the container network (curl http://<es-ip>:9200)"
else
  fail "wordpress:cli container could not reach ES"
fi

echo
echo "Script completed. See RESULTS summary below (printed by cleanup trap)."
