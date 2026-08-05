#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/config" "$TMP/run" "$TMP/state"

cat >"$TMP/bin/nft" <<'EOF'
#!/bin/bash
set -u
case "${1:-}" in
  -f)
    if [ "${NFT_FAIL_FULL:-0}" = "1" ] && grep -q 'WireGuard endpoint IPv' "$2"; then
      exit 1
    fi
    cp "$2" "$NFT_CAPTURE"
    : >"$NFT_ACTIVE"
    ;;
  list)
    [ "${NFT_FAIL_QUERY:-0}" != "1" ] || exit 1
    if [ "${2:-}" = "tables" ]; then
      [ ! -f "$NFT_ACTIVE" ] || echo 'table inet wg_killswitch'
      exit 0
    fi
    [ -f "$NFT_ACTIVE" ] || exit 1
    cat "$NFT_CAPTURE"
    ;;
  delete)
    [ "${NFT_FAIL_DELETE:-0}" != "1" ] || exit 1
    rm -f "$NFT_ACTIVE" "$NFT_CAPTURE"
    ;;
  *)
    exit 1
    ;;
esac
EOF

cat >"$TMP/bin/wg" <<'EOF'
#!/bin/bash
if [ "${3:-}" = "fwmark" ]; then
  echo 0xca6c
fi
EOF

cat >"$TMP/bin/ip" <<'EOF'
#!/bin/bash
# No public DNS host routes are present in the test namespace.
exit 1
EOF

cat >"$TMP/bin/logger" <<'EOF'
#!/bin/bash
exit 0
EOF

cat >"$TMP/bin/getent" <<'EOF'
#!/bin/bash
[ -n "${GETENT_CALL_LOG:-}" ] && printf '%s\n' "$*" >>"$GETENT_CALL_LOG"
if [ "${1:-}" = "ahostsv4" ] && [ -n "${GETENT_IPV4:-}" ]; then
  printf '%s STREAM %s\n' "$GETENT_IPV4" "${2:-host}"
  exit 0
fi
# Deliberately return no records unless a test opts into a synthetic DNS answer.
exit 2
EOF
chmod +x "$TMP/bin/"*

export PATH="$TMP/bin:/usr/bin:/bin"
export NFT_CAPTURE="$TMP/run/rules.nft"
export NFT_ACTIVE="$TMP/run/nft.active"
export WG_CONFIG_DIR="$TMP/config"
export WG_KILLSWITCH_STATE_FILE="$TMP/run/enabled"
export WG_KILLSWITCH_ROLLBACK_TOKEN_FILE="$TMP/run/rollback"
export WG_KILLSWITCH_ROLLBACK_LOCK_FILE="$TMP/run/rollback.lock"
export WG_KILLSWITCH_SELF_PATH="$REPO_DIR/wg-killswitch"
export WG_KILLSWITCH_ENDPOINT_STATE_FILE="$TMP/run/endpoint"
export WG_KILLSWITCH_PERSISTENT_STATE_DIR="$TMP/state"
export WG_KILLSWITCH_PORTAL_CANDIDATE_STATE_FILE="$TMP/run/portal-candidate"
export WG_KILLSWITCH_LOG_FILE="$TMP/run/killswitch.log"
export GETENT_CALL_LOG="$TMP/run/getent-calls"

cat >"$TMP/config/wg0.conf" <<'EOF'
[Interface]
PrivateKey = test
[Peer]
PublicKey = test
Endpoint = 203.0.113.10:51820
EOF

"$REPO_DIR/wg-killswitch" enable wg0
"$REPO_DIR/wg-killswitch" status >/dev/null
"$REPO_DIR/wg-killswitch" status-portal >/dev/null
[ "$(stat -c '%a' "$WG_KILLSWITCH_ENDPOINT_STATE_FILE")" = "600" ]

grep -q 'hook output.*policy drop' "$NFT_CAPTURE"
grep -q 'hook forward.*policy drop' "$NFT_CAPTURE"
grep -q '203.0.113.10.*udp dport 51820 accept' "$NFT_CAPTURE"
grep -q 'iifname "wgportal0" udp dport { 53, 443 } accept' "$NFT_CAPTURE"
grep -q 'iifname "wgportal0" tcp dport { 53, 80, 443 } accept' "$NFT_CAPTURE"
grep -q 'iifname "wgportal0" reject with icmpx type admin-prohibited' "$NFT_CAPTURE"
grep -q 'oifname "wgportal0" ct state established,related accept' "$NFT_CAPTURE"
grep -q 'oifname "wgportal0" reject with icmpx type admin-prohibited' "$NFT_CAPTURE"
portal_rule_line="$(grep -n 'iifname "wgportal0" udp dport' "$NFT_CAPTURE" | head -n1 | cut -d: -f1)"
tunnel_rule_line="$(grep -n 'forward via WireGuard' "$NFT_CAPTURE" | head -n1 | cut -d: -f1)"
ingress_reject_line="$(grep -n 'block unsolicited portal ingress' "$NFT_CAPTURE" | head -n1 | cut -d: -f1)"
private_rule_line="$(grep -n 'forward to LAN/private/tailnet IPv4' "$NFT_CAPTURE" | head -n1 | cut -d: -f1)"
[ "$portal_rule_line" -lt "$tunnel_rule_line" ]
[ "$ingress_reject_line" -lt "$private_rule_line" ]
grep -q 'block public non-WireGuard egress' "$NFT_CAPTURE"
if grep -q 'policy accept' "$NFT_CAPTURE"; then
  echo "unexpected accept-default policy" >&2
  exit 1
