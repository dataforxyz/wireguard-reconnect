# Omarchy Quattro desktop integration

`main` contains the Quattro native-menu port. The preceding `main` is preserved
as `archive/pre-quattro-20261115`; this is a historical reference, not a maintained
legacy release. To inspect or install that older version from a separate clone:

```bash
git clone --branch archive/pre-quattro-20261115 https://github.com/dataforxyz/wireguard-reconnect.git wireguard-reconnect-legacy
```

Read the [installer and rollback guide](installer.md) before any privileged
installation. Selecting a Git branch alone does not change the running VPN.

## What changed

`wireguard-status` opens recovery choices using `omarchy-menu-select`, with
Zenity as a fallback. It no longer depends on Walker for that menu. Closing the
picker leaves VPN connection and leak-protection state unchanged. Menu choices
retain the existing fixed privileged helper actions.

This desktop port does not change routes, keys, kill-switch rules, or Tailscale
settings. Tailscale integration remains an explicit installer option; it does
not log in or run `tailscale up`. See [Tailscale integration](tailscale.md).

## Status icon

The installer supplies `wireguard-status` in the user’s executable path. It does
not install a Quattro bar plugin or edit `~/.config/omarchy/shell.json`. A desktop
widget that understands the helper’s JSON output is required separately.

The migrated workstation’s custom QML status widget is configured to:

- poll `env WIREGUARD_AUTORECONNECT=0 wireguard-status` every ten seconds;
- invoke `wireguard-status toggle` on middle-click;
- leave left- and right-click unbound;
- display the JSON `text`, `tooltip`, and `class` returned by the helper.

Disabling automatic reconnect on this poll does not disable the monitor service.
The existing monitor handles network recovery; merely redrawing the bar does not
request a privileged reconnect. The widget module and its shell configuration
are tracked separately in the owner’s private `omarchy-desktop-config` repository.
They are not bundled with this public tool.

Green indicates verified protected connectivity. An intended-on but missing or
stale tunnel shows recovery choices; an intentional disconnect remains off for
that boot. A portal transaction has its own status and does not trigger another
toggle. CLI equivalents remain available through `make status`, `make toggle`,
`make reconnect`, and the other documented controls.

### Optional legacy Waybar integration

Older Waybar desktops can consume the same JSON helper. This configuration is
for Waybar, not Quattro’s shell.json:

```jsonc
"custom/wireguard": {
  "exec": "wireguard-status",
  "return-type": "json",
  "interval": 10,
  "signal": 10,
  "on-click-middle": "wireguard-status toggle"
}
```

The legacy example uses the helper’s configured autoreconnect policy. Set
`WIREGUARD_AUTORECONNECT=0` in its exec command for passive polling if desired.
Neither desktop integration changes saved VPN credentials.

## NetworkManager ordering

The migrated Quattro workstation uses NetworkManager. The helpers observe
kernel netlink/link/route state and wait for a physical route. The repository’s
base service units retain their old iwd/networkd `After=` entries; those entries
do not start or enable the old network managers.

The migration added this ordering drop-in for both
`wireguard-autostart.service` and `wireguard-monitor.service`:

```ini
[Unit]
After=NetworkManager.service
```

Use `/etc/systemd/system/UNIT.service.d/90-quattro-network.conf` for each unit,
with administrator authorization, then reload systemd definitions. This guide
does not direct stopping services or switching network managers. Wi-Fi profile
migration, live kill-switch verification, and peer reachability are separate
checks; preserve an independent recovery path before changing networking.

## Validation limits

Mocked tests cover menu dispatch, closing the picker, connection intent,
portal isolation status, and safe click bindings. The migrated workstation has
live VPN/Tailscale connectivity evidence, but that is not proof that every
NetworkManager, captive-portal, suspend/resume, or Wi-Fi-roaming scenario works.
The [testing guide](testing.md) distinguishes fixtures, namespace checks, and
real network acceptance. Never use a production connection for failure tests
without a coordinated recovery path.
