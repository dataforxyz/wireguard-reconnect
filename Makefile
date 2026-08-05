SHELL := /bin/bash

INTERFACE ?= $(shell head -n1 /usr/local/share/wireguard-reconnect/interface 2>/dev/null || printf '%s' wg0)
STATUS_SCRIPT ?= ./wireguard-status
PRIVILEGED_HELPER ?= /usr/local/bin/wireguard-reconnect
PKEXEC ?= pkexec
CURL ?= curl
CHECK_URL ?= https://example.com
DOMAIN ?=
PORTAL_SIMULATOR ?= ./tests/simulate-captive-portal.sh
PORTAL_CONTAINER_SIMULATOR ?= ./tests/simulate-captive-portal-container.sh
INTENT_STATE ?= /run/wireguard-reconnect.enabled
KILLSWITCH_STATE ?= /run/wg-killswitch.enabled

.PHONY: help status toggle connect disconnect reconnect reset portal portal-simulate portal-container-simulate logs diagnostics support-info test install uninstall

help:
	@printf '%s\n' \
	  'WireGuard controls:' \
	  '  make status       Show the same state used by the Waybar icon' \
	  '  make toggle       Same as middle-clicking the Waybar icon' \
	  '  make disconnect   Explicit intentional disconnect' \
	  '  make connect      Explicitly connect WireGuard' \
	  '  make reconnect    Bounce and reconnect WireGuard' \
	  '  make reset        Emergency full bypass: disable VPN intent and leak protection' \
	  '' \
	  'Captive portal:' \
	  '  make portal                 Detect, isolate login, and restore VPN automatically' \
	  '  make portal DOMAIN=x        Start the isolated browser at a known portal domain' \
	  '  make portal-simulate        Run a local no-root captive-portal simulation' \
	  '  make portal-container-simulate  Run the fake portal in Docker on loopback' \
	  '' \
	  'Troubleshooting:' \
	  '  make logs         Show recent service and helper logs' \
	  '  make diagnostics  Show raw interfaces/routes; redact before sharing' \
	  '  make support-info Show a reduced, shareable support summary' \
	  '  make test         Run the repository regression tests' \
	  '  make install      Install/update the system integration (uses sudo)' \
	  '  make uninstall    Remove the integration safely (uses sudo)'

status:
	@$(STATUS_SCRIPT)

toggle:
	@$(STATUS_SCRIPT) toggle

connect:
	@$(PKEXEC) $(PRIVILEGED_HELPER) up $(INTERFACE)

disconnect:
	@$(STATUS_SCRIPT) disconnect

reconnect:
	@$(STATUS_SCRIPT) reconnect

portal:
	@$(PKEXEC) $(PRIVILEGED_HELPER) portal $(INTERFACE) "$(DOMAIN)"

portal-simulate:
	@$(PORTAL_SIMULATOR)

portal-container-simulate:
	@$(PORTAL_CONTAINER_SIMULATOR)

# Recovery for a missing/stale wg0 that left the fail-closed guard armed.
# Older installed helpers return non-zero when wg0 is already absent, even
# though they successfully clear both intent and the nftables guard. Verify the
# resulting state instead of treating that harmless condition as a failed reset.
reset:
	@set +e; \
	$(PKEXEC) $(PRIVILEGED_HELPER) down $(INTERFACE); \
	rc=$$?; \
	if [[ ! -e $(INTENT_STATE) && ! -e $(KILLSWITCH_STATE) ]]; then \
	  printf '%s\n' 'WireGuard reset complete: VPN intent and leak-protection guard are off.'; \
	  $(CURL) --silent --show-error --head --max-time 8 $(CHECK_URL) >/dev/null \
	    && printf '%s\n' 'Direct internet connectivity check passed.' \
	    || printf '%s\n' 'Reset succeeded, but the direct internet check did not pass.'; \
	  exit 0; \
	fi; \
	printf '%s\n' 'WireGuard reset failed: intent or leak-protection state is still present.' >&2; \
	exit "$${rc:-1}"

