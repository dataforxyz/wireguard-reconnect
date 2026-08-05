# Installer and rollback model

> Installing changes root-owned nftables policy and can intentionally block
> public traffic when WireGuard cannot be verified. Keep a local root terminal
> available for the first installation and do not install remotely without an
> independent recovery path.

## Preconditions and options

Confirm the selected `/etc/wireguard/wgN.conf` already works with `wg-quick` and
uses `PersistentKeepalive = 25` on roaming laptops.

```bash
sudo ./install.sh
sudo INSTALL_INTERFACE=wg1 ./install.sh
sudo ENABLE_TAILSCALE_INTEGRATION=1 ./install.sh
```

The selected interface becomes the only profile accepted by the passwordless
helper. Tailscale policy repair is disabled by default; see
[Tailscale integration](tailscale.md).

## Installed state

The installer:

1. installs root helpers under `/usr/local/bin`;
2. installs `wireguard-status` in the invoking user's `~/.local/bin`;
3. records the desktop UID in a root-only portal identity file;
4. installs a narrow active-local-user polkit rule for the fixed reconnect
   helper;
5. pre-arms and verifies the fail-closed guard;
6. performs a protected selected-interface transition;
7. installs and enables guard, monitor, startup, and sleep integration;
8. records the authorized interface and optional Tailscale flag; and
9. verifies the nftables table, selected route, real HTTP traffic through
   WireGuard, and required services.

Backups are stored under `/var/backups/wireguard-reconnect-*` with mode `0700`.
Failed installation transactions automatically restore managed paths from that
transaction's backup. Successful installs retain their backup; it is never
automatically restored or deleted afterward.

## Transaction boundaries

The transaction holds exclusive install, reconnect, and portal locks while
helpers and firewall state are changing. This prevents Waybar, monitor,
suspend, and portal actions from observing a partially replaced installation.

A fresh install arms a 90-second recovery timer that removes only its newly
introduced guard if confirmation never arrives. An upgrade uses that timeout to
re-arm the validated prior interface instead of removing a pre-existing guard.
The timer is confirmed while all transaction locks remain held; guard and
protected traffic are verified again after confirmation.

## Interface migration

When changing from one managed `wgN` interface to another, the installer:

1. records whether the old and requested links existed;
2. pre-arms the guard for the requested interface;
3. tears down the previously managed full-tunnel interface under that guard;
4. re-verifies the guard in case root-owned `wg-quick` hooks changed firewall
   state; and
5. brings up and verifies the replacement before committing.

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
