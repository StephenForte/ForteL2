#!/usr/bin/env bash
# US-002: Start local L1 (Anvil) as a native process.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin anvil
require_bin cast

L1_STATE="$DATA_DIR/l1/anvil-state.json"
mkdir -p "$DATA_DIR/l1"

# Persist Anvil state so L1 contracts survive stop/start (required for rollup genesis L1 hash).
ANVIL_ARGS=(
  --host 127.0.0.1
  --port "${L1_RPC_PORT}"
  --chain-id "${L1_CHAIN_ID}"
  --block-time "${L1_BLOCK_TIME}"
  --accounts 10
  --balance 10000
  --mnemonic "test test test test test test test test test test test junk"
  --state "$L1_STATE"
  --state-interval 5
)
if [[ -f "$L1_STATE" ]]; then
  echo "Loading persisted L1 state from $L1_STATE"
fi

start_bg anvil anvil "${ANVIL_ARGS[@]}"

wait_for_rpc "$L1_RPC_URL" "L1 Anvil"
echo "L1 chain-id=$(cast chain-id --rpc-url "$L1_RPC_URL")"
echo "Known-good log line: look for 'Listening on 127.0.0.1:${L1_RPC_PORT}' in $LOG_DIR/anvil.log"
