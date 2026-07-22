#!/usr/bin/env bash
# Guided live demo: verify stack health, print a short talk track, serve guestbook
# + pipeline viewer on loopback, open URLs (macOS). Does not start the OP Stack.
#
# Usage:
#   ./scripts/demo-live.sh                 # infer from FORTEL2_ENV / L2_CHAIN_ID
#   ./scripts/demo-live.sh --local         # Phase 1 (.env / chain 901)
#   ./scripts/demo-live.sh --sepolia       # forces FORTEL2_ENV=.env.sepolia if unset
#
# Prerequisites:
#   Local:   ./scripts/start-all.sh
#   Sepolia: FORTEL2_ENV=.env.sepolia ./scripts/start-all-sepolia.sh
#
# Ctrl-C stops only HTTP servers this script started (not the chain).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE_FLAG=""
for arg in "$@"; do
  case "$arg" in
    --local) MODE_FLAG=local ;;
    --sepolia) MODE_FLAG=sepolia ;;
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} /^set -euo/{exit}' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (try --local, --sepolia, or --help)" >&2
      exit 1
      ;;
  esac
done

if [[ "$MODE_FLAG" == "sepolia" && -z "${FORTEL2_ENV:-}" ]]; then
  export FORTEL2_ENV=.env.sepolia
fi
if [[ "$MODE_FLAG" == "local" && -n "${FORTEL2_ENV:-}" && "$FORTEL2_ENV" == *sepolia* ]]; then
  echo "ERROR: --local conflicts with FORTEL2_ENV=$FORTEL2_ENV" >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

if [[ "$MODE_FLAG" == "sepolia" ]]; then
  require_sepolia_env
elif [[ "$MODE_FLAG" == "local" ]]; then
  if [[ "${L2_CHAIN_ID:-}" == "852" ]]; then
    echo "ERROR: --local but L2_CHAIN_ID=852 — unset FORTEL2_ENV or use --sepolia" >&2
    exit 1
  fi
  assert_local_rpc_urls
elif [[ "${L2_CHAIN_ID:-}" == "852" ]]; then
  require_sepolia_env
else
  assert_local_rpc_urls
fi

IS_SEPOLIA=0
if [[ "${L2_CHAIN_ID:-}" == "852" ]]; then
  IS_SEPOLIA=1
fi

DAPP_PORT="${DAPP_HTTP_PORT:-8080}"
VIEWER_PORT="${VIEWER_HTTP_PORT:-8081}"
DAPP_URL="http://127.0.0.1:${DAPP_PORT}/"
VIEWER_URL="http://127.0.0.1:${VIEWER_PORT}/"

# Pids of HTTP children we started (empty if ports were already in use).
STARTED_PIDS=()

port_listening() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
  else
    return 1
  fi
}

