#!/usr/bin/env bash
# T5-D1: loopback JSON-RPC method filter for the Sepolia write-facing RPC.
# Serves eth/net/web3 allowlist only on L2_WRITE_RPC_PORT; forwards to full
# op-geth on L2_RPC_URL (:9545). Does not change op-geth --http.api.
# cloudflared (spike step 3) dials this listener — never start a tunnel here.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_sepolia_env
require_bin python3
require_bin cast

WRITE_PORT="${L2_WRITE_RPC_PORT:-9555}"
require_http_port "$WRITE_PORT" "L2_WRITE_RPC_PORT"
WRITE_URL="http://127.0.0.1:${WRITE_PORT}"
assert_loopback_url "$WRITE_URL" "L2 write RPC filter"
assert_loopback_url "$L2_RPC_URL" "L2_RPC_URL (filter upstream)"

if command -v lsof >/dev/null 2>&1; then
  if lsof -nP -iTCP:"${WRITE_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    if is_running l2-rpc-filter; then
      echo "l2-rpc-filter already running on :${WRITE_PORT}"
      exit 0
    fi
    echo "ERROR: port ${WRITE_PORT} already in use (not our l2-rpc-filter pidfile)" >&2
    exit 1
  fi
fi

FILTER_PY="$SCRIPT_DIR/rpc-method-filter.py"
if [[ ! -f "$FILTER_PY" ]]; then
  echo "ERROR: missing $FILTER_PY" >&2
  exit 1
fi

wait_for_rpc "$L2_RPC_URL" "L2 op-geth (filter upstream)"

export L2_RPC_FILTER_LISTEN="127.0.0.1:${WRITE_PORT}"
export L2_RPC_FILTER_UPSTREAM="$L2_RPC_URL"

start_bg l2-rpc-filter python3 "$FILTER_PY"

# Filter speaks JSON-RPC; cast block-number is enough to confirm the door is open.
wait_for_rpc "$WRITE_URL" "L2 write RPC filter"
echo "Write-facing RPC filter up at $WRITE_URL → $(redact_rpc_url "$L2_RPC_URL")"
echo "Allowlist: eth/net/web3 methods only (see scripts/rpc-method-filter.py)."
echo "Full operator surface remains at $(redact_rpc_url "$L2_RPC_URL") (unchanged)."
