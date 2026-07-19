#!/usr/bin/env bash
# US-011 step 2: Wait for dispute game + prove withdrawal on L1 OptimismPortal.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin node
require_bin jq
warn_if_missing_env_file
assert_local_rpc_urls
refuse_foundry_defaults_unless_local_l2 "${ADMIN_PRIVATE_KEY:-}" "ADMIN_PRIVATE_KEY"

ARTIFACT_DIR="${BRIDGE_ARTIFACT_DIR:-$DATA_DIR/bridge}"
ARTIFACT="${1:-$ARTIFACT_DIR/last-withdrawal.json}"
BRIDGE_DIR="$SCRIPT_DIR/bridge"

if [[ ! -f "$ARTIFACT" ]]; then
  echo "ERROR: missing $ARTIFACT — run ./scripts/withdraw-initiate.sh first" >&2
  exit 1
fi
if [[ ! -d "$BRIDGE_DIR/node_modules/viem" ]]; then
  echo "Installing bridge helper deps (viem) ..."
  (cd "$BRIDGE_DIR" && npm ci --omit=dev)
fi

wait_for_rpc "$L1_RPC_URL" "L1"
wait_for_rpc "$L2_RPC_URL" "L2"

export DEPLOYMENTS_JSON="${DEPLOYMENTS_JSON:-$FORTEL2_ROOT/deployments/deployments.json}"
export L1_RPC_URL L2_RPC_URL L1_CHAIN_ID L2_CHAIN_ID ADMIN_ADDRESS ADMIN_PRIVATE_KEY

node "$BRIDGE_DIR/prove.mjs" "$ARTIFACT"
echo "Next: ./scripts/withdraw-finalize.sh"
