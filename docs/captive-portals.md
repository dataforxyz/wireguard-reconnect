# Captive-portal workflow

Captive-portal support is enabled by default but can be removed from the active
policy with `ENABLE_CAPTIVE_PORTAL=0`. Keep manual isolated portal handling but
disable automatic detection with `ENABLE_AUTO_PORTAL=0`. The workflow requires
the kill switch; `ENABLE_KILLSWITCH=0` automatically disables portal support.
Re-run the installer to change these persisted choices.

When automatic detection is enabled, the monitor starts portal handling only
after a protected WireGuard reconnect
still cannot pass traffic on Wi-Fi. Manual fallback uses the same transaction:

```bash
make portal
make portal DOMAIN=wifi.example.com
```

## Detection restrictions

Automatic launch requires:

- Wi-Fi as the physical default-route interface;
- VPN intent still on;
- the installer-recorded desktop UID;
- an active, local, non-remote Wayland session;
- two concrete portal-like probe responses; and
- per-BSSID and global rate limits.

DNS errors, timeouts, server errors, or only one usable detector are
inconclusive and never open a browser. Network, BSSID, route, or session changes
cancel the transaction and return fail-closed.

## Isolated transaction

Automatic and manual modes:

1. acquire the portal lock and verify the host guard;
2. take the selected WireGuard interface down without removing the guard;
3. create the `wgportal` network namespace and veth pair;
4. enable and remember only required per-interface forwarding state;
5. allow namespace DNS, HTTP, HTTPS, and QUIC while rejecting host-service and
   other namespace traffic;
6. probe independent Google and Cloudflare HTTP-204 endpoints;
7. open a Chromium-family browser with a fresh temporary profile only after
   interception is confirmed;
8. resolve and stage the WireGuard endpoint from the isolated namespace;
9. verify removal of browser/profile, namespace, NAT table, veth, and forwarding
   changes; and
10. reconnect WireGuard and verify route and real HTTP traffic.

Endpoint candidates discovered during portal mode remain runtime-only until
traffic succeeds through WireGuard. They cannot overwrite ordinary persistent
endpoint state before verification.

## Privacy and failure behavior

No normal host process receives direct underlay access. The temporary browser
has no regular cookies, extensions, password manager, sync state, or normal
profile. Closing it, cancellation, timeout, cleanup failure, or reconnect
failure leaves the host fail-closed.

The local and Docker-backed simulations do not touch live WireGuard or the host
ruleset:

```bash
make portal-simulate
make portal-container-simulate
```

The simulators exercise redirect/login/HTTP-204 transitions and, when supported,
a throwaway user/network namespace proving that web traffic works while
non-web and host-veth services remain blocked.
