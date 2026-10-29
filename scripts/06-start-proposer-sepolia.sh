#!/usr/bin/env bash
# Phase 2c: op-proposer against Sepolia DisputeGameFactory.
# Default: stock op-proposer. Optional US-054 demo: USE_CUSTOM_PROPOSER=1 + CONFIRM_CUSTOM_PROPOSER_SEPOLIA=1.
#
# PROPOSER_GAME_TYPE=8 (today): --rollup-rpc, no --superroot-rpcs. Unchanged argv.
# PROPOSER_GAME_TYPE=9 (OPU-4 cutover, one variable in .env.sepolia): --superroot-rpcs
# set to the loopback op-node and no --rollup-rpc. op-proposer v1.17.0 accepts
# the pair for type 9 (it is not in postInteropGameTypes) and would post an
# output root as rootClaim; SuperFaultDisputeGame.initialize then reverts
# BadExtraData. This script is the guard.
# The custom proposer (USE_CUSTOM_PROPOSER=1) refuses type 9; that port is OPU-3b.
#
# Fork rehearsal only (never edit .env.sepolia):
#   FORTEL2_ISOLATED_DATA_DIR  pid/log dir; must stay off the live DATA_DIR
#   FORTEL2_FORK_L1_RPC_URL    loopback Anvil fork; replaces L1_RPC_URL after source
#   FORTEL2_PROPOSER_GAME_TYPE / FORTEL2_PROPOSER_INTERVAL / FORTEL2_PROPOSER_RPC_PORT
#     override the env-file values after source
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Captured before lib.sh sources the env file, which assigns DATA_DIR and L1_RPC_URL.
_FORTEL2_ISOLATED_DATA_DIR="${FORTEL2_ISOLATED_DATA_DIR:-}"
_FORTEL2_FORK_L1_RPC_URL="${FORTEL2_FORK_L1_RPC_URL:-}"
_FORTEL2_PROPOSER_GAME_TYPE="${FORTEL2_PROPOSER_GAME_TYPE:-}"
_FORTEL2_PROPOSER_INTERVAL="${FORTEL2_PROPOSER_INTERVAL:-}"
_FORTEL2_PROPOSER_POLL="${FORTEL2_PROPOSER_POLL:-}"
_FORTEL2_PROPOSER_RPC_PORT="${FORTEL2_PROPOSER_RPC_PORT:-}"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

