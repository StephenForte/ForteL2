#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

cd "$FORTEL2_ROOT/dapp"
echo "Serving dapp at http://127.0.0.1:${DAPP_HTTP_PORT}/"
exec python3 -m http.server "${DAPP_HTTP_PORT}" --bind 127.0.0.1
