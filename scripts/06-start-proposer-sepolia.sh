#!/usr/bin/env bash
# Phase 2c: op-proposer against Sepolia DisputeGameFactory.
# Default: stock op-proposer. Optional US-054 demo: USE_CUSTOM_PROPOSER=1 + CONFIRM_CUSTOM_PROPOSER_SEPOLIA=1.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin jq
require_sepolia_env
refuse_foundry_defaults_unless_local_l2 "${PROPOSER_PRIVATE_KEY:-}" "PROPOSER_PRIVATE_KEY"
require_min_balance_eth "$PROPOSER_ADDRESS" "${SEPOLIA_PROPOSER_MIN_ETH:-0.15}" "PROPOSER"

DEPLOYMENTS="$(deployments_json_path)"
GAME_FACTORY=$(jq -r '.DisputeGameFactoryProxy // .disputeGameFactoryProxy // empty' "$DEPLOYMENTS")
if [[ -z "$GAME_FACTORY" || "$GAME_FACTORY" == "null" ]]; then
  echo "ERROR: DisputeGameFactoryProxy not found in $DEPLOYMENTS" >&2
  jq 'keys' "$DEPLOYMENTS" || true
  exit 1
fi

# Credit-budget defaults. Use SEPOLIA_PROPOSER_INTERVAL (default 1h; D-0074) — do not inherit
# legacy PROPOSER_INTERVAL=12s from older .env.sepolia templates (Phase 1 Anvil knob).
# Pin txmgr receipt/rebroadcast (upstream defaults are 12s) so in-flight fee bumps
# do not outpace the batcher's credit-budget cadence.
PROPOSER_INTERVAL="${SEPOLIA_PROPOSER_INTERVAL:-1h}"
PROPOSER_POLL="${SEPOLIA_PROPOSER_POLL_INTERVAL:-12s}"
PROPOSER_RECEIPT_QUERY="${SEPOLIA_PROPOSER_TXMGR_RECEIPT_QUERY_INTERVAL:-36s}"
PROPOSER_REBROADCAST="${SEPOLIA_PROPOSER_TXMGR_REBROADCAST_INTERVAL:-36s}"
PROPOSER_RESUBMISSION="${SEPOLIA_PROPOSER_RESUBMISSION_TIMEOUT:-72s}"

wait_for_rpc "$L1_RPC_URL" "L1 Sepolia"
wait_for_rpc "$L2_RPC_URL" "L2"

if [[ "${USE_CUSTOM_PROPOSER:-0}" == "1" ]]; then
  if [[ "${CONFIRM_CUSTOM_PROPOSER_SEPOLIA:-}" != "1" ]]; then
    echo "ERROR: Sepolia custom proposer is opt-in only." >&2
    echo "  Set CONFIRM_CUSTOM_PROPOSER_SEPOLIA=1 after reading proposer/README.md (US-054)." >&2
    echo "  Default remains stock: FORTEL2_ENV=.env.sepolia ./scripts/06-start-proposer-sepolia.sh" >&2
    exit 1
  fi
  # Build before stopping stock so a failed go build leaves Sepolia proposals running.
  require_bin go
  CUSTOM_PROPOSER_BIN="${CUSTOM_PROPOSER_BIN:-$BIN_DIR/fortel2-proposer}"
  mkdir -p "$(dirname "$CUSTOM_PROPOSER_BIN")"
  build_tmp="${CUSTOM_PROPOSER_BIN}.building.$$"
  cleanup_build_tmp() { rm -f "$build_tmp"; }
  trap cleanup_build_tmp EXIT
  echo "Building custom proposer → $build_tmp"
  (cd "$FORTEL2_ROOT/proposer" && go build -o "$build_tmp" ./cmd/propose-loop)
  mv -f "$build_tmp" "$CUSTOM_PROPOSER_BIN"
  trap - EXIT

  # start_bg returns 0 when the shared op-proposer pid is already alive — stop stock
  # (or a prior custom) first so we actually launch fortel2-proposer, not a false "started".
  if is_running op-proposer; then
    echo "Stopping existing op-proposer (pid $(cat "$PID_DIR/op-proposer.pid")) before custom start…"
    stop_bg op-proposer
  fi
  CUSTOM_POLL="${CUSTOM_PROPOSER_POLL_INTERVAL:-$PROPOSER_POLL}"
  CUSTOM_INTERVAL="${CUSTOM_PROPOSER_INTERVAL:-$PROPOSER_INTERVAL}"
  CUSTOM_CONFS="${CUSTOM_PROPOSER_CONFIRMATIONS:-2}"
  CUSTOM_RECEIPT_TIMEOUT="${CUSTOM_PROPOSER_RECEIPT_TIMEOUT:-10m}"
  echo "WARN: US-054 Sepolia custom-proposer demo — max ~15 min; abort → stock script." >&2
  start_bg op-proposer "$CUSTOM_PROPOSER_BIN" \
    -l1 "$L1_RPC_URL" \
    -rollup "$L2_NODE_RPC_URL" \
    -factory "$GAME_FACTORY" \
    -game-type "${PROPOSER_GAME_TYPE}" \
    -poll "$CUSTOM_POLL" \
    -proposal-interval "$CUSTOM_INTERVAL" \
    -allow-non-finalized=true \
    -confirmations "$CUSTOM_CONFS" \
    -receipt-timeout "$CUSTOM_RECEIPT_TIMEOUT"
  echo "Custom Sepolia proposer started (poll=${CUSTOM_POLL}, interval=${CUSTOM_INTERVAL}, confirmations=${CUSTOM_CONFS}). Revert: stop pid, then stock 06-start-proposer-sepolia.sh"
else
  require_bin op-proposer
  start_bg op-proposer op-proposer \
    --l1-eth-rpc="$L1_RPC_URL" \
    --rollup-rpc="$L2_NODE_RPC_URL" \
    --private-key="${PROPOSER_PRIVATE_KEY}" \
    --game-factory-address="$GAME_FACTORY" \
    --game-type="${PROPOSER_GAME_TYPE}" \
    --proposal-interval="${PROPOSER_INTERVAL}" \
    --allow-non-finalized=true \
    --poll-interval="${PROPOSER_POLL}" \
    --resubmission-timeout="${PROPOSER_RESUBMISSION}" \
    --txmgr.receipt-query-interval="${PROPOSER_RECEIPT_QUERY}" \
    --txmgr.rebroadcast-interval="${PROPOSER_REBROADCAST}" \
    --rpc.addr=127.0.0.1 \
    --rpc.port="${PROPOSER_RPC_PORT}" \
    --log.level=info

  echo "Sepolia proposer started against DisputeGameFactory=$GAME_FACTORY game-type=$PROPOSER_GAME_TYPE interval=${PROPOSER_INTERVAL} poll=${PROPOSER_POLL} txmgr receipt/rebroadcast=${PROPOSER_RECEIPT_QUERY}/${PROPOSER_REBROADCAST}"
  echo "Known-good: 'created dispute game' or 'Proposing'"
fi
