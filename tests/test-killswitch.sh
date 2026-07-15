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
# Deliberately return no records; literal IPv4 endpoints do not call getent.
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

grep -q 'hook output.*policy drop' "$NFT_CAPTURE"
grep -q 'hook forward.*policy drop' "$NFT_CAPTURE"
grep -q '203.0.113.10.*udp dport 51820 accept' "$NFT_CAPTURE"
grep -q 'block public non-WireGuard egress' "$NFT_CAPTURE"
if grep -q 'policy accept' "$NFT_CAPTURE"; then
  echo "unexpected accept-default policy" >&2
  exit 1
fi
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

printf 'kill-switch fail-closed tests: OK\n'