if [[ -n "$_FORTEL2_ISOLATED_DATA_DIR" ]]; then
  restore_caller_data_dir "$_FORTEL2_ISOLATED_DATA_DIR"
  case "$PID_DIR" in
    "$_FORTEL2_ISOLATED_DATA_DIR"/*) ;;
    *)
      echo "ERROR: isolated PID_DIR=$PID_DIR is not under FORTEL2_ISOLATED_DATA_DIR" >&2
      exit 1
      ;;
  esac
  echo "isolated PID_DIR=$PID_DIR"
fi
if [[ -n "$_FORTEL2_FORK_L1_RPC_URL" ]]; then
  assert_loopback_url "$_FORTEL2_FORK_L1_RPC_URL" "FORTEL2_FORK_L1_RPC_URL"
  restore_caller_l1_rpc_url "$_FORTEL2_FORK_L1_RPC_URL"
fi
if [[ -n "$_FORTEL2_PROPOSER_GAME_TYPE" ]]; then
  PROPOSER_GAME_TYPE="$_FORTEL2_PROPOSER_GAME_TYPE"
fi
if [[ -n "$_FORTEL2_PROPOSER_INTERVAL" ]]; then
  SEPOLIA_PROPOSER_INTERVAL="$_FORTEL2_PROPOSER_INTERVAL"
fi
if [[ -n "$_FORTEL2_PROPOSER_POLL" ]]; then
  SEPOLIA_PROPOSER_POLL_INTERVAL="$_FORTEL2_PROPOSER_POLL"
fi
if [[ -n "$_FORTEL2_PROPOSER_RPC_PORT" ]]; then
  PROPOSER_RPC_PORT="$_FORTEL2_PROPOSER_RPC_PORT"
fi

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

# Credit-budget defaults. Use SEPOLIA_PROPOSER_INTERVAL (default 8h; D-0133 supersedes
# D-0074’s 1h — each game is permanent scan load for resolve-games and any challenger) — do not inherit
# legacy PROPOSER_INTERVAL=12s from older .env.sepolia templates (Phase 1 Anvil knob).
# Pin txmgr receipt/rebroadcast (upstream defaults are 12s) so in-flight fee bumps
# do not outpace the batcher's credit-budget cadence.
PROPOSER_INTERVAL="${SEPOLIA_PROPOSER_INTERVAL:-8h}"
PROPOSER_POLL="${SEPOLIA_PROPOSER_POLL_INTERVAL:-120s}"
PROPOSER_RECEIPT_QUERY="${SEPOLIA_PROPOSER_TXMGR_RECEIPT_QUERY_INTERVAL:-36s}"
PROPOSER_REBROADCAST="${SEPOLIA_PROPOSER_TXMGR_REBROADCAST_INTERVAL:-36s}"
PROPOSER_RESUBMISSION="${SEPOLIA_PROPOSER_RESUBMISSION_TIMEOUT:-72s}"

# Init-path 429s kill the process (D-0107 class); start_bg's 0.3s check is too
# short for Driver version/batch fetch. Same grace/retry as the challenger so
# a 03:00 wake colliding with resolve-games on the shared QuickNode 50/s cap
# does not leave a partial stack. Funding (require_min_balance_eth) stays
# above this loop — permanent refusals must not be retried.
# Unset-only defaults (${VAR-default}, not ${VAR:-default}): an explicit empty
# PROPOSER_START_* in the env must be refused, not silently replaced with 15/3.
apply_proposer_start_retry_defaults() {
  PROPOSER_START_GRACE_SEC="${PROPOSER_START_GRACE_SEC-15}"
  PROPOSER_START_ATTEMPTS="${PROPOSER_START_ATTEMPTS-3}"
  PROPOSER_START_BACKOFF_SEC="${PROPOSER_START_BACKOFF_SEC-5}"
}
validate_proposer_start_retry_env() {
  if ! [[ "${PROPOSER_START_GRACE_SEC:-}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: PROPOSER_START_GRACE_SEC must be a positive integer (got ${PROPOSER_START_GRACE_SEC:-})" >&2
    return 1
  fi
  if ! [[ "${PROPOSER_START_ATTEMPTS:-}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: PROPOSER_START_ATTEMPTS must be a positive integer (got ${PROPOSER_START_ATTEMPTS:-})" >&2
    return 1
  fi
  if ! [[ "${PROPOSER_START_BACKOFF_SEC:-}" =~ ^(0|[1-9][0-9]*)$ ]]; then
    echo "ERROR: PROPOSER_START_BACKOFF_SEC must be a non-negative integer (got ${PROPOSER_START_BACKOFF_SEC:-})" >&2
    return 1
  fi
}
apply_proposer_start_retry_defaults
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
  local backoff="${PROPOSER_START_BACKOFF_SEC:-5}"
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

# Custom proposer has no super-root proposal path. Refuse before stop_bg:
# the custom branch stops whatever pidfile it sees, which on the live DATA_DIR
# is the live proposer.
refuse_custom_proposer_type9() {
  if [[ "${USE_CUSTOM_PROPOSER:-0}" == "1" && "${PROPOSER_GAME_TYPE:-}" == "9" ]]; then
    echo "ERROR: USE_CUSTOM_PROPOSER=1 cannot start PROPOSER_GAME_TYPE=9 (super-root)." >&2
    echo "  Type 9 is ported in OPU-3b, not in this stock start script." >&2
    echo "  Leave USE_CUSTOM_PROPOSER unset and set PROPOSER_GAME_TYPE=9 for stock op-proposer." >&2
    return 1
  fi
}

# PROPOSER_ROLLUP_RPC is not a type-8 input. It exists so a type-9 start that
# would also pass a rollup RPC fails closed. op-proposer v1.17.0 would accept it.
refuse_type9_rollup_rpc() {
  if [[ "${PROPOSER_GAME_TYPE:-}" != "9" ]]; then
    return 0
  fi
  if [[ -n "${PROPOSER_ROLLUP_RPC:-}" ]]; then
    echo "ERROR: PROPOSER_GAME_TYPE=9 refuses a rollup RPC (PROPOSER_ROLLUP_RPC is set)." >&2
    echo "  Type 9 must start with --superroot-rpcs only. A rollup RPC posts an output root as rootClaim." >&2
    return 1
  fi
}

# Zero gameImpls(9) means U20 has not registered the super-root game. Type 8
# does not call this.
assert_game_impl_for_type9() {
  local factory="$1"
  local rpc="$2"
  local impl h
  if [[ "${PROPOSER_GAME_TYPE:-}" != "9" ]]; then
    return 0
  fi
  impl="$(cast call "$factory" "gameImpls(uint32)(address)" 9 --rpc-url "$rpc" | awk 'NR==1{print $1}')"
  h="$(printf '%s' "$impl" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "$h" || "$h" == "0x" || "$h" =~ ^0x0+$ ]]; then
    echo "ERROR: refusing PROPOSER_GAME_TYPE=9: DisputeGameFactory.gameImpls(9) is the zero address (U20 has not registered type 9)." >&2
    return 1
  fi
}

# Sets proposer_cmd. Type 8 matches the pre-OPU-3a argv. Type 9 swaps
# --rollup-rpc for --superroot-rpcs and changes nothing else.
build_stock_proposer_cmd() {
  local factory="$1"
  if [[ "${PROPOSER_GAME_TYPE}" == "9" ]]; then
    proposer_cmd=(
      op-proposer
      --l1-eth-rpc="$L1_RPC_URL"
      --superroot-rpcs="$L2_NODE_RPC_URL"
      --private-key="${PROPOSER_PRIVATE_KEY}"
      --game-factory-address="$factory"
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
  else
    proposer_cmd=(
      op-proposer
      --l1-eth-rpc="$L1_RPC_URL"
      --rollup-rpc="$L2_NODE_RPC_URL"
      --private-key="${PROPOSER_PRIVATE_KEY}"
      --game-factory-address="$factory"
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
  fi
}

# Copy-then-truncate $LOG_DIR/*.log before this process holds the fd.
# `mv` of a live log does not reclaim disk (D-0138). Failure must not block start.
"$SCRIPT_DIR/rotate-logs.sh" --dir "$LOG_DIR" || echo "WARN: log rotation failed for $LOG_DIR — continuing" >&2

refuse_custom_proposer_type9
refuse_type9_rollup_rpc
assert_game_impl_for_type9 "$GAME_FACTORY" "$L1_RPC_URL"

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
  build_stock_proposer_cmd "$GAME_FACTORY"
  start_proposer_with_retry

  echo "Sepolia proposer started against DisputeGameFactory=$GAME_FACTORY game-type=$PROPOSER_GAME_TYPE interval=${PROPOSER_INTERVAL} poll=${PROPOSER_POLL} txmgr receipt/rebroadcast=${PROPOSER_RECEIPT_QUERY}/${PROPOSER_REBROADCAST}"
  echo "Known-good: 'created dispute game' or 'Proposing'"
fi
