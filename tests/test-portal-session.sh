#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/loginctl" <<'EOF'
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
chmod +x "$TMP/loginctl"

WIREGUARD_LOGINCTL_BIN="$TMP/loginctl" "$REPO_DIR/wireguard-portal" session-active 1000
if MOCK_SESSION_ACTIVE=no WIREGUARD_LOGINCTL_BIN="$TMP/loginctl" \
    "$REPO_DIR/wireguard-portal" session-active 1000; then exit 1; fi
if MOCK_SESSION_REMOTE=yes WIREGUARD_LOGINCTL_BIN="$TMP/loginctl" \
    "$REPO_DIR/wireguard-portal" session-active 1000; then exit 1; fi
if MOCK_SESSION_CLASS=manager WIREGUARD_LOGINCTL_BIN="$TMP/loginctl" \
    "$REPO_DIR/wireguard-portal" session-active 1000; then exit 1; fi
if MOCK_SESSION_TYPE=tty WIREGUARD_LOGINCTL_BIN="$TMP/loginctl" \
    "$REPO_DIR/wireguard-portal" session-active 1000; then exit 1; fi

grep -Fq 'desktop session became inactive during portal login' "$REPO_DIR/wireguard-portal"
printf 'captive portal active-session tests: OK\n'
