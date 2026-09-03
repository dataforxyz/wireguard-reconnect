# Changelog

All notable public changes are documented here. The project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Added a yellow/stale Waybar recovery menu with restart, isolated portal-check,
  and intentional-disconnect actions.
- Added transient, cleanup-verified UFW forwarding exceptions for the isolated
  captive-portal namespace while retaining the nftables DNS/web restrictions.
- Added persisted installer opt-outs for the kill switch, automatic reconnect,
  boot connection, captive-portal support, automatic portal detection, and the
  install-time connection. Defaults preserve the existing full feature set.

### Changed

- Fixed explicit Tailscale integration so marked control, DERP, and peer
  transport sockets bypass WireGuard's full-tunnel policy while general DNS
  and unmarked public traffic remain on WireGuard.
- Refactored installer and uninstaller orchestration into named internal phases
  without introducing a shared privileged shell library.
- Split detailed installer, Tailscale, captive-portal, and testing guidance into
  focused operator documents while keeping the README as a concise entry point.

### Tests

- Added disposable user/mount-namespace coverage for fresh install success and
  rollback, managed interface migration and exact-state rollback, Tailscale
  opt-out, successful uninstall cleanup, and fail-closed uninstall retention.
- Added maintenance-contract checks for executable preflight coverage, installed
  artifact cleanup, sensitive file modes, standalone privileged helpers, README
  size, and relative documentation links.

## [1.3.0-beta.1] - 2026-08-05

Initial public beta.

### Added

- Event-driven WireGuard recovery for boot, suspend/resume, Wi-Fi roaming, and
  physical route changes.
- Fail-closed nftables guard with endpoint-only bootstrap, emergency policy-drop
  fallback, continuous verification, and traffic-gated endpoint persistence.
- Automatic captive-portal detection using a temporary network namespace,
  DNS/web-only forwarding, an ephemeral Chromium-family profile, verified
  teardown, and protected WireGuard restoration.
- Make-based status, connect, reconnect, intentional disconnect, emergency
  reset, portal, diagnostics, support-summary, test, install, and uninstall
  commands.
- Rootless and Docker-backed portal simulations plus nftables, concurrency,
  active-session, probe-classification, wake-reconnect, and fail-closed tests.
- GPL-3.0-or-later licensing, GitHub Actions CI, security/contribution/conduct
  policies, public issue and pull-request templates, support matrix,
  architecture/threat-model documentation, and privacy/performance notes.
- Transactional installation with a 90-second guard rollback, protected traffic
  verification, service verification, remote-install refusal, selected-interface
  link/policy restoration, and file/runtime-rule restoration on failure.
- Safe uninstall that preserves WireGuard configuration and backups and can
  restore a specifically requested installer backup.

### Security

- Passwordless desktop actions are restricted to the active local user, a fixed
  root-owned helper, a fixed action whitelist, and one install-authorized `wgN`
  interface.
- New endpoint DNS remains runtime-only until traffic succeeds through WireGuard;
  isolated portal candidates cannot overwrite ordinary runtime or persistent
  endpoint state.
- Automatic browser launch requires two portal-like HTTP responses and an active
  local graphical session. Partial probe failure, session changes, network
  changes, timeout, cancellation, cleanup failure, and reconnect failure remain
  fail-closed.
- Endpoint, BSSID, and portal transaction metadata is root-only, while logs omit
  endpoint values and are automatically bounded or rotated.

### Changed

- Tailscale route integration is explicit opt-in, preserves pre-existing policy
  rules, and adds/removes only a tracked project-owned rule when needed. It
  never starts or reconfigures Tailscale.
- External periodic portal health checks are separated from the 15-second local
  nftables watchdog and run at most once per 60 seconds by default.
- Intentional monitor replacement during install/resume is treated as a clean
  systemd shutdown instead of a misleading exit-143 service failure.

[1.3.0-beta.1]: https://github.com/dataforxyz/wireguard-reconnect/releases/tag/v1.3.0-beta.1
