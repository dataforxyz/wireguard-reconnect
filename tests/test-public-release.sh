#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Public source must not contain the former machine-specific user identity.
if git -C "$REPO_DIR" grep -IEq \
    'dxyz|dataforxyz@gmail\.com' -- ':!tests/test-public-release.sh'; then
  echo "personal machine identity remains in the public tree" >&2
  exit 1
fi

grep -Fq 'GNU GENERAL PUBLIC LICENSE' "$REPO_DIR/LICENSE"
grep -Fq 'GPL-3.0-or-later' "$REPO_DIR/README.md"
grep -Fq 'Copyright (C) 2026 dataforxyz' "$REPO_DIR/COPYRIGHT"
grep -Fq 'SPDX-License-Identifier: GPL-3.0-or-later' "$REPO_DIR/wireguard-reconnect"
test -f "$REPO_DIR/SECURITY.md"
test -f "$REPO_DIR/CONTRIBUTING.md"
test -f "$REPO_DIR/CODE_OF_CONDUCT.md"
test -f "$REPO_DIR/.github/workflows/ci.yml"

grep -Fq 'TAILSCALE_ENABLED_FILE=' "$REPO_DIR/wireguard-reconnect"
grep -Fq 'ENABLE_TAILSCALE_INTEGRATION' "$REPO_DIR/install.sh"
# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq '[ "$TAILSCALE_ENABLED" = "1" ]' "$REPO_DIR/wireguard-reconnect"
if grep -Fq 'tailscale up' "$REPO_DIR/wireguard-reconnect"; then
  echo "helper must not start or reconfigure Tailscale" >&2
  exit 1
fi

grep -Fq 'AUTHORIZED_INTERFACE_FILE=' "$REPO_DIR/wireguard-reconnect"
# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq 'Interface $IFACE is not authorized' "$REPO_DIR/wireguard-reconnect"
grep -Fq 'WIREGUARD_INTERFACE=%s' "$REPO_DIR/install.sh"
grep -Fq 'PUBLIC_INTERFACE_FILE=' "$REPO_DIR/wireguard-status"
grep -Fq '/usr/local/share/wireguard-reconnect/interface' "$REPO_DIR/Makefile"
grep -Fq 'EnvironmentFile=/etc/wireguard-reconnect/environment' "$REPO_DIR/wireguard-killswitch.service"
grep -Fq 'RequiredBy=network-pre.target' "$REPO_DIR/wireguard-killswitch.service"
if grep -Fq 'enable wg0' "$REPO_DIR/wireguard-killswitch.service"; then
  echo "kill-switch unit remains hardcoded to wg0" >&2
  exit 1
fi

# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq 'enable-rollback "$INTERFACE"' "$REPO_DIR/install.sh"
grep -Fq 'wg-killswitch confirm' "$REPO_DIR/install.sh"
grep -Fq 'trap rollback_install EXIT' "$REPO_DIR/install.sh"
grep -Fq 'ALLOW_REMOTE_INSTALL' "$REPO_DIR/install.sh"
# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq 'if [ "$guard_was_active" != "1" ]' "$REPO_DIR/install.sh"
# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq 'enable "$prior_guard_interface"' "$REPO_DIR/install.sh"
grep -Fq 'WG_KILLSWITCH_ROLLBACK_ACTION=rearm' "$REPO_DIR/install.sh"
grep -Fq 'systemctl stop wireguard-monitor.service' "$REPO_DIR/install.sh"
grep -Fq 'Unsafe target user directory' "$REPO_DIR/install.sh"
grep -Fq 'Unsafe desktop user name' "$REPO_DIR/install.sh"
grep -Fq 'requested_iface_was_present' "$REPO_DIR/install.sh"
# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq 'wg-quick down "$prior_installed_interface"' "$REPO_DIR/install.sh"
grep -Fq 'restore_managed_tailscale_rules' "$REPO_DIR/install.sh"

grep -Fq 'WIREGUARD_PORTAL_SCAN_INTERVAL:-60' "$REPO_DIR/wireguard-monitor"
grep -Fq 'SuccessExitStatus=143' "$REPO_DIR/wireguard-monitor.service"
grep -Fq 'make uninstall' "$REPO_DIR/README.md"
grep -Fq 'support-info:' "$REPO_DIR/Makefile"
grep -Fq 'WIREGUARD_PORTAL_CHECK_URL_PRIMARY' "$REPO_DIR/wireguard-portal"
# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq 'chmod 0600 "$ENDPOINT_STATE_FILE"' "$REPO_DIR/wg-killswitch"
grep -Fq 'state retained' "$REPO_DIR/wg-killswitch"
grep -Fq 'confirm_rollback' "$REPO_DIR/wg-killswitch"
# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq 'chmod 0600 "$LOG_FILE"' "$REPO_DIR/wg-killswitch"
# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq 'chmod 0600 "$LOG_FILE"' "$REPO_DIR/wireguard-reconnect"
# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq 'chmod 0600 "$PORTAL_STATE"' "$REPO_DIR/wireguard-portal"
if grep -Fq 'while /usr/bin/ip -4 rule del to 100.64.0.0/10' "$REPO_DIR/wireguard-reconnect"; then
  echo "Tailscale integration still deletes pre-existing rules" >&2
  exit 1
fi
if grep -Fq 'remove_public_dns_host_routes' "$REPO_DIR/wg-killswitch"; then
  echo "kill switch still permanently deletes public DNS routes" >&2
  exit 1
fi
# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq 'wireguard-reconnect down "$IFACE"' "$REPO_DIR/uninstall.sh"
grep -Fq 'Captive-portal mode is active or cleanup is incomplete' "$REPO_DIR/uninstall.sh"

helper_down_line="$(grep -n 'wireguard-reconnect down' "$REPO_DIR/uninstall.sh" | head -n1 | cut -d: -f1)"
helper_remove_line="$(grep -n '^    /usr/local/bin/wireguard-reconnect' "$REPO_DIR/uninstall.sh" | head -n1 | cut -d: -f1)"
[ "$helper_down_line" -lt "$helper_remove_line" ]

printf 'public release hygiene tests: OK\n'
