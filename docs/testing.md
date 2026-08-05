# Testing and maintenance

## Test layers

`make test` runs local logic and namespace-safe regression tests:

```bash
make test
```

The suite covers:

- nftables policy-drop generation, emergency fallback, endpoint provenance,
  deletion/query failures, and rollback timers;
- boot autostart idempotency;
- status/Waybar middle-click safety;
- Make control dispatch;
- portal orchestration, probe classification, active-session restrictions,
  cooldowns, and concurrency;
- fresh install success/failure, interface migration success/exact-state
  rollback, Tailscale opt-out, and successful/fail-closed uninstall inside a
  disposable user/mount namespace;
- public-release security contracts and version consistency; and
- maintenance contracts tying installed artifacts, services, documentation, and
  installer preflight together.

Kernel and container integration checks are available separately:

```bash
./tests/test-portal-netns.sh
./tests/test-installer-netns.sh
make portal-simulate
make portal-container-simulate
```

GitHub Actions requires the namespace/nftables isolation test to report `OK`
and runs the Docker-backed simulation in a separate job. CI also runs Bash
syntax, informational-severity ShellCheck, systemd unit verification, and
whitespace checks.

## Diagnostics

Start with:

```bash
make support-info  # reduced summary
make logs          # raw logs; redact before sharing
make diagnostics   # routes/addresses/rules; redact before sharing
```

More targeted commands:

```bash
systemctl status wireguard-killswitch.service wireguard-monitor.service wireguard-autostart.service
journalctl -u wireguard-killswitch.service -u wireguard-monitor.service -u wireguard-autostart.service -b
journalctl -t wg-killswitch -t wireguard-reconnect -t wireguard-monitor -t wireguard-portal -b
wireguard-status
```

Privileged runtime logs and portal/endpoint metadata are root-only. Journald
uses host rotation policy; `/run` state disappears on reboot. Reconnect and
portal logs are replaced per transaction, while `wg-killswitch.log` is locked
and trimmed at 256 KiB to its newest 1000 lines by default.

## Performance checks

The local nftables watchdog runs every 15 seconds. External portal/recovery
checks are separately serialized and occur at most once every 60 seconds while
VPN intent and a physical route are present. Netlink events remain immediate.

Connectivity checks use configurable Google and Cloudflare HTTP-204 endpoints.
The project has no analytics or project-owned telemetry server, but those
providers can observe ordinary request metadata.

## Maintainability boundaries

The privileged executables intentionally remain standalone. Do not create a
user-writable or separately versioned shell library sourced by root helpers just
to reduce repeated constants: that would widen the replacement and
version-skew attack surface. Prefer small internal functions, fixed-action
root-owned helpers, and tests that assert contracts across standalone scripts.