cleanup() {
  local pid
  for pid in "${STARTED_PIDS[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT INT TERM

run_health() {
  require_bin cast
  require_bin jq
  local fail=0
  echo "=== Health ==="
  if (( IS_SEPOLIA )); then
    echo "Mode: Sepolia (L1=${L1_CHAIN_ID} L2=${L2_CHAIN_ID})"
    echo "L1 RPC: $(redact_rpc_url "$L1_RPC_URL")"
  else
    echo "Mode: local Anvil (L1=${L1_CHAIN_ID} L2=${L2_CHAIN_ID})"
  fi

  local l1_block l2_block l1_chain l2_chain
  if l1_block=$(cast block-number --rpc-url "$L1_RPC_URL" 2>/dev/null); then
    l1_chain=$(cast chain-id --rpc-url "$L1_RPC_URL" 2>/dev/null || echo "")
    if [[ "$l1_chain" == "${L1_CHAIN_ID}" ]]; then
      echo "  PASS  L1 block=$l1_block chain=$l1_chain"
    else
      echo "  FAIL  L1 chain-id=$l1_chain expected ${L1_CHAIN_ID}" >&2
      fail=1
    fi
  else
    echo "  FAIL  L1 RPC unreachable ($(redact_rpc_url "$L1_RPC_URL"))" >&2
    fail=1
  fi

  if l2_block=$(cast block-number --rpc-url "$L2_RPC_URL" 2>/dev/null); then
    l2_chain=$(cast chain-id --rpc-url "$L2_RPC_URL" 2>/dev/null || echo "")
    if [[ "$l2_chain" == "${L2_CHAIN_ID}" ]]; then
      echo "  PASS  L2 block=$l2_block chain=$l2_chain"
    else
      echo "  FAIL  L2 chain-id=$l2_chain expected ${L2_CHAIN_ID}" >&2
      fail=1
    fi
  else
    echo "  FAIL  L2 RPC unreachable at $L2_RPC_URL" >&2
    fail=1
  fi

  if cast rpc optimism_syncStatus --rpc-url "$L2_NODE_RPC_URL" >/tmp/fortel2-demo-live-$$.json 2>/dev/null; then
    local unsafe safe
    unsafe=$(jq -r '.unsafe_l2.number // empty' /tmp/fortel2-demo-live-$$.json)
    safe=$(jq -r '.safe_l2.number // empty' /tmp/fortel2-demo-live-$$.json)
    rm -f /tmp/fortel2-demo-live-$$.json
    if [[ -n "$unsafe" && -n "$safe" ]]; then
      echo "  PASS  syncStatus unsafe=$unsafe safe=$safe (lag=$((unsafe - safe)))"
    else
      echo "  FAIL  optimism_syncStatus missing heads" >&2
      fail=1
    fi
  else
    echo "  FAIL  optimism_syncStatus at $L2_NODE_RPC_URL" >&2
    fail=1
  fi

  if (( fail )); then
    echo >&2
    if (( IS_SEPOLIA )); then
      echo "Stack not ready. Try: FORTEL2_ENV=.env.sepolia ./scripts/start-all-sepolia.sh" >&2
    else
      echo "Stack not ready. Try: ./scripts/start-all.sh && ./scripts/status.sh" >&2
    fi
    exit 1
  fi
  echo
}

print_talk_track() {
  cat <<EOF
=== Talk track ===
  Sequencer  — L2 unsafe / safe / finalized heads (local op-node + L2).
  Batcher    — L2 data posted to L1 batch inbox (needs L1 RPC).
  Proposer   — dispute games / output roots on L1 factory.
  Aggregate  — recent L2 tx throughput + mempool pending/queued.

  Guestbook (:${DAPP_PORT}) is the write-path demo (Phase 1 MetaMask).
  Pipeline viewer (:${VIEWER_PORT}) is the ops surface — not a block explorer.
EOF
  if (( IS_SEPOLIA )); then
    cat <<'EOF'
  Sepolia tip: close the viewer when idle — Batcher/Proposer burn L1 API credits.
  Deposit: FORTEL2_ENV=.env.sepolia ./scripts/deposit-eth-sepolia.sh
EOF
  else
    cat <<'EOF'
  Local tip: after a reset, MetaMask → Delete activity and nonce data if txs stick.
  Bridge: ./scripts/deposit-eth.sh then withdraw-initiate / prove / finalize.
EOF
  fi
  echo
}

ensure_http() {
  local label="$1"
  local port="$2"
  local script="$3"
  if port_listening "$port"; then
    echo "  ·     $label already on :$port — reusing"
    return 0
  fi
  echo "  ·     starting $label on :$port"
  # Background only — not scripts/lib.sh start_bg (privileged).
  if [[ -n "${FORTEL2_ENV:-}" ]]; then
    FORTEL2_ENV="$FORTEL2_ENV" "$script" >/tmp/fortel2-${label}-$$.log 2>&1 &
  else
    "$script" >/tmp/fortel2-${label}-$$.log 2>&1 &
  fi
  STARTED_PIDS+=("$!")
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if port_listening "$port"; then
      echo "  PASS  $label listening on :$port"
      return 0
    fi
    sleep 0.5
  done
  echo "  FAIL  $label did not bind :$port (see /tmp/fortel2-${label}-$$.log)" >&2
  exit 1
}

open_urls() {
  echo "=== URLs ==="
  echo "  Guestbook: $DAPP_URL"
  echo "  Viewer:    $VIEWER_URL"
  if [[ "$(uname -s)" == "Darwin" ]] && command -v open >/dev/null 2>&1; then
    open "$DAPP_URL" "$VIEWER_URL" || true
    echo "  ·     opened in default browser"
  else
    echo "  ·     open the URLs above in a browser (loopback only)"
  fi
  echo
}

run_health
print_talk_track

echo "=== HTTP servers ==="
ensure_http "dapp" "$DAPP_PORT" "$SCRIPT_DIR/serve-dapp.sh"
ensure_http "viewer" "$VIEWER_PORT" "$SCRIPT_DIR/serve-viewer.sh"
echo

open_urls

echo "Demo live — Ctrl-C stops HTTP started by this script (chain keeps running)."
if (( IS_SEPOLIA )); then
  echo "Full checklist: FORTEL2_ENV=.env.sepolia ./scripts/demo-checklist.sh"
else
  echo "Full checklist: ./scripts/demo-checklist.sh"
fi
echo

# Keep foreground so trap cleanup runs on Ctrl-C.
if ((${#STARTED_PIDS[@]})); then
  wait "${STARTED_PIDS[@]}" || true
else
  echo "Both ports were already served — exiting (nothing to wait on)."
fi
