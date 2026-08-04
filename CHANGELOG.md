# Changelog

All notable changes to this project are documented here. The project follows
[Semantic Versioning](https://semver.org/).

## [1.2.1] - 2026-08-04

### Fixed

- Restart the persistent network monitor during upgrades instead of relying on
  `systemctl enable --now`, which leaves an already-running older event loop in
  memory after new automatic captive-portal logic is installed.

## [1.2.0] - 2026-08-04

### Added

- Automatically starts fail-closed captive-portal detection after a Wi-Fi
  network event when the normal protected WireGuard reconnect remains offline.
- Added serialized per-BSSID cooldown tracking plus a short global anti-popup
  interval so repeated or rapidly changing AP identities cannot open windows in
  a loop.
- Added root-owned desktop-user discovery for safe automatic Wayland browser
  launch and a no-root regression test for automatic dispatch and cooldown.
- Cancels an active portal transaction if the physical default route, Wi-Fi
  interface, gateway, BSSID, or active local graphical session changes during
  login.

### Security

- Automatic detection uses the same isolated namespace, portal lock, restricted
  nftables rules, staged endpoint candidate, verified teardown, and protected
  reconnect path as the manual `make portal` command.
- Automatic mode is Wi-Fi-only, rechecks VPN health while atomically holding
  both monitor and privileged-helper action locks, targets only the active local
  graphical session, and launches a
  browser only after both independent checks return portal-like non-204 2xx/3xx
  or 511 responses. Partial probe failures and server errors remain fail-closed
  without opening a window.

## [1.1.0] - 2026-08-04

### Added

- Added Make targets for WireGuard status, toggle, disconnect, connect,
  reconnect, reset, diagnostics, logs, tests, install, and captive-portal mode.
- Added one-command captive-portal orchestration using a root-created network
  namespace, veth/NAT isolation, an ephemeral Chromium-family browser profile,
  automatic HTTP-204 login detection, cleanup, WireGuard restoration, and
  post-connect verification.
- Added no-root loopback and optional Docker-backed captive-portal simulators,
  plus a rootless kernel namespace/nftables isolation smoke test.
- Added Waybar portal-mode status and paused automatic reconnect attempts while
  the isolated portal transaction owns the underlay.
- Documented a safer Waybar binding that reserves connect/disconnect toggling
  for middle-click and leaves the easier-to-hit left and right buttons unbound.

### Fixed

- Made intentional disconnect idempotent when `wg0` is already missing, so a
  stuck fail-closed guard can still be cleanly reset for emergency recovery.

### Security

- Kept the host-wide kill switch armed throughout captive-portal login.
- Restricted the portal namespace to DNS, HTTP, HTTPS, and QUIC, with explicit
  source and unsolicited-ingress rejection before tunnel/private/LAN accepts.
- Serialized every VPN action against portal mode, verified teardown before
  clearing portal state, and preserved/restored only the required per-interface
  forwarding settings without changing global IPv4 router mode.
- Allowed portal isolation to start with an unresolved WireGuard endpoint while
  still requiring verified policy-drop and namespace rules; portal DNS results
  remain runtime candidates and are promoted to the persistent endpoint cache
  only after full endpoint-aware connection and real WG traffic verification.

## [1.0.1] - 2026-07-15

### Fixed

- Made boot-time `up` requests idempotent when the monitor and autostart service
  both observe a missing interface before either serialized request completes.
- Avoided an unnecessary second WireGuard bounce when autostart finds that the
  event monitor has already created `wg0`.
- Eliminated the resulting false critical `wg-quick up wg0 failed` journal entry
  seen during the first hardened installation.

## [1.0.0] - 2026-07-15

### Added

- Fail-closed nftables kill switch with default-drop output and forward chains.
- Early-boot kill-switch service and default-on WireGuard startup service.
- Event-driven reconnects for suspend/resume, Wi-Fi roaming, and route changes.
- Fifteen-second kill-switch verification and repair watchdog.
- Root-only persistent WireGuard endpoint cache for protected bootstrapping.
- Emergency policy-drop guard when the complete nftables ruleset is rejected.
- Waybar status, connect, reconnect, and intentional-disconnect controls.
- Tailscale route preservation and full-tunnel coexistence.
- Automated fail-closed nftables regression tests.
- Installer backups, narrow polkit authorization, and systemd integration.

### Security

- WireGuard connect/reconnect now refuses to proceed without a verified guard.
- The guard remains active while the tunnel is bounced and is verified again
  after WireGuard installs its final routes and fwmark.
- Critical failures are recorded in `/run/wireguard-reconnect.failure` and
  surfaced in the Waybar tooltip.

[1.2.1]: https://github.com/dataforxyz/wireguard-reconnect/releases/tag/v1.2.1
[1.2.0]: https://github.com/dataforxyz/wireguard-reconnect/releases/tag/v1.2.0
[1.1.0]: https://github.com/dataforxyz/wireguard-reconnect/releases/tag/v1.1.0
[1.0.1]: https://github.com/dataforxyz/wireguard-reconnect/releases/tag/v1.0.1
[1.0.0]: https://github.com/dataforxyz/wireguard-reconnect/releases/tag/v1.0.0