fi
test ! -e "$TMP/state/endpoint"

# When unprivileged user namespaces are available, ask the real nft parser to
# validate the generated transaction inside a throwaway network namespace.
if command -v unshare >/dev/null 2>&1 && unshare -Urn true 2>/dev/null; then
  unshare -Urn /usr/bin/nft -c -f "$NFT_CAPTURE"
fi

# Confirmation is atomic with the rollback watcher: a confirmed short timer
# must never disable the already-verified table later.
WG_KILLSWITCH_ROLLBACK_SECONDS=1 "$REPO_DIR/wg-killswitch" enable-rollback wg0
"$REPO_DIR/wg-killswitch" confirm
sleep 2
"$REPO_DIR/wg-killswitch" status >/dev/null

# Upgrade-time expiry re-arms the prior protected interface instead of ever
# disabling a pre-existing guard.
cp "$TMP/config/wg0.conf" "$TMP/config/wg1.conf"
WG_KILLSWITCH_ROLLBACK_SECONDS=1 WG_KILLSWITCH_ROLLBACK_ACTION=rearm \
  WG_KILLSWITCH_ROLLBACK_INTERFACE=wg1 \
  "$REPO_DIR/wg-killswitch" enable-rollback wg0
sleep 2
[ "$(cat "$WG_KILLSWITCH_STATE_FILE")" = "wg1" ]
"$REPO_DIR/wg-killswitch" status >/dev/null
"$REPO_DIR/wg-killswitch" enable wg0

# A second, explicitly traffic-verified refresh is the only operation allowed
# to promote the runtime endpoint into the persistent cache.
WIREGUARD_ENDPOINT_VERIFIED=1 "$REPO_DIR/wg-killswitch" enable wg0
test -s "$TMP/state/endpoint"

"$REPO_DIR/wg-killswitch" disable
test ! -e "$NFT_ACTIVE"

# If a hostname cannot be resolved and there is no matching cache, enable must
# return failure but leave a policy-drop guard installed. This is fail-closed.
rm -f "$TMP/state/endpoint"
sed -i 's/203\.0\.113\.10/vpn.invalid/' "$TMP/config/wg0.conf"
if "$REPO_DIR/wg-killswitch" enable wg0; then
  echo "expected unresolved endpoint to return failure" >&2
  exit 1
fi
test -e "$NFT_ACTIVE"
grep -q 'hook output.*policy drop' "$NFT_CAPTURE"
if grep -q 'WireGuard endpoint IPv' "$NFT_CAPTURE"; then
  echo "unresolved endpoint unexpectedly received an allow rule" >&2
  exit 1
fi
if "$REPO_DIR/wg-killswitch" status >/dev/null; then
  echo "expected unresolved guard status to be unverified" >&2
  exit 1
fi
"$REPO_DIR/wg-killswitch" status-portal >/dev/null

# A DNS answer obtained before any verified WG traffic may be used only as a
# runtime endpoint allowlist candidate. It must not poison the persistent cache.
export GETENT_IPV4=198.51.100.50
"$REPO_DIR/wg-killswitch" enable wg0
"$REPO_DIR/wg-killswitch" status >/dev/null
grep -q '198.51.100.50.*udp dport 51820 accept' "$NFT_CAPTURE"
test ! -e "$TMP/state/endpoint"
unset GETENT_IPV4

# With a guard already active, resume/reconnect must use the last verified
# persistent endpoint before DNS. Public DNS is blocked by the guard and waiting
# for it would consume the reconnect helper's entire timeout.
cat >"$WG_KILLSWITCH_PERSISTENT_STATE_DIR/endpoint" <<'EOF'
IFACE=wg0
ENDPOINT_HOST=vpn.invalid
ENDPOINT_PORT=51820
ENDPOINT4=203.0.113.30
ENDPOINT6=
WG_MARK=0xca6c
EOF
: >"$GETENT_CALL_LOG"
"$REPO_DIR/wg-killswitch" enable wg0
"$REPO_DIR/wg-killswitch" status >/dev/null
grep -q '203.0.113.30.*udp dport 51820 accept' "$NFT_CAPTURE"
test ! -s "$GETENT_CALL_LOG"
rm -f "$WG_KILLSWITCH_PERSISTENT_STATE_DIR/endpoint"
cp "$WG_KILLSWITCH_ENDPOINT_STATE_FILE" "$TMP/run/ordinary-endpoint-before-portal"

