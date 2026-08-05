#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Run this installer as root: sudo ./install.sh" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_VERSION="$(head -n 1 "$SCRIPT_DIR/VERSION")"
[[ "$PROJECT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || {
    echo "Invalid semantic version in $SCRIPT_DIR/VERSION: $PROJECT_VERSION" >&2
    exit 1
}

TARGET_USER="${INSTALL_USER:-${SUDO_USER:-}}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    TARGET_USER="$(logname 2>/dev/null || true)"
fi
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    echo "Could not determine the desktop user. Re-run with INSTALL_USER=<user>." >&2
    exit 1
fi
[[ "$TARGET_USER" =~ ^[A-Za-z_][A-Za-z0-9_.-]*\$?$ ]] || {
    echo "Unsafe desktop user name: $TARGET_USER" >&2
    exit 1
}
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
    echo "Could not determine home directory for $TARGET_USER" >&2
    exit 1
fi
[ ! -L "$TARGET_HOME" ] || { echo "Refusing symlinked target home: $TARGET_HOME" >&2; exit 1; }
[ "$(stat -c '%u' "$TARGET_HOME")" = "$(id -u "$TARGET_USER")" ] || {
    echo "Target home is not owned by $TARGET_USER: $TARGET_HOME" >&2
    exit 1
}
for user_dir in "$TARGET_HOME/.local" "$TARGET_HOME/.local/bin"; do
    [ ! -e "$user_dir" ] || {
        [ -d "$user_dir" ] && [ ! -L "$user_dir" ] && \
            [ "$(stat -c '%u' "$user_dir")" = "$(id -u "$TARGET_USER")" ]
    } || { echo "Unsafe target user directory: $user_dir" >&2; exit 1; }
done

INTERFACE="${INSTALL_INTERFACE:-${WIREGUARD_INTERFACE:-wg0}}"
[[ "$INTERFACE" =~ ^wg[0-9]+$ ]] || { echo "Invalid WireGuard interface: $INTERFACE" >&2; exit 1; }
[ -f "/etc/wireguard/${INTERFACE}.conf" ] || {
    echo "Missing WireGuard config: /etc/wireguard/${INTERFACE}.conf" >&2
    exit 1
}
TAILSCALE_ENABLED="${ENABLE_TAILSCALE_INTEGRATION:-0}"
[ "$TAILSCALE_ENABLED" = "0" ] || [ "$TAILSCALE_ENABLED" = "1" ] || {
    echo "ENABLE_TAILSCALE_INTEGRATION must be 0 or 1" >&2
    exit 1
}

if [ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}" ] && [ "${ALLOW_REMOTE_INSTALL:-0}" != "1" ]; then
    echo "Refusing remote installation: firewall changes can interrupt SSH." >&2
    echo "Use a local console, or explicitly set ALLOW_REMOTE_INSTALL=1 with an independent recovery path." >&2
    exit 1
fi

required_paths=(
    /usr/bin/install /usr/bin/systemctl /usr/bin/loginctl /usr/bin/ip /usr/bin/iw
    /usr/bin/wg /usr/bin/wg-quick /usr/bin/curl /usr/bin/flock /usr/bin/nft
    /usr/bin/pkexec /usr/bin/runuser /usr/bin/resolvectl /usr/bin/sysctl
    /usr/bin/getent /usr/bin/timeout /usr/bin/setsid /usr/bin/logger
    /usr/bin/find /usr/bin/awk /usr/bin/sed /usr/bin/tail /usr/bin/stat
    /usr/bin/pkill /usr/bin/grep /usr/bin/seq /usr/bin/cp /usr/bin/mkdir
    /usr/bin/rm /usr/bin/dirname /usr/bin/cut /usr/bin/head /usr/bin/sort
    /usr/bin/date /usr/bin/sleep /usr/bin/id /usr/bin/logname /usr/bin/chmod
    /usr/bin/realpath
)
for path in "${required_paths[@]}"; do
    [ -x "$path" ] || { echo "Missing required executable: $path" >&2; exit 1; }
done
browser_found=0
for browser in /usr/bin/chromium /usr/bin/brave /usr/bin/google-chrome-stable; do
    [ -x "$browser" ] && browser_found=1
done
[ "$browser_found" = "1" ] || {
    echo "Missing a supported browser under /usr/bin (chromium, brave, or google-chrome-stable)" >&2
    exit 1
}

INSTALL_LOCK_FILE="/run/wireguard-reconnect.install.lock"
exec 7>"$INSTALL_LOCK_FILE"
if ! flock -x -w 30 7; then
    echo "Another WireGuard action or install/uninstall transaction is active; refusing installation." >&2
    exit 1
fi
install_lock_held=1
exec 5>/run/wireguard-reconnect.lock
if ! flock -x -w 30 5; then
    echo "A reconnect action is active; refusing installation." >&2
    exit 1
fi
exec 8>/run/wireguard-portal.lock
if ! flock -x -w 30 8; then
    echo "A captive-portal transaction is active; refusing installation." >&2
    exit 1
fi
action_locks_held=1
if [ -e /run/wireguard-portal.active ]; then
    echo "Captive-portal cleanup is incomplete; refusing installation." >&2
    exit 1
fi

BACKUP_DIR="/var/backups/wireguard-reconnect-$(date +%Y%m%d-%H%M%S)"
install -d -m 0700 "$BACKUP_DIR"
backup_if_present() {
    local path="$1" relative
    [ -e "$path" ] || return 0
    relative="${path#/}"
    mkdir -p "$BACKUP_DIR/$(dirname "$relative")"
    cp -a "$path" "$BACKUP_DIR/$relative"
}

cancel_guard_rollback() {
    exec 6>/run/wg-killswitch.rollback.lock
    flock -x 6
    rm -f /run/wg-killswitch.rollback-token
}

cleanup_managed_tailscale_rules() {
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

restore_managed_tailscale_rules() {
    local state=/run/wireguard-reconnect.tailscale-rules pref
    [ -r "$state" ] || return 0
    pref="$(/usr/bin/awk -F= '$1 == "V4_PREF" {print $2; exit}' "$state" 2>/dev/null || true)"
    if [[ "$pref" =~ ^[0-9]+$ ]]; then
        /usr/bin/ip -4 rule add pref "$pref" to 100.64.0.0/10 lookup 52 2>/dev/null || true
    fi
    pref="$(/usr/bin/awk -F= '$1 == "V6_PREF" {print $2; exit}' "$state" 2>/dev/null || true)"
    if [[ "$pref" =~ ^[0-9]+$ ]]; then
        /usr/bin/ip -6 rule add pref "$pref" to fd7a:115c:a1e0::/48 lookup 52 2>/dev/null || true
    fi
}

managed_paths=(
    /usr/local/bin/wireguard-reconnect
    /usr/local/bin/wireguard-portal
    /usr/local/bin/wireguard-monitor
    /usr/local/bin/wireguard-autostart
    /usr/local/bin/wg-killswitch
    /usr/local/share/wireguard-reconnect/VERSION
    /usr/local/share/wireguard-reconnect/interface
    /usr/lib/systemd/system-sleep/wireguard-reconnect
    /etc/systemd/system/wireguard-monitor.service
    /etc/systemd/system/wireguard-autostart.service
    /etc/systemd/system/wireguard-killswitch.service
    /etc/polkit-1/rules.d/49-wireguard-reconnect.rules
    /etc/wireguard-reconnect/portal-user
    /etc/wireguard-reconnect/interface
    /etc/wireguard-reconnect/environment
    /etc/wireguard-reconnect/tailscale-enabled
    /etc/wireguard-reconnect/tailscale-operator
    /run/wireguard-reconnect.tailscale-rules
    "$TARGET_HOME/.local/bin/wireguard-status"
)
for path in "${managed_paths[@]}"; do backup_if_present "$path"; done

prior_installed_interface=""
if [ -r /etc/wireguard-reconnect/interface ]; then
    prior_installed_interface="$(head -n1 /etc/wireguard-reconnect/interface 2>/dev/null || true)"
    [[ "$prior_installed_interface" =~ ^wg[0-9]+$ ]] || {
        echo "Existing installed interface state is invalid; refusing installation." >&2
        exit 1
    }
fi
requested_iface_was_present=0
prior_iface_was_present=0
/usr/bin/ip link show "$INTERFACE" >/dev/null 2>&1 && requested_iface_was_present=1
if [ -n "$prior_installed_interface" ]; then
    /usr/bin/ip link show "$prior_installed_interface" >/dev/null 2>&1 && prior_iface_was_present=1
fi

guard_was_active=0
prior_guard_interface=""
nft_tables="$(/usr/bin/nft list tables 2>/dev/null)" || {
    echo "Cannot query nftables state; refusing firewall installation." >&2
    exit 1
}
if /usr/bin/grep -Fxq 'table inet wg_killswitch' <<<"$nft_tables"; then
    guard_was_active=1
    [ -x /usr/local/bin/wg-killswitch ] || {
        echo "An existing WireGuard policy-drop table has no recovery helper; refusing installation." >&2
        exit 1
    }
    if [ -r /run/wg-killswitch.enabled ]; then
        prior_guard_interface="$(head -n1 /run/wg-killswitch.enabled 2>/dev/null || true)"
    fi
    if ! [[ "$prior_guard_interface" =~ ^wg[0-9]+$ ]] || \
        [ ! -f "/etc/wireguard/${prior_guard_interface}.conf" ]; then
        echo "An existing fail-closed guard has no safely restorable interface state; refusing installation." >&2
        exit 1
    fi
    [ -n "$prior_installed_interface" ] || prior_installed_interface="$prior_guard_interface"
fi
if [ -n "$prior_installed_interface" ] && /usr/bin/ip link show "$prior_installed_interface" >/dev/null 2>&1; then
    prior_iface_was_present=1
fi
monitor_was_enabled=0
monitor_was_active=0
autostart_was_enabled=0
killswitch_was_enabled=0
systemctl is-enabled --quiet wireguard-monitor.service 2>/dev/null && monitor_was_enabled=1
systemctl is-active --quiet wireguard-monitor.service 2>/dev/null && monitor_was_active=1
systemctl is-enabled --quiet wireguard-autostart.service 2>/dev/null && autostart_was_enabled=1
systemctl is-enabled --quiet wireguard-killswitch.service 2>/dev/null && killswitch_was_enabled=1
install_committed=0
rollback_install() {
    local rc=$?
    trap - EXIT
    [ "$install_committed" = "1" ] && exit "$rc"
    echo "Installation failed; rolling back installed files and firewall state." >&2
    # Cancel the timer before any bounded wait for action locks. This is
    # independent of the installed helper and atomic with the timer's decision.
    cancel_guard_rollback
    if [ "$install_lock_held" != "1" ]; then
        if ! flock -x -w 30 7; then
            echo "Could not serialize rollback; installed helpers are retained for manual recovery." >&2
            exit "$rc"
        fi
        install_lock_held=1
    fi
    if [ "$action_locks_held" != "1" ]; then
        if ! flock -x -w 30 5 || ! flock -x -w 30 8; then
            echo "Could not serialize rollback against active actions; helpers are retained." >&2
            exit "$rc"
        fi
        action_locks_held=1
    fi
    systemctl disable --now wireguard-monitor.service wireguard-autostart.service wireguard-killswitch.service 2>/dev/null || true
    cleanup_managed_tailscale_rules
    # Remove only an interface created by this install attempt, while the guard
    # is still present. A teardown failure retains the new recovery helpers.
    if [ "$requested_iface_was_present" != "1" ] && \
        /usr/bin/ip link show "$INTERFACE" >/dev/null 2>&1; then
        if ! /usr/bin/wg-quick down "$INTERFACE" >/dev/null 2>&1; then
            echo "Rollback could not remove the newly created $INTERFACE; helpers are retained for recovery." >&2
            exit "$rc"
        fi
    fi
    # If a guard existed before the upgrade, never tear down its nftables table:
    # the restored helper atomically replaces it below. Fresh installs must
    # verify removal of any newly created table before helpers are removed.
    if [ "$guard_was_active" != "1" ] && [ -x /usr/local/bin/wg-killswitch ]; then
        if ! /usr/local/bin/wg-killswitch disable >/dev/null 2>&1; then
            echo "Rollback could not remove the new nftables guard; helpers are retained for recovery." >&2
            exit "$rc"
        fi
    fi

    local path backup
    for path in "${managed_paths[@]}"; do
        backup="$BACKUP_DIR/${path#/}"
        if [ -e "$backup" ]; then
            mkdir -p "$(dirname "$path")"
            rm -rf "$path"
            cp -a "$backup" "$path"
        else
            rm -rf "$path"
        fi
    done
    restore_managed_tailscale_rules
    systemctl daemon-reload 2>/dev/null || true
    if [ "$killswitch_was_enabled" = "1" ]; then systemctl enable wireguard-killswitch.service 2>/dev/null || true; fi
    if [ "$monitor_was_enabled" = "1" ]; then systemctl enable wireguard-monitor.service 2>/dev/null || true; fi
    if [ "$autostart_was_enabled" = "1" ]; then systemctl enable wireguard-autostart.service 2>/dev/null || true; fi
    if [ "$guard_was_active" = "1" ] && [ -x /usr/local/bin/wg-killswitch ]; then
        if ! /usr/local/bin/wg-killswitch enable "$prior_guard_interface" >/dev/null 2>&1; then
            echo "WARNING: prior guard could not be fully restored; the existing policy-drop table was left in place." >&2
        fi
    fi
    if [ "$prior_iface_was_present" = "1" ] && [ -n "$prior_installed_interface" ] && \
        ! /usr/bin/ip link show "$prior_installed_interface" >/dev/null 2>&1; then
        if ! /usr/bin/wg-quick up "$prior_installed_interface" >/dev/null 2>&1; then
            echo "WARNING: prior interface $prior_installed_interface could not be restored; protection remains fail-closed." >&2
        elif [ "$guard_was_active" = "1" ] && [ -x /usr/local/bin/wg-killswitch ]; then
            /usr/local/bin/wg-killswitch enable "$prior_guard_interface" >/dev/null 2>&1 || true
        fi
    fi
    flock -u 8 || true
    flock -u 5 || true
    flock -u 7 || true
    action_locks_held=0
    install_lock_held=0
    if [ "$monitor_was_active" = "1" ]; then systemctl restart wireguard-monitor.service 2>/dev/null || true; fi
    echo "Rollback complete. Backup retained at: $BACKUP_DIR" >&2
    exit "$rc"
}
trap rollback_install EXIT

# Quiesce the event-driven caller before replacing helpers and units. The
# already-armed nftables guard remains active throughout this window.
if [ "$monitor_was_active" = "1" ]; then
    systemctl stop wireguard-monitor.service
fi

echo "Installing wireguard-reconnect v${PROJECT_VERSION} for ${INTERFACE}..."
install -Dm644 "$SCRIPT_DIR/VERSION" /usr/local/share/wireguard-reconnect/VERSION
printf '%s\n' "$INTERFACE" >/usr/local/share/wireguard-reconnect/interface
chmod 0644 /usr/local/share/wireguard-reconnect/interface
install -Dm755 "$SCRIPT_DIR/wireguard-reconnect" /usr/local/bin/wireguard-reconnect
install -Dm755 "$SCRIPT_DIR/wireguard-portal" /usr/local/bin/wireguard-portal
install -Dm755 "$SCRIPT_DIR/wireguard-monitor" /usr/local/bin/wireguard-monitor
install -Dm755 "$SCRIPT_DIR/wireguard-autostart" /usr/local/bin/wireguard-autostart
install -Dm755 "$SCRIPT_DIR/wg-killswitch" /usr/local/bin/wg-killswitch
install -Dm755 "$SCRIPT_DIR/wireguard-reconnect-sleep" /usr/lib/systemd/system-sleep/wireguard-reconnect
install -Dm644 "$SCRIPT_DIR/wireguard-monitor.service" /etc/systemd/system/wireguard-monitor.service
install -Dm644 "$SCRIPT_DIR/wireguard-autostart.service" /etc/systemd/system/wireguard-autostart.service
install -Dm644 "$SCRIPT_DIR/wireguard-killswitch.service" /etc/systemd/system/wireguard-killswitch.service

install -d -m 0700 /etc/wireguard-reconnect
install -m 0600 /dev/null /etc/wireguard-reconnect/portal-user
printf '%s\n' "$(id -u "$TARGET_USER")" >/etc/wireguard-reconnect/portal-user
install -m 0600 /dev/null /etc/wireguard-reconnect/interface
printf '%s\n' "$INTERFACE" >/etc/wireguard-reconnect/interface
install -m 0600 /dev/null /etc/wireguard-reconnect/tailscale-enabled
printf '%s\n' "$TAILSCALE_ENABLED" >/etc/wireguard-reconnect/tailscale-enabled
install -m 0600 /dev/null /etc/wireguard-reconnect/environment
printf 'WIREGUARD_INTERFACE=%s\nWIREGUARD_TAILSCALE_ENABLED=%s\n' \
    "$INTERFACE" "$TAILSCALE_ENABLED" >/etc/wireguard-reconnect/environment
rm -f /etc/wireguard-reconnect/tailscale-operator
if [ "$TAILSCALE_ENABLED" != "1" ]; then
    cleanup_managed_tailscale_rules
fi

if [ ! -d "$TARGET_HOME/.local/bin" ]; then
    install -d -m 0755 -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" "$TARGET_HOME/.local/bin"
fi
install -m 0755 -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" \
    "$SCRIPT_DIR/wireguard-status" "$TARGET_HOME/.local/bin/wireguard-status"

cat >/etc/polkit-1/rules.d/49-wireguard-reconnect.rules <<EOF
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.policykit.exec" &&
        action.lookup("program") == "/usr/local/bin/wireguard-reconnect" &&
        subject.active && subject.local && subject.user == "$TARGET_USER") {
        return polkit.Result.YES;
    }
});
EOF
chmod 0644 /etc/polkit-1/rules.d/49-wireguard-reconnect.rules

