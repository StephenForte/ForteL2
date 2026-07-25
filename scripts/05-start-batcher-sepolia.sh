#!/usr/bin/env bash
# Phase 2c: op-batcher against Sepolia L1 (calldata DA).
# Default: stock op-batcher. Optional US-044 demo: USE_CUSTOM_BATCHER=1 + CONFIRM_CUSTOM_BATCHER_SEPOLIA=1.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin jq
require_sepolia_env
refuse_foundry_defaults_unless_local_l2 "${BATCHER_PRIVATE_KEY:-}" "BATCHER_PRIVATE_KEY"
require_min_balance_eth "$BATCHER_ADDRESS" "${SEPOLIA_BATCHER_MIN_ETH:-0.15}" "BATCHER"

DEPLOYMENTS="$(deployments_json_path)"
if [[ ! -f "$DEPLOYMENTS" ]]; then
  echo "ERROR: missing $DEPLOYMENTS — run Phase 2b Sepolia deploy first" >&2
  exit 1
fi

BATCH_INBOX=$(jq -r '.batch_inbox_address // .batch_inbox // empty' "$DEPLOY_DIR/rollup.json")
ROLLUP_JSON="${DEPLOY_DIR}/rollup.json"
BATCHER_DA_TYPE="${BATCHER_DA_TYPE:-calldata}"
BATCHER_CONFS="${SEPOLIA_BATCHER_NUM_CONFIRMATIONS:-2}"
# Credit-budget defaults (QuickNode): longer channels + slower polls cut fee-oracle spam.
# Fee tip/blob RPCs fire on craft + fee-bump (no dedicated estimate interval) — gated by
# rebroadcast/receipt. Override via .env.sepolia when demoing a faster cadence.
BATCHER_POLL="${SEPOLIA_BATCHER_POLL_INTERVAL:-12s}"
BATCHER_CHANNEL_DURATION="${SEPOLIA_BATCHER_MAX_CHANNEL_DURATION:-30}"
BATCHER_RECEIPT_QUERY="${SEPOLIA_BATCHER_TXMGR_RECEIPT_QUERY_INTERVAL:-36s}"
BATCHER_REBROADCAST="${SEPOLIA_BATCHER_TXMGR_REBROADCAST_INTERVAL:-36s}"

wait_for_rpc "$L1_RPC_URL" "L1 Sepolia"
wait_for_rpc "$L2_RPC_URL" "L2"

if [[ "${USE_CUSTOM_BATCHER:-0}" == "1" ]]; then
  if [[ "${CONFIRM_CUSTOM_BATCHER_SEPOLIA:-}" != "1" ]]; then
    echo "ERROR: Sepolia custom batcher is opt-in only." >&2
    echo "  Set CONFIRM_CUSTOM_BATCHER_SEPOLIA=1 after reading batcher/README.md (US-044)." >&2
    echo "  Default remains stock: FORTEL2_ENV=.env.sepolia ./scripts/05-start-batcher-sepolia.sh" >&2
    exit 1
  fi
  if [[ ! -f "$ROLLUP_JSON" ]]; then
    echo "ERROR: missing $ROLLUP_JSON" >&2
    exit 1
  fi
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
  # Honor credit-budget poll default (do not spam QuickNode).
  CUSTOM_POLL="${CUSTOM_BATCHER_POLL_INTERVAL:-$BATCHER_POLL}"
  # Match stock SEPOLIA_BATCHER_NUM_CONFIRMATIONS before advancing lastSubmitted.
  CUSTOM_CONFS="${CUSTOM_BATCHER_CONFIRMATIONS:-$BATCHER_CONFS}"
  # Sepolia inclusion can exceed local Anvil waits; keep waiting the same tx (no resubmit).
  CUSTOM_RECEIPT_TIMEOUT="${CUSTOM_BATCHER_RECEIPT_TIMEOUT:-10m}"
  echo "WARN: US-044 Sepolia custom-batcher demo — max ~15 min; abort → stock script." >&2
  start_bg op-batcher "$CUSTOM_BATCHER_BIN" \
    -l1 "$L1_RPC_URL" \
    -l2 "$L2_RPC_URL" \
    -rollup "$L2_NODE_RPC_URL" \
    -rollup-json "$ROLLUP_JSON" \
    -poll "$CUSTOM_POLL" \
    -max-blocks "${CUSTOM_BATCHER_MAX_BLOCKS:-6}" \
    -confirmations "$CUSTOM_CONFS" \
    -receipt-timeout "$CUSTOM_RECEIPT_TIMEOUT" \
    -wait-safe=0
  echo "Custom Sepolia batcher started (poll=${CUSTOM_POLL}, confirmations=${CUSTOM_CONFS}, receipt-timeout=${CUSTOM_RECEIPT_TIMEOUT}). Revert: stop pid, then stock 05-start-batcher-sepolia.sh"
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
    --poll-interval="${BATCHER_POLL}" \
    --sub-safety-margin=2 \
    --num-confirmations="${BATCHER_CONFS}" \
    --safe-abort-nonce-too-low-count=3 \
    --resubmission-timeout=60s \
    --max-channel-duration="${BATCHER_CHANNEL_DURATION}" \
    --txmgr.receipt-query-interval="${BATCHER_RECEIPT_QUERY}" \
    --txmgr.rebroadcast-interval="${BATCHER_REBROADCAST}" \
    --log.level=info
  echo "Sepolia batcher started (DA=${BATCHER_DA_TYPE}, confs=${BATCHER_CONFS}, poll=${BATCHER_POLL}, max-channel-duration=${BATCHER_CHANNEL_DURATION})."
fi

echo "Inspect: cast nonce ${BATCHER_ADDRESS} --rpc-url $L1_RPC_URL"
if [[ -n "${BATCH_INBOX:-}" ]]; then
  echo "Batch inbox: $BATCH_INBOX"
fi
