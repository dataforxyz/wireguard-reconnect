#!/bin/bash
# Execute the real installer in a disposable user/mount namespace with mocked
# kernel/systemd commands. No host files, interfaces, firewall, or services are
# modified.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_USER="$(id -un)"
TEST_UID="$(id -u)"
TEST_GID="$(id -g)"
TEST_HOME="$HOME"

if ! command -v unshare >/dev/null 2>&1 || \
   ! unshare -Urnm --map-auto bash -c 'mount --make-rprivate /' 2>/dev/null; then
  echo "installer namespace transaction test: SKIP (mapped mount namespaces unavailable)"
  exit 0
fi

make_mocks() {
  local root="$1"
  mkdir -p "$root/mocks"

  cat >"$root/mocks/nft" <<'EOF'
#!/bin/bash
set -u
printf '%s\n' "$*" >>"$MOCK_STATE/nft-calls"
case "${1:-}" in
  list)
    if [ "${2:-}" = "tables" ]; then
      [ ! -e "$MOCK_STATE/nft-active" ] || echo 'table inet wg_killswitch'
      exit 0
    fi
    [ -e "$MOCK_STATE/nft-active" ] || exit 1
    cat "$MOCK_STATE/nft-rules"
    ;;
  -f)
    echo 'nft-apply' >>"$MOCK_STATE/events"
    if ! cp "$2" "$MOCK_STATE/nft-rules" 2>>"$MOCK_STATE/nft-errors"; then
      echo "copy failed: $2" >>"$MOCK_STATE/nft-errors"
      exit 1
    fi
    : >"$MOCK_STATE/nft-active"
    ;;
  delete)
    rm -f "$MOCK_STATE/nft-active" "$MOCK_STATE/nft-rules"
    ;;
  *) exit 1 ;;
esac
EOF

  cat >"$root/mocks/ip" <<'EOF'
#!/bin/bash
set -u
printf '%s\n' "$*" >>"$MOCK_STATE/ip-calls"
if [ "${1:-}" = "link" ] && [ "${2:-}" = "show" ]; then
  [ -e "$MOCK_STATE/link-${3:-wg0}" ]
  exit
fi
if [ "${1:-}" = "-4" ] && [ "${2:-}" = "route" ] && [ "${3:-}" = "get" ]; then
  [ -e "$MOCK_STATE/link-$TEST_INTERFACE" ] || exit 1
  echo "${4:-9.9.9.9} dev $TEST_INTERFACE src 10.0.0.2"
  exit 0
fi
if [ "${1:-}" = "-4" ] || [ "${1:-}" = "-6" ]; then
  exit 0
fi
exit 0
EOF

  cat >"$root/mocks/curl" <<'EOF'
#!/bin/bash
iface=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--interface" ]; then iface="${2:-}"; shift; fi
  shift
done
echo "curl $iface" >>"$MOCK_STATE/events"
if [ "${MOCK_CURL_FAIL:-0}" = "1" ] || [ -z "$iface" ] || \
   [ ! -e "$MOCK_STATE/link-$iface" ]; then
  printf '000'
  exit 28
fi
if [ "${EXPECT_KILLSWITCH:-1}" = "1" ] && \
   { [ ! -e "$MOCK_STATE/nft-active" ] || \
     ! grep -Fq "oifname \"$iface\" accept" "$MOCK_STATE/nft-rules"; }; then
  printf '000'
  exit 28
fi
printf '204'
EOF

  cat >"$root/mocks/sleep" <<'EOF'
#!/bin/bash
# Verification retries are instantaneous. The rollback timer stays alive only
# until confirmation/rollback removes its token, so no namespace child lingers.
if [ "${1:-}" = "90" ]; then
  while [ -e /run/wg-killswitch.rollback-token ]; do
    "$MOCK_ORIG_BIN/sleep" 0.02
  done
fi
exit 0
EOF

  cat >"$root/mocks/wg-quick" <<'EOF'