# Older releases logged resolved endpoint values to world-readable runtime files.
# Start a new private log epoch before invoking the upgraded helpers.
for runtime_log in /run/wg-killswitch.log /run/wireguard-reconnect.log /run/wireguard-portal.log; do
    : >"$runtime_log"
    chmod 0600 "$runtime_log"
done
for runtime_state in /run/wg-killswitch.endpoint /run/wg-killswitch.portal-candidate \
    /run/wireguard-portal.active /run/wireguard-portal.autodetect; do
    [ ! -e "$runtime_state" ] || chmod 0600 "$runtime_state"
done

systemctl daemon-reload

echo "Pre-arming the fail-closed kill switch with a 90-second rollback..."
if [ "$guard_was_active" = "1" ]; then
    WG_KILLSWITCH_ROLLBACK_ACTION=rearm \
        WG_KILLSWITCH_ROLLBACK_INTERFACE="$prior_guard_interface" \
        /usr/local/bin/wg-killswitch enable-rollback "$INTERFACE"
else
    /usr/local/bin/wg-killswitch enable-rollback "$INTERFACE"
fi
/usr/local/bin/wg-killswitch status >/dev/null

# A configured interface migration is protected by the new guard: remove the
# previously managed full-tunnel interface before bringing up the replacement,
# avoiding conflicting wg-quick policy rule sets.
if [ "$prior_iface_was_present" = "1" ] && [ -n "$prior_installed_interface" ] && \
    [ "$prior_installed_interface" != "$INTERFACE" ]; then
    /usr/bin/wg-quick down "$prior_installed_interface"
    /usr/local/bin/wg-killswitch enable "$INTERFACE"
    /usr/local/bin/wg-killswitch status >/dev/null
