#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(head -n 1 "$REPO_DIR/VERSION")"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
  echo "VERSION is not valid semantic versioning: $VERSION" >&2
  exit 1
fi

expected="wireguard-reconnect $VERSION"
actual="$(WIREGUARD_RECONNECT_VERSION_FILE="$REPO_DIR/VERSION" "$REPO_DIR/wireguard-reconnect" --version)"
if [ "$actual" != "$expected" ]; then
  printf 'unexpected --version output\nexpected: %s\nactual:   %s\n' "$expected" "$actual" >&2
  exit 1
fi

grep -Fq "## [$VERSION]" "$REPO_DIR/CHANGELOG.md"
grep -Fq "Current release: **v$VERSION**" "$REPO_DIR/README.md"

printf 'version consistency tests: OK (%s)\n' "$VERSION"