#!/bin/bash
set -u
case "${1:-}" in
  up)
    iface="${2##*/}"
    iface="${iface%.conf}"
    [[ "$iface" =~ ^wg[0-9]+$ ]] || iface="$TEST_INTERFACE"
    : >"$MOCK_STATE/link-$iface"
    echo "wg-up $iface" >>"$MOCK_STATE/events"
    echo "up $iface" >>"$MOCK_STATE/wg-quick-calls"
    ;;
  down)
    iface="${2##*/}"
    iface="${iface%.conf}"
    [[ "$iface" =~ ^wg[0-9]+$ ]] || iface="$TEST_INTERFACE"
    echo "wg-down $iface" >>"$MOCK_STATE/events"
    echo "down $iface" >>"$MOCK_STATE/wg-quick-calls"
    [ "${MOCK_WG_QUICK_DOWN_FAIL:-0}" != "1" ] || exit 1
    rm -f "$MOCK_STATE/link-$iface"
    ;;
  *) exit 2 ;;
esac
EOF

  cat >"$root/mocks/wg" <<'EOF'
#!/bin/bash
if [ "${3:-}" = "fwmark" ]; then echo 0xca6c; fi
EOF

  cat >"$root/mocks/getent" <<'EOF'
#!/bin/bash
case "${1:-}" in
  passwd)
    echo "$TEST_USER:x:$TEST_UID:$TEST_GID:Test User:$TEST_HOME:/bin/bash"
    ;;
  ahostsv4)
    echo "203.0.113.10 STREAM ${2:-vpn.invalid}"
    ;;
  ahostsv6)
    exit 2
    ;;
  *) exit 2 ;;
esac
EOF

  cat >"$root/mocks/systemctl" <<'EOF'
#!/bin/bash
set -u
printf '%s\n' "$*" >>"$MOCK_STATE/systemctl-calls"
command="${1:-}"
shift || true
case "$command" in
  is-active|is-enabled)
    unit=""
    for arg in "$@"; do [[ "$arg" == -* ]] || unit="$arg"; done
    [ -n "$unit" ] && [ -e "$MOCK_STATE/${command#is-}-$unit" ]
    ;;
  enable|reenable)
    for arg in "$@"; do
      [[ "$arg" == -* ]] || : >"$MOCK_STATE/enabled-$arg"
    done
    ;;
  start|restart)
    for arg in "$@"; do
      [[ "$arg" == -* ]] || : >"$MOCK_STATE/active-$arg"
    done
    ;;
  stop)
    for arg in "$@"; do
      [[ "$arg" == -* ]] || rm -f "$MOCK_STATE/active-$arg"
    done
    ;;
  disable)
    for arg in "$@"; do
      if [ -n "${MOCK_SYSTEMCTL_DISABLE_FAIL:-}" ] && [ "$arg" = "$MOCK_SYSTEMCTL_DISABLE_FAIL" ]; then
        exit 1
      fi
      [[ "$arg" == -* ]] || rm -f "$MOCK_STATE/enabled-$arg" "$MOCK_STATE/active-$arg"
    done
    ;;
  daemon-reload|reset-failed|status) exit 0 ;;
  *) exit 0 ;;
esac
EOF

  for name in pkill pkexec logger resolvectl loginctl iw runuser sysctl; do
    cat >"$root/mocks/$name" <<'EOF'
#!/bin/bash
exit 0
EOF
  done
  chmod +x "$root/mocks/"*
}

run_case() {
  local mode="$1" root interface=wg0
  [[ "$mode" == migration* ]] && interface=wg1
  root="$(mktemp -d)"
  make_mocks "$root"
  mkdir -p "$root/state"
  cp -a "$REPO_DIR" "$root/repo"

  if ! unshare -Urnm --map-auto env \
      REPO_DIR="$root/repo" CASE_ROOT="$root" MOCK_STATE="$root/state" \
      TEST_USER="$TEST_USER" TEST_UID="$TEST_UID" TEST_GID="$TEST_GID" \
      TEST_HOME="$TEST_HOME" TEST_INTERFACE="$interface" TEST_MODE="$mode" \
      bash -s <<'INNER'
set -euo pipefail
mount --make-rprivate /
orig="$CASE_ROOT/orig-bin"
export MOCK_ORIG_BIN="$orig"
mkdir -p "$orig"
mount --bind /usr/bin "$orig"
mount -t tmpfs tmpfs /usr/bin
for path in "$orig"/*; do "$orig/ln" -s "$path" "/usr/bin/${path##*/}"; done
[ -e /usr/bin/chromium ] || "$orig/ln" -s "$orig/true" /usr/bin/chromium
for name in nft ip iw curl wg-quick pkill pkexec resolvectl loginctl runuser sysctl logger; do
  "$orig/rm" -f "/usr/bin/$name"
  "$orig/touch" "/usr/bin/$name"
  mount --bind "$CASE_ROOT/mocks/$name" "/usr/bin/$name"
