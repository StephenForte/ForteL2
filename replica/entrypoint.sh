#!/bin/sh
# Phase 3 combined entrypoint: op-geth + op-node verifier (no sequencer).
set -eu

DATA_DIR="${DATA_DIR:-/data}"
JWT_FILE="${JWT_FILE:-$DATA_DIR/jwt.txt}"
GENESIS="${GENESIS:-/config/genesis.json}"
ROLLUP="${ROLLUP:-/config/rollup.json}"
L2_HTTP_PORT="${L2_HTTP_PORT:-8545}"
L2_AUTH_PORT="${L2_AUTH_PORT:-8551}"
L2_NODE_RPC_PORT="${L2_NODE_RPC_PORT:-9545}"

if [ -z "${L1_RPC_URL:-}" ]; then
  echo "ERROR: L1_RPC_URL is required (Sepolia HTTPS — set as Render secret)" >&2
  exit 1
fi

if [ ! -f "$GENESIS" ] || [ ! -f "$ROLLUP" ]; then
  echo "ERROR: missing $GENESIS and/or $ROLLUP — run pack-replica-artifacts.sh before build/deploy" >&2
  exit 1
fi

mkdir -p "$DATA_DIR"
if [ ! -f "$JWT_FILE" ]; then
  if [ -n "${JWT_SECRET:-}" ]; then
    printf '%s' "$JWT_SECRET" > "$JWT_FILE"
  else
    openssl rand -hex 32 > "$JWT_FILE"
  fi
  chmod 600 "$JWT_FILE"
fi

if [ ! -d "$DATA_DIR/geth" ]; then
  echo "Initializing op-geth datadir"
  geth init --datadir="$DATA_DIR" --state.scheme=hash "$GENESIS"
fi

echo "Starting op-geth (verifier EL)"
geth \
  --datadir="$DATA_DIR" \
  --http --http.addr=0.0.0.0 --http.port="$L2_HTTP_PORT" \
  --http.api=eth,net,web3,debug,txpool \
  --http.vhosts=* --http.corsdomain=* \
  --authrpc.addr=127.0.0.1 --authrpc.port="$L2_AUTH_PORT" --authrpc.vhosts=* \
  --authrpc.jwtsecret="$JWT_FILE" \
  --syncmode=full --gcmode=archive \
  --rollup.disabletxpoolgossip=true \
  --nodiscover --maxpeers=0 \
  --verbosity=3 &
GETH_PID=$!

# Wait for engine API
i=0
while [ "$i" -lt 60 ]; do
  if [ -S "$DATA_DIR/geth.ipc" ] || kill -0 "$GETH_PID" 2>/dev/null; then
    sleep 2
    break
  fi
  sleep 1
  i=$((i + 1))
done

echo "Starting op-node (verifier / L1 derivation)"
op-node \
  --l1="$L1_RPC_URL" \
  --l1.rpckind=standard \
  --l1.trustrpc=true \
  --l1.beacon.ignore=true \
  --l2="http://127.0.0.1:${L2_AUTH_PORT}" \
  --l2.jwt-secret="$JWT_FILE" \
  --l2.enginekind=geth \
  --rollup.config="$ROLLUP" \
  --sequencer.enabled=false \
  --verifier.l1-confs=1 \
  --p2p.disable=true \
  --rpc.addr=0.0.0.0 \
  --rpc.port="$L2_NODE_RPC_PORT" \
  --log.level=info &
NODE_PID=$!

term() {
  kill "$NODE_PID" "$GETH_PID" 2>/dev/null || true
  wait "$NODE_PID" "$GETH_PID" 2>/dev/null || true
}
trap term INT TERM

wait "$NODE_PID"
term
