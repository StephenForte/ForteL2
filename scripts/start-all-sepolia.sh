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

DEPLOYMENTS="$(deployments_json_path)"
# Require L1 proxy JSON too — batcher/proposer read it; without this check the
# sequencer can start and then 05-start-batcher-sepolia.sh exits, leaving
# op-geth + op-node orphaned.
if [[ ! -f "$DEPLOY_DIR/genesis.json" || ! -f "$DEPLOY_DIR/rollup.json" || ! -f "$DEPLOYMENTS" ]]; then
  echo "ERROR: missing Sepolia genesis/rollup under $DEPLOY_DIR or L1 proxies at $DEPLOYMENTS" >&2
  echo "Run: FORTEL2_ENV=.env.sepolia ./scripts/02-deploy-contracts-sepolia.sh" >&2
  exit 1
fi

# Preflight gas floors before touching the sequencer. A mid-start fail on
# require_min_balance_eth otherwise leaves op-geth holding :9545 and the next
# wake (launchd) dies on assert_l2_ports_free.
require_eth_address "BATCHER_ADDRESS" "${BATCHER_ADDRESS:-}"
require_eth_address "PROPOSER_ADDRESS" "${PROPOSER_ADDRESS:-}"
require_min_balance_eth "$BATCHER_ADDRESS" "${SEPOLIA_BATCHER_MIN_ETH:-0.15}" "BATCHER"
require_min_balance_eth "$PROPOSER_ADDRESS" "${SEPOLIA_PROPOSER_MIN_ETH:-0.15}" "PROPOSER"

echo "=== ForteL2 Phase 2c — Sepolia-backed L2 ==="
echo "L1 RPC:  $(redact_rpc_url "$L1_RPC_URL")"
echo "DATA_DIR: $DATA_DIR"
echo "DEPLOY:  $DEPLOY_DIR"
echo "(Phase 1 Anvil/datadir not started or modified)"
echo

# If batcher/proposer still fail after the sequencer is up, tear down so wake
# does not leave orphans on L2 ports.
sepolia_start_cleanup() {
  echo "ERROR: Sepolia start failed after sequencer — stopping partial stack" >&2
  "$SCRIPT_DIR/stop-all-sepolia.sh" || true
}
trap sepolia_start_cleanup ERR

"$SCRIPT_DIR/04-start-sequencer-sepolia.sh"
sleep 3
"$SCRIPT_DIR/05-start-batcher-sepolia.sh"
"$SCRIPT_DIR/06-start-proposer-sepolia.sh"
trap - ERR

echo
echo "=== Sepolia L2 stack is up ==="
echo "L2 RPC:  $(redact_rpc_url "$L2_RPC_URL")  (chain $L2_CHAIN_ID)"
echo "Status:  FORTEL2_ENV=.env.sepolia $SCRIPT_DIR/status.sh"
echo "Stop:    FORTEL2_ENV=.env.sepolia $SCRIPT_DIR/stop-all-sepolia.sh"
