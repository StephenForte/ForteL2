#!/usr/bin/env bash
# P:0 spike: isolated op-reth + verifier op-node for ForteL2 Sepolia L2 852.
# Throwaway. Does not replace 04-start-sequencer*.sh. Does not call start_bg/stop_bg.
# From the ForteL2 repo root: ./scripts/spike-op-reth.sh --blocks 5
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORTEL2_ROOT_HINT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
usage: spike-op-reth.sh [--blocks N] [--genesis PATH] [--rollup PATH] [--no-wipe] [--preflight]

P:0 sidecar PoC — verifier-only op-reth on ForteL2 chain 852. Not a chat prompt.

  --blocks N       hash-match at this L2 block (default 5). Not tip-sync.
  --genesis PATH   852 genesis.json (else local deploy copy, else fortel2-replica)
  --rollup PATH    must be chain 852 (default: deployments/sepolia/rollup.json)
  --no-wipe        reuse $DATA_DIR/l2/spike-op-reth
  --preflight      refusals only; does not require op-reth or start processes

Refuses:
  - chain 901 / any rollup whose l2_chain_id is not 852
  - live op-geth datadir ($DATA_DIR/l2/op-geth)
  - binding :9545 :9546 :9547 :9551 (sequencer ports)
  - start_bg / stop_bg (this script never calls them)
  - FORTEL2_ENV=.env.sepolia (do not load role keys)
  - Docker / OrbStack binary paths

Default sidecar ports: HTTP 19845, auth 19851, op-node 19847.
L1: existing non-loopback L1_RPC_URL, or https://ethereum-sepolia-rpc.publicnode.com
Oracle: https://fortel2-replica-rpc.onrender.com (eth_getBlockByNumber only)
EOF
}

# --help before sourcing lib.sh so this works without a chain or sepolia env.
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

# Do not load operator Sepolia keys. Check before lib.sh sources the env file.
case "${FORTEL2_ENV:-}" in
  .env.sepolia|.env.sepolia.*|/*/.env.sepolia|/*/.env.sepolia.*)
    echo "ERROR: refusing FORTEL2_ENV=${FORTEL2_ENV} — do not load Sepolia role keys" >&2
    echo "Unset FORTEL2_ENV and pass L1_RPC_URL if you have a dedicated Sepolia RPC." >&2
    exit 2
    ;;
esac

BLOCKS=5
NO_WIPE=0
PREFLIGHT=0
GENESIS_ARG=""
ROLLUP_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --blocks) BLOCKS="$2"; shift 2 ;;
    --genesis) GENESIS_ARG="$2"; shift 2 ;;
    --rollup) ROLLUP_ARG="$2"; shift 2 ;;
    --no-wipe) NO_WIPE=1; shift ;;
    --preflight) PREFLIGHT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ! [[ "$BLOCKS" =~ ^[0-9]+$ ]] || [[ "$BLOCKS" -lt 1 ]]; then
  echo "ERROR: --blocks must be an integer >= 1" >&2
  exit 2
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

RESERVED_PORTS="9545 9546 9547 9551"
SPIKE_EL_HTTP_PORT="${SPIKE_EL_HTTP_PORT:-19845}"
SPIKE_EL_AUTH_PORT="${SPIKE_EL_AUTH_PORT:-19851}"
SPIKE_NODE_RPC_PORT="${SPIKE_NODE_RPC_PORT:-19847}"
SPIKE_EL_WS_PORT="${SPIKE_EL_WS_PORT:-19846}"
SPIKE_EL_P2P_PORT="${SPIKE_EL_P2P_PORT:-30329}"
SPIKE_DATADIR="${SPIKE_DATADIR:-$DATA_DIR/l2/spike-op-reth}"
SPIKE_JWT="${SPIKE_JWT:-$DATA_DIR/jwt/spike-op-reth-jwt.txt}"
LIVE_GETH_DATADIR="$DATA_DIR/l2/op-geth"
DEFAULT_ROLLUP="$FORTEL2_ROOT/deployments/sepolia/rollup.json"
DEFAULT_L1="https://ethereum-sepolia-rpc.publicnode.com"
REPLICA_RPC="${SPIKE_REPLICA_RPC:-https://fortel2-replica-rpc.onrender.com}"
SEQ_TIP_RPC="${SPIKE_SEQ_TIP_RPC:-https://fortel2-sequencer-rpc.onrender.com}"
REPLICA_GENESIS_URL="${SPIKE_GENESIS_URL:-https://raw.githubusercontent.com/StephenForte/fortel2-replica/main/config/genesis.json}"
ROLLUP="${ROLLUP_ARG:-$DEFAULT_ROLLUP}"

