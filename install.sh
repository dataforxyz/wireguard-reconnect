#!/bin/bash
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Run this installer as root: sudo ./install.sh" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_VERSION="$(head -n 1 "$SCRIPT_DIR/VERSION")"
if ! [[ "$PROJECT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
    echo "Invalid semantic version in $SCRIPT_DIR/VERSION: $PROJECT_VERSION" >&2
    exit 1
fi
TARGET_USER="${INSTALL_USER:-${SUDO_USER:-}}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    TARGET_USER="$(logname 2>/dev/null || true)"
fi
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    echo "Could not determine the desktop user. Re-run with INSTALL_USER=<user>." >&2
    exit 1
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
    echo "Could not determine home directory for $TARGET_USER" >&2
    exit 1
fi

for command in install systemctl loginctl ip iw wg wg-quick curl flock nft pkexec runuser; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "Missing required command: $command" >&2
        exit 1
    }
done
if ! command -v chromium >/dev/null 2>&1 && \
   ! command -v brave >/dev/null 2>&1 && \
   ! command -v google-chrome-stable >/dev/null 2>&1; then
    echo "Missing a supported captive-portal browser (chromium, brave, or google-chrome-stable)" >&2
    exit 1
fi

BACKUP_DIR="/var/backups/wireguard-reconnect-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
backup_if_present() {
    local path="$1" relative
    [ -e "$path" ] || return 0
    relative="${path#/}"
    mkdir -p "$BACKUP_DIR/$(dirname "$relative")"
    cp -a "$path" "$BACKUP_DIR/$relative"
}

backup_if_present /usr/local/bin/wireguard-reconnect
backup_if_present /usr/local/bin/wireguard-portal
backup_if_present /usr/local/bin/wireguard-monitor
backup_if_present /usr/local/bin/wireguard-autostart
backup_if_present /usr/local/bin/wg-killswitch
backup_if_present /usr/local/share/wireguard-reconnect/VERSION
backup_if_present /usr/lib/systemd/system-sleep/wireguard-reconnect
backup_if_present /etc/systemd/system/wireguard-monitor.service
backup_if_present /etc/systemd/system/wireguard-autostart.service
backup_if_present /etc/systemd/system/wireguard-killswitch.service
backup_if_present /etc/polkit-1/rules.d/49-wireguard-reconnect.rules
backup_if_present /etc/wireguard-reconnect/portal-user
backup_if_present "$TARGET_HOME/.local/bin/wireguard-status"

echo "Installing WireGuard reconnect v${PROJECT_VERSION} components..."
install -Dm644 "$SCRIPT_DIR/VERSION" /usr/local/share/wireguard-reconnect/VERSION
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

install -d -m 0755 -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" "$TARGET_HOME/.local/bin"
install -m 0755 -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" \
    "$SCRIPT_DIR/wireguard-status" "$TARGET_HOME/.local/bin/wireguard-status"

# Narrow passwordless authorization: only the fixed, root-owned helper and only
# for the active local desktop user. No shell or arbitrary command is allowed.
cat > /etc/polkit-1/rules.d/49-wireguard-reconnect.rules <<EOF
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.policykit.exec" &&
        action.lookup("program") == "/usr/local/bin/wireguard-reconnect" &&
        subject.active && subject.local && subject.user == "$TARGET_USER") {
        return polkit.Result.YES;
    }
});
EOF
chmod 0644 /etc/polkit-1/rules.d/49-wireguard-reconnect.rules

systemctl daemon-reload

echo "Pre-arming and verifying the fail-closed kill switch..."
if ! /usr/local/bin/wg-killswitch enable wg0; then
    echo "Kill-switch setup failed. WireGuard will not be restarted." >&2
    echo "Public traffic may currently be blocked intentionally; inspect /run/wg-killswitch.log." >&2
    exit 1
fi
/usr/local/bin/wg-killswitch status >/dev/null

systemctl enable --now wireguard-killswitch.service
systemctl enable wireguard-monitor.service
# `enable --now` does not restart an already-running monitor during upgrades.
# Restart explicitly so the live event loop always executes the just-installed
# automatic portal and concurrency logic.
systemctl restart wireguard-monitor.service
systemctl enable wireguard-autostart.service
systemctl restart wireguard-autostart.service

# Refresh Waybar if it is running so it immediately uses the installed status
# command and reflects the boot-time connection pass.
pkill -RTMIN+10 -u "$TARGET_USER" waybar 2>/dev/null || true

echo
echo "Installed wireguard-reconnect v${PROJECT_VERSION} successfully."
echo "WireGuard is now enabled by default on every boot."
echo "Backup of replaced files: $BACKUP_DIR"
echo
systemctl status wireguard-killswitch.service wireguard-monitor.service wireguard-autostart.service --no-pager

echo
echo "Checking PersistentKeepalive in WireGuard configs..."
for conf in /etc/wireguard/*.conf; do
    [ -f "$conf" ] || continue
    if grep -q "^[[:space:]]*PersistentKeepalive[[:space:]]*=" "$conf"; then
        echo "OK: $conf has PersistentKeepalive"
    else
        echo "WARNING: $conf is missing PersistentKeepalive (recommended: 25)"
    fi
done
