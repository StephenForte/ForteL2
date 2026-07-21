#!/usr/bin/env bash
# Phase 2c: cold-start L2 against Sepolia L1 (no Anvil, no redeploy).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_sepolia_env
assert_block_times
assert_l2_ports_free
warn_if_missing_env_file

if [[ ! -f "$DEPLOY_DIR/genesis.json" || ! -f "$DEPLOY_DIR/rollup.json" ]]; then
  echo "ERROR: missing Sepolia genesis/rollup under $DEPLOY_DIR" >&2
  echo "Run: FORTEL2_ENV=.env.sepolia ./scripts/02-deploy-contracts-sepolia.sh" >&2
  exit 1
fi

echo "=== ForteL2 Phase 2c — Sepolia-backed L2 ==="
echo "L1 RPC:  $L1_RPC_URL"
echo "DATA_DIR: $DATA_DIR"
echo "DEPLOY:  $DEPLOY_DIR"
echo "(Phase 1 Anvil/datadir not started or modified)"
echo

"$SCRIPT_DIR/04-start-sequencer-sepolia.sh"
sleep 3
"$SCRIPT_DIR/05-start-batcher-sepolia.sh"
"$SCRIPT_DIR/06-start-proposer-sepolia.sh"

echo
echo "=== Sepolia L2 stack is up ==="
echo "L2 RPC:  $L2_RPC_URL  (chain $L2_CHAIN_ID)"
echo "Status:  FORTEL2_ENV=.env.sepolia $SCRIPT_DIR/status.sh"
echo "Stop:    FORTEL2_ENV=.env.sepolia $SCRIPT_DIR/stop-all-sepolia.sh"
