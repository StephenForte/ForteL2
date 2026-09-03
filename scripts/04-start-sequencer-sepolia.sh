#!/usr/bin/env bash
# Phase 2c / Task 5: Start the live Sepolia EL + op-node (no Anvil).
# FORTEL2_EL=geth (default): op-geth + enginekind=geth — byte-identical to pre-Task-5.
# FORTEL2_EL=reth: candidate op-reth on live ports + enginekind=reth.
# --verifier-only: geth rollback path — sequencer starts stopped (never stock
#   --sequencer.stopped=false as the first rollback step; PRD §9).
# --print-plan: print selector + flags and exit (no processes). Tests use this.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Snapshot before lib.sh sources .env.sepolia — rollback exports FORTEL2_EL=geth
# while the file may still say reth. Same trap as 03-init-l2.sh.
_CALLER_EL="${FORTEL2_EL:-}"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
[[ -n "$_CALLER_EL" ]] && { FORTEL2_EL="$_CALLER_EL"; export FORTEL2_EL; }

require_fortel2_el

VERIFIER_ONLY=0
PRINT_PLAN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verifier-only) VERIFIER_ONLY=1; shift ;;
    --print-plan) PRINT_PLAN=1; shift ;;
    -h|--help)
      echo "usage: 04-start-sequencer-sepolia.sh [--verifier-only] [--print-plan]"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "$VERIFIER_ONLY" -eq 1 && "$(fortel2_el)" == "reth" ]]; then
  echo "ERROR: --verifier-only is the geth rollback path (PRD §9); refuse under FORTEL2_EL=reth" >&2
  exit 1
fi

SEQ_STOPPED=false
if [[ "$VERIFIER_ONLY" -eq 1 ]]; then
  SEQ_STOPPED=true
fi

if [[ "$PRINT_PLAN" -eq 1 ]]; then
  echo "EL=$(fortel2_live_el_pid)"
  echo "ENGINEKIND=$(fortel2_live_enginekind)"
  echo "SEQUENCER_STOPPED=${SEQ_STOPPED}"
  echo "DATADIR=$DATA_DIR/l2/$(fortel2_live_el_pid)"
  echo "JWT=live"
  echo "SAFEDB=$(fortel2_live_safedb_path)"
  echo "LOG=$(fortel2_live_el_log)"
  if [[ "$(fortel2_el)" == "reth" ]]; then
    echo "PROFILE=${FORTEL2_RETH_PROFILE:-<required sequencer_faultproof>}"
    echo 'CORS=*'
  fi
  exit 0
fi

