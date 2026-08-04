#!/bin/bash
# Run the fake captive portal in Docker and exercise the real detector state
# machine against it. The container binds only to loopback and is always removed.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="wireguard-reconnect-portal-simulator:local"
CONTAINER="wireguard-portal-sim-$$"
CONTAINER_ID=""

cleanup() {
    if [ -n "$CONTAINER_ID" ]; then
        docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
    else
        docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    fi
    docker image rm "$IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

command -v docker >/dev/null 2>&1 || {
    echo "Docker is required for the container portal simulation" >&2
    exit 2
}
docker info >/dev/null 2>&1 || {
    echo "The Docker daemon is not available to this user" >&2
    exit 2
}

docker build --quiet \
    -t "$IMAGE" \
    -f "$REPO_DIR/tests/container-portal/Dockerfile" \
    "$REPO_DIR/tests" >/dev/null

CONTAINER_ID="$(docker run --rm --detach \
    --name "$CONTAINER" \
    --publish 127.0.0.1::8080 \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,size=8m \
    --memory 64m \
    --pids-limit 64 \
    "$IMAGE")"

host_port="$(docker port "$CONTAINER_ID" 8080/tcp | awk -F: 'NF {print $NF; exit}')"
[[ "$host_port" =~ ^[0-9]+$ ]] || {
    echo "Could not determine the fake portal's loopback port" >&2
    exit 1
}
url="http://127.0.0.1:${host_port}/generate_204"

for _ in $(seq 1 50); do
    if curl --silent --max-time 1 --output /dev/null "$url"; then
        break
    fi
    sleep 0.1
done

printf 'Container captive portal simulator: %s\n' "$url"
"$REPO_DIR/wireguard-portal" simulate "$url"
"$REPO_DIR/tests/test-portal-netns.sh"
printf 'Container captive portal simulation: PASS\n'