done

orig_etc="$CASE_ROOT/orig-etc"
mkdir -p "$orig_etc"
mount --bind /etc "$orig_etc"
mount -t tmpfs tmpfs /etc
for path in "$orig_etc"/*; do "$orig/ln" -s "$path" "/etc/${path##*/}"; done
for path in wireguard wireguard-reconnect systemd polkit-1; do "$orig/rm" -rf "/etc/$path"; done
mkdir -p /etc/wireguard /etc/systemd/system /etc/polkit-1/rules.d
for iface in wg0 wg1; do
  cat >"/etc/wireguard/$iface.conf" <<'EOF'
[Interface]
PrivateKey = test
Address = 10.0.0.2/32
[Peer]
PublicKey = test
Endpoint = 203.0.113.10:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
done

mount -t tmpfs tmpfs /usr/local
mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /var/backups
mount -t tmpfs tmpfs /var/lib
mount -t tmpfs tmpfs /usr/lib/systemd/system-sleep
home_src="$CASE_ROOT/home"
mkdir -p "$home_src"
chown "$TEST_UID:$TEST_GID" "$home_src"
mount --bind "$home_src" "$TEST_HOME"
trap 'chown -R 0:0 "$CASE_ROOT" 2>/dev/null || true' EXIT

export PATH="$CASE_ROOT/mocks:/usr/bin:/bin"
if [[ "$TEST_MODE" == migration* || "$TEST_MODE" == tailscale-optout || "$TEST_MODE" == optout-disable-failure ]]; then
  mkdir -p /usr/local/bin
  cat >/usr/local/bin/wg-killswitch <<'EOF'
#!/bin/bash
# prior-helper-sentinel
exit 0
EOF
  chmod 0750 /usr/local/bin/wg-killswitch
  printf 'prior-monitor-unit\n' >/etc/systemd/system/wireguard-monitor.service
  chmod 0640 /etc/systemd/system/wireguard-monitor.service
  printf 'prior-polkit-rule\n' >/etc/polkit-1/rules.d/49-wireguard-reconnect.rules
  chmod 0640 /etc/polkit-1/rules.d/49-wireguard-reconnect.rules
  install -d -o "$TEST_USER" -g "$TEST_GID" -m 0755 "$TEST_HOME/.local/bin"
  chown "$TEST_UID:$TEST_GID" "$TEST_HOME/.local" "$TEST_HOME/.local/bin"
  printf 'prior-user-status\n' >"$TEST_HOME/.local/bin/wireguard-status"
  chown "$TEST_UID:$TEST_GID" "$TEST_HOME/.local/bin/wireguard-status"
  chmod 0700 "$TEST_HOME/.local/bin/wireguard-status"
  install -d -m 0700 /etc/wireguard-reconnect
  printf 'wg0\n' >/etc/wireguard-reconnect/interface
  printf '0\n' >/etc/wireguard-reconnect/tailscale-enabled
  printf 'WIREGUARD_INTERFACE=wg0\nWIREGUARD_TAILSCALE_ENABLED=0\n' >/etc/wireguard-reconnect/environment
  install -d -m 0755 /usr/local/share/wireguard-reconnect
  printf 'wg0\n' >/usr/local/share/wireguard-reconnect/interface
  printf 'wg0\n' >/run/wg-killswitch.enabled
  : >"$MOCK_STATE/link-wg0"
  : >"$MOCK_STATE/nft-active"
  : >"$MOCK_STATE/active-wireguard-monitor.service"
  : >"$MOCK_STATE/enabled-wireguard-monitor.service"
  : >"$MOCK_STATE/active-wireguard-autostart.service"
  : >"$MOCK_STATE/enabled-wireguard-autostart.service"
  : >"$MOCK_STATE/enabled-wireguard-killswitch.service"
  printf 'prior-portal-stamp\n' >/run/wireguard-portal.autodetect
  printf 'prior-portal-candidate\n' >/run/wg-killswitch.portal-candidate
  chmod 0600 /run/wireguard-portal.autodetect /run/wg-killswitch.portal-candidate
