#!/usr/bin/env bash
# Phase 2c: op-proposer against Sepolia DisputeGameFactory.
# Default: stock op-proposer. Optional US-054 demo: USE_CUSTOM_PROPOSER=1 + CONFIRM_CUSTOM_PROPOSER_SEPOLIA=1.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin jq
require_sepolia_env
refuse_foundry_defaults_unless_local_l2 "${PROPOSER_PRIVATE_KEY:-}" "PROPOSER_PRIVATE_KEY"
require_min_balance_eth "$PROPOSER_ADDRESS" "${SEPOLIA_PROPOSER_MIN_ETH:-0.15}" "PROPOSER"

DEPLOYMENTS="$(deployments_json_path)"
GAME_FACTORY=$(jq -r '.DisputeGameFactoryProxy // .disputeGameFactoryProxy // empty' "$DEPLOYMENTS")
if [[ -z "$GAME_FACTORY" || "$GAME_FACTORY" == "null" ]]; then
  echo "ERROR: DisputeGameFactoryProxy not found in $DEPLOYMENTS" >&2
  jq 'keys' "$DEPLOYMENTS" || true
  exit 1
fi

# Credit-budget defaults. Use SEPOLIA_PROPOSER_INTERVAL (default 1h; D-0074) — do not inherit
# legacy PROPOSER_INTERVAL=12s from older .env.sepolia templates (Phase 1 Anvil knob).
# Pin txmgr receipt/rebroadcast (upstream defaults are 12s) so in-flight fee bumps
# do not outpace the batcher's credit-budget cadence.
PROPOSER_INTERVAL="${SEPOLIA_PROPOSER_INTERVAL:-1h}"
PROPOSER_POLL="${SEPOLIA_PROPOSER_POLL_INTERVAL:-12s}"
PROPOSER_RECEIPT_QUERY="${SEPOLIA_PROPOSER_TXMGR_RECEIPT_QUERY_INTERVAL:-36s}"
PROPOSER_REBROADCAST="${SEPOLIA_PROPOSER_TXMGR_REBROADCAST_INTERVAL:-36s}"
PROPOSER_RESUBMISSION="${SEPOLIA_PROPOSER_RESUBMISSION_TIMEOUT:-72s}"

