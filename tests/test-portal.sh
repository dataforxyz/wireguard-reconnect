#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# The local simulator exercises the detector transition from redirected captive
# response to the expected 204 without root privileges or real firewall edits.
output="$("$REPO_DIR/tests/simulate-captive-portal.sh")"
grep -Fq 'initial detector response HTTP 302' <<<"$output"
grep -Fq 'captive portal detected; isolated browser would open' <<<"$output"
grep -Fq 'HTTP 204 detected; namespace would be destroyed' <<<"$output"
grep -Fq 'WireGuard reconnect and verification would run' <<<"$output"
grep -Eq 'portal namespace kernel (isolation test: OK|test: SKIP)' <<<"$output"
grep -Fq 'Local captive portal simulation: PASS' <<<"$output"

# Security regressions: production mode must require root, use a fixed namespace
# and ephemeral browser profile, and clean the namespace before VPN restoration.
grep -Fq 'Production portal mode must run as root' "$REPO_DIR/wireguard-portal"
grep -Fq 'WIREGUARD_PORTAL_LOCK_HELD' "$REPO_DIR/wireguard-reconnect"
grep -Fq 'WIREGUARD_PORTAL_LOCK_HELD' "$REPO_DIR/wireguard-portal"
# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq 'net.ipv4.conf.${HOST_IFACE}.forwarding' "$REPO_DIR/wireguard-portal"
# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq 'if [ "$PHYSICAL_FORWARD_PREVIOUS" != "1" ]' "$REPO_DIR/wireguard-portal"
if grep -Fq 'net.ipv4.ip_forward=1' "$REPO_DIR/wireguard-portal"; then
  echo "portal helper must not toggle global IPv4 router mode" >&2
  exit 1
fi
grep -Fq 'cp.cloudflare.com/generate_204' "$REPO_DIR/wireguard-portal"
grep -Fq 'portal_resources_present' "$REPO_DIR/wireguard-portal"
# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq 'physical interface $PHYSICAL_IFACE disappeared' "$REPO_DIR/wireguard-portal"
grep -Fq 'WIREGUARD_PORTAL_RESTORE=1' "$REPO_DIR/wireguard-portal"
grep -Fq 'WIREGUARD_PORTAL_RESTORE' "$REPO_DIR/wireguard-reconnect"
# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq 'ip netns add "$NS"' "$REPO_DIR/wireguard-portal"
grep -Fq 'hosts: files dns' "$REPO_DIR/wireguard-portal"
# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq -- '--user-data-dir="$PROFILE_DIR"' "$REPO_DIR/wireguard-portal"
grep -Fq 'cleanup_namespace' "$REPO_DIR/wireguard-portal"
grep -Fq 'hook input priority -10' "$REPO_DIR/wireguard-portal"
# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq 'iifname "$HOST_IFACE" reject' "$REPO_DIR/wireguard-portal"
grep -Fq 'refresh_endpoint_cache' "$REPO_DIR/wireguard-portal"
grep -Fq 'unverified runtime endpoint candidate' "$REPO_DIR/wireguard-portal"
grep -Fq 'promoted the endpoint candidate after verified WireGuard traffic' "$REPO_DIR/wireguard-portal"
grep -Fq '/var/lib/wg-killswitch/endpoint' "$REPO_DIR/wireguard-portal"
grep -Fq 'restore_vpn' "$REPO_DIR/wireguard-portal"
# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq '[ -f "$PORTAL_STATE" ] && return 0' "$REPO_DIR/wireguard-monitor"
grep -Fq 'status-portal' "$REPO_DIR/wireguard-reconnect"
grep -Fq 'Captive-portal mode is active; refusing' "$REPO_DIR/wireguard-reconnect"

# Exercise the early-validation cleanup as uid 0 in a throwaway user+mount+net
# namespace. The parent-created active marker must not survive an invalid URL.
if command -v unshare >/dev/null 2>&1 && unshare -Urnm true 2>/dev/null; then
  # shellcheck disable=SC2016 # Inner script intentionally expands in the child shell.
  unshare -Urnm bash -c '
    set -e
    mount -t tmpfs tmpfs /run
    printf marker >/run/wireguard-portal.active
    set +e
    "$1" run wg0 "bad domain with spaces" 1000 >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 2 ]
    [ ! -e /run/wireguard-portal.active ]
  ' bash "$REPO_DIR/wireguard-portal"

  # A live portal lock must reject every normal helper action before any
  # kill-switch or wg-quick mutation can run.
  # shellcheck disable=SC2016 # Inner script intentionally expands in the child shell.
  unshare -Urnm bash -c '
    set -e
    mount -t tmpfs tmpfs /run
    mkdir -p /tmp/wgtest
    : >/tmp/wgtest/wg0.conf
    mount --bind /tmp/wgtest /etc/wireguard
    flock /run/wireguard-portal.lock sleep 10 & holder=$!
    trap "kill $holder 2>/dev/null || true" EXIT
    sleep 0.05
    set +e
    "$1" down wg0 >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 1 ]
    grep -Fq "Captive-portal mode is active; refusing down" /run/wireguard-reconnect.log
  ' bash "$REPO_DIR/wireguard-reconnect"
fi

printf 'captive portal orchestration tests: OK\n'