fi
if [ "$TEST_MODE" = tailscale-optout ]; then
  printf '1\n' >/etc/wireguard-reconnect/tailscale-enabled
  printf 'WIREGUARD_INTERFACE=wg0\nWIREGUARD_TAILSCALE_ENABLED=1\n' >/etc/wireguard-reconnect/environment
  printf 'V4_MARK_PREF=5199\nV6_MARK_PREF=5199\nV4_PREF=5200\n' >/run/wireguard-reconnect.tailscale-rules
  chmod 0600 /run/wireguard-reconnect.tailscale-rules
fi

export SUDO_USER="$TEST_USER" INSTALL_INTERFACE="$TEST_INTERFACE" ENABLE_TAILSCALE_INTEGRATION=0
export ENABLE_KILLSWITCH=1 ENABLE_AUTOMATIC_RECONNECT=1 ENABLE_AUTOSTART=1
export ENABLE_CAPTIVE_PORTAL=1 ENABLE_AUTO_PORTAL=1 CONNECT_ON_INSTALL=1 EXPECT_KILLSWITCH=1
if [ "$TEST_MODE" = options-persist ]; then
  install -d -m 0700 /etc/wireguard-reconnect
  for option_file in killswitch-enabled automatic-reconnect-enabled autostart-enabled \
      captive-portal-enabled auto-portal-enabled connect-on-install; do
    printf '0\n' >"/etc/wireguard-reconnect/$option_file"
    chmod 0600 "/etc/wireguard-reconnect/$option_file"
  done
  unset ENABLE_KILLSWITCH ENABLE_AUTOMATIC_RECONNECT ENABLE_AUTOSTART
  unset ENABLE_CAPTIVE_PORTAL ENABLE_AUTO_PORTAL CONNECT_ON_INSTALL
  export EXPECT_KILLSWITCH=0
fi
if [ "$TEST_MODE" = options-invalid ]; then
  install -d -m 0700 /etc/wireguard-reconnect
  printf 'invalid\n' >/etc/wireguard-reconnect/killswitch-enabled
  chmod 0600 /etc/wireguard-reconnect/killswitch-enabled
  unset ENABLE_KILLSWITCH
fi
case "$TEST_MODE" in
  migration-failure)
    export ENABLE_CAPTIVE_PORTAL=0 ENABLE_AUTO_PORTAL=0
    ;;
  minimal)
    export ENABLE_KILLSWITCH=0 ENABLE_AUTOMATIC_RECONNECT=0 ENABLE_AUTOSTART=0
    export ENABLE_CAPTIVE_PORTAL=0 ENABLE_AUTO_PORTAL=0 CONNECT_ON_INSTALL=0 EXPECT_KILLSWITCH=0
    ;;
  manual-no-guard)
    export ENABLE_KILLSWITCH=0 ENABLE_AUTOMATIC_RECONNECT=0 ENABLE_AUTOSTART=0
    export ENABLE_CAPTIVE_PORTAL=0 ENABLE_AUTO_PORTAL=0 CONNECT_ON_INSTALL=1 EXPECT_KILLSWITCH=0
    ;;
  kill-only-optout)
    export ENABLE_KILLSWITCH=0 EXPECT_KILLSWITCH=0
    ;;
  auto-reconnect-optout)
    export ENABLE_AUTOMATIC_RECONNECT=0
    ;;
  optout-disable-failure)
    export ENABLE_KILLSWITCH=0 ENABLE_CAPTIVE_PORTAL=0 EXPECT_KILLSWITCH=0
    export MOCK_SYSTEMCTL_DISABLE_FAIL=wireguard-killswitch.service
    ;;
  guarded-manual)
    export ENABLE_AUTOMATIC_RECONNECT=0 ENABLE_AUTOSTART=0 ENABLE_CAPTIVE_PORTAL=0
    export ENABLE_AUTO_PORTAL=0 CONNECT_ON_INSTALL=0
    ;;
  no-boot-connect)
    export ENABLE_AUTOSTART=0 CONNECT_ON_INSTALL=0
    ;;
  boot-only)
    export ENABLE_KILLSWITCH=0 ENABLE_AUTOMATIC_RECONNECT=0 ENABLE_AUTOSTART=1
    export ENABLE_CAPTIVE_PORTAL=0 ENABLE_AUTO_PORTAL=0 CONNECT_ON_INSTALL=0 EXPECT_KILLSWITCH=0
    ;;
