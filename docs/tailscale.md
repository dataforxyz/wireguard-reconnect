# Tailscale integration

wireguard-reconnect separates Tailscale transport exceptions from optional
policy-rule repair. It never starts or reconfigures Tailscale.

## Bypass scope

There are two distinct behaviors:

1. **Transport exceptions are always present in the kill switch.** Traffic that
   already leaves through `tailscale0`, and Tailscale's encrypted underlay
   sockets carrying its Linux packet mark, are allowed so `tailscaled` can keep
   peer tunnels alive while ordinary public traffic remains blocked. The
   tailnet IPv4 range `100.64.0.0/10` and IPv6 range
   `fd7a:115c:a1e0::/48` are also documented private/tailnet destination
   exceptions. These exceptions do not start Tailscale or change its
   preferences.
2. **Policy-rule repair is explicit opt-in.** With
   `ENABLE_TAILSCALE_INTEGRATION=1`, the installer records the choice and the
   reconnect helper first verifies that `tailscaled` is healthy and table 52
   has an active `tailscale0` route. If WireGuard's full-tunnel rules would win
   first, it adds a root-owned, tracked destination rule immediately ahead of
   them. Existing policy rules are never deleted or rewritten.

Enable or disable policy-rule repair by re-running the transactional installer.
After the first explicit opt-in, later upgrades retain the recorded value when
the option is omitted:

```bash
sudo ENABLE_TAILSCALE_INTEGRATION=1 ./install.sh
sudo ENABLE_TAILSCALE_INTEGRATION=0 ./install.sh
```

Disabling removes only a rule recorded as project-owned. An absent runtime state
file is normal when an adequate pre-existing rule already precedes WireGuard.

## What it does not configure

The integration does **not** run `tailscale up`, change DNS or
`--accept-routes`, advertise routes, or select/configure an exit node. Configure
those behaviors with Tailscale itself. Existing exit-node policy is outside the
tested integration and may have additional ordering requirements; this project
only manages destination rules for already-active tailnet routes alongside the
WireGuard full tunnel.

## State and verification

```bash
sudo cat /etc/wireguard-reconnect/tailscale-enabled
sudo cat /run/wireguard-reconnect.tailscale-rules 2>/dev/null || true
sudo tailscale status
ip -4 route show table 52
ip -6 route show table 52
ip -4 rule show | grep -E '100\.64\.0\.0/10|lookup 51820'
ip -6 rule show | grep -E 'fd7a:115c:a1e0::/48|lookup 51820'
```

On disable, uninstall, or failed-install rollback, only rules recorded in the
root-only runtime state file are removed or restored.

The same exception principle applies to loopback, DHCP, LAN/private
destinations, local Docker/bridge interfaces, and the configured WireGuard UDP
endpoint. These are narrow reachability exceptions, not isolation from hostile
services reachable on those networks. See
[Kill-switch exceptions](../README.md#kill-switch-exceptions).
