#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/run"

cat >"$TMP/bin/ip" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-4" ] && [ "${2:-}" = "route" ]; then
  echo 'default via 192.0.2.1 dev wlan0'
  exit 0
fi
if [ "${1:-}" = "link" ] && [ "${2:-}" = "show" ]; then
  [ "${AUTOSTART_IFACE_PRESENT:-0}" = "1" ]
  exit $?
fi
exit 1
EOF

cat >"$TMP/bin/helper" <<'EOF'
#!/bin/bash
printf '%s %s\n' "$1" "$2" >>"$AUTOSTART_CALL_LOG"
EOF

cat >"$TMP/bin/logger" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$TMP/bin/"*

export PATH="$TMP/bin:/usr/bin:/bin"
export WIREGUARD_INTENT_STATE="$TMP/run/intent"
export WIREGUARD_RECONNECT_HELPER="$TMP/bin/helper"
export WIREGUARD_STARTUP_WAIT=0
export AUTOSTART_CALL_LOG="$TMP/run/calls"

AUTOSTART_IFACE_PRESENT=1 "$REPO_DIR/wireguard-autostart"
test -s "$TMP/run/intent"
test ! -e "$AUTOSTART_CALL_LOG"

AUTOSTART_IFACE_PRESENT=0 "$REPO_DIR/wireguard-autostart"
grep -Fxq 'up wg0' "$AUTOSTART_CALL_LOG"

printf 'autostart idempotency tests: OK\n'
