#!/usr/bin/env bash
# Phase 2c: op-batcher against Sepolia L1 (calldata DA).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin op-batcher
require_bin jq
require_sepolia_env
refuse_foundry_defaults_unless_local_l2 "${BATCHER_PRIVATE_KEY:-}" "BATCHER_PRIVATE_KEY"
require_min_balance_eth "$BATCHER_ADDRESS" "${SEPOLIA_BATCHER_MIN_ETH:-0.05}" "BATCHER"

DEPLOYMENTS="$(deployments_json_path)"
if [[ ! -f "$DEPLOYMENTS" ]]; then
  echo "ERROR: missing $DEPLOYMENTS — run Phase 2b Sepolia deploy first" >&2
  exit 1
fi

BATCH_INBOX=$(jq -r '.batch_inbox_address // .batch_inbox // empty' "$DEPLOY_DIR/rollup.json")
BATCHER_DA_TYPE="${BATCHER_DA_TYPE:-calldata}"
BATCHER_CONFS="${SEPOLIA_BATCHER_NUM_CONFIRMATIONS:-2}"

wait_for_rpc "$L1_RPC_URL" "L1 Sepolia"
wait_for_rpc "$L2_RPC_URL" "L2"

start_bg op-batcher op-batcher \
  --l1-eth-rpc="$L1_RPC_URL" \
  --l2-eth-rpc="$L2_RPC_URL" \
  --rollup-rpc="$L2_NODE_RPC_URL" \
  --private-key="${BATCHER_PRIVATE_KEY}" \
  --data-availability-type="${BATCHER_DA_TYPE}" \
  --rpc.addr=127.0.0.1 \
  --rpc.port=8548 \
  --poll-interval=2s \
  --sub-safety-margin=2 \
  --num-confirmations="${BATCHER_CONFS}" \
  --safe-abort-nonce-too-low-count=3 \
  --resubmission-timeout=60s \
  --max-channel-duration=2 \
  --log.level=info

echo "Sepolia batcher started (DA=${BATCHER_DA_TYPE}, confs=${BATCHER_CONFS})."
echo "Inspect: cast nonce ${BATCHER_ADDRESS} --rpc-url $L1_RPC_URL"
if [[ -n "${BATCH_INBOX:-}" ]]; then
  echo "Batch inbox: $BATCH_INBOX"
fi
