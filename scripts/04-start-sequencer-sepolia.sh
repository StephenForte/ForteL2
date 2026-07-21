#!/usr/bin/env bash
# Phase 2c: Start op-geth + op-node against Ethereum Sepolia L1 (no Anvil, no custom L1-900 config).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin op-geth
require_bin op-node
require_bin cast
require_sepolia_env
assert_block_times
assert_l2_ports_free
refuse_foundry_defaults_unless_local_l2 "${SEQUENCER_PRIVATE_KEY:-}" "SEQUENCER_PRIVATE_KEY"

"$SCRIPT_DIR/03-init-l2.sh"

DATADIR="$DATA_DIR/l2/op-geth"
JWT="$DATA_DIR/jwt/jwt.txt"
ROLLUP="$DEPLOY_DIR/rollup.json"

if [[ ! -f "$ROLLUP" ]]; then
  echo "ERROR: missing $ROLLUP — run FORTEL2_ENV=.env.sepolia ./scripts/02-deploy-contracts-sepolia.sh first" >&2
  exit 1
fi

wait_for_rpc "$L1_RPC_URL" "L1 Sepolia"
L1_ID="$(cast chain-id --rpc-url "$L1_RPC_URL")"
if [[ "$L1_ID" != "11155111" ]]; then
  echo "ERROR: L1 RPC chain-id is $L1_ID (expected 11155111)" >&2
  exit 1
fi

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

sleep 2

# Calldata DA dry-run: ignore beacon (same class as Phase 1). No custom L1-900 chain-config —
# Sepolia is a known L1. Slightly higher L1 confs than Anvil for public RPC noise.
L1_CONFS="${SEPOLIA_VERIFIER_L1_CONFS:-1}"
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
  --sequencer.enabled=true \
  --sequencer.stopped=false \
  --sequencer.max-safe-lag=3600 \
  --verifier.l1-confs="${L1_CONFS}" \
  --p2p.disable=true \
  --p2p.sequencer.key="${SEQUENCER_PRIVATE_KEY}" \
  --rpc.addr=127.0.0.1 \
  --rpc.port="${L2_NODE_RPC_PORT}" \
  --rpc.enable-admin \
  --log.level=info

wait_for_rpc "$L2_RPC_URL" "L2 op-geth"
echo "Sepolia sequencer up. L2 block=$(cast block-number --rpc-url "$L2_RPC_URL") chain=$(cast chain-id --rpc-url "$L2_RPC_URL")"
echo "DATA_DIR=$DATA_DIR (Phase 1 datadir untouched)"
echo "Known-good: op-geth 'HTTP server started' ; op-node 'Sequencer' / 'Created new L2 block'"
