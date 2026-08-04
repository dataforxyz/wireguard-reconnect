# wireguard-reconnect

Event-driven WireGuard recovery for a Linux laptop using iwd/systemd-networkd,
with Waybar controls, a full-tunnel kill switch, and Tailscale route repair.

Current release: **v1.2.1**

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
- **Automatic captive portals without host leaks:** after a Wi-Fi/AP/network
  event, a failed protected reconnect automatically starts detection from a
  dedicated network namespace. Only when independent probes indicate a portal
  does it open an ephemeral Chromium profile inside that namespace and allow its
  DNS/web traffic over the Wi-Fi underlay. Every normal host process remains
  blocked by the kill switch. After login returns the expected HTTP 204s, the
  namespace is destroyed and WireGuard is restored and verified automatically.

## Files

- `wireguard-reconnect` — root-owned, fixed-action helper used through `pkexec`
- `wireguard-portal` — isolated captive-portal namespace/browser orchestrator
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
3. records that desktop user's UID in the root-only automatic-portal identity
   file and installs a narrow polkit rule allowing the local active user to
   invoke only `/usr/local/bin/wireguard-reconnect` without a password;
4. pre-arms and verifies the kill switch, persisting only the endpoint metadata
   needed for the next early boot;
5. installs and enables the kill-switch, monitor, and startup services;
6. installs the system-sleep hook; and
7. runs one immediate health/connection pass.

The Waybar module should execute `wireguard-status` and bind only middle-click
to `wireguard-status toggle`. Leaving left- and right-click unbound prevents an
accidental connect or disconnect:

## Make commands

Run `make` or `make help` in this repository to list the available controls.
The common commands mirror the Waybar icon and provide an explicit recovery
path:

```jsonc
"custom/wireguard": {
  "exec": "wireguard-status",
  "return-type": "json",
  "interval": 10,
  "signal": 10,
  "on-click-middle": "wireguard-status toggle"
}
```

```bash
make status       # show the icon's current state
make toggle       # same as middle-clicking the icon
make disconnect   # explicit intentional disconnect
make connect      # explicitly connect wg0
make reconnect    # explicitly bounce and reconnect wg0
make reset        # EMERGENCY full bypass; disables leak protection
```

### Captive portals

The installed network monitor normally starts portal mode automatically after a
new Wi-Fi connection or AP change when a protected WireGuard reconnect still
cannot pass traffic. It identifies the active desktop user from the root-owned
`/etc/wireguard-reconnect/portal-user` file written by the installer, verifies
that user owns the active local graphical session, and launches the isolated
browser only when both probes return concrete portal-like HTTP responses
(non-204 2xx/3xx or status 511). DNS errors, timeouts, server errors, or one
blocked check endpoint are treated as
inconclusive and never open a browser. Repeat attempts on the same BSSID are
rate-limited for five minutes; a different AP bypasses that per-AP cooldown
after a short 30-second global anti-popup interval. A periodic guarded health
check also catches portals connected before the Wayland session was available.

If Wi-Fi disconnects, the default route/BSSID changes, or the selected desktop
session becomes inactive or remote during login, the transaction cancels, tears
down its isolated path, and returns fail-closed. The next network event evaluates
the new AP and active local session.

Manual fallback remains one command:

```bash
make portal
```

Automatic and manual modes perform the same transaction:

1. acquires a portal lock honored by every connect, disconnect, and reconnect
   action, then verifies the host-wide fail-closed nftables guard;
2. takes `wg0` down without removing that guard;
3. creates a root-owned network namespace and veth pair, enabling and recording
   only the two required per-interface forwarding knobs without changing the
   host's global IPv4 router mode; when the physical interface was already
   forwarding, existing Docker/libvirt/Tailscale routed flows are preserved;
4. permits only DNS, HTTP, HTTPS, and QUIC from that namespace and rejects
   namespace-originated access to services on the host itself;
5. probes independent Google and Cloudflare plain-HTTP 204 endpoints so one
   allow-listed detector cannot create a false "open internet" result;
6. when interception is detected, opens an isolated Chromium-family browser
   with a new temporary profile inside the namespace;
