#!/usr/bin/env bash
# Cold start: L1 → deploy (if needed) → sequencer → batcher → proposer
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

assert_block_times
assert_local_rpc_urls
warn_if_missing_env_file

"$SCRIPT_DIR/01-start-l1.sh"

if [[ ! -f "$DEPLOY_DIR/genesis.json" || ! -f "$FORTEL2_ROOT/deployments/deployments.json" ]]; then
  "$SCRIPT_DIR/02-deploy-contracts.sh"
else
  echo "Deploy artifacts already present — skipping 02-deploy-contracts.sh (run reset.sh to redeploy)"
fi

"$SCRIPT_DIR/04-start-sequencer.sh"
sleep 3
"$SCRIPT_DIR/05-start-batcher.sh"
"$SCRIPT_DIR/06-start-proposer.sh"

echo
echo "=== ForteL2 Phase 1 stack is up ==="
echo "L1 RPC:  $L1_RPC_URL  (chain $L1_CHAIN_ID)"
echo "L2 RPC:  $L2_RPC_URL  (chain $L2_CHAIN_ID)"
echo "Logs:    $LOG_DIR"
echo "Status:  $SCRIPT_DIR/status.sh"