refuse_reserved_port() {
  local name="$1" port="$2" p
  for p in $RESERVED_PORTS; do
    if [[ "$port" == "$p" ]]; then
      echo "ERROR: refusing $name=$port — sequencer port :9545/:9546/:9547/:9551 stay untouched" >&2
      exit 2
    fi
  done
}

refuse_live_geth_datadir() {
  local resolved live
  resolved="$(cd "$(dirname "$SPIKE_DATADIR")" 2>/dev/null && pwd)/$(basename "$SPIKE_DATADIR")"
  live="$(cd "$(dirname "$LIVE_GETH_DATADIR")" 2>/dev/null && pwd)/$(basename "$LIVE_GETH_DATADIR")"
  if [[ "$resolved" == "$live" ]]; then
    echo "ERROR: refusing live op-geth datadir $LIVE_GETH_DATADIR" >&2
    exit 2
  fi
  case "$SPIKE_DATADIR" in
    */l2/op-geth|*/l2/op-geth/)
      echo "ERROR: refusing live op-geth datadir $SPIKE_DATADIR" >&2
      exit 2
      ;;
  esac
}

refuse_docker_bin() {
  local name="$1" path
  path="$(command -v "$name" 2>/dev/null || true)"
  [[ -n "$path" ]] || return 0
  path="$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")"
  case "$path" in
    */Docker.app/*|*/OrbStack/*|*/.docker/*|*/docker/bin/*)
      echo "ERROR: refusing Docker/OrbStack $name at $path — native binary only" >&2
      exit 2
      ;;
  esac
}

require_rollup_852() {
  local id
  if [[ ! -f "$ROLLUP" ]]; then
    echo "ERROR: missing rollup $ROLLUP (expected deployments/sepolia/rollup.json)" >&2
    exit 2
  fi
  id="$(jq -r '.l2_chain_id // empty' "$ROLLUP")"
  if [[ "$id" != "852" ]]; then
    echo "ERROR: refusing chain ${id:-<missing>} — this spike is ForteL2 852 only (not 901)" >&2
    exit 2
  fi
  if jq -e '.karst_time != null' "$ROLLUP" >/dev/null 2>&1; then
    echo "ERROR: rollup has karst_time set — this spike leaves Karst unset" >&2
    exit 2
  fi
}

refuse_reserved_port SPIKE_EL_HTTP_PORT "$SPIKE_EL_HTTP_PORT"
refuse_reserved_port SPIKE_EL_WS_PORT "$SPIKE_EL_WS_PORT"
refuse_reserved_port SPIKE_EL_AUTH_PORT "$SPIKE_EL_AUTH_PORT"
refuse_reserved_port SPIKE_NODE_RPC_PORT "$SPIKE_NODE_RPC_PORT"
refuse_live_geth_datadir
require_rollup_852

case "${L1_RPC_URL:-}" in
  http://127.0.0.1:*|http://localhost:*|https://127.0.0.1:*|https://localhost:*|"")
    L1_RPC_URL="$DEFAULT_L1"
    echo "Using public Sepolia L1 smoke URL (loopback/empty L1_RPC_URL is Anvil — not 852)"
    ;;
esac
assert_remote_l1_rpc_url "$L1_RPC_URL" "L1_RPC_URL"

if [[ "$PREFLIGHT" -eq 1 ]]; then
  echo "preflight ok: rollup=$ROLLUP l2=852 sidecar=:$SPIKE_EL_HTTP_PORT/:$SPIKE_EL_AUTH_PORT/:$SPIKE_NODE_RPC_PORT"
  echo "datadir=$SPIKE_DATADIR (not $LIVE_GETH_DATADIR)"
  exit 0
fi

require_bin op-reth
require_bin op-node
require_bin cast
require_bin jq
require_bin curl
require_bin openssl
refuse_docker_bin op-reth
refuse_docker_bin op-node

RETH_VER="$(op-reth --version 2>/dev/null || op-reth node --version 2>/dev/null || true)"
echo "op-reth version: ${RETH_VER:-<unparsed>}"
if ! printf '%s' "$RETH_VER" | grep -Eq '2\.(3|4|[5-9]|[1-9][0-9])'; then
  echo "WARN: expected op-reth v2.3.3+; record the actual string in tasks/spike-op-reth.md" >&2
fi

resolve_genesis() {
  if [[ -n "$GENESIS_ARG" ]]; then
    [[ -f "$GENESIS_ARG" ]] || { echo "ERROR: --genesis not a file: $GENESIS_ARG" >&2; exit 1; }
    printf '%s' "$GENESIS_ARG"
    return
  fi
  if [[ -f "$DEPLOY_DIR/genesis.json" ]]; then
    local gid
    gid="$(jq -r '.config.chainId // empty' "$DEPLOY_DIR/genesis.json")"
    if [[ "$gid" == "852" ]]; then
      printf '%s' "$DEPLOY_DIR/genesis.json"
      return
    fi
    echo "WARN: $DEPLOY_DIR/genesis.json chainId=$gid — ignoring (not 852)"
  fi
  mkdir -p "$DATA_DIR/l2"
  local dest="$DATA_DIR/l2/spike-op-reth-genesis.json"
  echo "Fetching 852 genesis from fortel2-replica (not in git)"
  curl -fsSL "$REPLICA_GENESIS_URL" -o "$dest"
  local gid
  gid="$(jq -r '.config.chainId // empty' "$dest")"
  if [[ "$gid" != "852" ]]; then
    echo "ERROR: fetched genesis chainId=$gid (want 852)" >&2
    exit 1
  fi
  printf '%s' "$dest"
}

GENESIS="$(resolve_genesis)"
echo "genesis=$GENESIS"

mkdir -p "$(dirname "$SPIKE_JWT")" "$SPIKE_DATADIR" "$DATA_DIR/logs"
if [[ ! -f "$SPIKE_JWT" ]]; then
  openssl rand -hex 32 > "$SPIKE_JWT"
  chmod 600 "$SPIKE_JWT"
fi

if [[ "$NO_WIPE" -eq 0 ]]; then
  echo "Wiping spike datadir $SPIKE_DATADIR (live op-geth untouched)"
  rm -rf "$SPIKE_DATADIR"
  mkdir -p "$SPIKE_DATADIR"
fi

# reth may accept `init` or init-on-start via --chain. Try init; continue if unsupported.
if op-reth init --help >/dev/null 2>&1; then
  echo "Initializing op-reth datadir from genesis"
  op-reth init --datadir="$SPIKE_DATADIR" --chain="$GENESIS" \
    >>"$DATA_DIR/logs/spike-op-reth.log" 2>&1 || true
fi

EL_PID=""
NODE_PID=""
cleanup_spike() {
  if [[ -n "${NODE_PID:-}" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
    kill "$NODE_PID" 2>/dev/null || true
    wait "$NODE_PID" 2>/dev/null || true
  fi
  if [[ -n "${EL_PID:-}" ]] && kill -0 "$EL_PID" 2>/dev/null; then
    kill "$EL_PID" 2>/dev/null || true
    wait "$EL_PID" 2>/dev/null || true
  fi
}
trap cleanup_spike EXIT

SPIKE_HTTP="http://127.0.0.1:${SPIKE_EL_HTTP_PORT}"
SPIKE_AUTH="http://127.0.0.1:${SPIKE_EL_AUTH_PORT}"
SPIKE_NODE="http://127.0.0.1:${SPIKE_NODE_RPC_PORT}"
assert_loopback_url "$SPIKE_HTTP" "spike EL HTTP"
assert_loopback_url "$SPIKE_AUTH" "spike EL auth"
assert_loopback_url "$SPIKE_NODE" "spike op-node"

echo "Checking L1 is Sepolia (11155111) at $(redact_rpc_url "$L1_RPC_URL")"
L1_ID="$(cast chain-id --rpc-url "$L1_RPC_URL")"
if [[ "$L1_ID" != "11155111" ]]; then
  echo "ERROR: L1 chain-id is $L1_ID (expected 11155111)" >&2
  exit 1
fi

echo "Starting op-reth (http :$SPIKE_EL_HTTP_PORT auth :$SPIKE_EL_AUTH_PORT)"
# Flag names recorded in tasks/spike-op-reth.md after the first successful run.
op-reth node \
  --chain="$GENESIS" \
  --datadir="$SPIKE_DATADIR" \
  --http \
  --http.addr=127.0.0.1 \
  --http.port="$SPIKE_EL_HTTP_PORT" \
  --http.api=eth,net,web3,debug,txpool \
  --ws \
  --ws.addr=127.0.0.1 \
  --ws.port="$SPIKE_EL_WS_PORT" \
  --authrpc.addr=127.0.0.1 \
  --authrpc.port="$SPIKE_EL_AUTH_PORT" \
  --authrpc.jwtsecret="$SPIKE_JWT" \
  --port="$SPIKE_EL_P2P_PORT" \
  --disable-discovery \
  >>"$DATA_DIR/logs/spike-op-reth.log" 2>&1 &
EL_PID=$!

wait_for_rpc "$SPIKE_HTTP" "spike op-reth" 90

echo "Starting verifier op-node --l2.enginekind=reth (rpc :$SPIKE_NODE_RPC_PORT)"
op-node \
  --l1="$L1_RPC_URL" \
  --l1.rpckind=standard \
  --l1.trustrpc=true \
  --l1.beacon.ignore=true \
  --l2="$SPIKE_AUTH" \
  --l2.jwt-secret="$SPIKE_JWT" \
  --l2.enginekind=reth \
  --rollup.config="$ROLLUP" \
  --sequencer.enabled=false \
  --p2p.disable=true \
  --rpc.addr=127.0.0.1 \
  --rpc.port="$SPIKE_NODE_RPC_PORT" \
  --log.level=info \
  >>"$DATA_DIR/logs/spike-op-reth-node.log" 2>&1 &
NODE_PID=$!

wait_for_opnode_rpc "$SPIKE_NODE" "spike op-node" 90

rpc_block_hash() {
  local url="$1" spec="$2"
  cast block "$spec" --rpc-url "$url" --json | jq -r '.hash'
}

echo "Oracle replica $(redact_rpc_url "$REPLICA_RPC") (read-only)"
REP0="$(rpc_block_hash "$REPLICA_RPC" 0)"
SPIKE0="$(rpc_block_hash "$SPIKE_HTTP" 0)"
echo "genesis replica=$REP0 sidecar=$SPIKE0"
if [[ "$REP0" != "$SPIKE0" || "$REP0" == "null" || -z "$REP0" ]]; then
  echo "ERROR: genesis hash mismatch (or replica unreachable)" >&2
  exit 1
fi

echo "Waiting for sidecar L2 block $BLOCKS ..."
tries=0
while (( tries < 180 )); do
  head="$(cast block-number --rpc-url "$SPIKE_HTTP" 2>/dev/null || echo 0)"
  if [[ "$head" =~ ^[0-9]+$ ]] && (( head >= BLOCKS )); then
    break
  fi
  sleep 2
  ((tries++)) || true
done
head="$(cast block-number --rpc-url "$SPIKE_HTTP")"
if ! [[ "$head" =~ ^[0-9]+$ ]] || (( head < BLOCKS )); then
  echo "ERROR: sidecar head=$head never reached block $BLOCKS (see $DATA_DIR/logs/spike-op-reth-node.log)" >&2
  exit 1
fi

REPN="$(rpc_block_hash "$REPLICA_RPC" "$BLOCKS")"
SPIKEN="$(rpc_block_hash "$SPIKE_HTTP" "$BLOCKS")"
echo "block $BLOCKS replica=$REPN sidecar=$SPIKEN"
if [[ "$REPN" != "$SPIKEN" || "$REPN" == "null" || -z "$REPN" ]]; then
  echo "ERROR: hash mismatch at block $BLOCKS" >&2
  exit 1
fi

if SEQN="$(rpc_block_hash "$SEQ_TIP_RPC" "$BLOCKS" 2>/dev/null)"; then
  if [[ "$SEQN" == "$SPIKEN" ]]; then
    echo "sequencer-tip door also matches at block $BLOCKS"
  else
    echo "WARN: sequencer-tip hash at $BLOCKS is $SEQN (replica/sidecar $SPIKEN) — door may be stale or asleep"
  fi
else
  echo "WARN: sequencer-tip door did not answer (nightly window or filter) — replica match is enough"
fi

echo "RPC namespace probe (record in tasks/spike-op-reth.md)"
for method in net_version web3_clientVersion; do
  if cast rpc "$method" --rpc-url "$SPIKE_HTTP" >/dev/null 2>&1; then
    echo "  PASS $method"
  else
    echo "  FAIL $method" >&2
    exit 1
  fi
done
if cast rpc debug_getRawHeader 0x0 --rpc-url "$SPIKE_HTTP" >/dev/null 2>&1 \
  || cast rpc debug_traceBlockByNumber 0x0 --rpc-url "$SPIKE_HTTP" >/dev/null 2>&1; then
  echo "  PASS debug (some method answered)"
else
  echo "  MISS debug — record as no equivalent / needs a flag"
fi
if cast rpc txpool_status --rpc-url "$SPIKE_HTTP" >/dev/null 2>&1; then
  echo "  PASS txpool_status"
else
  echo "  MISS txpool_status — record as no equivalent / needs a flag"
fi
if cast proof 0x0000000000000000000000000000000000000000 --rpc-url "$SPIKE_HTTP" >/dev/null 2>&1; then
  echo "  PASS eth_getProof (cast proof)"
else
  echo "  MISS eth_getProof — record archive/proofs flag"
fi
if cast rpc debug_setHead 0x0 --rpc-url "$SPIKE_HTTP" >/dev/null 2>&1; then
  echo "  UNEXPECTED debug_setHead answered — do not use on a keeper datadir; record for derivation"
else
  echo "  MISS debug_setHead (expected possible) — derivation mid-chain needs another path"
fi

echo
echo "spike-op-reth: PASS (block $BLOCKS hash-matched replica)"
echo "  sidecar logs: $DATA_DIR/logs/spike-op-reth.log + spike-op-reth-node.log"
echo "  kill switch: EXIT trap stops sidecar only; live op-geth untouched"
echo "  Fill tasks/spike-op-reth.md. Cloud PASS does not prove darwin/arm64."
