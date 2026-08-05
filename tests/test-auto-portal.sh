#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/run" "$TMP/sys/class/net/wlan0/wireless" "$TMP/run/user/1000"
python3 - "$TMP/run/user/1000/wayland-test" <<'PY'
import socket
import sys
sock = socket.socket(socket.AF_UNIX)
sock.bind(sys.argv[1])
sock.close()
PY

cat >"$TMP/bin/ip" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-4" ] && [ "${2:-}" = "route" ] && [ "${3:-}" = "show" ]; then
  printf 'default via 192.0.2.1 dev %s\n' "${MOCK_PHYSICAL_IFACE:-wlan0}"
  exit 0
fi
if [ "${1:-}" = "link" ] && [ "${2:-}" = "show" ] && [ "${MOCK_VPN_ONLINE:-0}" = "1" ]; then
  exit 0
fi
if [ "${1:-}" = "-4" ] && [ "${2:-}" = "route" ] && [ "${3:-}" = "get" ] && [ "${MOCK_VPN_ONLINE:-0}" = "1" ]; then
  printf '9.9.9.9 dev wg0\n'
  exit 0
fi
exit 1
EOF

cat >"$TMP/bin/iw" <<'EOF'
#!/bin/bash
cat <<EOT
Connected to ${MOCK_BSSID:-02:00:00:00:00:01} (on ${2:-wlan0})
	SSID: ${MOCK_SSID:-Test Portal WiFi}
EOT
EOF

cat >"$TMP/bin/loginctl" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "list-sessions" ]; then
  printf 'test-session 1000 testuser seat0 1 user tty1 no -\n'
  exit 0
fi
if [ "${1:-}" = "show-session" ]; then
  case "${4:-}" in
    Active) printf '%s\n' "${MOCK_SESSION_ACTIVE:-yes}" ;;
    Remote) printf '%s\n' "${MOCK_SESSION_REMOTE:-no}" ;;
    Class) printf '%s\n' "${MOCK_SESSION_CLASS:-user}" ;;
    Type) printf '%s\n' "${MOCK_SESSION_TYPE:-wayland}" ;;
    *) exit 1 ;;
  esac
  exit 0
fi
exit 1
EOF

cat >"$TMP/bin/helper" <<'EOF'
#!/bin/bash
printf 'uid=%s inherited=%s args=%s\n' "${PKEXEC_UID:-missing}" "${WIREGUARD_RECONNECT_LOCK_HELD:-0}" "$*" >>"$AUTO_PORTAL_CALL_LOG"
sleep "${MOCK_HELPER_DELAY:-0}"
EOF

cat >"$TMP/bin/curl" <<'EOF'
#!/bin/bash
[ "${MOCK_VPN_ONLINE:-0}" = "1" ] && printf '204'
EOF

cat >"$TMP/bin/logger" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$TMP/bin/"*

printf '1000\n' >"$TMP/portal-user"
chmod 0600 "$TMP/portal-user"

run_monitor() {
  unshare -Ur env \
    PATH="$TMP/bin:/usr/bin:/bin" \
    MOCK_PHYSICAL_IFACE="${MOCK_PHYSICAL_IFACE:-wlan0}" \
    MOCK_BSSID="${MOCK_BSSID:-02:00:00:00:00:01}" \
    MOCK_SSID="${MOCK_SSID:-Test Portal WiFi}" \
    MOCK_HELPER_DELAY="${MOCK_HELPER_DELAY:-0}" \
    MOCK_SESSION_ACTIVE="${MOCK_SESSION_ACTIVE:-yes}" \
    MOCK_SESSION_REMOTE="${MOCK_SESSION_REMOTE:-no}" \
    MOCK_SESSION_CLASS="${MOCK_SESSION_CLASS:-user}" \
    MOCK_SESSION_TYPE="${MOCK_SESSION_TYPE:-wayland}" \
    MOCK_VPN_ONLINE="${MOCK_VPN_ONLINE:-0}" \
    AUTO_PORTAL_CALL_LOG="$TMP/run/calls" \
    WIREGUARD_RECONNECT_HELPER="$TMP/bin/helper" \
    WIREGUARD_PORTAL_USER_FILE="$TMP/portal-user" \
    WIREGUARD_PORTAL_STAMP="$TMP/run/stamp" \
    WIREGUARD_MONITOR_LOCK="$TMP/run/action.lock" \
    WIREGUARD_RECONNECT_LOCK="$TMP/run/reconnect.lock" \
    WIREGUARD_IW_BIN="$TMP/bin/iw" \
    WIREGUARD_LOGINCTL_BIN="$TMP/bin/loginctl" \
    WIREGUARD_SYS_CLASS_NET="$TMP/sys/class/net" \
    WIREGUARD_USER_RUNTIME_ROOT="$TMP/run/user" \
    WIREGUARD_PORTAL_COOLDOWN=300 \
    WIREGUARD_PORTAL_GLOBAL_COOLDOWN=0 \
    "$REPO_DIR/wireguard-monitor" --auto-portal-once
}

