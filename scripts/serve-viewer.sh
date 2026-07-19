#!/usr/bin/env bash
# Serve the Phase 1c pipeline viewer on loopback only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

# Refresh addresses/RPCs from the live deploy tree when available.
"$SCRIPT_DIR/gen-viewer-config.sh"

PORT="${VIEWER_HTTP_PORT:-8081}"
serve_static_loopback "$FORTEL2_ROOT/viewer" "$PORT" "pipeline viewer HTTP"
