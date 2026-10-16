#!/bin/bash
# Spike for the owned loopback zone (PLAN.md §2f-ter). Verifies, with throwaway
# addresses/ports that cannot collide with a running WP Container, the three
# assumptions the design rests on:
#
#   A. pf `rdr` on lo0 for traffic to a lo0 ALIAS reaches an unprivileged
#      listener on 127.0.0.1 (and the IPv6 equivalent onto ::1).
#   B. a `(bridgeN)` dynamic-address rule LOADS while the interface is absent,
#      and on the live vmnet bridge redirects container→gateway traffic onto a
#      127.0.0.1 listener (the in-container WordPress loopback path).
#   C. `/etc/resolver/<zone>` with a non-53 `port` is honoured by BOTH resolver
#      paths: libinfo (`dscacheutil`, curl) and mDNSResponder (`dns-sd`, Safari).
#
# Run as YOUR user (not under sudo) from the repo root:
#     scripts/spike-loopback-zone.sh
# It calls sudo itself for the privileged steps and removes everything it added
# (alias, pf anchor + enable token, resolver file, listeners) on exit.
#
# Spike values (deliberately NOT the production ones):
#   alias 127.0.0.78 / fd77:7063::78, zone wpc-spike.test, listener :47999,
#   DNS :47999/udp, anchor com.apple/wpc-spike, bridge test port 8099.
set -u

ALIAS4=127.0.0.78
ALIAS6=fd77:7063::78
ZONE=wpc-spike.test
PORT=47999
ANCHOR=com.apple/wpc-spike
BRIDGE=${BRIDGE:-bridge100}
BRIDGE_PORT=8099
WORK=$(mktemp -d /tmp/wpc-spike.XXXXXX)
TOKEN=""
PIDS=()

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
info() { printf '  .... %s\n' "$*"; }

cleanup() {
    echo "== cleanup"
    for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
    sudo /sbin/pfctl -a "$ANCHOR" -F all >/dev/null 2>&1
    [ -n "$TOKEN" ] && sudo /sbin/pfctl -X "$TOKEN" >/dev/null 2>&1
    sudo /sbin/ifconfig lo0 -alias "$ALIAS4" 2>/dev/null
    sudo /sbin/ifconfig lo0 inet6 "$ALIAS6" -alias 2>/dev/null
    sudo rm -f "/etc/resolver/$ZONE"
    sudo /usr/bin/killall -HUP mDNSResponder 2>/dev/null
    rm -rf "$WORK"
    echo "   removed alias, anchor, pf token, resolver file, listeners"
}
trap cleanup EXIT

sudo -v || exit 1
echo "== environment"
info "macOS $(sw_vers -productVersion), net.inet.tcp.l4s=$(sysctl -n net.inet.tcp.l4s 2>/dev/null || echo n/a)"
info "(l4s=1 on macOS 27 betas corrupts SYNs to vmnet IPs — a B failure with l4s=1 is NOT a pf failure)"

# --- listeners (unprivileged, as this user) ---------------------------------
cat > "$WORK/http.py" <<'PY'
import http.server, socket, sys
class V6(http.server.ThreadingHTTPServer): address_family = socket.AF_INET6
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = f"spike-ok host={self.headers.get('Host')} via={self.server.server_address[0]}\n".encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
addr, port = sys.argv[1], int(sys.argv[2])
(V6 if ":" in addr else http.server.ThreadingHTTPServer)((addr, port), H).serve_forever()
PY
cat > "$WORK/dns.py" <<'PY'
# Minimal authoritative responder: A for *.<zone> -> alias, everything else empty.
import socket, struct, sys
zone, alias, port = sys.argv[1].encode(), socket.inet_aton(sys.argv[2]), int(sys.argv[3])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", port))
while True:
    q, peer = s.recvfrom(512)
    i, labels = 12, []
    while q[i]: labels.append(q[i+1:i+1+q[i]]); i += 1 + q[i]
    qtype = struct.unpack(">H", q[i+1:i+3])[0]; qend = i + 5
    name = b".".join(labels).lower()
    ok = name == zone or name.endswith(b"." + zone)
    ans = b""
    if ok and qtype == 1:
        ans = b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 60, 4) + alias
    flags = 0x8400 | (q[2] & 1) << 8 | (0 if ok else 5)
    s.sendto(q[:2] + struct.pack(">HHHHH", flags, 1, 1 if ans else 0, 0, 0) + q[12:qend] + ans, peer)
PY
python3 "$WORK/http.py" 127.0.0.1 $PORT & PIDS+=($!)
python3 "$WORK/http.py" ::1 $PORT & PIDS+=($!)
python3 "$WORK/dns.py" "$ZONE" "$ALIAS4" $PORT & PIDS+=($!)
sleep 1
curl -s --max-time 2 "http://127.0.0.1:$PORT/" >/dev/null && info "listeners up on 127.0.0.1/::1:$PORT (+ udp DNS)" || { fail "listener did not start"; exit 1; }