esac
if [ "$TEST_MODE" = no-boot-connect ]; then
  printf 'wg0\n' >/run/wireguard-reconnect.enabled
fi
if [ "$TEST_MODE" = minimal ] || [ "$TEST_MODE" = kill-only-optout ]; then
  for portal_command in iw loginctl runuser resolvectl sysctl setsid; do
    umount "/usr/bin/$portal_command" 2>/dev/null || true
    rm -f "/usr/bin/$portal_command"
  done
fi
export MOCK_STATE TEST_USER TEST_UID TEST_GID TEST_HOME TEST_INTERFACE EXPECT_KILLSWITCH
export MOCK_SYSTEMCTL_DISABLE_FAIL="${MOCK_SYSTEMCTL_DISABLE_FAIL:-}"
if [ "$TEST_MODE" = failure ] || [ "$TEST_MODE" = migration-failure ]; then export MOCK_CURL_FAIL=1; fi

set +e
/usr/bin/bash "$REPO_DIR/install.sh" >"$CASE_ROOT/install.out" 2>&1
rc=$?
set -e
if [[ "$TEST_MODE" == uninstall* ]] && [ "$rc" -eq 0 ]; then
  [ "$TEST_MODE" != uninstall-failure ] || export MOCK_WG_QUICK_DOWN_FAIL=1
  set +e
  /usr/bin/bash "$REPO_DIR/uninstall.sh" >"$CASE_ROOT/uninstall.out" 2>&1
  rc=$?
  set -e
