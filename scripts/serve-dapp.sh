#!/usr/bin/env bash
# Serve the static guestbook dApp on loopback only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

PORT="${DAPP_HTTP_PORT:-8080}"
serve_static_loopback "$FORTEL2_ROOT/dapp" "$PORT" "dApp HTTP"
