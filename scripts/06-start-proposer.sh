#!/usr/bin/env bash
# US-006: Start op-proposer (posts output roots / dispute games to L1).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin op-proposer
require_bin jq

DEPLOYMENTS="$FORTEL2_ROOT/deployments/deployments.json"
GAME_FACTORY=$(jq -r '.DisputeGameFactoryProxy // .disputeGameFactoryProxy // empty' "$DEPLOYMENTS")
if [[ -z "$GAME_FACTORY" || "$GAME_FACTORY" == "null" ]]; then
  echo "ERROR: DisputeGameFactoryProxy not found in $DEPLOYMENTS" >&2
  jq 'keys' "$DEPLOYMENTS" || true
  exit 1
fi

wait_for_rpc "$L1_RPC_URL" "L1"
wait_for_rpc "$L2_RPC_URL" "L2"

start_bg op-proposer op-proposer \
  --l1-eth-rpc="$L1_RPC_URL" \
  --rollup-rpc="$L2_NODE_RPC_URL" \
  --private-key="${PROPOSER_PRIVATE_KEY}" \
  --game-factory-address="$GAME_FACTORY" \
  --game-type="${PROPOSER_GAME_TYPE}" \
  --proposal-interval="${PROPOSER_INTERVAL}" \
  --allow-non-finalized=true \
  --poll-interval=2s \
  --rpc.port=8560 \
  --log.level=info

echo "Proposer started against DisputeGameFactory=$GAME_FACTORY game-type=$PROPOSER_GAME_TYPE"
echo "Known-good log: 'created dispute game' or 'Proposing output root'"
