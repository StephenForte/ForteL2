#!/usr/bin/env bash
# US-006 / US-053: Start proposer (posts output roots / dispute games to L1).
# Default: stock op-proposer. Opt-in learning rebuild: USE_CUSTOM_PROPOSER=1.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin jq
assert_local_rpc_urls
refuse_foundry_defaults_unless_local_l2 "${PROPOSER_PRIVATE_KEY:-}" "PROPOSER_PRIVATE_KEY"

DEPLOYMENTS="$FORTEL2_ROOT/deployments/deployments.json"
GAME_FACTORY=$(jq -r '.DisputeGameFactoryProxy // .disputeGameFactoryProxy // empty' "$DEPLOYMENTS")
if [[ -z "$GAME_FACTORY" || "$GAME_FACTORY" == "null" ]]; then
  echo "ERROR: DisputeGameFactoryProxy not found in $DEPLOYMENTS" >&2
  jq 'keys' "$DEPLOYMENTS" || true
  exit 1
fi

wait_for_rpc "$L1_RPC_URL" "L1"
wait_for_rpc "$L2_RPC_URL" "L2"

if [[ "${USE_CUSTOM_PROPOSER:-0}" == "1" ]]; then
  # Build before stopping stock so a failed go build leaves the running proposer intact
  # (especially important on Sepolia — see AGENTS.md: prefer reversible ops).
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
  # Keep pid name op-proposer so stop-all.sh / status still work (no lib.sh changes).
  CUSTOM_POLL="${CUSTOM_PROPOSER_POLL_INTERVAL:-2s}"
  CUSTOM_INTERVAL="${CUSTOM_PROPOSER_INTERVAL:-${PROPOSER_INTERVAL:-12s}}"
  start_bg op-proposer "$CUSTOM_PROPOSER_BIN" \
    -l1 "$L1_RPC_URL" \
    -rollup "$L2_NODE_RPC_URL" \
    -factory "$GAME_FACTORY" \
    -game-type "${PROPOSER_GAME_TYPE}" \
    -poll "$CUSTOM_POLL" \
    -proposal-interval "$CUSTOM_INTERVAL" \
    -allow-non-finalized=true \
    -confirmations "${CUSTOM_PROPOSER_CONFIRMATIONS:-1}"
  echo "Custom proposer started (USE_CUSTOM_PROPOSER=1, poll=${CUSTOM_POLL}, interval=${CUSTOM_INTERVAL})."
  echo "Kill switch: stop this process, then USE_CUSTOM_PROPOSER=0 ./scripts/06-start-proposer.sh"
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
    --poll-interval=2s \
    --rpc.addr=127.0.0.1 \
    --rpc.port="${PROPOSER_RPC_PORT}" \
    --log.level=info

  echo "Proposer started against DisputeGameFactory=$GAME_FACTORY game-type=$PROPOSER_GAME_TYPE"
  echo "Known-good log: 'created dispute game' or 'Proposing output root'"
fi

echo "Proposer target DisputeGameFactory=$GAME_FACTORY game-type=$PROPOSER_GAME_TYPE"
