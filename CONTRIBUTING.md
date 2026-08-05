# Contributing

Contributions are welcome, especially reproducible fixes for additional Wi-Fi
hardware, captive portals, and Linux distributions.

## Before opening a pull request

1. Open an issue for substantial behavior or security-boundary changes.
2. Work in a topic branch or worktree; keep `main` clean.
3. Do not commit WireGuard configs, real endpoint addresses, private keys,
   portal cookies, usernames, or machine-specific logs.
4. Preserve fail-closed behavior on every error and cancellation path.
5. Add or update regression coverage.

Run the same checks as CI:

```bash
make test
bash -n install.sh uninstall.sh wg-killswitch wireguard-autostart \
  wireguard-monitor wireguard-portal wireguard-reconnect \
  wireguard-reconnect-sleep wireguard-status tests/*.sh
shellcheck install.sh uninstall.sh wg-killswitch wireguard-autostart \
  wireguard-monitor wireguard-portal wireguard-reconnect \
  wireguard-reconnect-sleep wireguard-status tests/*.sh
git diff --check
```

For installer, uninstall, or interface-migration changes, run the disposable
transaction test explicitly and confirm it reports `OK` rather than `SKIP`:

```bash
./tests/test-installer-netns.sh
```

For portal changes, also run:

```bash
make portal-simulate
make portal-container-simulate
```

Operator documentation is organized under [`docs/`](docs/README.md). Keep the
root README focused on support, quick start, controls, and security boundaries.
Detailed transaction, Tailscale, portal, and test material belongs in the
corresponding operator document.

## Maintainability boundaries

- Keep privileged executables standalone; do not source a separately writable or
  separately versioned shell library from root helpers.
- Prefer small internal phase functions over copy/pasted orchestration blocks.
- Any new absolute executable path must be covered by installer preflight.
- Installed privileged artifacts must have a matching uninstall contract.
- Preserve root-only modes for endpoint, portal, rollback, and privileged log
  state.

`tests/test-maintenance.sh` enforces these cross-file contracts and validates
relative Markdown links.

## Review expectations

Changes affecting nftables, root helpers, polkit, endpoint trust, namespace
cleanup, or automatic browser launch require an explicit security review.
Performance changes should include wake/reconnect timing or polling-impact
evidence. Documentation must distinguish tested support from assumptions.

By contributing, you agree that your contribution is licensed under
GPL-3.0-or-later, the same license as the project.
