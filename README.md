# wireguard-reconnect

Event-driven WireGuard recovery for a Linux laptop using iwd/systemd-networkd,
with Waybar controls, a full-tunnel kill switch, and Tailscale route repair.

Current release: **v1.0.1**

## Behavior

- **Before normal networking at boot:** pre-arms a fail-closed nftables guard
  using a root-only cached WireGuard endpoint.
- **On every system boot:** marks `wg0` as intended-on and connects it as soon as
  a physical default route is available.
- **After suspend/resume:** restarts the network monitor, waits for Wi-Fi, tests
  real traffic through `wg0`, and reconnects only when stale.
- **After Wi-Fi/AP/network changes:** reacts to netlink route/link/address events
  instead of waiting for Waybar's polling threshold.
- **After an intentional disconnect:** leaves WireGuard off for the rest of that
  boot. The next system boot enables it again by default.
- **With Tailscale:** keeps tailnet policy routes ahead of WireGuard's full-tunnel
  rules.
- **With the kill switch:** caches the WireGuard endpoint so reconnect can
  bootstrap without leaking general traffic over the physical interface.
- **Fail-closed reconnects:** the nftables guard is armed and verified before
  `wg0` is brought up, remains active while `wg0` is bounced, and is verified
  again afterward. A failed verification takes `wg0` down and leaves public
  traffic blocked.

## Files

- `wireguard-reconnect` — root-owned, fixed-action helper used through `pkexec`
- `wg-killswitch` — nftables full-tunnel kill switch
- `wireguard-status` — Waybar JSON status/toggle/autoreconnect command
- `wireguard-monitor` — event-driven physical-network monitor
- `wireguard-autostart` — enables WireGuard by default on each boot
- `wireguard-reconnect-sleep` — restarts the monitor after resume
- `wireguard-monitor.service` — persistent network monitor
- `wireguard-autostart.service` — boot-time default-on policy
- `wireguard-killswitch.service` — early-boot fail-closed nftables guard

## Install

Run from this repository:

```bash
sudo ./install.sh
```

The installer:

1. installs root helpers under `/usr/local/bin`;
2. installs `wireguard-status` into the invoking user's `~/.local/bin`;
3. installs a narrow polkit rule allowing that local active user to invoke only
   `/usr/local/bin/wireguard-reconnect` without a password;
4. pre-arms and verifies the kill switch, persisting only the endpoint metadata
   needed for the next early boot;
5. installs and enables the kill-switch, monitor, and startup services;
6. installs the system-sleep hook; and
7. runs one immediate health/connection pass.

The Waybar module should execute `wireguard-status`, left-click
`wireguard-status toggle`, and right-click `wireguard-status disconnect`.

## Make commands

Run `make` or `make help` in this repository to list the available controls.
The common commands mirror the Waybar icon and provide an explicit recovery
path:

```bash
make status       # show the icon's current state
make toggle       # same as left-clicking the icon
make disconnect   # same as right-clicking the icon
make connect      # explicitly connect wg0
make reconnect    # explicitly bounce and reconnect wg0
make reset        # clear stuck VPN intent and leak protection, even if wg0 is missing
```

Troubleshooting and maintenance commands are also available:

```bash
make diagnostics
make logs
make test
make install      # sudo install/update of the system integration
```

`make reset` is the captive-portal/emergency escape hatch. It intentionally
leaves WireGuard off, disables the fail-closed guard, and verifies that direct
internet traffic is available. Re-enable the VPN afterward with `make connect`
or the Waybar icon.

Check the installed version with:

```bash
wireguard-reconnect --version
```

## Versioning and releases

The project follows [Semantic Versioning](https://semver.org/):

- **MAJOR** for incompatible behavior or installation changes
- **MINOR** for backward-compatible features
- **PATCH** for backward-compatible fixes

`VERSION` is the source of truth for the current release. Release commits are
tagged as `vMAJOR.MINOR.PATCH`, and notable changes are recorded in
[`CHANGELOG.md`](CHANGELOG.md).

Release checklist:

1. update `VERSION`;
2. move release notes into `CHANGELOG.md` with the release date;
3. update the current release shown in this README;
4. run the test and static-validation commands;
5. commit, create an annotated `vX.Y.Z` tag, and push the commit and tag to both
   GitHub and FGit.

## Configuration overrides

Environment variables may be supplied through systemd service drop-ins:

- `WIREGUARD_INTERFACE=wg0`
- `WIREGUARD_MONITOR_DEBOUNCE=5`
- `WIREGUARD_MONITOR_STABILIZE_DELAY=2`
- `WIREGUARD_STARTUP_WAIT=30`
- `WIREGUARD_CHECK_URL=http://connectivitycheck.gstatic.com/generate_204`
- `WIREGUARD_CHECK_TIMEOUT=4`

## Diagnostics

```bash
systemctl status wireguard-killswitch.service wireguard-monitor.service wireguard-autostart.service
journalctl -u wireguard-killswitch.service -u wireguard-monitor.service -u wireguard-autostart.service -b
journalctl -t wg-killswitch -t wireguard-reconnect -t wireguard-monitor -b
wireguard-status
```

The latest privileged helper output is written to
`/run/wireguard-reconnect.log`. Critical fail-closed state is also written to
`/run/wireguard-reconnect.failure` and shown in the Waybar tooltip.

Run the unprivileged nftables-generation regression test with:

```bash
./tests/test-killswitch.sh
./tests/test-autostart.sh
./tests/test-status.sh
./tests/test-make-controls.sh
./tests/test-version.sh
```

The autostart test verifies that startup is idempotent when another boot
component has already created `wg0`. The version test ensures `VERSION`,
`CHANGELOG.md`, the README release label, and `wireguard-reconnect --version`
remain consistent. The kill-switch test
verifies policy-drop output/forward chains, the endpoint-only public
exception, unresolved-endpoint behavior, and fallback to a smaller emergency
guard when the full nftables ruleset is rejected. Failure cases leave a
blocking guard installed while returning non-zero so WireGuard stays down.

## Kill-switch exceptions

When enabled, public IPv4 and IPv6 egress is rejected unless it uses `wg0`.
Explicit exceptions are limited to loopback, LAN/private destinations, DHCP,
the configured WireGuard UDP endpoint, Tailscale's marked encrypted underlay,
`tailscale0`, and local Docker/bridge interfaces. An intentional Waybar
**disconnect** removes the guard so captive portals and direct troubleshooting
work; the next system boot restores the default-on guarded policy.
