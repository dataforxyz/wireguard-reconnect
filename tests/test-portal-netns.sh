#!/bin/bash
# Rootless kernel-level smoke test for the portal veth and nftables boundaries.
set -euo pipefail

if [ "${PORTAL_NETNS_INNER:-0}" != "1" ]; then
    if ! command -v unshare >/dev/null 2>&1 || ! unshare -Urn true 2>/dev/null; then
        echo "portal namespace kernel test: SKIP (unprivileged user namespaces unavailable)"
        exit 0
    fi
    exec unshare -Urn env PORTAL_NETNS_INNER=1 "$0"
fi

PORTAL_PID=""
INTERNET_PID=""
OTHER_PID=""
SERVER_PIDS=()
cleanup() {
    local pid
    for pid in "${SERVER_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    [ -z "$PORTAL_PID" ] || kill "$PORTAL_PID" 2>/dev/null || true
    [ -z "$INTERNET_PID" ] || kill "$INTERNET_PID" 2>/dev/null || true
    [ -z "$OTHER_PID" ] || kill "$OTHER_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

ip link set lo up
sysctl -q -w net.ipv4.ip_forward=0
[ "$(sysctl -n net.ipv4.ip_forward)" = "0" ]

unshare -n sleep 60 & PORTAL_PID=$!
unshare -n sleep 60 & INTERNET_PID=$!
unshare -n sleep 60 & OTHER_PID=$!

ip link add wgportal0 type veth peer name portaleth
ip link set portaleth netns "$PORTAL_PID"
ip address add 10.254.254.1/30 dev wgportal0
ip link set wgportal0 up
nsenter -t "$PORTAL_PID" -n ip link set lo up
nsenter -t "$PORTAL_PID" -n ip address add 10.254.254.2/30 dev portaleth
nsenter -t "$PORTAL_PID" -n ip link set portaleth up
nsenter -t "$PORTAL_PID" -n ip route add default via 10.254.254.1

ip link add uplink0 type veth peer name interneteth
ip link set interneteth netns "$INTERNET_PID"
ip address add 10.200.0.1/30 dev uplink0
ip link set uplink0 up
nsenter -t "$INTERNET_PID" -n ip link set lo up
nsenter -t "$INTERNET_PID" -n ip address add 10.200.0.2/30 dev interneteth
nsenter -t "$INTERNET_PID" -n ip link set interneteth up
nsenter -t "$INTERNET_PID" -n ip route add 10.254.254.0/30 via 10.200.0.1

ip link add existing0 type veth peer name othereth
ip link set othereth netns "$OTHER_PID"
ip address add 10.210.0.1/30 dev existing0
ip link set existing0 up
nsenter -t "$OTHER_PID" -n ip link set lo up
nsenter -t "$OTHER_PID" -n ip address add 10.210.0.2/30 dev othereth
nsenter -t "$OTHER_PID" -n ip link set othereth up
nsenter -t "$OTHER_PID" -n ip route add default via 10.210.0.1
nsenter -t "$INTERNET_PID" -n ip route add 10.210.0.0/30 via 10.200.0.1

nft -f - <<'EOF'
table inet portal_test {
  chain portal_forward_gate {
    type filter hook forward priority -10; policy accept;
    iifname "uplink0" oifname "wgportal0" ct state established,related accept
    iifname "uplink0" drop
  }
  chain input {
    type filter hook input priority -10; policy accept;
    iifname "wgportal0" reject with icmpx type admin-prohibited
  }
  chain forward {
    type filter hook forward priority filter; policy drop;
    iifname "wgportal0" udp dport { 53, 443 } accept
    iifname "wgportal0" tcp dport { 53, 80, 443 } accept
    iifname "wgportal0" reject with icmpx type admin-prohibited
    oifname "wgportal0" ct state established,related accept
    oifname "wgportal0" reject with icmpx type admin-prohibited
    oifname "uplink0" accept
    ip daddr 10.0.0.0/8 accept
  }
}
EOF

# Production enables only the two required per-interface forwarding knobs after
# the portal-only gate is installed; global router mode remains disabled.
sysctl -q -w net.ipv4.conf.wgportal0.forwarding=1
sysctl -q -w net.ipv4.conf.uplink0.forwarding=1
sysctl -q -w net.ipv4.conf.existing0.forwarding=1
[ "$(sysctl -n net.ipv4.ip_forward)" = "0" ]

nsenter -t "$INTERNET_PID" -n python3 -m http.server 80 --bind 10.200.0.2 >/dev/null 2>&1 &
SERVER_PIDS+=("$!")
nsenter -t "$INTERNET_PID" -n python3 -m http.server 22 --bind 10.200.0.2 >/dev/null 2>&1 &
SERVER_PIDS+=("$!")
python3 -m http.server 80 --bind 10.254.254.1 >/dev/null 2>&1 &
SERVER_PIDS+=("$!")
nsenter -t "$PORTAL_PID" -n python3 -m http.server 80 --bind 10.254.254.2 >/dev/null 2>&1 &
SERVER_PIDS+=("$!")
nsenter -t "$OTHER_PID" -n python3 -m http.server 80 --bind 10.210.0.2 >/dev/null 2>&1 &
SERVER_PIDS+=("$!")

for _ in $(seq 1 30); do
    if nsenter -t "$PORTAL_PID" -n curl --silent --max-time 1 http://10.200.0.2/ >/dev/null 2>&1; then
        break
    fi
    sleep 0.05
done
nsenter -t "$PORTAL_PID" -n curl --fail --silent --max-time 2 http://10.200.0.2/ >/dev/null
for _ in $(seq 1 30); do
    if nsenter -t "$PORTAL_PID" -n curl --silent --max-time 1 http://10.254.254.2/ >/dev/null 2>&1; then
        break
    fi
    sleep 0.05
done
nsenter -t "$PORTAL_PID" -n curl --fail --silent --max-time 2 http://10.254.254.2/ >/dev/null

if nsenter -t "$PORTAL_PID" -n curl --silent --max-time 1 http://10.200.0.2:22/ >/dev/null 2>&1; then
    echo "portal namespace unexpectedly reached a non-web destination port" >&2
    exit 1
fi
if nsenter -t "$PORTAL_PID" -n curl --silent --max-time 1 http://10.254.254.1/ >/dev/null 2>&1; then
    echo "portal namespace unexpectedly reached a host service" >&2
    exit 1
fi
if nsenter -t "$INTERNET_PID" -n curl --silent --max-time 1 http://10.254.254.2/ >/dev/null 2>&1; then
    echo "unsolicited inbound traffic unexpectedly reached the portal namespace" >&2
    exit 1
fi
if nsenter -t "$INTERNET_PID" -n curl --silent --max-time 1 http://10.210.0.2/ >/dev/null 2>&1; then
    echo "new physical-interface forwarding unexpectedly bypassed the conditional gate" >&2
    exit 1
fi

# Model a host whose physical interface was already forwarding: production
# omits the conditional gate, so an unrelated pre-existing private route must
# continue working while the portal-specific source/ingress rules remain.
nft delete table inet portal_test
nft -f - <<'EOF'
table inet portal_test {
  chain input {
    type filter hook input priority -10; policy accept;
    iifname "wgportal0" reject with icmpx type admin-prohibited
  }
  chain forward {
    type filter hook forward priority filter; policy drop;
    iifname "wgportal0" udp dport { 53, 443 } accept
    iifname "wgportal0" tcp dport { 53, 80, 443 } accept
    iifname "wgportal0" reject with icmpx type admin-prohibited
    oifname "wgportal0" ct state established,related accept
    oifname "wgportal0" reject with icmpx type admin-prohibited
    oifname "uplink0" accept
    ip daddr 10.0.0.0/8 accept
  }
}
EOF
for _ in $(seq 1 30); do
    if nsenter -t "$INTERNET_PID" -n curl --silent --max-time 1 http://10.210.0.2/ >/dev/null 2>&1; then
        break
    fi
    sleep 0.05
done
nsenter -t "$INTERNET_PID" -n curl --fail --silent --max-time 2 http://10.210.0.2/ >/dev/null

printf 'portal namespace kernel isolation test: OK\n'
