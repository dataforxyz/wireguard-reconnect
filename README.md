# wireguard-reconnect

Helper scripts to keep WireGuard tunnels alive on a Linux laptop:

- `wireguard-monitor` — watches `ip monitor route` and bounces tunnels on Wi-Fi switch
- `wireguard-reconnect` — bounces every active `wg-quick` interface that has a config in `/etc/wireguard/`
- `wireguard-reconnect-sleep` — bounces tunnels after `systemd-suspend` post-wake
- `wireguard-monitor.service` — systemd unit for the route monitor

Run `./install.sh` to install scripts to `/usr/local/bin` and enable the systemd unit.
