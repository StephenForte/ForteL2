#!/usr/bin/env bash
# Phase 2c: op-proposer against Sepolia DisputeGameFactory.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin op-proposer
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

# Credit-budget defaults: proposals every few minutes, slower L1 poll.
PROPOSER_POLL="${SEPOLIA_PROPOSER_POLL_INTERVAL:-12s}"
# PROPOSER_INTERVAL comes from .env.sepolia (example default 5m).
: "${PROPOSER_INTERVAL:=5m}"

wait_for_rpc "$L1_RPC_URL" "L1 Sepolia"
wait_for_rpc "$L2_RPC_URL" "L2"

start_bg op-proposer op-proposer \
  --l1-eth-rpc="$L1_RPC_URL" \
  --rollup-rpc="$L2_NODE_RPC_URL" \
  --private-key="${PROPOSER_PRIVATE_KEY}" \
  --game-factory-address="$GAME_FACTORY" \
  --game-type="${PROPOSER_GAME_TYPE}" \
  --proposal-interval="${PROPOSER_INTERVAL}" \
  --allow-non-finalized=true \
  --poll-interval="${PROPOSER_POLL}" \
  --rpc.addr=127.0.0.1 \
  --rpc.port="${PROPOSER_RPC_PORT}" \
  --log.level=info

echo "Sepolia proposer started against DisputeGameFactory=$GAME_FACTORY game-type=$PROPOSER_GAME_TYPE interval=${PROPOSER_INTERVAL} poll=${PROPOSER_POLL}"
echo "Known-good: 'created dispute game' or 'Proposing'"