fi

systemctl reenable wireguard-killswitch.service
systemctl start wireguard-killswitch.service

# Bring up/idempotently validate the selected interface while install, reconnect,
# and portal locks are still held. Automatic portal work cannot begin while the
# rollback timer is armed.
WIREGUARD_INSTALL_LOCK_HELD=1 WIREGUARD_RECONNECT_LOCK_HELD=1 \
    WIREGUARD_ACTION_LOCKS_HELD=1 \
    /usr/local/bin/wireguard-reconnect up "$INTERFACE"

verified=0
for _ in $(seq 1 10); do
    if /usr/bin/ip -4 route get 9.9.9.9 2>/dev/null | /usr/bin/grep -q " dev ${INTERFACE}\\b"; then
        code="$(/usr/bin/curl --interface "$INTERFACE" --silent --show-error --max-time 4 \
            --output /dev/null --write-out '%{http_code}' \
            http://connectivitycheck.gstatic.com/generate_204 2>/dev/null || true)"
        if [ "$code" = "204" ] || [ "$code" = "200" ]; then
            verified=1
            break
        fi
    fi
    sleep 2
done
[ "$verified" = "1" ] || {
    echo "WireGuard traffic was not verified after installation." >&2
    exit 1
}
/usr/local/bin/wg-killswitch status >/dev/null
systemctl is-active --quiet wireguard-killswitch.service || {
    echo "Required service is not active: wireguard-killswitch.service" >&2
    exit 1
}
# Confirmation is serialized with the timer. Re-verify every commit invariant
# afterward so a timer that won the lock first cannot produce a fail-open commit.
/usr/local/bin/wg-killswitch confirm
/usr/local/bin/wg-killswitch status >/dev/null
/usr/bin/ip -4 route get 9.9.9.9 2>/dev/null | /usr/bin/grep -q " dev ${INTERFACE}\b"
code="$(/usr/bin/curl --interface "$INTERFACE" --silent --show-error --max-time 4 \
    --output /dev/null --write-out '%{http_code}' \
    http://connectivitycheck.gstatic.com/generate_204 2>/dev/null || true)"
