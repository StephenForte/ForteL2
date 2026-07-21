#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

echo "=== Process status ==="
procs=(op-geth op-node op-batcher op-proposer)
if [[ "${L2_CHAIN_ID:-}" != "852" ]]; then
  procs=(anvil "${procs[@]}")
fi
for name in "${procs[@]}"; do
  if is_running "$name"; then
    echo "  $name: RUNNING pid=$(cat "$PID_DIR/$name.pid")"
  else
    echo "  $name: stopped"
  fi
done

if [[ "${L2_CHAIN_ID:-}" == "852" ]]; then
  echo "  (Sepolia mode — no Anvil; DATA_DIR=$DATA_DIR)"
fi

echo
echo "=== RPC ==="
if cast block-number --rpc-url "$L1_RPC_URL" >/dev/null 2>&1; then
  echo "  L1 block=$(cast block-number --rpc-url "$L1_RPC_URL") chain=$(cast chain-id --rpc-url "$L1_RPC_URL")"
else
  echo "  L1: unreachable"
fi
if cast block-number --rpc-url "$L2_RPC_URL" >/dev/null 2>&1; then
  echo "  L2 block=$(cast block-number --rpc-url "$L2_RPC_URL") chain=$(cast chain-id --rpc-url "$L2_RPC_URL")"
else
  echo "  L2: unreachable"
fi
