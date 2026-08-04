# Changelog

All notable changes to this project are documented here. The project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Added Make targets for WireGuard status, toggle, disconnect, connect,
  reconnect, reset, diagnostics, logs, tests, and install.
- Documented a safer Waybar binding that reserves connect/disconnect toggling
  for middle-click and leaves the easier-to-hit left and right buttons unbound.

### Fixed

- Made intentional disconnect idempotent when `wg0` is already missing, so a
  stuck fail-closed guard can still be cleanly reset for captive-portal access.

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

[1.0.1]: https://github.com/dataforxyz/wireguard-reconnect/releases/tag/v1.0.1
[1.0.0]: https://github.com/dataforxyz/wireguard-reconnect/releases/tag/v1.0.0
