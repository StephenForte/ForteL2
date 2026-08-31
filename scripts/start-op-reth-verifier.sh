#!/usr/bin/env bash
# Isolated op-reth + verifier op-node for ForteL2 Sepolia L2 852 (Task 2).
# Opt-in. Does not replace 04-start-sequencer-sepolia.sh (live op-geth until Task 5).
# Pid names: op-reth / op-reth-node. Logs: data/logs/op-reth.log, op-reth-node.log.
# Never binds :9545/:9546/:9547/:9551. Never opens $DATA_DIR/l2/op-geth.
# Mid-chain rewind: wipe the reth datadir and re-derive — never debug_setHead.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
usage: start-op-reth-verifier.sh [--preflight] [--wipe] [--wait-blocks N] [--genesis PATH] [--rollup PATH]

Opt-in 852 verifier sidecar (FORTEL2_EL=reth). Not the live sequencer.

  --preflight       refusals only; does not require op-reth or start processes
  --wipe            wipe the allowed reth datadir before init (op-geth never)
  --wait-blocks N   after attach, wait until L2 head >= N (default 0 = genesis only)
  --genesis PATH    852 genesis.json (else Sepolia deploy copy / replica pack)
  --rollup PATH     must be chain 852 (default: deployments/sepolia/rollup.json)

Requires FORTEL2_RETH_PROFILE=sequencer_faultproof | verifier (no silent default).
Datadir: $DATA_DIR/l2/op-reth (or FORTEL2_RETH_DATADIR=$DATA_DIR/l2/spike-op-reth).
Ports default 19545/19546/19551/19547/30330 (env-overridable; live 954x refused).
JWT: fresh file under the verifier datadir — never the live JWT.

Do not export FORTEL2_ENV=.env.sepolia (role keys). Snapshot L1_RPC_URL and
optional DATA_DIR before this script sources .env (Phase 1 would clobber them):
  unset FORTEL2_ENV
  export L1_RPC_URL="$(grep '^L1_RPC_URL=' .env.sepolia | cut -d= -f2-)"
  export FORTEL2_EL=reth FORTEL2_RETH_PROFILE=verifier
  ./scripts/start-op-reth-verifier.sh --wait-blocks 5

Task 3 candidate (sequencer_faultproof from first start of $DATA_DIR/l2/op-reth;
half-rate L1 reads on a months-deep historical derive — do not print L1_RPC_URL):
  unset FORTEL2_ENV
  export L1_RPC_URL="$(grep '^L1_RPC_URL=' .env.sepolia | cut -d= -f2-)"
  export DATA_DIR="$(grep '^DATA_DIR=' .env.sepolia | cut -d= -f2-)"
  export FORTEL2_EL=reth FORTEL2_RETH_PROFILE=sequencer_faultproof
  export SEPOLIA_L1_RPC_RATE_LIMIT=10
  ./scripts/start-op-reth-verifier.sh
  ./scripts/verify-reth-parity.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

case "${FORTEL2_ENV:-}" in
  .env.sepolia|.env.sepolia.*|/*/.env.sepolia|/*/.env.sepolia.*)
    echo "ERROR: refusing FORTEL2_ENV=${FORTEL2_ENV} — do not load Sepolia role keys" >&2
    echo "Unset FORTEL2_ENV and pass L1_RPC_URL. Optional: export DATA_DIR to the Sepolia runtime dir without sourcing .env.sepolia." >&2
    exit 2
    ;;
esac