fi
event_line() {
  grep -n -m1 -Fx "$1" "$MOCK_STATE/events" | cut -d: -f1
}
case "$TEST_MODE" in
  success)
    [ "$rc" -eq 0 ]
    [ -x /usr/local/bin/wireguard-reconnect ]
    [ -x /usr/local/bin/wg-killswitch ]
    [ -e "$MOCK_STATE/link-wg0" ]
    [ -e "$MOCK_STATE/nft-active" ]
    [ "$(event_line nft-apply)" -lt "$(event_line 'wg-up wg0')" ]
    [ "$(event_line 'wg-up wg0')" -lt "$(event_line 'curl wg0')" ]
    ;;
  failure)
    [ "$rc" -ne 0 ]
    [ ! -e /usr/local/bin/wireguard-reconnect ]
    [ ! -e "$MOCK_STATE/link-wg0" ]
    [ ! -e "$MOCK_STATE/nft-active" ]
    grep -Fq 'Rollback complete' "$CASE_ROOT/install.out"
    ;;
  migration)
    [ "$rc" -eq 0 ]
    [ ! -e "$MOCK_STATE/link-wg0" ]
    [ -e "$MOCK_STATE/link-wg1" ]
    grep -Fxq 'wg1' /etc/wireguard-reconnect/interface
    [ -e "$MOCK_STATE/nft-active" ]
    [ "$(event_line nft-apply)" -lt "$(event_line 'wg-down wg0')" ]
    [ "$(event_line 'wg-down wg0')" -lt "$(event_line 'wg-up wg1')" ]
    ;;
  migration-failure)
    [ "$rc" -ne 0 ]
    [ -e "$MOCK_STATE/link-wg0" ]
    [ ! -e "$MOCK_STATE/link-wg1" ]
    grep -Fxq 'wg0' /etc/wireguard-reconnect/interface
    grep -Fq 'prior-helper-sentinel' /usr/local/bin/wg-killswitch
    [ "$(stat -c '%a' /usr/local/bin/wg-killswitch)" = 750 ]
    grep -Fxq 'prior-monitor-unit' /etc/systemd/system/wireguard-monitor.service
    [ "$(stat -c '%a' /etc/systemd/system/wireguard-monitor.service)" = 640 ]
    grep -Fxq 'prior-polkit-rule' /etc/polkit-1/rules.d/49-wireguard-reconnect.rules
    [ "$(stat -c '%a' /etc/polkit-1/rules.d/49-wireguard-reconnect.rules)" = 640 ]
    grep -Fxq 'prior-user-status' "$TEST_HOME/.local/bin/wireguard-status"
    [ "$(stat -c '%a' "$TEST_HOME/.local/bin/wireguard-status")" = 700 ]
    grep -Fxq 'prior-portal-stamp' /run/wireguard-portal.autodetect
    grep -Fxq 'prior-portal-candidate' /run/wg-killswitch.portal-candidate
    [ "$(stat -c '%a' /run/wireguard-portal.autodetect)" = 600 ]
    [ "$(stat -c '%a' /run/wg-killswitch.portal-candidate)" = 600 ]
    [ -e "$MOCK_STATE/nft-active" ]
    [ -e "$MOCK_STATE/active-wireguard-monitor.service" ]
    [ -e "$MOCK_STATE/enabled-wireguard-monitor.service" ]
    [ -e "$MOCK_STATE/enabled-wireguard-autostart.service" ]
    [ -e "$MOCK_STATE/enabled-wireguard-killswitch.service" ]
    grep -Fq 'Rollback complete' "$CASE_ROOT/install.out"
    ;;
  tailscale-optout)
    [ "$rc" -eq 0 ]
    [ -e "$MOCK_STATE/link-wg0" ]
    [ ! -e /run/wireguard-reconnect.tailscale-rules ]
    grep -Fq -- '-4 rule del pref 5199 fwmark 0x80000/0xff0000 lookup main' "$MOCK_STATE/ip-calls"
    grep -Fq -- '-6 rule del pref 5199 fwmark 0x80000/0xff0000 lookup main' "$MOCK_STATE/ip-calls"
    grep -Fq -- '-4 rule del pref 5200 to 100.64.0.0/10 lookup 52' "$MOCK_STATE/ip-calls"
    grep -Fxq '0' /etc/wireguard-reconnect/tailscale-enabled
    ;;
  minimal)
    [ "$rc" -eq 0 ]
    [ ! -e "$MOCK_STATE/link-wg0" ]
    [ ! -e "$MOCK_STATE/nft-active" ]
    [ ! -e "$MOCK_STATE/enabled-wireguard-killswitch.service" ]
    [ ! -e "$MOCK_STATE/enabled-wireguard-monitor.service" ]
    [ ! -e "$MOCK_STATE/enabled-wireguard-autostart.service" ]
    grep -Fxq '0' /etc/wireguard-reconnect/killswitch-enabled
    grep -Fxq '0' /etc/wireguard-reconnect/automatic-reconnect-enabled
    grep -Fxq '0' /etc/wireguard-reconnect/autostart-enabled
    grep -Fxq '0' /etc/wireguard-reconnect/captive-portal-enabled
    grep -Fxq '0' /usr/local/share/wireguard-reconnect/automatic-reconnect-enabled
    set +e
    /usr/local/bin/wireguard-reconnect portal wg0 >/dev/null 2>&1
    portal_rc=$?
    set -e
    [ "$portal_rc" -ne 0 ]
    [ ! -e /run/wireguard-reconnect.enabled ]
    [ ! -e /run/wireguard-portal.active ]
    ;;
  manual-no-guard)
    [ "$rc" -eq 0 ]
    [ -e "$MOCK_STATE/link-wg0" ]
    [ ! -e "$MOCK_STATE/nft-active" ]
    [ -e /run/wireguard-reconnect.enabled ]
    [ ! -e "$MOCK_STATE/active-wireguard-killswitch.service" ]
    [ ! -e "$MOCK_STATE/active-wireguard-monitor.service" ]
    [ ! -e "$MOCK_STATE/active-wireguard-autostart.service" ]
    ;;
  kill-only-optout)
    [ "$rc" -eq 0 ]
    [ -e "$MOCK_STATE/link-wg0" ]
    [ ! -e "$MOCK_STATE/nft-active" ]
    grep -Fxq '0' /etc/wireguard-reconnect/killswitch-enabled
    grep -Fxq '0' /etc/wireguard-reconnect/captive-portal-enabled
    grep -Fxq '0' /etc/wireguard-reconnect/auto-portal-enabled
    [ -e "$MOCK_STATE/active-wireguard-monitor.service" ]
    [ -e "$MOCK_STATE/active-wireguard-autostart.service" ]
    ;;
  auto-reconnect-optout)
    [ "$rc" -eq 0 ]
    [ -e "$MOCK_STATE/link-wg0" ]
    [ -e "$MOCK_STATE/nft-active" ]
    grep -Fxq '0' /etc/wireguard-reconnect/automatic-reconnect-enabled
    grep -Fxq '0' /etc/wireguard-reconnect/auto-portal-enabled
    [ ! -e "$MOCK_STATE/active-wireguard-monitor.service" ]
    [ -e "$MOCK_STATE/active-wireguard-autostart.service" ]
    ;;
  optout-disable-failure)
    [ "$rc" -ne 0 ]
    [ -e "$MOCK_STATE/link-wg0" ]
    [ -e "$MOCK_STATE/nft-active" ]
    [ -e "$MOCK_STATE/enabled-wireguard-killswitch.service" ]
    grep -Fq 'prior-helper-sentinel' /usr/local/bin/wg-killswitch
    grep -Fxq 'wg0' /etc/wireguard-reconnect/interface
    grep -Fq 'Rollback complete' "$CASE_ROOT/install.out"
    ;;
  guarded-manual)
    [ "$rc" -eq 0 ]
    [ ! -e "$MOCK_STATE/link-wg0" ]
    [ -e "$MOCK_STATE/nft-active" ]
    [ -e "$MOCK_STATE/active-wireguard-killswitch.service" ]
    [ -e "$MOCK_STATE/enabled-wireguard-killswitch.service" ]
    [ ! -e "$MOCK_STATE/active-wireguard-monitor.service" ]
    [ ! -e "$MOCK_STATE/active-wireguard-autostart.service" ]
    ;;
  no-boot-connect)
    [ "$rc" -eq 0 ]
    [ ! -e "$MOCK_STATE/link-wg0" ]
    [ -e "$MOCK_STATE/nft-active" ]
    [ -e "$MOCK_STATE/enabled-wireguard-monitor.service" ]
    [ ! -e "$MOCK_STATE/active-wireguard-monitor.service" ]
    [ ! -e "$MOCK_STATE/enabled-wireguard-autostart.service" ]
    [ ! -e /run/wireguard-reconnect.enabled ]
    [ -e /run/wireguard-reconnect.autostart-suppressed ]
    set +e
    /usr/local/bin/wireguard-reconnect auto-up wg0 >/dev/null 2>&1
    auto_rc=$?
    set -e
    [ "$auto_rc" -eq 3 ]
    [ ! -e "$MOCK_STATE/link-wg0" ]
    ;;
  disconnect-suppresses-auto)
    [ "$rc" -eq 0 ]
    /usr/local/bin/wireguard-reconnect down wg0
    [ ! -e "$MOCK_STATE/link-wg0" ]
    [ ! -e "$MOCK_STATE/nft-active" ]
    [ ! -e /run/wireguard-reconnect.enabled ]
    [ -e /run/wireguard-reconnect.autostart-suppressed ]
    set +e
    /usr/local/bin/wireguard-reconnect auto-up wg0 >/dev/null 2>&1
    auto_rc=$?
    set -e
    [ "$auto_rc" -eq 3 ]
    [ ! -e "$MOCK_STATE/link-wg0" ]
    ;;
  boot-only)
    [ "$rc" -eq 0 ]
    [ ! -e "$MOCK_STATE/link-wg0" ]
    [ ! -e "$MOCK_STATE/nft-active" ]
    [ -e "$MOCK_STATE/enabled-wireguard-autostart.service" ]
    [ ! -e "$MOCK_STATE/active-wireguard-autostart.service" ]
    [ ! -e "$MOCK_STATE/enabled-wireguard-monitor.service" ]
    ;;
  options-persist)
    [ "$rc" -eq 0 ]
    [ ! -e "$MOCK_STATE/link-wg0" ]
    [ ! -e "$MOCK_STATE/nft-active" ]
    grep -Fxq '0' /etc/wireguard-reconnect/killswitch-enabled
    grep -Fxq '0' /etc/wireguard-reconnect/automatic-reconnect-enabled
    grep -Fxq '0' /etc/wireguard-reconnect/autostart-enabled
    grep -Fxq '0' /etc/wireguard-reconnect/captive-portal-enabled
    grep -Fxq '0' /etc/wireguard-reconnect/connect-on-install
    ;;
  options-invalid)
    [ "$rc" -ne 0 ]
    [ ! -e /usr/local/bin/wireguard-reconnect ]
    [ ! -e "$MOCK_STATE/nft-active" ]
    grep -Fq 'Invalid persisted installer option' "$CASE_ROOT/install.out"
    ;;
  uninstall)
    [ "$rc" -eq 0 ]
    [ ! -e /usr/local/bin/wireguard-reconnect ]
    [ ! -e /etc/wireguard-reconnect ]
    [ -e /etc/wireguard/wg0.conf ]
    [ ! -e "$MOCK_STATE/link-wg0" ]
    [ ! -e "$MOCK_STATE/nft-active" ]
    ;;
  uninstall-failure)
    [ "$rc" -ne 0 ]
    [ -x /usr/local/bin/wireguard-reconnect ]
    [ -d /etc/wireguard-reconnect ]
    [ -e /etc/systemd/system/wireguard-monitor.service ]
    [ -e "$MOCK_STATE/link-wg0" ]
    [ -e "$MOCK_STATE/nft-active" ]
    [ -e /run/wireguard-reconnect.enabled ]
    [ -e "$MOCK_STATE/active-wireguard-monitor.service" ]
    [ -e "$MOCK_STATE/active-wireguard-autostart.service" ]
    ;;
