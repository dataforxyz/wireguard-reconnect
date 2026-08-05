#!/bin/bash
# Maintain cross-file contracts that are easy to break during shell refactors.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

production=(
  install.sh uninstall.sh wg-killswitch wireguard-autostart wireguard-monitor
  wireguard-portal wireguard-reconnect wireguard-reconnect-sleep wireguard-status
)

# Root helpers remain standalone. A separately replaceable sourced shell library
# would widen the privileged attack and version-skew surface.
if grep -En '^[[:space:]]*(source|\.)[[:space:]]+' "${production[@]}"; then
  echo "production scripts must not source external shell libraries" >&2
  exit 1
fi

# Every hard-coded required executable must be covered by installer preflight.
used="$(mktemp)"
required="$(mktemp)"
trap 'rm -f "$used" "$required"' EXIT
for file in "${production[@]}"; do
  grep -Eo '/usr/bin/[A-Za-z0-9._+-]+' "$file" || true
done | sort -u >"$used"
sed -n \
  -e '/required_paths=(/,/^)/p' \
  -e '/required_paths+=(/,/^[[:space:]]*)/p' install.sh |
  grep -Eo '/usr/bin/[A-Za-z0-9._+-]+' | sort -u >"$required"
while IFS= read -r path; do
  case "$path" in
    /usr/bin/chromium|/usr/bin/brave|/usr/bin/google-chrome-stable|/usr/bin/tailscale)
      continue
      ;;
  esac
  grep -Fxq "$path" "$required" || {
    echo "absolute executable is missing from installer preflight: $path" >&2
    exit 1
  }
done <"$used"

# Fixed systemd commands must map to executable tracked helpers.
while IFS= read -r command; do
  helper="${command##*/}"
  [ -x "$helper" ] || {
    echo "systemd ExecStart helper is missing or not executable: $command" >&2
    exit 1
  }
done < <(grep -hE '^ExecStart=' ./*.service | sed -E 's/^ExecStart=([^ ]+).*/\1/')

# Installed privileged helpers and units must also appear in uninstall cleanup.
managed=(
  /usr/local/bin/wireguard-reconnect
  /usr/local/bin/wireguard-portal
  /usr/local/bin/wireguard-monitor
  /usr/local/bin/wireguard-autostart
  /usr/local/bin/wg-killswitch
  /usr/lib/systemd/system-sleep/wireguard-reconnect
  /etc/systemd/system/wireguard-monitor.service
  /etc/systemd/system/wireguard-autostart.service
  /etc/systemd/system/wireguard-killswitch.service
  /etc/polkit-1/rules.d/49-wireguard-reconnect.rules
)
for path in "${managed[@]}"; do
  grep -Fq "$path" install.sh || { echo "installer contract missing: $path" >&2; exit 1; }
  grep -Fq "$path" uninstall.sh || { echo "uninstaller contract missing: $path" >&2; exit 1; }
done

# Sensitive privileged state must not regress to world-readable modes.
# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq 'chmod 0600 "$LOG_FILE"' wg-killswitch
# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq 'chmod 0600 "$LOG_FILE"' wireguard-reconnect
# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq 'chmod 0600 "$PORTAL_STATE"' wireguard-portal
# shellcheck disable=SC2016 # Assert literal production-script source text.
grep -Fq 'chmod 0600 "$ENDPOINT_STATE_FILE"' wg-killswitch
if grep -Fq 'tailscale up' wireguard-reconnect; then
  echo "Tailscale integration must not reconfigure the daemon" >&2
  exit 1
fi

# Every optional feature remains explicit, persisted, and documented. Optional
# units must not pull disabled companions back in through Wants= dependencies.
options=(
  ENABLE_KILLSWITCH ENABLE_AUTOMATIC_RECONNECT ENABLE_AUTOSTART
  ENABLE_CAPTIVE_PORTAL ENABLE_AUTO_PORTAL CONNECT_ON_INSTALL
  ENABLE_TAILSCALE_INTEGRATION
)
for option in "${options[@]}"; do
  grep -Fq "$option" install.sh || { echo "installer option missing: $option" >&2; exit 1; }
  grep -Fq "$option" docs/installer.md || { echo "installer option undocumented: $option" >&2; exit 1; }
done
if grep -Eq '^Wants=.*wireguard-killswitch' wireguard-monitor.service; then
  echo 'monitor must not pull the optional kill-switch unit' >&2
  exit 1
fi
if grep -Eq '^Wants=.*(wireguard-killswitch|wireguard-monitor)' wireguard-autostart.service; then
  echo 'autostart must not pull optional companion units' >&2
  exit 1
fi
grep -Fq 'automatic-reconnect-enabled' wireguard-status
grep -Fq 'captive-portal-enabled' wireguard-reconnect

# Keep the front page navigable; detailed operator material belongs in docs/.
[ "$(wc -l <README.md)" -le 350 ] || {
  echo "README.md exceeded 350 lines; move detailed material into docs/" >&2
  exit 1
}
for doc in docs/installer.md docs/tailscale.md docs/captive-portals.md docs/testing.md; do
  [ -s "$doc" ] || { echo "required operator document is missing: $doc" >&2; exit 1; }
done

# Validate relative Markdown links across the repository.
python3 - "$REPO_DIR" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
failed = []
for source in [*root.glob("*.md"), *root.glob("docs/*.md")]:
    text = source.read_text(encoding="utf-8")
    for target in re.findall(r"\[[^]]+\]\(([^)]+)\)", text):
        target = target.split("#", 1)[0]
        if not target or "://" in target or target.startswith(("mailto:", "/")):
            continue
        resolved = (source.parent / target).resolve()
        try:
            resolved.relative_to(root)
        except ValueError:
            failed.append((source, target, "escapes repository"))
            continue
        if not resolved.exists():
            failed.append((source, target, "missing"))
if failed:
    for source, target, reason in failed:
        print(f"{source.relative_to(root)}: {target}: {reason}", file=sys.stderr)
    raise SystemExit(1)
PY

printf 'maintenance contracts: OK\n'