# A portal DNS result is usable for the immediate protected bootstrap but must
# not replace the last verified persistent cache before WG traffic succeeds.
cat >"$WG_KILLSWITCH_PORTAL_CANDIDATE_STATE_FILE" <<'EOF'
IFACE=wg0
ENDPOINT_HOST=vpn.invalid
ENDPOINT_PORT=51820
ENDPOINT4=203.0.113.20
ENDPOINT6=
WG_MARK=0xca6c
EOF
export GETENT_IPV4=198.51.100.50
WIREGUARD_PORTAL_RESTORE=1 "$REPO_DIR/wg-killswitch" enable wg0
"$REPO_DIR/wg-killswitch" status >/dev/null
grep -q '203.0.113.20.*udp dport 51820 accept' "$NFT_CAPTURE"
if grep -q '198.51.100.50.*udp dport 51820 accept' "$NFT_CAPTURE"; then
  echo "untrusted live DNS overrode the atomic portal candidate" >&2
  exit 1
fi
test ! -e "$TMP/state/endpoint"
cmp -s "$WG_KILLSWITCH_ENDPOINT_STATE_FILE" "$TMP/run/ordinary-endpoint-before-portal"

# Discarding a failed portal candidate must return ordinary reconnects to the
# prior generic runtime state; the portal IP cannot leak across provenance.
rm -f "$WG_KILLSWITCH_PORTAL_CANDIDATE_STATE_FILE"
: >"$GETENT_CALL_LOG"
"$REPO_DIR/wg-killswitch" enable wg0
"$REPO_DIR/wg-killswitch" status >/dev/null
grep -q '203.0.113.30.*udp dport 51820 accept' "$NFT_CAPTURE"
if grep -q '203.0.113.20.*udp dport 51820 accept' "$NFT_CAPTURE"; then
  echo "discarded portal candidate leaked into ordinary reconnect state" >&2
  exit 1
fi
test ! -s "$GETENT_CALL_LOG"
unset GETENT_IPV4

# A rejected full ruleset must fall back to a smaller emergency policy-drop
# guard and still report failure so WireGuard is not brought up.
"$REPO_DIR/wg-killswitch" disable
sed -i 's/vpn\.invalid/203.0.113.10/' "$TMP/config/wg0.conf"
export NFT_FAIL_FULL=1
if "$REPO_DIR/wg-killswitch" enable wg0; then
  echo "expected full-ruleset failure to propagate" >&2
  exit 1
fi
test -e "$NFT_ACTIVE"
grep -q 'hook output.*policy drop' "$NFT_CAPTURE"
grep -q 'emergency block public non-WireGuard egress' "$NFT_CAPTURE"
"$REPO_DIR/wg-killswitch" status-portal >/dev/null

# A failed nft deletion must be reported and retain enough state/helper context
# for a later recovery attempt instead of claiming success.
export NFT_FAIL_DELETE=1
if "$REPO_DIR/wg-killswitch" disable; then
  echo "expected nft delete failure to propagate" >&2
  exit 1
fi
test -e "$NFT_ACTIVE"
test -e "$WG_KILLSWITCH_STATE_FILE"
unset NFT_FAIL_DELETE
export NFT_FAIL_QUERY=1
if "$REPO_DIR/wg-killswitch" disable; then
  echo "expected nft query failure to propagate" >&2
  exit 1
fi
test -e "$NFT_ACTIVE"
test -e "$WG_KILLSWITCH_STATE_FILE"
unset NFT_FAIL_QUERY
"$REPO_DIR/wg-killswitch" disable
test ! -e "$NFT_ACTIVE"
test ! -e "$WG_KILLSWITCH_STATE_FILE"

# The only append-style runtime log is bounded during long uptimes. Journald
# handles its own rotation; reconnect and portal transaction logs are truncated
# when each new transaction begins.
for _ in 1 2 3 4 5; do
  WG_KILLSWITCH_LOG_MAX_BYTES=1 WG_KILLSWITCH_LOG_KEEP_LINES=2 \
    "$REPO_DIR/wg-killswitch" confirm
done
test "$(wc -l <"$WG_KILLSWITCH_LOG_FILE")" -le 2
# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq 'WIREGUARD_ENDPOINT_VERIFIED="$endpoint_verified"' "$REPO_DIR/wireguard-reconnect"
grep -Fq 'if vpn_traffic_verified; then' "$REPO_DIR/wireguard-reconnect"
# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq 'endpoint_state="$PORTAL_ENDPOINT_CANDIDATE"' "$REPO_DIR/wireguard-reconnect"

printf 'kill-switch fail-closed tests: OK\n'