esac
[ ! -e /run/wg-killswitch.rollback-token ]
case "$TEST_MODE" in
  success|migration|tailscale-optout)
    [ -e "$MOCK_STATE/active-wireguard-monitor.service" ]
    [ -e "$MOCK_STATE/active-wireguard-autostart.service" ]
    ;;
esac
INNER
  then
    echo "installer namespace transaction test failed: $mode" >&2
    [ ! -f "$root/install.out" ] || cat "$root/install.out" >&2
    [ ! -f "$root/uninstall.out" ] || cat "$root/uninstall.out" >&2
    [ ! -f "$root/state/nft-calls" ] || { echo '-- nft calls --' >&2; cat "$root/state/nft-calls" >&2; }
    [ ! -s "$root/state/nft-errors" ] || { echo '-- nft errors --' >&2; cat "$root/state/nft-errors" >&2; }
    [ ! -f "$root/state/wg-quick-calls" ] || { echo '-- wg-quick calls --' >&2; cat "$root/state/wg-quick-calls" >&2; }
    [ ! -f "$root/state/systemctl-calls" ] || { echo '-- systemctl calls --' >&2; cat "$root/state/systemctl-calls" >&2; }
    rm -rf "$root"
    return 1
  fi
  rm -rf "$root"
}

run_case success
run_case failure
run_case migration
run_case migration-failure
run_case tailscale-optout
run_case minimal
run_case manual-no-guard
run_case kill-only-optout
run_case auto-reconnect-optout
run_case optout-disable-failure
run_case guarded-manual
run_case no-boot-connect
run_case disconnect-suppresses-auto
run_case boot-only
run_case options-persist
run_case options-invalid
run_case uninstall
run_case uninstall-failure
printf 'installer namespace transaction test: OK\n'
