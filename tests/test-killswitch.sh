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
    [ -f "$NFT_ACTIVE" ] || exit 1
    cat "$NFT_CAPTURE"
    ;;
  delete)
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
export WG_KILLSWITCH_ENDPOINT_STATE_FILE="$TMP/run/endpoint"
export WG_KILLSWITCH_PERSISTENT_STATE_DIR="$TMP/state"
export WG_KILLSWITCH_PORTAL_CANDIDATE_STATE_FILE="$TMP/run/portal-candidate"
export WG_KILLSWITCH_LOG_FILE="$TMP/run/killswitch.log"

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
test -s "$TMP/state/endpoint"

# When unprivileged user namespaces are available, ask the real nft parser to
# validate the generated transaction inside a throwaway network namespace.
if command -v unshare >/dev/null 2>&1 && unshare -Urn true 2>/dev/null; then
  unshare -Urn /usr/bin/nft -c -f "$NFT_CAPTURE"
fi

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

printf 'kill-switch fail-closed tests: OK\n'