if [[ "$(fortel2_el)" == "reth" ]]; then
  require_reth_profile "${FORTEL2_RETH_PROFILE:-}"
  if [[ "${FORTEL2_RETH_PROFILE}" != "sequencer_faultproof" ]]; then
    echo "ERROR: live Sepolia reth requires FORTEL2_RETH_PROFILE=sequencer_faultproof (got ${FORTEL2_RETH_PROFILE})" >&2
    exit 1
  fi
  require_reth_enginekind reth
  require_bin op-reth
  require_bin op-node
  require_bin cast
  require_sepolia_env
  assert_block_times
  assert_l2_ports_free
  refuse_foundry_defaults_unless_local_l2 "${SEQUENCER_PRIVATE_KEY:-}" "SEQUENCER_PRIVATE_KEY"

  DATADIR="$(require_reth_datadir "${FORTEL2_RETH_DATADIR:-$DATA_DIR/l2/op-reth}")"
  JWT="$DATA_DIR/jwt/jwt.txt"
  ROLLUP="$DEPLOY_DIR/rollup.json"
  LIVE_SAFEDB="$(fortel2_live_safedb_path)"
  if [[ ! -f "$JWT" ]]; then
    echo "ERROR: missing live JWT $JWT — cutover reuses the live sequencer JWT (not the sidecar file)" >&2
    exit 1
  fi
  if [[ ! -f "$ROLLUP" ]]; then
    echo "ERROR: missing $ROLLUP — run FORTEL2_ENV=.env.sepolia ./scripts/02-deploy-contracts-sepolia.sh first" >&2
    exit 1
  fi
  require_sepolia_genesis_hash "$ROLLUP"

  "$SCRIPT_DIR/03-init-l2.sh"
  GENESIS="$(resolve_reth_genesis)"
  require_genesis_852 "$GENESIS" "$ROLLUP"

  echo "Initializing proofs-history store at $DATADIR/historical-proofs (skip-backfill; idempotent)"
  op-reth proofs init --datadir="$DATADIR" --chain="$GENESIS" \
    --proofs-history.skip-backfill

  wait_for_rpc "$L1_RPC_URL" "L1 Sepolia"
  L1_ID="$(cast chain-id --rpc-url "$L1_RPC_URL")"
  if [[ "$L1_ID" != "11155111" ]]; then
    echo "ERROR: L1 RPC chain-id is $L1_ID (expected 11155111)" >&2
    exit 1
  fi

  L1_CONFS="${SEPOLIA_VERIFIER_L1_CONFS:-1}"
  L1_HTTP_POLL="${SEPOLIA_L1_HTTP_POLL_INTERVAL:-12s}"
  L1_RPC_RATE_LIMIT="${SEPOLIA_L1_RPC_RATE_LIMIT:-20}"
  L1_RPC_KIND="${SEPOLIA_L1_RPC_KIND:-quicknode}"
  PROFILE_FLAGS=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && PROFILE_FLAGS+=("$f")
  done < <(reth_profile_flags sequencer_faultproof)

  echo "Starting live op-reth (sequencer_faultproof) http :${L2_EL_HTTP_PORT} datadir=$DATADIR"
  start_bg op-reth op-reth node \
    --chain="$GENESIS" \
    --datadir="$DATADIR" \
    --http \
    --http.addr=127.0.0.1 \
    --http.port="${L2_EL_HTTP_PORT}" \
    --http.api=eth,net,web3,debug,txpool \
    --http.corsdomain="*" \
    --ws \
    --ws.addr=127.0.0.1 \
    --ws.port="${L2_EL_WS_PORT}" \
    --authrpc.addr=127.0.0.1 \
    --authrpc.port="${L2_EL_AUTH_PORT}" \
    --authrpc.jwtsecret="$JWT" \
    --disable-discovery \
    "${PROFILE_FLAGS[@]}"

  sleep 2

  mkdir -p "$LIVE_SAFEDB"
  echo "Live op-node SafeDB=$LIVE_SAFEDB (sidecar \$DATA_DIR/l2/op-reth-safedb untouched)"
  start_bg op-node op-node \
    --l1="$L1_RPC_URL" \
    --l1.rpckind="${L1_RPC_KIND}" \
    --l1.trustrpc=true \
    --l1.http-poll-interval="${L1_HTTP_POLL}" \
    --l1.rpc-rate-limit="${L1_RPC_RATE_LIMIT}" \
    --l1.beacon.ignore=true \
    --l1.beacon.slot-duration-override="${L1_BLOCK_TIME}" \
    --l2="http://127.0.0.1:${L2_EL_AUTH_PORT}" \
    --l2.jwt-secret="$JWT" \
    --l2.enginekind=reth \
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
    --safedb.path="$LIVE_SAFEDB" \
    --log.level=info

  wait_for_rpc "$L2_RPC_URL" "L2 op-reth"
  echo "Sepolia sequencer up (FORTEL2_EL=reth). L2 block=$(cast block-number --rpc-url "$L2_RPC_URL") chain=$(cast chain-id --rpc-url "$L2_RPC_URL")"
  echo "DATA_DIR=$DATA_DIR (op-geth datadir read-only; never opened)"
  echo "op-node L1 poll=${L1_HTTP_POLL} rpc-rate-limit=${L1_RPC_RATE_LIMIT} kind=${L1_RPC_KIND} enginekind=reth"
  echo "Known-good: op-reth 'Starting JSON-RPC' ; op-node 'Sequencer' / 'Created new L2 block'"
  exit 0
fi

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
# Credit-budget: explicit tip poll + soft self-throttle on L1 RPC (requests/sec).
L1_HTTP_POLL="${SEPOLIA_L1_HTTP_POLL_INTERVAL:-12s}"
L1_RPC_RATE_LIMIT="${SEPOLIA_L1_RPC_RATE_LIMIT:-20}"
# Receipts-fetch kind: QuickNode is the live L1 (D-0102). Rollback: SEPOLIA_L1_RPC_KIND=standard.
L1_RPC_KIND="${SEPOLIA_L1_RPC_KIND:-quicknode}"
start_bg op-node op-node \
  --l1="$L1_RPC_URL" \
  --l1.rpckind="${L1_RPC_KIND}" \
  --l1.trustrpc=true \
  --l1.http-poll-interval="${L1_HTTP_POLL}" \
  --l1.rpc-rate-limit="${L1_RPC_RATE_LIMIT}" \
  --l1.beacon.ignore=true \
  --l1.beacon.slot-duration-override="${L1_BLOCK_TIME}" \
  --l2="http://127.0.0.1:${L2_EL_AUTH_PORT}" \
  --l2.jwt-secret="$JWT" \
  --l2.enginekind=geth \
  --rollup.config="$ROLLUP" \
  --sequencer.enabled=true \
  --sequencer.stopped="${SEQ_STOPPED}" \
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
echo "op-node L1 poll=${L1_HTTP_POLL} rpc-rate-limit=${L1_RPC_RATE_LIMIT} kind=${L1_RPC_KIND}"
echo "Known-good: op-geth 'HTTP server started' ; op-node 'Sequencer' / 'Created new L2 block'"