if ! command -v unshare >/dev/null 2>&1 || ! unshare -Ur true 2>/dev/null; then
  printf 'automatic portal monitor tests: SKIP (unprivileged user namespaces unavailable)\n'
  exit 0
fi

run_monitor
grep -Fxq 'uid=1000 inherited=1 args=auto-portal wg0' "$TMP/run/calls"
[ "$(stat -c '%a' "$TMP/run/stamp")" = "600" ]

# Same BSSID is rate-limited.
run_monitor || true
test "$(wc -l <"$TMP/run/calls")" -eq 1

# A new AP fingerprint bypasses the old AP's cooldown.
MOCK_BSSID=02:00:00:00:00:02 run_monitor
test "$(wc -l <"$TMP/run/calls")" -eq 2

# Automatic portal mode is Wi-Fi-only.
MOCK_PHYSICAL_IFACE=enp5s0 run_monitor || true
test "$(wc -l <"$TMP/run/calls")" -eq 2

# A remote or inactive graphical session cannot receive an automatic browser.
MOCK_BSSID=02:00:00:00:00:03 MOCK_SESSION_ACTIVE=no run_monitor || true
test "$(wc -l <"$TMP/run/calls")" -eq 2
MOCK_BSSID=02:00:00:00:00:03 MOCK_SESSION_REMOTE=yes run_monitor || true
test "$(wc -l <"$TMP/run/calls")" -eq 2

# A group/world-writable identity file is not trusted by the root monitor.
chmod 0666 "$TMP/portal-user"
MOCK_BSSID=02:00:00:00:00:04 run_monitor || true
test "$(wc -l <"$TMP/run/calls")" -eq 2
chmod 0600 "$TMP/portal-user"

# A VPN that recovered before the automatic action lock is acquired is left up.
MOCK_BSSID=02:00:00:00:00:05 MOCK_VPN_ONLINE=1 run_monitor || true
test "$(wc -l <"$TMP/run/calls")" -eq 2

# A concurrent reconnect/action prevents watchdog portal dispatch.
flock "$TMP/run/action.lock" sleep 0.2 & lock_holder=$!
MOCK_BSSID=02:00:00:00:00:05 run_monitor || true
wait "$lock_holder"
test "$(wc -l <"$TMP/run/calls")" -eq 2

# A direct helper action uses a separate lock and also blocks stale dispatch.
flock "$TMP/run/reconnect.lock" sleep 0.2 & helper_lock_holder=$!
MOCK_BSSID=02:00:00:00:00:05 run_monitor || true
wait "$helper_lock_holder"
test "$(wc -l <"$TMP/run/calls")" -eq 2

# Concurrent event and periodic checks serialize the cooldown decision.
: >"$TMP/run/calls"
rm -f "$TMP/run/stamp" "$TMP/run/stamp.lock"
MOCK_HELPER_DELAY=0.2 run_monitor & first=$!
MOCK_HELPER_DELAY=0.2 run_monitor & second=$!
wait "$first" || true
wait "$second" || true
test "$(wc -l <"$TMP/run/calls")" -eq 1

grep -Fq 'exec 9>/run/wireguard-monitor.portal-scan.lock' "$REPO_DIR/wireguard-monitor"
grep -Fq 'repair_if_needed "periodic Wi-Fi health check"' "$REPO_DIR/wireguard-monitor"
printf 'automatic Wi-Fi captive portal detection tests: OK\n'
