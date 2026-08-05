#!/bin/bash
# Boot connection is controlled by the autostart-owned intent marker. Merely
# running the monitor (or arming a guard) must not create connection intent.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/run"

cat >"$TMP/bin/ip" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "link" ] && [ "${2:-}" = "show" ]; then exit 1; fi
if [ "${1:-}" = "-4" ] && [ "${2:-}" = "route" ] && [ "${3:-}" = "show" ]; then
  echo 'default via 192.0.2.1 dev wlan0'
  exit 0
fi
if [ "${1:-}" = "monitor" ]; then
  /usr/bin/sleep 0.2
  exit 0
fi
exit 1
EOF

cat >"$TMP/bin/curl" <<'EOF'
#!/bin/bash
printf '000'
exit 28
EOF

cat >"$TMP/bin/helper" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$MONITOR_CALL_LOG"
exit 0
EOF

cat >"$TMP/bin/logger" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$TMP/bin/"*

run_monitor() {
  env \
    PATH="$TMP/bin:/usr/bin:/bin" \
    MONITOR_CALL_LOG="$TMP/run/calls" \
    WIREGUARD_INTENT_STATE="$TMP/run/intent" \
    WIREGUARD_KILLSWITCH_STATE="$TMP/run/guard" \
    WIREGUARD_RECONNECT_HELPER="$TMP/bin/helper" \
    WIREGUARD_KILLSWITCH_HELPER="$TMP/bin/helper" \
    WIREGUARD_MONITOR_LOCK="$TMP/run/action.lock" \
    WIREGUARD_RECONNECT_LOCK="$TMP/run/reconnect.lock" \
    WIREGUARD_PORTAL_STATE="$TMP/run/portal.active" \
    WIREGUARD_KILLSWITCH=1 \
    WIREGUARD_GUARD_CHECK_INTERVAL=0.05 \
    WIREGUARD_AUTO_PORTAL=0 \
    WIREGUARD_MONITOR_DEBOUNCE=0 \
    WIREGUARD_MONITOR_STABILIZE_DELAY=0 \
    "$REPO_DIR/wireguard-monitor"
}

# A monitor enabled at boot without autostart must remain passive. An absent
# guard state also models intentional disconnect: the watchdog must not re-arm.
run_monitor
test ! -e "$TMP/run/calls"

# Once autostart or a manual up action records intent, the same monitor repairs.
printf 'wg0\n' >"$TMP/run/intent"
run_monitor
grep -Fxq 'auto-up wg0' "$TMP/run/calls"

printf 'monitor boot-intent separation tests: OK\n'
