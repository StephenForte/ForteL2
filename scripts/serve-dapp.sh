#!/usr/bin/env bash
# Serve the static guestbook dApp on loopback only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

PORT="${DAPP_HTTP_PORT:-8080}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "ERROR: invalid DAPP_HTTP_PORT: $PORT" >&2
  exit 1
fi
# Explicit loopback URL check (matches bind below).
assert_loopback_url "http://127.0.0.1:${PORT}" "dApp HTTP"

cd "$FORTEL2_ROOT/dapp"
echo "Serving dapp at http://127.0.0.1:${PORT}/ (loopback only)"
exec python3 -m http.server "${PORT}" --bind 127.0.0.1