[ "$code" = "204" ] || [ "$code" = "200" ] || {
    echo "Protected traffic failed after rollback confirmation." >&2
    exit 1
}
systemctl is-active --quiet wireguard-killswitch.service || {
    echo "Kill-switch service stopped before commit" >&2
    exit 1
}

# The timer is gone and guard/traffic were verified after confirmation. Release
# the exclusive transaction locks, then start long-lived automatic callers.
flock -u 8
flock -u 5
flock -u 7
action_locks_held=0
install_lock_held=0
systemctl enable wireguard-monitor.service
systemctl restart wireguard-monitor.service
systemctl enable wireguard-autostart.service
systemctl restart wireguard-autostart.service
for unit in wireguard-killswitch.service wireguard-monitor.service wireguard-autostart.service; do
    systemctl is-active --quiet "$unit" || { echo "Required service stopped before commit: $unit" >&2; exit 1; }
done

/usr/bin/pkill -RTMIN+10 -u "$TARGET_USER" waybar 2>/dev/null || true
install_committed=1
trap - EXIT

echo
echo "Installed wireguard-reconnect v${PROJECT_VERSION} successfully."
echo "Interface: $INTERFACE"
echo "Tailscale route integration: $([ "$TAILSCALE_ENABLED" = "1" ] && echo enabled || echo disabled)"
echo "Backup of replaced files: $BACKUP_DIR"
echo
systemctl status wireguard-killswitch.service wireguard-monitor.service wireguard-autostart.service --no-pager

echo
echo "Checking PersistentKeepalive in $INTERFACE config..."
if grep -q "^[[:space:]]*PersistentKeepalive[[:space:]]*=" "/etc/wireguard/${INTERFACE}.conf"; then
    echo "OK: /etc/wireguard/${INTERFACE}.conf has PersistentKeepalive"
else
    echo "WARNING: /etc/wireguard/${INTERFACE}.conf is missing PersistentKeepalive (recommended: 25)"
fi
