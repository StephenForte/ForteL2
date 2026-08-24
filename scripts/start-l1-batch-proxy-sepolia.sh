#!/usr/bin/env bash
# Loopback JSON-RPC proxy that splits oversized L1 batches for op-challenger.
# Forwards to L1_RPC_URL (env only). Challenger opts in via CHALLENGER_L1_RPC_URL.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_sepolia_env
require_bin python3
require_bin cast

PROXY_PORT="${L1_BATCH_PROXY_PORT:-9549}"
require_http_port "$PROXY_PORT" "L1_BATCH_PROXY_PORT"
PROXY_URL="http://127.0.0.1:${PROXY_PORT}"
assert_loopback_url "$PROXY_URL" "L1 batch proxy listen"

if [[ -z "${L1_RPC_URL:-}" ]]; then
  echo "ERROR: L1_RPC_URL is required (upstream for l1-batch-proxy)" >&2
  exit 1
fi

if command -v lsof >/dev/null 2>&1; then
  if lsof -nP -iTCP:"${PROXY_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    if is_running l1-batch-proxy; then
      echo "l1-batch-proxy already running on :${PROXY_PORT}"
      exit 0
    fi
    echo "ERROR: port ${PROXY_PORT} already in use (not our l1-batch-proxy pidfile)" >&2
    exit 1
  fi
fi

PROXY_PY="$SCRIPT_DIR/l1-batch-proxy.py"
if [[ ! -f "$PROXY_PY" ]]; then
  echo "ERROR: missing $PROXY_PY" >&2
  exit 1
fi

wait_for_rpc "$L1_RPC_URL" "L1 Sepolia (batch-proxy upstream)"

export L1_BATCH_PROXY_LISTEN="127.0.0.1:${PROXY_PORT}"
# L1_RPC_URL is read by the proxy from the environment — never argv.

start_bg l1-batch-proxy python3 "$PROXY_PY"

wait_for_rpc "$PROXY_URL" "L1 batch proxy"
echo "L1 batch proxy up at $PROXY_URL → $(redact_rpc_url "$L1_RPC_URL")"
echo "Set CHALLENGER_L1_RPC_URL=$PROXY_URL in .env.sepolia for op-challenger to use this door."
