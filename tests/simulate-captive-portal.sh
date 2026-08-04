#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() {
    [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

python3 -u "$REPO_DIR/tests/portal-simulator.py" >"$TMP/port" 2>"$TMP/server.log" &
SERVER_PID=$!

for _ in $(seq 1 50); do
    [ -s "$TMP/port" ] && break
    kill -0 "$SERVER_PID" 2>/dev/null || {
        cat "$TMP/server.log" >&2
        exit 1
    }
    sleep 0.05
done

port="$(head -n1 "$TMP/port" 2>/dev/null || true)"
[[ "$port" =~ ^[0-9]+$ ]] || {
    echo "Captive portal simulator did not start" >&2
    cat "$TMP/server.log" >&2
    exit 1
}

url="http://127.0.0.1:${port}/generate_204"
echo "Local captive portal simulator: $url"
"$REPO_DIR/wireguard-portal" simulate "$url"
"$REPO_DIR/tests/test-portal-netns.sh"
echo "Local captive portal simulation: PASS"