PREFLIGHT=0
WIPE=0
WAIT_BLOCKS=0
GENESIS_ARG=""
ROLLUP_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --preflight) PREFLIGHT=1; shift ;;
    --wipe) WIPE=1; shift ;;
    --wait-blocks) WAIT_BLOCKS="$2"; shift 2 ;;
    --genesis) GENESIS_ARG="$2"; shift 2 ;;
    --rollup) ROLLUP_ARG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ! [[ "$WAIT_BLOCKS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --wait-blocks must be an integer >= 0" >&2
  exit 2
fi

_CALLER_L1_RPC_URL="${L1_RPC_URL:-}"
_CALLER_DATA_DIR="${DATA_DIR:-}"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

restore_caller_l1_rpc_url "$_CALLER_L1_RPC_URL"
restore_caller_data_dir "$_CALLER_DATA_DIR"

FORTEL2_EL=reth
export FORTEL2_EL
require_fortel2_el
require_reth_enginekind reth
require_reth_profile
require_reth_verifier_ports
DATADIR="$(require_reth_datadir)"
export FORTEL2_RETH_DATADIR="$DATADIR"
ROLLUP="${ROLLUP_ARG:-${FORTEL2_RETH_ROLLUP:-$FORTEL2_ROOT/deployments/sepolia/rollup.json}}"
export FORTEL2_RETH_ROLLUP="$ROLLUP"
require_sepolia_genesis_hash "$ROLLUP"

if [[ -n "$GENESIS_ARG" ]]; then
  FORTEL2_RETH_GENESIS="$GENESIS_ARG"
fi
export FORTEL2_RETH_GENESIS
export FORTEL2_RETH_PROFILE

if [[ "$PREFLIGHT" -eq 1 ]]; then
  # Only resolve genesis when the caller supplied one — otherwise Phase 1
  # $DEPLOY_DIR/genesis.json (901) would fail closed on an otherwise-valid preflight.
  if [[ -n "${FORTEL2_RETH_GENESIS:-}" ]]; then
    GENESIS="$(resolve_reth_genesis)"
    require_genesis_852 "$GENESIS" "$ROLLUP"
    echo "preflight genesis=$GENESIS"
  fi
  echo "preflight ok: FORTEL2_EL=reth profile=${FORTEL2_RETH_PROFILE} datadir=$DATADIR"
  echo "ports http=$(reth_http_port) ws=$(reth_ws_port) auth=$(reth_auth_port) node=$(reth_node_rpc_port) p2p=$(reth_p2p_port)"
  echo "enginekind=reth genesis_hash=$FORTEL2_L2_GENESIS_HASH_852"
  echo "rewind: wipe datadir + re-derive (never debug_setHead)"
  exit 0
fi

require_bin op-reth
require_bin op-node
require_bin cast
require_bin jq
require_bin openssl
require_bin lsof

GENESIS="$(resolve_reth_genesis)"
require_genesis_852 "$GENESIS" "$ROLLUP"

l1_is_publicnode() {
  case "${1:-}" in
    *publicnode.com*) return 0 ;;
    *) return 1 ;;
  esac
}

if [[ -z "${L1_RPC_URL:-}" ]]; then
  echo "ERROR: L1_RPC_URL is required (export a receipts-capable Sepolia URL before invoking; do not FORTEL2_ENV=.env.sepolia)" >&2
  exit 1
fi
assert_remote_l1_rpc_url "$L1_RPC_URL" "L1_RPC_URL"
if l1_is_publicnode "$L1_RPC_URL"; then
  echo "ERROR: refusing PublicNode L1 — op-node receipt fetch returns 0 (got 0 receipts but expected N)" >&2
  echo "Export a receipts-capable L1_RPC_URL (QuickNode). Default --l1.rpckind=quicknode." >&2
  exit 2
fi

HTTP_PORT="$(reth_http_port)"
WS_PORT="$(reth_ws_port)"
AUTH_PORT="$(reth_auth_port)"
NODE_PORT="$(reth_node_rpc_port)"
P2P_PORT="$(reth_p2p_port)"
EL_HTTP="http://127.0.0.1:${HTTP_PORT}"
EL_AUTH="http://127.0.0.1:${AUTH_PORT}"
NODE_HTTP="http://127.0.0.1:${NODE_PORT}"
assert_loopback_url "$EL_HTTP" "op-reth HTTP"
assert_loopback_url "$EL_AUTH" "op-reth auth"
assert_loopback_url "$NODE_HTTP" "op-reth-node RPC"

if ! command -v lsof >/dev/null 2>&1; then
  echo "ERROR: lsof is required to verify sidecar ports are free" >&2
  exit 1
fi
for port in "$HTTP_PORT" "$WS_PORT" "$AUTH_PORT" "$NODE_PORT" "$P2P_PORT"; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "ERROR: sidecar port $port already in use" >&2
    exit 1
  fi
done

if [[ "$WIPE" -eq 1 ]]; then
  wipe_reth_datadir "$DATADIR"
fi

"$SCRIPT_DIR/03-init-l2.sh"

JWT="$(reth_jwt_path "$DATADIR")"
write_reth_jwt "$JWT"

PROFILE_FLAGS=()
while IFS= read -r f; do
  [[ -n "$f" ]] && PROFILE_FLAGS+=("$f")
done < <(reth_profile_flags)

# --proofs-history ExEx refuses to start unless the store is initialized.
# Panic text names `initialize-op-proofs`; the pinned binary's command is
# `op-reth proofs init`. skip-backfill: V1 has no backfill, and this datadir
# starts at genesis so history is filled forward during Task 3 derive.
if [[ "$FORTEL2_RETH_PROFILE" == "sequencer_faultproof" ]]; then
  echo "Initializing proofs-history store at $DATADIR/historical-proofs (skip-backfill; idempotent)"
  op-reth proofs init --datadir="$DATADIR" --chain="$GENESIS" \
    --proofs-history.skip-backfill
fi

