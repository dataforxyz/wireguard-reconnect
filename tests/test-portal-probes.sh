#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORTAL="$REPO_DIR/wireguard-portal"

# Two concrete non-204 HTTP responses are evidence of interception.
"$PORTAL" classify-probes 302 302
"$PORTAL" classify-probes 200 511

# Partial endpoint failure, endpoint-specific blocking, and unrestricted access
# are not enough evidence to open a browser automatically.
if "$PORTAL" classify-probes 302 000; then exit 1; fi
if "$PORTAL" classify-probes 000 000; then exit 1; fi
if "$PORTAL" classify-probes 204 302; then exit 1; fi
if "$PORTAL" classify-probes 204 204; then exit 1; fi
if "$PORTAL" classify-probes 500 500; then exit 1; fi
if "$PORTAL" classify-probes invalid 302; then exit 1; fi

grep -Fq 'portal detection was inconclusive; refusing to open a browser' "$PORTAL"
printf 'captive portal probe classification tests: OK\n'
