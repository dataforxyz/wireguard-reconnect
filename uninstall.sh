#!/bin/bash
# Remove wireguard-reconnect without touching WireGuard configuration or backups.
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Run this uninstaller as root: sudo ./uninstall.sh" >&2
    exit 1
fi

IFACE="${WIREGUARD_INTERFACE:-}"
if [ -z "$IFACE" ] && [ -r /etc/wireguard-reconnect/interface ]; then
    IFACE="$(head -n1 /etc/wireguard-reconnect/interface 2>/dev/null || true)"
fi
[ -n "$IFACE" ] || IFACE=wg0
[[ "$IFACE" =~ ^wg[0-9]+$ ]] || { echo "Invalid installed interface: $IFACE" >&2; exit 1; }
TARGET_USER="${UNINSTALL_USER:-${SUDO_USER:-}}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    TARGET_USER="$(logname 2>/dev/null || true)"
fi
TARGET_HOME=""
SAFE_USER_STATUS_PATH=0
if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ] && \
    [[ "$TARGET_USER" =~ ^[A-Za-z_][A-Za-z0-9_.-]*\$?$ ]]; then
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    if [ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME" ] && [ ! -L "$TARGET_HOME" ] && \
        [ "$(stat -c '%u' "$TARGET_HOME")" = "$(id -u "$TARGET_USER")" ] && \
        { [ ! -e "$TARGET_HOME/.local/bin" ] || { [ -d "$TARGET_HOME/.local/bin" ] && \
            [ ! -L "$TARGET_HOME/.local/bin" ] && \
            [ "$(stat -c '%u' "$TARGET_HOME/.local/bin")" = "$(id -u "$TARGET_USER")" ]; }; }; then
        SAFE_USER_STATUS_PATH=1
    else
        echo "Warning: unsafe target user path; leaving wireguard-status untouched." >&2
    fi
fi

VALIDATED_RESTORE_BACKUP=""
if [ -n "${RESTORE_BACKUP_DIR:-}" ]; then
    [ ! -L "$RESTORE_BACKUP_DIR" ] || { echo "Refusing symlinked backup path" >&2; exit 1; }
    VALIDATED_RESTORE_BACKUP="$(realpath -e "$RESTORE_BACKUP_DIR")"
    case "$VALIDATED_RESTORE_BACKUP" in
        /var/backups/wireguard-reconnect-*) ;;
        *) echo "RESTORE_BACKUP_DIR must name a wireguard-reconnect backup under /var/backups" >&2; exit 1 ;;
    esac
    [ -d "$VALIDATED_RESTORE_BACKUP" ] || { echo "Backup not found: $VALIDATED_RESTORE_BACKUP" >&2; exit 1; }
    [ "$(stat -c '%u' "$VALIDATED_RESTORE_BACKUP")" = "0" ] || { echo "Backup is not root-owned" >&2; exit 1; }
    [ $((8#$(stat -c '%a' "$VALIDATED_RESTORE_BACKUP") & 0022)) -eq 0 ] || {
        echo "Backup is writable by a non-root group or user" >&2
        exit 1
    }
fi

release_transaction_locks() {
    flock -u 8
    flock -u 5
    flock -u 7
}

abort_uninstall() {
    local message="$1"
    echo "$message" >&2
    release_transaction_locks || true
    if [ "$monitor_was_active" = "1" ]; then systemctl start wireguard-monitor.service 2>/dev/null || true; fi
    if [ "$autostart_was_active" = "1" ]; then systemctl restart wireguard-autostart.service 2>/dev/null || true; fi
    exit 1
}

remove_tracked_tailscale_rules() {
    local state=/run/wireguard-reconnect.tailscale-rules pref
    [ -r "$state" ] || return 0
    pref="$(/usr/bin/awk -F= '$1 == "V4_PREF" {print $2; exit}' "$state" 2>/dev/null || true)"
    if [[ "$pref" =~ ^[0-9]+$ ]]; then
        /usr/bin/ip -4 rule del pref "$pref" to 100.64.0.0/10 lookup 52 2>/dev/null || true
    fi
    pref="$(/usr/bin/awk -F= '$1 == "V6_PREF" {print $2; exit}' "$state" 2>/dev/null || true)"
    if [[ "$pref" =~ ^[0-9]+$ ]]; then
        /usr/bin/ip -6 rule del pref "$pref" to fd7a:115c:a1e0::/48 lookup 52 2>/dev/null || true
    fi
    rm -f "$state"
}

disconnect_and_remove_guard() {
    if [ -x /usr/local/bin/wireguard-reconnect ]; then
        WIREGUARD_INSTALL_LOCK_HELD=1 WIREGUARD_RECONNECT_LOCK_HELD=1 \
            WIREGUARD_ACTION_LOCKS_HELD=1 /usr/local/bin/wireguard-reconnect down "$IFACE" || \
            abort_uninstall "Could not cleanly disconnect $IFACE and remove the kill switch; uninstall aborted."
    elif [ -x /usr/local/bin/wg-killswitch ]; then
        /usr/local/bin/wg-killswitch disable || \
            abort_uninstall "Could not remove the kill switch; uninstall aborted."
    elif /usr/bin/grep -Fxq 'table inet wg_killswitch' <<<"$nft_tables"; then
        abort_uninstall "A WireGuard policy-drop table exists but the recovery helper is missing; refusing destructive cleanup."
    fi
}

remove_installed_files() {
    rm -f \
        /usr/local/bin/wireguard-reconnect \
        /usr/local/bin/wireguard-portal \
        /usr/local/bin/wireguard-monitor \
        /usr/local/bin/wireguard-autostart \
        /usr/local/bin/wg-killswitch \
        /usr/lib/systemd/system-sleep/wireguard-reconnect \
        /etc/systemd/system/wireguard-monitor.service \
        /etc/systemd/system/wireguard-autostart.service \
        /etc/systemd/system/wireguard-killswitch.service \
        /etc/polkit-1/rules.d/49-wireguard-reconnect.rules
    rm -rf /usr/local/share/wireguard-reconnect /etc/wireguard-reconnect \
        /var/lib/wg-killswitch /run/wireguard-reconnect
}

remove_runtime_state() {
    rm -f \
        /run/wireguard-reconnect.enabled /run/wireguard-reconnect.autostart-suppressed \
        /run/wireguard-reconnect.failure /run/wireguard-reconnect.log \
        /run/wireguard-reconnect.tailscale-rules \
        /run/wg-killswitch.enabled /run/wg-killswitch.endpoint /run/wg-killswitch.portal-candidate \
        /run/wg-killswitch.log /run/wg-killswitch.log.lock /run/wg-killswitch.rollback-token \
        /run/wireguard-portal.active /run/wireguard-portal.autodetect /run/wireguard-portal.log
}

restore_requested_backup() {
    [ -n "$VALIDATED_RESTORE_BACKUP" ] || return 0
    cp -a "$VALIDATED_RESTORE_BACKUP"/. /
    systemctl daemon-reload
    echo "Restored explicitly requested backup: $VALIDATED_RESTORE_BACKUP"
}

# Serialize the entire destructive transaction against both new helpers (the
# install lock) and pre-public helpers (the action locks). Lock files remain in
# /run after uninstall so waiters cannot split onto a newly created inode.
exec 7>/run/wireguard-reconnect.install.lock
flock -x -w 30 7 || { echo "Another install/uninstall or WireGuard action is active." >&2; exit 1; }
exec 5>/run/wireguard-reconnect.lock
flock -x -w 30 5 || { echo "A reconnect action is active." >&2; exit 1; }
exec 8>/run/wireguard-portal.lock
flock -x -w 30 8 || { echo "A captive-portal transaction is active." >&2; exit 1; }

if [ -e /run/wireguard-portal.active ]; then
    echo "Captive-portal mode is active or cleanup is incomplete; refusing uninstall." >&2
    echo "Close/cancel the portal transaction and verify cleanup first." >&2
    exit 1
fi
nft_tables="$(/usr/bin/nft list tables 2>/dev/null)" || {
    echo "Cannot query nftables state; refusing to remove recovery helpers." >&2
    exit 1
}

monitor_was_active=0
autostart_was_active=0
systemctl is-active --quiet wireguard-monitor.service 2>/dev/null && monitor_was_active=1
systemctl is-active --quiet wireguard-autostart.service 2>/dev/null && autostart_was_active=1
systemctl stop wireguard-monitor.service wireguard-autostart.service 2>/dev/null || true

# Intentional down is the supported operation that removes both the interface
# and fail-closed nftables guard. Do not delete the helpers if that cleanup fails.
disconnect_and_remove_guard
remove_tracked_tailscale_rules

systemctl disable wireguard-monitor.service wireguard-autostart.service 2>/dev/null || true
systemctl disable --now wireguard-killswitch.service 2>/dev/null || true

remove_installed_files
remove_runtime_state

if [ "$SAFE_USER_STATUS_PATH" = "1" ]; then
    rm -f "$TARGET_HOME/.local/bin/wireguard-status"
fi

systemctl daemon-reload
systemctl reset-failed wireguard-monitor.service wireguard-autostart.service wireguard-killswitch.service 2>/dev/null || true

restore_requested_backup
release_transaction_locks

echo "wireguard-reconnect removed."
echo "WireGuard configs under /etc/wireguard and unrequested installer backups were not modified."
