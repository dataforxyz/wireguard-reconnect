#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/run"

cat >"$TMP/bin/ip" <<'EOF'
#!/bin/bash
# Model the recovery case: wg0 is missing.
if [ "${1:-}" = "link" ] && [ "${2:-}" = "show" ]; then
  exit 1
fi
exit 1
EOF

cat >"$TMP/bin/wg" <<'EOF'
#!/bin/bash
exit 0
EOF

cat >"$TMP/bin/pkexec" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$STATUS_CALL_LOG"
EOF

cat >"$TMP/bin/pkill" <<'EOF'
#!/bin/bash
exit 0
EOF

cat >"$TMP/bin/notify-send" <<'EOF'
#!/bin/bash
exit 0
EOF

chmod +x "$TMP/bin/"*

export PATH="$TMP/bin:/usr/bin:/bin"
export STATUS_CALL_LOG="$TMP/run/calls"
export WIREGUARD_RECONNECT_HELPER="$TMP/bin/helper"
export WIREGUARD_PORTAL_STATE="$TMP/run/portal.active"
export WIREGUARD_KILLSWITCH_STATE="$TMP/run/guard"
export WIREGUARD_INTENT_STATE="$TMP/run/intent"
export XDG_RUNTIME_DIR="$TMP/run"

"$REPO_DIR/wireguard-status" disconnect

grep -Fxq "$TMP/bin/helper down wg0" "$STATUS_CALL_LOG"

printf 'wg1\n' >"$TMP/run/interface"
: >"$STATUS_CALL_LOG"
WIREGUARD_PUBLIC_INTERFACE_FILE="$TMP/run/interface" "$REPO_DIR/wireguard-status" disconnect
grep -Fxq "$TMP/bin/helper down wg1" "$STATUS_CALL_LOG"

touch "$WIREGUARD_PORTAL_STATE"
portal_status="$("$REPO_DIR/wireguard-status")"
grep -Fq '"class": "portal"' <<<"$portal_status"
grep -Fq 'Normal host traffic remains blocked' <<<"$portal_status"
: >"$STATUS_CALL_LOG"
"$REPO_DIR/wireguard-status" toggle
test ! -s "$STATUS_CALL_LOG"

# An armed guard is protection state, not boot connection intent. With no
# autostart-owned intent marker, Waybar must remain manual and not reconnect.
rm -f "$WIREGUARD_PORTAL_STATE"
touch "$WIREGUARD_KILLSWITCH_STATE"
: >"$STATUS_CALL_LOG"
guarded_status="$(WIREGUARD_AUTORECONNECT=0 "$REPO_DIR/wireguard-status")"
grep -Fq '"class": "disconnected"' <<<"$guarded_status"
grep -Fq 'kill switch is armed' <<<"$guarded_status"
test ! -s "$STATUS_CALL_LOG"

if grep -Eq 'Left-click|Right-click|left-click|right-click' "$REPO_DIR/wireguard-status"; then
  echo "unsafe click instruction remains in wireguard-status" >&2
  exit 1
fi
grep -q 'Middle-click' "$REPO_DIR/wireguard-status"
printf 'status disconnect, portal isolation, and safe-click tests: OK\n'