# --- A: lo0 alias + rdr ------------------------------------------------------
echo "== A: lo0 alias + pf rdr onto an unprivileged 127.0.0.1 listener"
sudo /sbin/ifconfig lo0 alias "$ALIAS4" netmask 255.255.255.255
sudo /sbin/ifconfig lo0 inet6 "$ALIAS6" prefixlen 128 alias
cat > "$WORK/rules" <<EOF
rdr pass on lo0 inet proto tcp from any to $ALIAS4 port { 80 443 } -> 127.0.0.1 port $PORT
rdr pass on lo0 inet6 proto tcp from any to $ALIAS6 port { 80 443 } -> ::1 port $PORT
rdr pass on bridge199 inet proto tcp from any to (bridge199) port 80 -> 127.0.0.1 port $PORT
rdr pass on $BRIDGE inet proto tcp from any to ($BRIDGE) port $BRIDGE_PORT -> 127.0.0.1 port $PORT
EOF
if sudo /sbin/pfctl -a "$ANCHOR" -f "$WORK/rules" 2>"$WORK/pf.err"; then
    pass "anchor loaded (incl. a (bridge199) rule for an interface that does not exist)  [B1]"
else
    fail "anchor load failed: $(cat "$WORK/pf.err")"
    info "retrying without the bridge199 rule to keep testing A"
    grep -v bridge199 "$WORK/rules" > "$WORK/rules2"
    sudo /sbin/pfctl -a "$ANCHOR" -f "$WORK/rules2" || exit 1
fi
TOKEN=$(sudo /sbin/pfctl -E 2>&1 | sed -n 's/^Token : //p')
info "pf enable token: ${TOKEN:-<none parsed>}"
out=$(curl -sS --max-time 3 "http://$ALIAS4/" 2>&1); [[ $out == spike-ok* ]] && pass "http://$ALIAS4/ -> $out" || fail "http://$ALIAS4/ -> $out"
out=$(curl -sS --max-time 3 "http://[$ALIAS6]/" 2>&1); [[ $out == spike-ok* ]] && pass "http://[$ALIAS6]/ -> $out" || fail "http://[$ALIAS6]/ -> $out"
out=$(curl -sS --max-time 3 "http://127.0.0.1:443/" -o /dev/null -w '%{http_code}' 2>&1); info "127.0.0.1:443 untouched by the spike (answers with whatever already owns it: $out)"

# --- B: vmnet gateway rdr ----------------------------------------------------
echo "== B: container -> ($BRIDGE):$BRIDGE_PORT redirected onto 127.0.0.1:$PORT"
if ifconfig "$BRIDGE" >/dev/null 2>&1; then
    GW=$(ifconfig "$BRIDGE" | awk '/inet /{print $2; exit}')
    CT=$(container list --format json 2>/dev/null | python3 -c 'import json,sys
for c in json.load(sys.stdin):
    n=c.get("configuration",{}).get("id","")
    if n.startswith("wpc-") and n.endswith("-wp"): print(n); break')
    if [ -n "$CT" ]; then
        out=$(container exec "$CT" curl -sS --max-time 5 "http://$GW:$BRIDGE_PORT/" 2>&1)
        [[ $out == spike-ok* ]] && pass "$CT -> http://$GW:$BRIDGE_PORT/ -> $out  [B2]" \
            || fail "$CT -> http://$GW:$BRIDGE_PORT/ -> $out  [B2] (see header note on l4s)"
    else
        info "no running wpc-*-wp container — start any site and re-run for B2"
    fi
else
    info "$BRIDGE absent — start any site and re-run for B2"
fi

# --- C: /etc/resolver with a custom port -------------------------------------
echo "== C: /etc/resolver/$ZONE with 'port $PORT'"
sudo mkdir -p /etc/resolver
printf '# wp-container spike\nnameserver 127.0.0.1\nport %s\n' "$PORT" | sudo tee "/etc/resolver/$ZONE" >/dev/null
sudo /usr/bin/killall -HUP mDNSResponder; sleep 1
scutil --dns | grep -A4 "domain   : $ZONE" | sed 's/^/        /'
out=$(dscacheutil -q host -a name "probe.$ZONE" | awk '/ip_address/{print $2}')
[ "$out" = "$ALIAS4" ] && pass "dscacheutil (libinfo) probe.$ZONE -> $out" || fail "dscacheutil probe.$ZONE -> '${out}'"
dns-sd -G v4 "probe.$ZONE" > "$WORK/dnssd" 2>&1 & DPID=$!; sleep 2; kill $DPID 2>/dev/null
grep -q "$ALIAS4" "$WORK/dnssd" && pass "dns-sd -G v4 (mDNSResponder / Safari path) probe.$ZONE -> $ALIAS4" \
    || { fail "dns-sd -G v4 probe.$ZONE"; sed 's/^/        /' "$WORK/dnssd"; }
out=$(curl -sS --max-time 3 "http://deep.sub.probe.$ZONE/" 2>&1)
[[ $out == spike-ok* ]] && pass "end-to-end http://deep.sub.probe.$ZONE/ -> $out" || fail "end-to-end -> $out"
echo "== done (Safari: open http://probe.$ZONE/ now if you want to eyeball it — press Enter to clean up)"
read -r _
