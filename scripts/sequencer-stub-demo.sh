#!/usr/bin/env bash
# US-062: Sequencer stub demo — builds N empty L2 blocks on an isolated op-geth.
# Reference stack is READ-ONLY (never engine_*). Kill switch: stop this script
# (trap kills the stub EL) and optionally wipe $DATA_DIR/l2/sequencer-stub-op-geth.
# Reverting to stock op-node is a no-op by construction — the reference sequencer
# is never displaced (D-T6-1).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

BLOCKS=10
while [[ $# -gt 0 ]]; do
  case "$1" in
    --blocks) BLOCKS="$2"; shift 2 ;;
    -h|--help)
      echo "usage: sequencer-stub-demo.sh [--blocks N]"
      echo "  Builds N consecutive empty L2 blocks (default 10) on an isolated EL."
      echo "  Proves reference tip hash is unchanged before/after."
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ "$BLOCKS" -lt 1 ]]; then
  echo "ERROR: --blocks must be >= 1" >&2
  exit 2
fi

assert_local_rpc_urls
assert_block_times
require_bin op-geth
require_bin go
require_bin cast
require_bin jq

ROLLUP="$DEPLOY_DIR/rollup.json"
GENESIS="$DEPLOY_DIR/genesis.json"
[[ -f "$ROLLUP" ]] || { echo "missing $ROLLUP — start reference stack first (./scripts/start-all.sh)" >&2; exit 1; }
[[ -f "$GENESIS" ]] || { echo "missing $GENESIS" >&2; exit 1; }

# Isolated stub EL — separate from derivation-check ports (D-T4-1 / D-T6-1).
STUB_EL_HTTP_PORT="${STUB_EL_HTTP_PORT:-19745}"
STUB_EL_AUTH_PORT="${STUB_EL_AUTH_PORT:-19751}"
STUB_EL_P2P_PORT="${STUB_EL_P2P_PORT:-30324}"
STUB_DATADIR="$DATA_DIR/l2/sequencer-stub-op-geth"
STUB_JWT="$DATA_DIR/jwt/sequencer-stub-jwt.txt"
mkdir -p "$(dirname "$STUB_JWT")" "$STUB_DATADIR" "$DATA_DIR/logs"

if [[ ! -f "$STUB_JWT" ]]; then
  openssl rand -hex 32 > "$STUB_JWT"
fi

cleanup_stub_el() {
  if [[ -n "${STUB_PID:-}" ]] && kill -0 "$STUB_PID" 2>/dev/null; then
    kill "$STUB_PID" 2>/dev/null || true
    wait "$STUB_PID" 2>/dev/null || true
  fi
}
trap cleanup_stub_el EXIT

# --- Reference tip BEFORE (read-only proof) ---
wait_for_rpc "$L2_RPC_URL" "reference op-geth"
REF_TIP_BEFORE="$(cast block latest --rpc-url "$L2_RPC_URL" --json)"
REF_NUM_BEFORE="$(echo "$REF_TIP_BEFORE" | jq -r '.number')"
REF_HASH_BEFORE="$(echo "$REF_TIP_BEFORE" | jq -r '.hash')"
echo "reference tip BEFORE: num=$REF_NUM_BEFORE hash=$REF_HASH_BEFORE"

# Fresh stub datadir each demo run (kill switch = wipe this tree).
if [[ -d "$STUB_DATADIR/geth" ]]; then
  echo "Wiping prior stub EL datadir at $STUB_DATADIR"
  rm -rf "$STUB_DATADIR"
  mkdir -p "$STUB_DATADIR"
fi

echo "Initializing stub op-geth at $STUB_DATADIR"
op-geth init --datadir="$STUB_DATADIR" --state.scheme=hash "$GENESIS"

echo "Starting stub op-geth (http :$STUB_EL_HTTP_PORT auth :$STUB_EL_AUTH_PORT p2p :$STUB_EL_P2P_PORT)"
op-geth \
  --datadir="$STUB_DATADIR" \
  --port="$STUB_EL_P2P_PORT" \
  --http --http.addr=127.0.0.1 --http.port="$STUB_EL_HTTP_PORT" \
  --http.api=eth,net,web3,debug \
  --authrpc.addr=127.0.0.1 --authrpc.port="$STUB_EL_AUTH_PORT" \
  --authrpc.jwtsecret="$STUB_JWT" \
  --syncmode=full --gcmode=archive \
  --nodiscover --maxpeers=0 \
  --rollup.disabletxpoolgossip=true \
  >>"$DATA_DIR/logs/sequencer-stub-op-geth.log" 2>&1 &
STUB_PID=$!

STUB_HTTP="http://127.0.0.1:${STUB_EL_HTTP_PORT}"
STUB_AUTH="http://127.0.0.1:${STUB_EL_AUTH_PORT}"
wait_for_rpc "$STUB_HTTP" "stub op-geth"

echo "Running sequencer-stub --blocks $BLOCKS ..."
(cd "$FORTEL2_ROOT/derivation" && go run ./cmd/sequencer-stub \
  -rollup "$ROLLUP" \
  -l1 "$L1_RPC_URL" \
  -seal-auth "$STUB_AUTH" \
  -seal-http "$STUB_HTTP" \
  -jwt "$STUB_JWT" \
  -blocks "$BLOCKS")

# --- Reference tip AFTER ---
REF_TIP_AFTER="$(cast block latest --rpc-url "$L2_RPC_URL" --json)"
REF_NUM_AFTER="$(echo "$REF_TIP_AFTER" | jq -r '.number')"
REF_HASH_AFTER="$(echo "$REF_TIP_AFTER" | jq -r '.hash')"
echo "reference tip AFTER:  num=$REF_NUM_AFTER hash=$REF_HASH_AFTER"

if [[ "$REF_HASH_BEFORE" != "$REF_HASH_AFTER" ]]; then
  # Tip may advance under the live sequencer — prove the BEFORE hash still exists
  # unchanged (stub never mutated reference state).
  STILL="$(cast block "$REF_NUM_BEFORE" --rpc-url "$L2_RPC_URL" --json | jq -r '.hash')"
  if [[ "$STILL" != "$REF_HASH_BEFORE" ]]; then
    echo "ERROR: reference block $REF_NUM_BEFORE hash changed ($REF_HASH_BEFORE -> $STILL) — stub must not touch reference EL" >&2
    exit 1
  fi
  echo "reference-tip proof: block $REF_NUM_BEFORE hash unchanged ($REF_HASH_BEFORE); tip advanced naturally under stock sequencer to $REF_NUM_AFTER"
else
  echo "reference-tip proof: tip hash unchanged ($REF_HASH_BEFORE)"
fi

echo
echo "Kill switch: this script's EXIT trap stops the stub EL."
echo "  Wipe isolated state:  rm -rf \"$STUB_DATADIR\""
echo "  Stock op-node: untouched (never displaced) — no restart required."
echo "sequencer-stub-demo: PASS"
