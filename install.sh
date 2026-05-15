#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing WireGuard reconnect scripts..."

# Install helper scripts
install -Dm755 "$SCRIPT_DIR/wireguard-reconnect" /usr/local/bin/wireguard-reconnect
install -Dm755 "$SCRIPT_DIR/wireguard-monitor" /usr/local/bin/wireguard-monitor

# Install sleep hook
install -Dm755 "$SCRIPT_DIR/wireguard-reconnect-sleep" /usr/lib/systemd/system-sleep/wireguard-reconnect

# Install and enable monitoring service
install -Dm644 "$SCRIPT_DIR/wireguard-monitor.service" /etc/systemd/system/wireguard-monitor.service
systemctl daemon-reload
systemctl enable --now wireguard-monitor.service

echo "Done. Checking service status..."
systemctl status wireguard-monitor.service --no-pager

# Check PersistentKeepalive in WireGuard configs
echo ""
echo "Checking PersistentKeepalive in WireGuard configs..."
for conf in /etc/wireguard/*.conf; do
    [ -f "$conf" ] || continue
    if ! grep -q "PersistentKeepalive" "$conf"; then
        echo "WARNING: $conf is missing PersistentKeepalive in [Peer] section"
        echo "  Add 'PersistentKeepalive = 25' to each [Peer] block"
    else
        echo "OK: $conf has PersistentKeepalive set"
    fi
done