logs:
	@printf '%s\n' 'WARNING: raw logs may contain network addresses, interface names, and local paths. Redact before sharing.'
	@journalctl \
	  -u wireguard-killswitch.service \
	  -u wireguard-monitor.service \
	  -u wireguard-autostart.service \
	  -t wg-killswitch \
	  -t wireguard-reconnect \
	  -t wireguard-monitor \
	  -t wireguard-portal \
	  -b --no-pager -n 400
	@printf '\n-- monitor process --\n'
	@systemctl show wireguard-monitor.service -p ActiveState -p SubState -p ActiveEnterTimestamp -p MainPID || true
	@printf '\n-- /run/wg-killswitch.log --\n'
	@tail -n 100 /run/wg-killswitch.log 2>/dev/null || echo '(root-only; use sudo make logs for helper detail)'
	@printf '\n-- /run/wireguard-reconnect.log --\n'
	@tail -n 50 /run/wireguard-reconnect.log 2>/dev/null || echo '(root-only; use sudo make logs for helper detail)'
	@printf '\n-- /run/wireguard-reconnect.failure --\n'
	@cat /run/wireguard-reconnect.failure 2>/dev/null || true
	@printf '\n-- /run/wireguard-portal.log --\n'
	@tail -n 100 /run/wireguard-portal.log 2>/dev/null || echo '(root-only; use sudo make logs for helper detail)'

diagnostics:
	@printf '%s\n' 'WARNING: diagnostics contain addresses, routes, interfaces, and local metadata. Redact before sharing.'
	@printf '%s\n' '-- status --'
	@$(STATUS_SCRIPT)
	@printf '%s\n' '-- WireGuard --'
	@wg show || true
	@printf '%s\n' '-- links --'
	@ip -brief link
	@printf '%s\n' '-- addresses --'
	@ip -brief address
	@printf '%s\n' '-- main routes --'
	@ip route show table main
	@printf '%s\n' '-- policy rules --'
	@ip rule show
	@printf '%s\n' '-- runtime intent --'
	@[[ -e /run/wireguard-reconnect.enabled ]] && cat /run/wireguard-reconnect.enabled || echo off
	@printf '%s\n' '-- leak-protection guard --'
	@[[ -e /run/wg-killswitch.enabled ]] && cat /run/wg-killswitch.enabled || echo off
	@printf '%s\n' '-- captive portal transaction --'
	@[[ -e /run/wireguard-portal.active ]] && echo active || echo inactive

support-info:
	@printf '%s\n' '-- version --'
	@WIREGUARD_RECONNECT_VERSION_FILE=./VERSION ./wireguard-reconnect --version
	@printf '%s\n' '-- platform --'
	@printf 'kernel=%s\n' "$$(uname -r)"
	@awk -F= '/^(ID|VERSION_ID)=/ {print}' /etc/os-release 2>/dev/null || true
	@printf '%s\n' '-- service state --'
	@for unit in wireguard-killswitch wireguard-monitor wireguard-autostart; do \
	  printf '%s active=%s enabled=%s\n' "$$unit" \
	    "$$(systemctl is-active "$$unit.service" 2>/dev/null || true)" \
	    "$$(systemctl is-enabled "$$unit.service" 2>/dev/null || true)"; \
	done
	@printf '%s\n' '-- VPN summary --'
	@$(STATUS_SCRIPT)

test:
	@./tests/test-killswitch.sh
	@./tests/test-autostart.sh
	@./tests/test-status.sh
	@./tests/test-make-controls.sh
	@./tests/test-portal.sh
	@./tests/test-portal-probes.sh
	@./tests/test-portal-session.sh
	@./tests/test-auto-portal.sh
	@./tests/test-maintenance.sh
	@./tests/test-installer-netns.sh
	@./tests/test-public-release.sh
	@./tests/test-version.sh

install:
	sudo ./install.sh

uninstall:
	sudo ./uninstall.sh