L1_RPC_KIND="${SEPOLIA_L1_RPC_KIND:-quicknode}"
L1_CONFS="${SEPOLIA_VERIFIER_L1_CONFS:-1}"
L1_HTTP_POLL="${SEPOLIA_L1_HTTP_POLL_INTERVAL:-12s}"
L1_RPC_RATE_LIMIT="${SEPOLIA_L1_RPC_RATE_LIMIT:-20}"

echo "Checking L1 is Sepolia (11155111) at $(redact_rpc_url "$L1_RPC_URL")"
L1_ID="$(cast chain-id --rpc-url "$L1_RPC_URL")"
if [[ "$L1_ID" != "11155111" ]]; then
  echo "ERROR: L1 chain-id is $L1_ID (expected 11155111)" >&2
  exit 1
fi

echo "Starting op-reth profile=${FORTEL2_RETH_PROFILE} http :$HTTP_PORT auth :$AUTH_PORT datadir=$DATADIR"
start_bg op-reth op-reth node \
  --chain="$GENESIS" \
  --datadir="$DATADIR" \
  --http \
  --http.addr=127.0.0.1 \
  --http.port="$HTTP_PORT" \
  --http.api=eth,net,web3,debug,txpool \
  --ws \
  --ws.addr=127.0.0.1 \
  --ws.port="$WS_PORT" \
  --authrpc.addr=127.0.0.1 \
  --authrpc.port="$AUTH_PORT" \
  --authrpc.jwtsecret="$JWT" \
  --port="$P2P_PORT" \
  --disable-discovery \
  "${PROFILE_FLAGS[@]}"

sleep 2
wait_for_rpc "$EL_HTTP" "op-reth sidecar" 90

echo "Starting op-reth-node --l2.enginekind=reth (rpc :$NODE_PORT) l1.rpckind=${L1_RPC_KIND} l1.rpc-rate-limit=${L1_RPC_RATE_LIMIT}"
start_bg op-reth-node op-node \
  --l1="$L1_RPC_URL" \
  --l1.rpckind="${L1_RPC_KIND}" \
  --l1.trustrpc=true \
  --l1.http-poll-interval="${L1_HTTP_POLL}" \
  --l1.rpc-rate-limit="${L1_RPC_RATE_LIMIT}" \
  --l1.beacon.ignore=true \
  --l2="$EL_AUTH" \
  --l2.jwt-secret="$JWT" \
  --l2.enginekind=reth \
  --rollup.config="$ROLLUP" \
  --sequencer.enabled=false \
  --verifier.l1-confs="${L1_CONFS}" \
  --p2p.disable=true \
  --rpc.addr=127.0.0.1 \
  --rpc.port="$NODE_PORT" \
  --log.level=info

wait_for_opnode_rpc "$NODE_HTTP" "op-reth-node" 90

GEN0="$(cast block 0 --rpc-url "$EL_HTTP" --json | jq -r '.hash')"
echo "genesis sidecar=$GEN0 expected=$FORTEL2_L2_GENESIS_HASH_852"
if [[ "$GEN0" != "$FORTEL2_L2_GENESIS_HASH_852" ]]; then
  echo "ERROR: genesis hash mismatch — stopping sidecar (live stack untouched)" >&2
  stop_reth_sidecar
  exit 1
fi
echo "genesis hash match $GEN0"

if [[ "$WAIT_BLOCKS" -gt 0 ]]; then
  echo "Waiting for sidecar L2 block $WAIT_BLOCKS ..."
  tries=0
  while (( tries < 180 )); do
    head="$(cast block-number --rpc-url "$EL_HTTP" 2>/dev/null || echo 0)"
    if [[ "$head" =~ ^[0-9]+$ ]] && (( head >= WAIT_BLOCKS )); then
      break
    fi
    sleep 2
    ((tries++)) || true
  done
  head="$(cast block-number --rpc-url "$EL_HTTP")"
  if ! [[ "$head" =~ ^[0-9]+$ ]] || (( head < WAIT_BLOCKS )); then
    echo "ERROR: sidecar head=$head never reached block $WAIT_BLOCKS (see $LOG_DIR/op-reth-node.log)" >&2
    exit 1
  fi
  echo "sidecar L2 head=$head (>= $WAIT_BLOCKS)"
fi

echo "op-reth verifier up. EL=$EL_HTTP node=$NODE_HTTP profile=${FORTEL2_RETH_PROFILE}"
echo "Stop: ./scripts/stop-op-reth-verifier.sh (or stop-all.sh — sidecar names only; live geth stays if on another DATA_DIR)"
echo "Known-good: op-reth log 'Starting JSON-RPC' / 'RPC'; op-reth-node 'derived' / 'Forkchoice'"
