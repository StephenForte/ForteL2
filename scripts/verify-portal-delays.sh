#!/usr/bin/env bash
# US-011: Print OptimismPortal delay immutables (expect short values after redeploy with overrides).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin cast
require_bin jq
assert_loopback_url "${L1_RPC_URL:-}" "L1_RPC_URL"
DEPLOYMENTS_JSON="${DEPLOYMENTS_JSON:-$FORTEL2_ROOT/deployments/deployments.json}"
PORTAL=$(jq -r '.OptimismPortalProxy // empty' "$DEPLOYMENTS_JSON")
require_eth_address "OptimismPortalProxy" "$PORTAL"

wait_for_rpc "$L1_RPC_URL" "L1"

PROOF=$(cast call "$PORTAL" "proofMaturityDelaySeconds()(uint64)" --rpc-url "$L1_RPC_URL")
FINAL=$(cast call "$PORTAL" "disputeGameFinalityDelaySeconds()(uint64)" --rpc-url "$L1_RPC_URL")
GAME=$(cast call "$PORTAL" "respectedGameType()(uint32)" --rpc-url "$L1_RPC_URL")

echo "OptimismPortal $PORTAL"
echo "  proofMaturityDelaySeconds       = $PROOF  (intent default ${PROOF_MATURITY_DELAY_SECONDS:-12})"
echo "  disputeGameFinalityDelaySeconds = $FINAL  (intent default ${DISPUTE_GAME_FINALITY_DELAY_SECONDS:-6})"
echo "  respectedGameType               = $GAME"

# Mainnet-scale = 604800 / 302400. Treat anything under 1 day as "shortened".
if (( PROOF < 86400 && FINAL < 86400 )); then
  echo "OK — delays look shortened for local prove/finalize."
  exit 0
fi
echo "WARN — delays still look mainnet-scale. op-deployer may have ignored globalDeployOverrides (optimism#14869)."
echo "      withdraw-finalize.sh will Anvil time-warp as a fallback; named knobs remain in intent/.env.example."
exit 0
