#!/usr/bin/env bash
# US-004: Start sequencer = op-geth (execution) + op-node (consensus/derivation) in sequencer mode.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin op-geth
require_bin op-node
require_bin cast
assert_block_times
assert_local_rpc_urls
refuse_foundry_defaults_unless_local_l2 "${SEQUENCER_PRIVATE_KEY:-}" "SEQUENCER_PRIVATE_KEY"

"$SCRIPT_DIR/03-init-l2.sh"

DATADIR="$DATA_DIR/l2/op-geth"
JWT="$DATA_DIR/jwt/jwt.txt"
ROLLUP="$DEPLOY_DIR/rollup.json"

wait_for_rpc "$L1_RPC_URL" "L1 Anvil"

start_bg op-geth op-geth \
  --datadir="$DATADIR" \
  --http \
  --http.addr=127.0.0.1 \
  --http.port="${L2_EL_HTTP_PORT}" \
  --http.vhosts="*" \
  --http.corsdomain="*" \
  --http.api=eth,net,web3,debug,txpool,admin,miner \
  --ws \
  --ws.addr=127.0.0.1 \
  --ws.port="${L2_EL_WS_PORT}" \
  --ws.origins="*" \
  --ws.api=eth,net,web3,debug,txpool,admin,miner \
  --authrpc.addr=127.0.0.1 \
  --authrpc.port="${L2_EL_AUTH_PORT}" \
  --authrpc.vhosts="*" \
  --authrpc.jwtsecret="$JWT" \
  --syncmode=full \
  --gcmode=archive \
  --rollup.disabletxpoolgossip=true \
  --miner.gasprice=1 \
  --txpool.pricelimit=1 \
  --nodiscover \
  --maxpeers=0

# Give engine API a moment before op-node attaches
sleep 2

# --l2.enginekind=geth : Phase 0 verified op-geth on arm64
# --l1.beacon.ignore + slot-duration-override : Anvil has no beacon API
# --rollup.l1-chain-config : required for custom L1 chain ID 900 (not in superchain registry)
start_bg op-node op-node \
  --l1="$L1_RPC_URL" \
  --l1.rpckind=standard \
  --l1.trustrpc=true \
  --l1.beacon.ignore=true \
  --l1.beacon.slot-duration-override="${L1_BLOCK_TIME}" \
  --l2="http://127.0.0.1:${L2_EL_AUTH_PORT}" \
  --l2.jwt-secret="$JWT" \
  --l2.enginekind=geth \
  --rollup.config="$ROLLUP" \
  --rollup.l1-chain-config="$FORTEL2_ROOT/config/l1-chain-config.json" \
  --sequencer.enabled=true \
  --sequencer.stopped=false \
  --sequencer.max-safe-lag=3600 \
  --verifier.l1-confs=0 \
  --p2p.disable=true \
  --p2p.sequencer.key="${SEQUENCER_PRIVATE_KEY}" \
  --rpc.addr=127.0.0.1 \
  --rpc.port="${L2_NODE_RPC_PORT}" \
  --rpc.enable-admin \
  --log.level=info

wait_for_rpc "$L2_RPC_URL" "L2 op-geth"
echo "Sequencer up. L2 block=$(cast block-number --rpc-url "$L2_RPC_URL")"
echo "Known-good: op-geth log 'HTTP server started' ; op-node log 'Sequencer started' or 'Created new L2 block'"