# Init-path 429s kill the process (D-0107 class); start_bg's 0.3s check is too
# short for Driver version/batch fetch. Same grace/retry as the challenger so
# a 03:00 wake colliding with resolve-games on the shared QuickNode 50/s cap
# does not leave a partial stack. Funding (require_min_balance_eth) stays
# above this loop — permanent refusals must not be retried.
PROPOSER_START_GRACE_SEC="${PROPOSER_START_GRACE_SEC:-15}"
PROPOSER_START_ATTEMPTS="${PROPOSER_START_ATTEMPTS:-3}"
validate_proposer_start_retry_env() {
  if ! [[ "${PROPOSER_START_GRACE_SEC:-}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: PROPOSER_START_GRACE_SEC must be a positive integer (got ${PROPOSER_START_GRACE_SEC:-})" >&2
    return 1
  fi
  if ! [[ "${PROPOSER_START_ATTEMPTS:-}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: PROPOSER_START_ATTEMPTS must be a positive integer (got ${PROPOSER_START_ATTEMPTS:-})" >&2
    return 1
  fi
}
validate_proposer_start_retry_env

wait_for_rpc "$L1_RPC_URL" "L1 Sepolia"
wait_for_rpc "$L2_RPC_URL" "L2"

# kill -0 on a recycled PID can look alive. Require the live process cmdline
# to still name the stock or custom proposer binary (pidfile is always op-proposer).
proposer_process_alive() {
  local pidfile="$PID_DIR/op-proposer.pid"
  local pid cmd
  [[ -f "$pidfile" ]] || return 1
  pid="$(tr -d '[:space:]' < "$pidfile")"
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmd="$(ps -p "$pid" -o args= 2>/dev/null || true)"
  [[ "$cmd" == *op-proposer* || "$cmd" == *fortel2-proposer* ]]
}

# Clear a dead/stale pidfile so start_bg will relaunch (it no-ops when kill -0
# succeeds on the pidfile contents).
proposer_clear_dead_pidfile() {
  local pidfile="$PID_DIR/op-proposer.pid"
  local pid
  [[ -f "$pidfile" ]] || return 0
  pid="$(tr -d '[:space:]' < "$pidfile")"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && proposer_process_alive; then
    return 0
  fi
  rm -f "$pidfile"
}

# Bounded post-start_bg retry for transient init RPC failures (429). Pre-start
# config gates (including require_min_balance_eth) are outside this loop on
# purpose. start_bg's return code is not liveness — the death happens after
# it returns; wait the grace and check the pid.
start_proposer_with_retry() {
  local attempt=1
  local max_attempts="$PROPOSER_START_ATTEMPTS"
  local grace="$PROPOSER_START_GRACE_SEC"
  local backoff=5
  local start_rc

  while (( attempt <= max_attempts )); do
    proposer_clear_dead_pidfile
    if proposer_process_alive; then
      echo "op-proposer already running (pid $(tr -d '[:space:]' < "$PID_DIR/op-proposer.pid"))"
      return 0
    fi
    echo "op-proposer start attempt ${attempt}/${max_attempts} (grace ${grace}s)"
    start_rc=0
    start_bg op-proposer "${proposer_cmd[@]}" || start_rc=$?
    if (( start_rc != 0 )); then
      echo "WARN: start_bg op-proposer failed immediately (attempt ${attempt}/${max_attempts}, rc=${start_rc})" >&2
    else
      sleep "$grace"
      if proposer_process_alive; then
        echo "op-proposer survived ${grace}s post-start grace"
        return 0
      fi
      echo "WARN: op-proposer died within ${grace}s grace (attempt ${attempt}/${max_attempts})" >&2
      proposer_clear_dead_pidfile
    fi
    if (( attempt >= max_attempts )); then
      break
    fi
    echo "Retrying op-proposer in ${backoff}s…" >&2
    sleep "$backoff"
    backoff=$((backoff * 2))
    attempt=$((attempt + 1))
  done

  echo "ERROR: op-proposer failed to stay up after ${max_attempts} attempts" >&2
  echo "--- tail of ${LOG_DIR}/op-proposer.log ---" >&2
  if [[ -f "$LOG_DIR/op-proposer.log" ]]; then
    tail -n 50 "$LOG_DIR/op-proposer.log" >&2 || true
  else
    echo "(no log file at $LOG_DIR/op-proposer.log)" >&2
  fi
  return 1
}

if [[ "${USE_CUSTOM_PROPOSER:-0}" == "1" ]]; then
  if [[ "${CONFIRM_CUSTOM_PROPOSER_SEPOLIA:-}" != "1" ]]; then
    echo "ERROR: Sepolia custom proposer is opt-in only." >&2
    echo "  Set CONFIRM_CUSTOM_PROPOSER_SEPOLIA=1 after reading proposer/README.md (US-054)." >&2
    echo "  Default remains stock: FORTEL2_ENV=.env.sepolia ./scripts/06-start-proposer-sepolia.sh" >&2
    exit 1
  fi
  # Build before stopping stock so a failed go build leaves Sepolia proposals running.
  require_bin go
  CUSTOM_PROPOSER_BIN="${CUSTOM_PROPOSER_BIN:-$BIN_DIR/fortel2-proposer}"
  mkdir -p "$(dirname "$CUSTOM_PROPOSER_BIN")"
  build_tmp="${CUSTOM_PROPOSER_BIN}.building.$$"
  cleanup_build_tmp() { rm -f "$build_tmp"; }
  trap cleanup_build_tmp EXIT
  echo "Building custom proposer → $build_tmp"
  (cd "$FORTEL2_ROOT/proposer" && go build -o "$build_tmp" ./cmd/propose-loop)
  mv -f "$build_tmp" "$CUSTOM_PROPOSER_BIN"
  trap - EXIT

  # start_bg returns 0 when the shared op-proposer pid is already alive — stop stock
  # (or a prior custom) first so we actually launch fortel2-proposer, not a false "started".
  if is_running op-proposer; then
    echo "Stopping existing op-proposer (pid $(cat "$PID_DIR/op-proposer.pid")) before custom start…"
    stop_bg op-proposer
  fi
  CUSTOM_POLL="${CUSTOM_PROPOSER_POLL_INTERVAL:-$PROPOSER_POLL}"
  CUSTOM_INTERVAL="${CUSTOM_PROPOSER_INTERVAL:-$PROPOSER_INTERVAL}"
  CUSTOM_CONFS="${CUSTOM_PROPOSER_CONFIRMATIONS:-2}"
  CUSTOM_RECEIPT_TIMEOUT="${CUSTOM_PROPOSER_RECEIPT_TIMEOUT:-10m}"
  echo "WARN: US-054 Sepolia custom-proposer demo — max ~15 min; abort → stock script." >&2
  proposer_cmd=(
    "$CUSTOM_PROPOSER_BIN"
    -l1 "$L1_RPC_URL"
    -rollup "$L2_NODE_RPC_URL"
    -factory "$GAME_FACTORY"
    -game-type "${PROPOSER_GAME_TYPE}"
    -poll "$CUSTOM_POLL"
    -proposal-interval "$CUSTOM_INTERVAL"
    -allow-non-finalized=true
    -confirmations "$CUSTOM_CONFS"
    -receipt-timeout "$CUSTOM_RECEIPT_TIMEOUT"
  )
  start_proposer_with_retry
  echo "Custom Sepolia proposer started (poll=${CUSTOM_POLL}, interval=${CUSTOM_INTERVAL}, confirmations=${CUSTOM_CONFS}). Revert: stop pid, then stock 06-start-proposer-sepolia.sh"
else
  require_bin op-proposer
  proposer_cmd=(
    op-proposer
    --l1-eth-rpc="$L1_RPC_URL"
    --rollup-rpc="$L2_NODE_RPC_URL"
    --private-key="${PROPOSER_PRIVATE_KEY}"
    --game-factory-address="$GAME_FACTORY"
    --game-type="${PROPOSER_GAME_TYPE}"
    --proposal-interval="${PROPOSER_INTERVAL}"
    --allow-non-finalized=true
    --poll-interval="${PROPOSER_POLL}"
    --resubmission-timeout="${PROPOSER_RESUBMISSION}"
    --txmgr.receipt-query-interval="${PROPOSER_RECEIPT_QUERY}"
    --txmgr.rebroadcast-interval="${PROPOSER_REBROADCAST}"
    --rpc.addr=127.0.0.1
    --rpc.port="${PROPOSER_RPC_PORT}"
    --log.level=info
  )
  start_proposer_with_retry

  echo "Sepolia proposer started against DisputeGameFactory=$GAME_FACTORY game-type=$PROPOSER_GAME_TYPE interval=${PROPOSER_INTERVAL} poll=${PROPOSER_POLL} txmgr receipt/rebroadcast=${PROPOSER_RECEIPT_QUERY}/${PROPOSER_REBROADCAST}"
  echo "Known-good: 'created dispute game' or 'Proposing'"
fi
