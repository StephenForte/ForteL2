#!/usr/bin/env bash
# US-005 / US-043: Start batcher (calldata DA — Anvil has no blobs/beacon).
# Default: stock op-batcher. Opt-in learning rebuild: USE_CUSTOM_BATCHER=1.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

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
ROLLUP_JSON="${DEPLOY_DIR}/rollup.json"
if [[ ! -f "$ROLLUP_JSON" ]]; then
  echo "ERROR: missing $ROLLUP_JSON — run scripts/02-deploy-contracts.sh first" >&2
  exit 1
fi

wait_for_rpc "$L1_RPC_URL" "L1"
wait_for_rpc "$L2_RPC_URL" "L2"

if [[ "${USE_CUSTOM_BATCHER:-0}" == "1" ]]; then
  # start_bg returns 0 when the shared op-batcher pid is already alive — stop stock
  # (or a prior custom) first so we actually launch fortel2-batcher, not a false "started".
  if is_running op-batcher; then
    echo "Stopping existing op-batcher (pid $(cat "$PID_DIR/op-batcher.pid")) before custom start…"
    stop_bg op-batcher
  fi
  require_bin go
  CUSTOM_BATCHER_BIN="${CUSTOM_BATCHER_BIN:-$BIN_DIR/fortel2-batcher}"
  mkdir -p "$(dirname "$CUSTOM_BATCHER_BIN")"
  echo "Building custom batcher → $CUSTOM_BATCHER_BIN"
  (cd "$FORTEL2_ROOT/batcher" && go build -o "$CUSTOM_BATCHER_BIN" ./cmd/submit-loop)
  # Keep pid name op-batcher so stop-all.sh / status still work (no lib.sh changes).
  CUSTOM_POLL="${CUSTOM_BATCHER_POLL_INTERVAL:-2s}"
  start_bg op-batcher "$CUSTOM_BATCHER_BIN" \
    -l1 "$L1_RPC_URL" \
    -l2 "$L2_RPC_URL" \
    -rollup "$L2_NODE_RPC_URL" \
    -rollup-json "$ROLLUP_JSON" \
    -poll "$CUSTOM_POLL" \
    -max-blocks "${CUSTOM_BATCHER_MAX_BLOCKS:-6}" \
    -confirmations "${CUSTOM_BATCHER_CONFIRMATIONS:-1}" \
    -wait-safe=0
  echo "Custom batcher started (USE_CUSTOM_BATCHER=1, poll=${CUSTOM_POLL})."
  echo "Kill switch: stop this process, then USE_CUSTOM_BATCHER=0 ./scripts/05-start-batcher.sh"
else
  require_bin op-batcher
  start_bg op-batcher op-batcher \
    --l1-eth-rpc="$L1_RPC_URL" \
    --l2-eth-rpc="$L2_RPC_URL" \
    --rollup-rpc="$L2_NODE_RPC_URL" \
    --private-key="${BATCHER_PRIVATE_KEY}" \
    --data-availability-type="${BATCHER_DA_TYPE}" \
    --rpc.addr=127.0.0.1 \
    --rpc.port="${BATCHER_RPC_PORT}" \
    --poll-interval=1s \
    --sub-safety-margin=1 \
    --num-confirmations=1 \
    --safe-abort-nonce-too-low-count=3 \
    --resubmission-timeout=30s \
    --max-channel-duration=1 \
    --log.level=info
  echo "Batcher started. Known-good log: 'publishing transaction' or 'SubmitBatchTx'"
fi

echo "Inspect batches later: cast nonce ${BATCHER_ADDRESS} --rpc-url $L1_RPC_URL"
if [[ -n "${BATCH_INBOX:-}" ]]; then
  echo "Batch inbox (from rollup.json): $BATCH_INBOX"
fi
