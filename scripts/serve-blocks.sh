#!/usr/bin/env bash
# Serve the Phase 6 block viewer on loopback only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

"$SCRIPT_DIR/gen-blocks-config.sh"

PORT="${BLOCKS_HTTP_PORT:-8082}"
serve_static_loopback "$FORTEL2_ROOT/blocks" "$PORT" "block viewer HTTP" \
  "$FORTEL2_ROOT/blocks/.csp-header"
