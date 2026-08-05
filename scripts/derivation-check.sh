#!/usr/bin/env bash
# US-061: Derivation verifier runbook — compares L1-derived block hashes to reference op-geth.
# Uses a separate sealing op-geth (own datadir/ports/JWT); reference stack is read-only.
# R2: mid-chain windows use a stopped-stack datadir copy + debug_setHead on the copy only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

SEPOLIA=0
START_L2=1
END_L2=20
CHANNEL_TX=""
JSON_OUT=""
ANCHOR_DATADIR=""
MAKE_ANCHOR=0
SCAN_FROM_GENESIS=0
REF_DATADIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sepolia) SEPOLIA=1; shift ;;
    --start-l2) START_L2="$2"; shift 2 ;;
    --end-l2) END_L2="$2"; shift 2 ;;
    --channel-tx) CHANNEL_TX="$2"; shift 2 ;;
    --json-out) JSON_OUT="$2"; shift 2 ;;
    --anchor-datadir) ANCHOR_DATADIR="$2"; shift 2 ;;
    --make-anchor) MAKE_ANCHOR=1; shift ;;
    --scan-from-genesis) SCAN_FROM_GENESIS=1; shift ;;
    -h|--help)
      cat <<'EOF'
usage: derivation-check.sh [options]

  --sepolia                 Sepolia L1 + local L2 852 (safe_l2 window)
  --start-l2 N              first L2 block inclusive (default 1)
  --end-l2 N                last L2 block inclusive (default 20)
  --channel-tx HASH         derive a single L1 batcher tx
  --json-out FILE           write JSON VerifyReport to FILE
  --anchor-datadir PATH     pre-made reference op-geth copy for mid-chain windows
  --make-anchor             copy reference datadir, then exit (reference EL MUST be
                            stopped; combine with --sepolia for the Sepolia env:
                            FORTEL2_ENV=.env.sepolia $0 --sepolia --make-anchor)
  --scan-from-genesis       allow L1 inbox scan from block 1 on large L1 chains

Mid-chain windows (start-l2 > 1) require --anchor-datadir or --make-anchor.
Copy the reference datadir while the stack is stopped (dev-sleep window is ideal).
EOF
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

REF_DATADIR="$DATA_DIR/l2/op-geth"
DEFAULT_ANCHOR="$DATA_DIR/l2/derivation-anchor-op-geth"
if [[ -z "$ANCHOR_DATADIR" ]]; then
  ANCHOR_DATADIR="$DEFAULT_ANCHOR"
fi

FROM_L1=""
# Window setup needs the live reference stack — skip it in --make-anchor mode,
# where the stack is REQUIRED to be stopped (Codex r3716308161).
if [[ "$SEPOLIA" -eq 1 && "$MAKE_ANCHOR" -eq 0 ]]; then
  wait_for_rpc "$L2_RPC_URL" "reference op-geth"
  SYNC_JSON="$(cast rpc optimism_syncStatus --rpc-url "$L2_NODE_RPC_URL")"
  SAFE_NUM="$(echo "$SYNC_JSON" | jq -r '.safe_l2.number')"
  END_L2="$SAFE_NUM"
  START_L2=$((SAFE_NUM - 49))
  if [[ "$START_L2" -lt 1 ]]; then START_L2=1; fi
  echo "Sepolia window: blocks ${START_L2}-${END_L2} (safe_l2=$SAFE_NUM)"
  echo "reference safe_l2=$(echo "$SYNC_JSON" | jq -c '.safe_l2')"
  echo "reference unsafe_l2=$(echo "$SYNC_JSON" | jq -c '.unsafe_l2')"
  SAFE_L1_ORIGIN="$(echo "$SYNC_JSON" | jq -r '.safe_l2.l1origin.number')"
  L1_LOOKBACK="${DERIVATION_L1_LOOKBACK:-300}"
  FROM_L1=$((SAFE_L1_ORIGIN - L1_LOOKBACK))
  if [[ "$FROM_L1" -lt 1 ]]; then FROM_L1=1; fi
  echo "L1 inbox scan from block $FROM_L1 (safe l1origin=$SAFE_L1_ORIGIN, lookback=$L1_LOOKBACK)"
fi

reference_el_responds() {
  curl -sf -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "$L2_RPC_URL" >/dev/null 2>&1
}

reference_el_locked() {
  [[ -f "$REF_DATADIR/geth/LOCK" ]]
}

refuse_live_anchor_copy() {
  if reference_el_responds; then
    echo "ERROR: reference op-geth RPC is up at $(redact_rpc_url "$L2_RPC_URL") — stop the stack before copying datadir" >&2
    exit 1
  fi
  # RPC-down does not prove process-down (startup/shutdown/hung HTTP still hold
  # the flock). Probe for a live process on the datadir; NEVER modify the
  # reference tree — a leftover geth/LOCK on a stopped geth is normal, and the
  # flock state does not survive the copy anyway (copy's LOCK removed below).
  if pgrep -f -- "$REF_DATADIR" >/dev/null 2>&1; then
    echo "ERROR: a process still references $REF_DATADIR (RPC down but op-geth may be starting/stopping) — stop the stack fully, then retry" >&2
    exit 1
  fi
  if reference_el_locked; then
    echo "note: geth/LOCK present at $REF_DATADIR (normal for a stopped geth); leaving reference tree untouched" >&2
  fi
}

