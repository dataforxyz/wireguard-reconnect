#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/run"

touch "$TMP/run/intent" "$TMP/run/guard"

cat >"$TMP/pkexec" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >"$MAKE_CONTROL_CALL_LOG"
rm -f "$MAKE_CONTROL_INTENT_STATE" "$MAKE_CONTROL_KILLSWITCH_STATE"
# Match the old helper's harmless non-zero result when wg0 was already absent.
exit 1
EOF

cat >"$TMP/curl" <<'EOF'
#!/bin/bash
exit 0
EOF

chmod +x "$TMP/pkexec" "$TMP/curl"
export MAKE_CONTROL_CALL_LOG="$TMP/run/call"
export MAKE_CONTROL_INTENT_STATE="$TMP/run/intent"
export MAKE_CONTROL_KILLSWITCH_STATE="$TMP/run/guard"

output="$(
  make -s -C "$REPO_DIR" reset \
    PKEXEC="$TMP/pkexec" \
    CURL="$TMP/curl" \
    PRIVILEGED_HELPER=/mock/wireguard-reconnect \
    INTENT_STATE="$MAKE_CONTROL_INTENT_STATE" \
    KILLSWITCH_STATE="$MAKE_CONTROL_KILLSWITCH_STATE"
)"

grep -Fxq '/mock/wireguard-reconnect down wg0' "$MAKE_CONTROL_CALL_LOG"
grep -Fq 'WireGuard reset complete' <<<"$output"
grep -Fq 'Direct internet connectivity check passed' <<<"$output"
test ! -e "$MAKE_CONTROL_INTENT_STATE"
test ! -e "$MAKE_CONTROL_KILLSWITCH_STATE"

printf 'make reset recovery test: OK\n'
