#!/usr/bin/env bash
# US-005: Start op-batcher (calldata DA — Anvil has no blobs/beacon).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin op-batcher
require_bin jq
assert_local_rpc_urls
refuse_foundry_defaults_unless_local_l2 "${BATCHER_PRIVATE_KEY:-}" "BATCHER_PRIVATE_KEY"

DEPLOYMENTS="$FORTEL2_ROOT/deployments/deployments.json"
if [[ ! -f "$DEPLOYMENTS" ]]; then
  echo "ERROR: missing $DEPLOYMENTS — run scripts/02-deploy-contracts.sh first" >&2
  exit 1
fi

# BatchInbox from rollup.json
BATCH_INBOX=$(jq -r '.batch_inbox_address // .batch_inbox // empty' "$DEPLOY_DIR/rollup.json")

wait_for_rpc "$L1_RPC_URL" "L1"
wait_for_rpc "$L2_RPC_URL" "L2"

start_bg op-batcher op-batcher \
  --l1-eth-rpc="$L1_RPC_URL" \
  --l2-eth-rpc="$L2_RPC_URL" \
  --rollup-rpc="$L2_NODE_RPC_URL" \
  --private-key="${BATCHER_PRIVATE_KEY}" \
  --data-availability-type="${BATCHER_DA_TYPE}" \
  --rpc.addr=127.0.0.1 \
  --rpc.port=8548 \
  --poll-interval=1s \
  --sub-safety-margin=1 \
  --num-confirmations=1 \
  --safe-abort-nonce-too-low-count=3 \
  --resubmission-timeout=30s \
  --max-channel-duration=1 \
  --log.level=info

echo "Batcher started. Known-good log: 'publishing transaction' or 'SubmitBatchTx'"
echo "Inspect batches later: cast nonce ${BATCHER_ADDRESS} --rpc-url $L1_RPC_URL"
if [[ -n "${BATCH_INBOX:-}" ]]; then
  echo "Batch inbox (from rollup.json): $BATCH_INBOX"
fi