if [[ "$MAKE_ANCHOR" -eq 1 ]]; then
  refuse_live_anchor_copy
  if [[ ! -d "$REF_DATADIR/geth/chaindata" ]]; then
    echo "ERROR: reference datadir missing at $REF_DATADIR" >&2
    exit 1
  fi
  echo "Copying reference datadir to anchor path $ANCHOR_DATADIR ..."
  rm -rf "$ANCHOR_DATADIR"
  cp -a "$REF_DATADIR" "$ANCHOR_DATADIR"
  rm -f "$ANCHOR_DATADIR/geth/LOCK"
  echo "Anchor datadir ready at $ANCHOR_DATADIR"
  # --make-anchor is copy-only: never continue into verification in the same
  # invocation (the stack is down; the window math needs it up).
  if reference_el_responds; then
    echo "ERROR: reference RPC came up during the copy — the anchor is suspect. Stop the stack and re-run --make-anchor." >&2
    exit 1
  fi
  echo "Next: restart the stack, then run derivation-check without --make-anchor."
  exit 0
fi

USE_ANCHOR=0
if [[ "$START_L2" -gt 1 ]]; then
  USE_ANCHOR=1
  if [[ ! -d "$ANCHOR_DATADIR/geth/chaindata" ]]; then
    echo "ERROR: mid-chain window start-l2=$START_L2 requires anchor datadir at $ANCHOR_DATADIR" >&2
    echo "  Stop the stack and run: $0 --make-anchor [--anchor-datadir PATH]" >&2
    exit 1
  fi
fi

# Separate sealing EL — never touches reference datadir (D-R1-1).
DERIV_EL_HTTP_PORT="${DERIV_EL_HTTP_PORT:-19645}"
DERIV_EL_AUTH_PORT="${DERIV_EL_AUTH_PORT:-19651}"
DERIV_JWT="$DATA_DIR/jwt/derivation-jwt.txt"
mkdir -p "$(dirname "$DERIV_JWT")"

if [[ "$USE_ANCHOR" -eq 1 ]]; then
  DERIV_DATADIR="$ANCHOR_DATADIR"
  echo "Using anchor datadir for sealing EL: $DERIV_DATADIR"
else
  DERIV_DATADIR="$DATA_DIR/l2/derivation-op-geth"
  mkdir -p "$DERIV_DATADIR"
  if [[ ! -d "$DERIV_DATADIR/geth/chaindata" ]]; then
    echo "Initializing sealing op-geth at $DERIV_DATADIR"
    op-geth init --datadir="$DERIV_DATADIR" --state.scheme=hash "$GENESIS"
  fi
fi

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
  echo "ERROR: reference op-node not responding at $(redact_rpc_url "$L2_NODE_RPC_URL")" >&2
  exit 1
fi
echo "reference op-node is up"

ANCHORED_HEAD=0
if [[ "$USE_ANCHOR" -eq 1 ]]; then
  HEAD_NUM=$((START_L2 - 1))
  HEAD_HEX="$(printf '0x%x' "$HEAD_NUM")"
  HEAD_HASH="$(cast block "$HEAD_NUM" --field hash --rpc-url "$L2_RPC_URL")"
  echo "Rolling sealing EL back to block $HEAD_NUM ($HEAD_HASH) via debug_setHead"
  cast rpc debug_setHead "$HEAD_HEX" --rpc-url "$SEAL_HTTP" >/dev/null
  ANCHORED_HEAD=1
fi

if [[ "$SEPOLIA" -eq 0 ]]; then
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
if [[ -n "${FROM_L1:-}" ]]; then
  VERIFY_ARGS+=(-from-l1 "$FROM_L1")
fi
if [[ "$ANCHORED_HEAD" -eq 1 ]]; then
  VERIFY_ARGS+=(-anchored-head)
fi
if [[ "$SCAN_FROM_GENESIS" -eq 1 ]]; then
  VERIFY_ARGS+=(-scan-from-genesis)
fi

echo "Running derivation verifier blocks ${START_L2}-${END_L2} ..."
if [[ -n "$JSON_OUT" ]]; then
  mkdir -p "$(dirname "$JSON_OUT")"
  VERIFY_ARGS+=(-json)
  (cd "$FORTEL2_ROOT/derivation" && go run ./cmd/verify "${VERIFY_ARGS[@]}") > "$JSON_OUT"
  echo "JSON report written to $JSON_OUT"
else
  (cd "$FORTEL2_ROOT/derivation" && go run ./cmd/verify "${VERIFY_ARGS[@]}")
fi
echo "derivation-check: PASS"
