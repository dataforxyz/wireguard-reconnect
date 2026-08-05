# Installer and rollback model

> Installing changes root-owned nftables policy and can intentionally block
> public traffic when WireGuard cannot be verified. Keep a local root terminal
> available for the first installation and do not install remotely without an
> independent recovery path.

## Preconditions and options

Confirm the selected `/etc/wireguard/wgN.conf` already works with `wg-quick` and
uses `PersistentKeepalive = 25` on roaming laptops.

The default installation preserves the original full feature set. Every
automatic or policy-enforcement component can be disabled explicitly:

| Installer option | Default | Effect when `0` |
|---|---:|---|
| `ENABLE_KILLSWITCH` | `1` | Do not arm nftables or enable the early-boot guard. Any existing project guard is removed transactionally. |
| `ENABLE_AUTOMATIC_RECONNECT` | `1` | Disable the network monitor, suspend/wake repair, guard watchdog, and Waybar-initiated automatic reconnect. Manual controls still work. |
| `ENABLE_AUTOSTART` | `1` | Do not mark/connect WireGuard automatically at the next boot. |
| `ENABLE_CAPTIVE_PORTAL` | `1` | Disable both manual and automatic isolated captive-portal handling. |
| `ENABLE_AUTO_PORTAL` | `1` | Keep manual portal handling but disable automatic Wi-Fi portal detection. |
| `CONNECT_ON_INSTALL` | `1` | Install/configure without bringing up WireGuard during this transaction. Selected services are enabled as requested but left stopped until the next boot. |
| `ENABLE_TAILSCALE_INTEGRATION` | `0` | Do not repair optional table-52 policy rules. Transport/tailnet guard exceptions remain part of kill-switch policy. |

All values must be `0` or `1`. On the first install, omitted options use the
defaults above. On upgrades, omitted feature options retain their previously
recorded values; pass an explicit `0` or `1` to change policy. The selected
interface becomes the only profile accepted by the passwordless helper.

Default full installation:

```bash
sudo ./install.sh
sudo INSTALL_INTERFACE=wg1 ./install.sh
```

Manual-only, with no automatic connection or captive-portal feature and no
kill switch:

```bash
sudo ENABLE_KILLSWITCH=0 \
  ENABLE_AUTOMATIC_RECONNECT=0 \
  ENABLE_AUTOSTART=0 \
  ENABLE_CAPTIVE_PORTAL=0 \
  CONNECT_ON_INSTALL=0 \
  ./install.sh
```

Fail-closed but manual connection only:

```bash
sudo ENABLE_AUTOMATIC_RECONNECT=0 \
  ENABLE_AUTOSTART=0 \
  ENABLE_AUTO_PORTAL=0 \
  CONNECT_ON_INSTALL=0 \
  ./install.sh
```

The latter arms the guard without connecting, so public traffic remains blocked
until `make connect` succeeds or `make disconnect` intentionally removes the
guard. `CONNECT_ON_INSTALL=0` refuses an active `wgN` interface migration,
because leaving the old full-tunnel interface running under a newly selected
configuration would be ambiguous.

Captive-portal handling requires the kill switch; setting
`ENABLE_KILLSWITCH=0` automatically disables captive-portal support and its
automatic detector. Portal-only commands and browser preflight are not required
when the feature is disabled. Automatic portal detection is also disabled when automatic
reconnect is disabled. Tailscale details are in
[Tailscale integration](tailscale.md).

## Installed state

The installer always installs the fixed helpers, user status command, selected
interface authorization, systemd units, and narrow polkit rule. It records all
selected options in root-only files under `/etc/wireguard-reconnect/`; nonsecret
Waybar-facing flags are also stored under
`/usr/local/share/wireguard-reconnect/`.

It then performs only the selected runtime actions: guard pre-arm/removal,
interface transition, optional immediate connection and traffic verification,
and enable/start or disable of the guard, monitor, and startup units. Disabled
units remain installed so a later transactional reinstall can enable them
without introducing a second installation layout.

Backups are stored under `/var/backups/wireguard-reconnect-*` with mode `0700`.
Failed installation transactions automatically restore managed paths from that
transaction's backup. Successful installs retain their backup; it is never
automatically restored or deleted afterward.

## Transaction boundaries

The transaction holds exclusive install, reconnect, and portal locks while
helpers and firewall state are changing. This prevents Waybar, monitor,
suspend, and portal actions from observing a partially replaced installation.

When the kill switch is selected, a fresh install arms a 90-second recovery
timer that removes only its newly introduced guard if confirmation never
arrives. An upgrade uses that timeout to re-arm the validated prior interface
instead of removing a pre-existing guard. The timer is confirmed while all
transaction locks remain held; guard state and, when immediate connection is
selected, protected traffic are verified again after confirmation.

With `ENABLE_KILLSWITCH=0`, the installer verifies removal of any existing
project guard before committing. With `CONNECT_ON_INSTALL=0`, it clears stale
runtime connection intent and does not claim that VPN traffic was verified;
requested automatic units are enabled but left stopped until the next boot.
If boot connection is enabled while the general monitor is disabled, the
bounded autostart unit asks systemd to retry after a late underlay instead of
silently abandoning the requested boot connection. An intentional disconnect
or `CONNECT_ON_INSTALL=0` writes a same-boot suppression marker, so queued
monitor/Waybar actions and autostart retries cannot undo that choice; `/run`
clears the marker for the next boot.

## Interface migration

When changing from one managed `wgN` interface to another, the installer
records both link states, applies the selected guard policy, tears down the old
managed interface, and brings up/verifies the replacement. With the default
kill switch this transition remains protected and the guard is re-verified
after root-owned `wg-quick` hooks. Without the kill switch, the explicitly
selected unguarded policy applies. An active migration requires
`CONNECT_ON_INSTALL=1`.

## Rollback

On failure, rollback:

- cancels the timeout atomically before waiting for action locks;
- stops automatic callers;
- removes only an interface created by that install attempt;
- preserves or re-arms a pre-existing guard;
- restores backed-up helpers, units, configuration, and user utility;
- restores a previously active managed interface;
- restores project-tracked Tailscale rules;
- re-enables managed units that were enabled before installation; and
- restarts the monitor if it was active before installation.

If nftables cannot be queried, guard deletion cannot be verified, or a newly
created interface cannot be safely removed, rollback retains the recovery
helpers and fails closed rather than claiming success.

## Uninstall

```bash
make uninstall
# or
sudo ./uninstall.sh
```

Uninstall holds the same transaction locks, refuses active/incomplete portal
cleanup, verifies guard removal, preserves `/etc/wireguard`, and leaves backups
untouched. A backup is restored only when explicitly requested:

```bash
sudo RESTORE_BACKUP_DIR=/var/backups/wireguard-reconnect-YYYYMMDD-HHMMSS ./uninstall.sh
```

If disconnect or guard removal fails, uninstall releases its locks, restores
previously active automatic services, and retains the helpers needed for
recovery.
