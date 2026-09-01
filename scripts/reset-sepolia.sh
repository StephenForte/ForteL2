#!/usr/bin/env bash
# Phase 2c: wipe Sepolia L2 runtime datadir only (JWT + op-geth under data-sepolia).
# Never touches Phase 1 data/ or deployments/deployments.json.
# Does NOT delete deployments/sepolia/.deployer (L1 contracts stay); set WIPE_SEPOLIA_DEPLOY=1 to also clear local genesis workdir.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_sepolia_env

require_fortel2_el
if [[ "$(fortel2_el)" == "reth" ]]; then
  echo "FORTEL2_EL=reth — stopping the full Sepolia stack, then wiping reth datadir only (op-geth untouched)"
  # After Task 5 the live rollup client is op-node (not op-reth-node). stop_reth_sidecar
  # alone would wipe the live EL while filter/batcher/proposer/op-node still hold ports.
  "$SCRIPT_DIR/stop-all-sepolia.sh" || true
  wipe_reth_datadir
  echo "Reth datadir reset complete. Mid-chain rewind is this wipe + re-derive; never debug_setHead."
  echo "op-geth at $DATA_DIR/l2/op-geth was not touched. Live JWT at $DATA_DIR/jwt untouched."
  exit 0
fi

"$SCRIPT_DIR/stop-all-sepolia.sh" || true

echo "Wiping Sepolia geth runtime under $DATA_DIR (op-reth candidate / rollback asset kept) ..."
# Never wipe $DATA_DIR/l2 wholesale — that would delete the Task 3–5 op-reth
# datadir and sidecar SafeDB. Geth reset is op-geth + jwt/pids/logs only.
rm -rf "$DATA_DIR/l2/op-geth" "$DATA_DIR/jwt" "$DATA_DIR/pids" "$DATA_DIR/logs"
mkdir -p "$DATA_DIR" "$DATA_DIR/l2"

if [[ "${WIPE_SEPOLIA_DEPLOY:-}" == "1" ]]; then
  echo "WIPE_SEPOLIA_DEPLOY=1 — removing $DEPLOY_DIR (L1 contracts on Sepolia remain; need re-inspect/redeploy for local genesis)"
  rm -rf "$DEPLOY_DIR"
fi

echo "Sepolia runtime reset complete. Phase 1 tree untouched."
