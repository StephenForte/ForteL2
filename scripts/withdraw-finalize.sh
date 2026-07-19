#!/usr/bin/env bash
# US-011 step 3: Resolve game if needed, time-warp delays, finalize on L1.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin node
require_bin cast
require_bin jq
warn_if_missing_env_file
assert_local_rpc_urls
refuse_foundry_defaults_unless_local_l2 "${ADMIN_PRIVATE_KEY:-}" "ADMIN_PRIVATE_KEY"

ARTIFACT_DIR="${BRIDGE_ARTIFACT_DIR:-$DATA_DIR/bridge}"
ARTIFACT="${1:-$ARTIFACT_DIR/last-withdrawal.json}"
BRIDGE_DIR="$SCRIPT_DIR/bridge"
DEPLOYMENTS_JSON="${DEPLOYMENTS_JSON:-$FORTEL2_ROOT/deployments/deployments.json}"

if [[ ! -f "$ARTIFACT" ]]; then
  echo "ERROR: missing $ARTIFACT — run prove first" >&2
  exit 1
fi
if [[ ! -d "$BRIDGE_DIR/node_modules/viem" ]]; then
  echo "Installing bridge helper deps (viem) ..."
  (cd "$BRIDGE_DIR" && npm ci --omit=dev)
fi

wait_for_rpc "$L1_RPC_URL" "L1"

PORTAL=$(jq -r '.OptimismPortalProxy' "$DEPLOYMENTS_JSON")
require_eth_address "OptimismPortalProxy" "$PORTAL"
echo "Live portal delays:"
echo -n "  proofMaturityDelaySeconds= "
cast call "$PORTAL" "proofMaturityDelaySeconds()(uint64)" --rpc-url "$L1_RPC_URL"
echo -n "  disputeGameFinalityDelaySeconds= "
cast call "$PORTAL" "disputeGameFinalityDelaySeconds()(uint64)" --rpc-url "$L1_RPC_URL"

export DEPLOYMENTS_JSON
export L1_RPC_URL L2_RPC_URL L1_CHAIN_ID L2_CHAIN_ID ADMIN_ADDRESS ADMIN_PRIVATE_KEY
export PROOF_MATURITY_DELAY_SECONDS DISPUTE_GAME_FINALITY_DELAY_SECONDS
export FAULT_GAME_MAX_CLOCK_DURATION

node "$BRIDGE_DIR/finalize.mjs" "$ARTIFACT"

echo "Recorded hashes in $ARTIFACT:"
jq '{l2TxHash, proveTxHash, finalizeTxHash, gameIndex, gameProxy}' "$ARTIFACT"
