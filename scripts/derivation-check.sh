#!/usr/bin/env bash
# US-061: Derivation verifier runbook — compares L1-derived block hashes to reference op-geth.
# Uses a separate sealing op-geth (own datadir/ports/JWT); reference stack is read-only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

SEPOLIA=0
START_L2=1
END_L2=20
CHANNEL_TX=""
JSON_OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sepolia) SEPOLIA=1; shift ;;
    --start-l2) START_L2="$2"; shift 2 ;;
    --end-l2) END_L2="$2"; shift 2 ;;
    --channel-tx) CHANNEL_TX="$2"; shift 2 ;;
    --json-out) JSON_OUT="$2"; shift 2 ;;
    -h|--help)
      echo "usage: derivation-check.sh [--sepolia] [--start-l2 N] [--end-l2 N] [--channel-tx HASH] [--json-out FILE]"
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ "$SEPOLIA" -eq 1 ]]; then
  require_sepolia_env
  assert_sepolia_rpc_urls
  assert_l2_loopback_urls
else
  assert_local_rpc_urls
fi

require_bin op-geth
require_bin go

ROLLUP="$DEPLOY_DIR/rollup.json"
GENESIS="$DEPLOY_DIR/genesis.json"
[[ -f "$ROLLUP" ]] || { echo "missing $ROLLUP — start reference stack first" >&2; exit 1; }
[[ -f "$GENESIS" ]] || { echo "missing $GENESIS" >&2; exit 1; }

# Separate sealing EL — never touches reference datadir (D-R1-1).
DERIV_EL_HTTP_PORT="${DERIV_EL_HTTP_PORT:-19645}"
DERIV_EL_AUTH_PORT="${DERIV_EL_AUTH_PORT:-19651}"
DERIV_DATADIR="$DATA_DIR/l2/derivation-op-geth"
DERIV_JWT="$DATA_DIR/jwt/derivation-jwt.txt"
mkdir -p "$(dirname "$DERIV_JWT")" "$DERIV_DATADIR"

if [[ ! -f "$DERIV_JWT" ]]; then
  openssl rand -hex 32 > "$DERIV_JWT"
fi

cleanup_deriv_el() {
  if [[ -n "${DERIV_PID:-}" ]] && kill -0 "$DERIV_PID" 2>/dev/null; then
    kill "$DERIV_PID" 2>/dev/null || true
    wait "$DERIV_PID" 2>/dev/null || true
  fi
}
trap cleanup_deriv_el EXIT

if [[ ! -d "$DERIV_DATADIR/geth/chaindata" ]]; then
  echo "Initializing sealing op-geth at $DERIV_DATADIR"
  op-geth init --datadir="$DERIV_DATADIR" --state.scheme=hash "$GENESIS"
fi

echo "Starting sealing op-geth (http :$DERIV_EL_HTTP_PORT auth :$DERIV_EL_AUTH_PORT)"
op-geth \
  --datadir="$DERIV_DATADIR" \
  --port=30323 \
  --http --http.addr=127.0.0.1 --http.port="$DERIV_EL_HTTP_PORT" \
  --http.api=eth,net,web3,debug \
  --authrpc.addr=127.0.0.1 --authrpc.port="$DERIV_EL_AUTH_PORT" \
  --authrpc.jwtsecret="$DERIV_JWT" \
  --syncmode=full --gcmode=archive \
  --nodiscover --maxpeers=0 \
  --rollup.disabletxpoolgossip=true \
  >>"$DATA_DIR/logs/derivation-op-geth.log" 2>&1 &
DERIV_PID=$!

SEAL_HTTP="http://127.0.0.1:${DERIV_EL_HTTP_PORT}"
SEAL_AUTH="http://127.0.0.1:${DERIV_EL_AUTH_PORT}"
wait_for_rpc "$SEAL_HTTP" "sealing op-geth"

# Reference stack health (read-only)
wait_for_rpc "$L2_RPC_URL" "reference op-geth"
if ! cast rpc optimism_syncStatus --rpc-url "$L2_NODE_RPC_URL" >/dev/null 2>&1; then
  echo "ERROR: reference op-node not responding at $L2_NODE_RPC_URL" >&2
  exit 1
fi
echo "reference op-node is up"

if [[ "$SEPOLIA" -eq 1 ]]; then
  SYNC_JSON="$(cast rpc optimism_syncStatus --rpc-url "$L2_NODE_RPC_URL")"
  SAFE_NUM="$(echo "$SYNC_JSON" | jq -r '.safe_l2.number')"
  END_L2="$SAFE_NUM"
  START_L2=$((SAFE_NUM - 49))
  if [[ "$START_L2" -lt 1 ]]; then START_L2=1; fi
  echo "Sepolia window: blocks $START_L2–$END_L2 (safe_l2=$SAFE_NUM)"
  echo "reference safe_l2=$(echo "$SYNC_JSON" | jq -c '.safe_l2')"
  echo "reference unsafe_l2=$(echo "$SYNC_JSON" | jq -c '.unsafe_l2')"
else
  SYNC_JSON="$(cast rpc optimism_syncStatus --rpc-url "$L2_NODE_RPC_URL" 2>/dev/null || echo '{}')"
  if [[ -n "$SYNC_JSON" && "$SYNC_JSON" != "{}" ]]; then
    echo "reference safe_l2=$(echo "$SYNC_JSON" | jq -c '.safe_l2 // empty')"
    echo "reference unsafe_l2=$(echo "$SYNC_JSON" | jq -c '.unsafe_l2 // empty')"
  fi
fi

VERIFY_ARGS=(
  -rollup "$ROLLUP"
  -l1 "$L1_RPC_URL"
  -ref-l2 "$L2_RPC_URL"
  -ref-node "$L2_NODE_RPC_URL"
  -seal-auth "$SEAL_AUTH"
  -seal-http "$SEAL_HTTP"
  -jwt "$DERIV_JWT"
  -start-l2 "$START_L2"
  -end-l2 "$END_L2"
)
if [[ -n "$CHANNEL_TX" ]]; then
  VERIFY_ARGS+=(-channel-tx "$CHANNEL_TX")
fi

echo "Running derivation verifier blocks $START_L2–$END_L2 ..."
if [[ -n "$JSON_OUT" ]]; then
  # -json puts ONLY the report on stdout (human lines go to stderr) — safe to capture.
  mkdir -p "$(dirname "$JSON_OUT")"
  VERIFY_ARGS+=(-json)
  (cd "$FORTEL2_ROOT/derivation" && go run ./cmd/verify "${VERIFY_ARGS[@]}") > "$JSON_OUT"
  echo "JSON report written to $JSON_OUT"
else
  (cd "$FORTEL2_ROOT/derivation" && go run ./cmd/verify "${VERIFY_ARGS[@]}")
fi
echo "derivation-check: PASS"
