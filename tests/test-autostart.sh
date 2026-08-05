#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/run"

cat >"$TMP/bin/ip" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-4" ] && [ "${2:-}" = "route" ]; then
  [ "${AUTOSTART_UNDERLAY:-1}" = "1" ] || exit 1
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

cat >"$TMP/bin/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$TMP/bin/"*

export PATH="$TMP/bin:/usr/bin:/bin"
export WIREGUARD_INTENT_STATE="$TMP/run/intent"
export WIREGUARD_AUTOSTART_SUPPRESS_STATE="$TMP/run/autostart-suppressed"
export WIREGUARD_RECONNECT_HELPER="$TMP/bin/helper"
export WIREGUARD_STARTUP_WAIT=0
export AUTOSTART_CALL_LOG="$TMP/run/calls"

AUTOSTART_IFACE_PRESENT=1 "$REPO_DIR/wireguard-autostart"
test -s "$TMP/run/intent"
test ! -e "$AUTOSTART_CALL_LOG"

AUTOSTART_IFACE_PRESENT=0 "$REPO_DIR/wireguard-autostart"
grep -Fxq 'auto-up wg0' "$AUTOSTART_CALL_LOG"

# If the monitor is opted out, a late underlay must make systemd retry the
# bounded boot connector instead of silently abandoning autostart.
set +e
AUTOSTART_UNDERLAY=0 WIREGUARD_AUTOSTART_RETRY=1 "$REPO_DIR/wireguard-autostart"
retry_rc=$?
set -e
[ "$retry_rc" -ne 0 ]
AUTOSTART_UNDERLAY=0 WIREGUARD_AUTOSTART_RETRY=0 "$REPO_DIR/wireguard-autostart"

# An intentional same-boot disconnect cancels pending systemd retries.
rm -f "$WIREGUARD_INTENT_STATE"
: >"$WIREGUARD_AUTOSTART_SUPPRESS_STATE"
: >"$AUTOSTART_CALL_LOG"
AUTOSTART_UNDERLAY=1 WIREGUARD_AUTOSTART_RETRY=1 "$REPO_DIR/wireguard-autostart"
test ! -e "$WIREGUARD_INTENT_STATE"
test ! -s "$AUTOSTART_CALL_LOG"

printf 'autostart idempotency tests: OK\n'