7. polls until the connectivity endpoint returns HTTP 204;
8. resolves the WireGuard endpoint from the authenticated isolated namespace
   and stages it as a runtime-only candidate so protected bootstrap does not
   depend on still-blocked host DNS; the persistent cache is updated only after
   real traffic through WireGuard is verified;
9. closes the browser and verifies destruction of its profile, namespace, NAT
   table, and veth before clearing portal state, restoring the two prior
   per-interface forwarding settings, or permitting any other VPN action;
10. reconnects WireGuard and verifies both the `wg0` route and real HTTP traffic.

No regular host process receives direct underlay access. The browser has no
normal profile, cookies, extensions, password manager, or sync state. Closing
it early, pressing Ctrl-C, timing out, or encountering an error triggers cleanup
and an attempted protected reconnect; if reconnect fails, the host remains
fail-closed.

A known starting domain is optional:

```bash
make portal DOMAIN=wifi.example.com
make portal DOMAIN=http://wifi.example.com/login
```

This only chooses the isolated browser's starting page; it does not create a
host-wide domain exception.

A no-root local simulation is included:

```bash
make portal-simulate
```

A Docker-backed variant runs the fake portal in an isolated container bound only
to a random loopback port, exercises the same detector state machine, removes
the container and its locally tagged test image, and runs the rootless kernel
namespace/firewall test:

```bash
make portal-container-simulate
```

The regular simulator starts a loopback HTTP server that initially redirects like a
captive portal, accepts a simulated login, then changes the detector response to
204. It also uses an unprivileged throwaway user/network namespace (when the
kernel permits one) to prove that portal HTTP succeeds while a non-web port and
a service on the host-side veth remain blocked. It never touches live
WireGuard, the host nftables ruleset, or the real network interfaces.

Troubleshooting and maintenance commands are also available:

```bash
make diagnostics
make logs
make test
make install      # sudo install/update of the system integration
```

`make reset` remains an emergency full bypass for repairing a broken ruleset.
It is not used by captive-portal mode and intentionally removes leak protection;
prefer `make portal` whenever the network requires browser authentication.

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
- `WIREGUARD_AUTO_PORTAL=1`
- `WIREGUARD_PORTAL_COOLDOWN=300`
- `WIREGUARD_PORTAL_GLOBAL_COOLDOWN=30`
- `WIREGUARD_PORTAL_USER_FILE=/etc/wireguard-reconnect/portal-user`
- `WIREGUARD_STARTUP_WAIT=30`
- `WIREGUARD_CHECK_URL=http://connectivitycheck.gstatic.com/generate_204`
- `WIREGUARD_CHECK_TIMEOUT=4`

## Diagnostics

```bash
systemctl status wireguard-killswitch.service wireguard-monitor.service wireguard-autostart.service
journalctl -u wireguard-killswitch.service -u wireguard-monitor.service -u wireguard-autostart.service -b
journalctl -t wg-killswitch -t wireguard-reconnect -t wireguard-monitor -t wireguard-portal -b
wireguard-status
```

The latest privileged helper output is written to
`/run/wireguard-reconnect.log`. Critical fail-closed state is also written to
`/run/wireguard-reconnect.failure` and shown in the Waybar tooltip. Captive
portal activity is written to `/run/wireguard-portal.log`, with active
transaction metadata in `/run/wireguard-portal.active`.

Run the unprivileged nftables-generation regression test with:

```bash
./tests/test-killswitch.sh
./tests/test-autostart.sh
./tests/test-status.sh
./tests/test-make-controls.sh
./tests/test-portal.sh
./tests/test-portal-netns.sh  # also run by the portal simulator when supported
./tests/test-auto-portal.sh
./tests/simulate-captive-portal-container.sh  # optional; requires Docker
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
Explicit host exceptions are limited to loopback, LAN/private destinations,
DHCP, the configured WireGuard UDP endpoint, Tailscale's marked encrypted
underlay, `tailscale0`, and local Docker/bridge interfaces. During captive-portal
mode, forwarded traffic from the root-created `wgportal0` veth is additionally
limited to DNS and web ports; all other traffic from that namespace is rejected
before the normal private/LAN forwarding exception. An intentional emergency
**disconnect/reset** still removes the guard completely; the next system boot
restores the default-on guarded policy.
