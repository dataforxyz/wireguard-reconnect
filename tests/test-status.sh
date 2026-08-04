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
export XDG_RUNTIME_DIR="$TMP/run"

"$REPO_DIR/wireguard-status" disconnect

grep -Fxq "$TMP/bin/helper down wg0" "$STATUS_CALL_LOG"
! grep -Eq 'Left-click|Right-click|left-click|right-click' "$REPO_DIR/wireguard-status"
grep -q 'Middle-click' "$REPO_DIR/wireguard-status"
printf 'status missing-interface disconnect and safe-click tests: OK\n'
