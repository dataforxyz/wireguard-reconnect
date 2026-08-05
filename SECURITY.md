# Security policy

## Supported versions

Security fixes are provided for the latest tagged release only. Users should
upgrade before reporting behavior that may already have been corrected.

## Reporting a vulnerability

Do not open a public issue for a vulnerability, suspected traffic leak,
privilege-boundary bypass, or captive-portal isolation failure. Use GitHub's
**Report a vulnerability** form in the repository Security tab so the report and
proof of concept remain private.

Include, where possible:

- the installed version (`wireguard-reconnect --version`);
- distribution, kernel, nftables, WireGuard, and systemd versions;
- relevant redacted output from `make logs` and `make diagnostics`;
- exact steps and whether WireGuard intent was on or intentionally off;
- whether `/run/wireguard-portal.active` existed;
- the expected and observed security boundary.

Never attach `/etc/wireguard/*.conf`, private keys, authentication cookies,
portal browser profiles, or unredacted endpoint credentials.

Reports will be acknowledged on a best-effort basis. Confirmed issues that can
expose host traffic, escape portal isolation, or cross the root/user boundary
receive priority over availability and compatibility bugs.

## Security model

The project is fail-closed when VPN intent is on: public host traffic is blocked
unless it uses WireGuard or an explicitly documented exception. Captive-portal
mode creates a restricted network namespace for a disposable browser; it is not
a full filesystem or process container. Root compromise, kernel compromise,
malicious WireGuard configuration hooks, and compromised browser/kernel
sandboxes are outside the boundary provided by these scripts.
