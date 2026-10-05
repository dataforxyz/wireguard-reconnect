#!/bin/bash
# Run the real helper and kernel policy routing in a disposable network namespace.
# Redirect fixed state paths into a temporary tree; never change host VPN state.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v unshare >/dev/null 2>&1 || ! unshare -Urn true 2>/dev/null; then
  echo 'Tailscale startup routing test: SKIP (user/network namespaces unavailable)'
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/root/etc/wireguard" "$TMP/root/run" "$TMP/bin"
touch "$TMP/root/etc/wireguard/wg0.conf"
cat >"$TMP/bin/tailscale" <<'EOF'
#!/bin/bash
# Model tailscaled still starting, before it has received any table-52 routes.
exit 1
EOF
cat >"$TMP/bin/resolvectl" <<'EOF'
#!/bin/bash
exit 0
EOF
cat >"$TMP/bin/wg-quick" <<'EOF'
#!/bin/bash
[ "$1" = down ] || exit 1
ip link del "$2"
EOF
chmod +x "$TMP/bin/"*
python3 - "$REPO_DIR/wireguard-reconnect" "$TMP" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
root = pathlib.Path(sys.argv[2])
for path in ("/run/", "/etc/", "/usr/local/"):
    source = source.replace(path, str(root / "root") + path)
for command in ("tailscale", "resolvectl", "wg-quick"):
    source = source.replace("/usr/bin/" + command, str(root / "bin" / command))
(root / "helper").write_text(source)
PY

# shellcheck disable=SC2016 # Variables intentionally expand inside the namespace.
unshare -Urn bash -c '
  set -euo pipefail
  root="$1"
  export WIREGUARD_KILLSWITCH=0 WIREGUARD_AUTHORIZED_INTERFACE=wg0
  export WIREGUARD_TAILSCALE_ENABLED=1
  state="$root/root/run/wireguard-reconnect.tailscale-rules"
  ip link add wg0 type dummy
  ip link add wlan0 type dummy
  ip link add tailscale0 type dummy
  for dev in wg0 wlan0 tailscale0; do ip link set "$dev" up; done
  ip addr add 10.8.0.2/32 dev wg0
  ip addr add 192.0.2.2/24 dev wlan0
  ip addr add 100.64.0.2/32 dev tailscale0
  ip -6 addr add 2001:db8::2/64 dev wlan0 nodad
  ip -6 addr add fd7a:115c:a1e0::2/128 dev tailscale0 nodad
  ip -4 route add default via 192.0.2.1 dev wlan0
  ip -6 route add default via 2001:db8::1 dev wlan0
  for family in -4 -6; do
    ip "$family" route add default dev wg0 table 51820
    ip "$family" rule add pref 5208 lookup main suppress_prefixlength 0
    ip "$family" rule add pref 5209 not fwmark 0xca6c lookup 51820
    ip "$family" rule add pref 5210 fwmark 0x80000/0xff0000 lookup main
  done

  # Neither daemon health nor table-52 routes are available at boot. Repair
  # must still let marked control traffic reach the uplink immediately.
  printf "wg0\n" >"$root/root/run/wireguard-reconnect.enabled"
  bash "$root/helper" auto-up wg0
  test -f "$state"
  test "$(wc -l <"$state")" -eq 4
  test "$(stat -c %a "$state")" = 600
  for family in -4 -6; do
    public=9.9.9.9
    [ "$family" = -4 ] || public=2001:4860:4860::8888
    ip "$family" route get "$public" | grep -q "dev wg0"
    ip "$family" route get "$public" mark 0x80000 | grep -q "dev wlan0"
  done
  ip -4 route get 100.64.0.3 | grep -q "dev wg0"
  ip -6 route get fd7a:115c:a1e0::3 | grep -q "dev wg0"

  # Routes arriving after login work without another WireGuard reconnect.
  ip -4 route add 100.64.0.0/10 dev tailscale0 table 52
  ip -6 route add fd7a:115c:a1e0::/48 dev tailscale0 table 52
  for dest in 100.64.0.3 100.100.100.100; do
    ip -4 route get "$dest" | grep -q "dev tailscale0"
    ip -4 route get "$dest" mark 0x80000 | grep -q "dev tailscale0"
  done
  ip -6 route get fd7a:115c:a1e0::3 | grep -q "dev tailscale0"
  ip -6 route get fd7a:115c:a1e0::3 mark 0x80000 | grep -q "dev tailscale0"

  # Repeated up actions neither duplicate rules nor lose tracked ownership.
  bash "$root/helper" up wg0
  test "$(wc -l <"$state")" -eq 4
  for family in -4 -6; do
    test "$(ip "$family" rule show | grep -c "^520[67]:")" -eq 2
  done

  # Intentional disconnect removes every rule owned by this integration.
  bash "$root/helper" down wg0
  test ! -e "$state"
  for family in -4 -6; do
    if ip "$family" rule show | grep -q "^520[67]:"; then exit 1; fi
  done
  ip link add wg0 type dummy
  ip link set wg0 up
  bash "$root/helper" up wg0
  test -f "$state"

  # Adequate pre-existing rules survive repair and intentional disconnect.
  for family in -4 -6; do
    ip "$family" rule add pref 1001 fwmark 0x80000/0xff0000 lookup main
  done
  ip -4 rule add pref 1000 to 100.64.0.0/10 lookup 52
  ip -6 rule add pref 1000 to fd7a:115c:a1e0::/48 lookup 52
  bash "$root/helper" up wg0
  test ! -e "$state"
  bash "$root/helper" down wg0
  for family in -4 -6; do
    test "$(ip "$family" rule show | grep -c "^100[01]:")" -eq 2
    if ip "$family" rule show | grep -q "^520[67]:"; then exit 1; fi
    ip "$family" rule del pref 1000
    ip "$family" rule del pref 1001
  done

  # A fresh connect with integration disabled adds no exceptions.
  ip link add wg0 type dummy
  ip link set wg0 up
  WIREGUARD_TAILSCALE_ENABLED=0 bash "$root/helper" up wg0
  test ! -e "$state"
  for family in -4 -6; do
    if ip "$family" rule show | grep -q "^520[67]:"; then exit 1; fi
  done
' bash "$TMP"

printf 'Tailscale startup routing test: OK\n'
