#!/usr/bin/env bash
# OPU-5d: on an Anvil fork only, heal the post-U20 anchor with one honest
# type-9 game, then show op-challenger counters a false type-9 claim and
# leaves a second honest type-9 game alone.
#
# Refuses any L1 that is not loopback chain id 900852. Never edits
# .env.sepolia. Never prints a key or a QuickNode URL. Pids and logs stay
# under a temp DATA_DIR. Kills only the processes this script started.
#
# OD-1 = fork only. OD-8 = the anchor moves when the first honest type-9
# game is finalized and closed. Do not point this at Sepolia.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OPU5_CHAIN_ID=900852
OPU5_MAX_CLOCK=7200
OPU5_FINALITY=1800

opu5_die() {
  echo "ERROR: $*" >&2
  exit 1
}

opu5_phase() {
  echo "phase: $*"
}

opu5_assert_pid_dir() {
  local pid_dir="$1"
  local temp_root="$2"
  echo "isolated PID_DIR=$pid_dir"
  case "$pid_dir" in
    "$temp_root"/*) ;;
    *) opu5_die "resolved PID_DIR is not under the temp dir" ;;
  esac
}

opu5_assert_loopback() {
  local url="$1"
  case "$url" in
    http://127.0.0.1:*|http://localhost:*|https://127.0.0.1:*|https://localhost:*) ;;
    *) opu5_die "refusing to sign: L1 is not loopback" ;;
  esac
}

opu5_assert_not_metered() {
  local label="$1"
  local url="$2"
  case "$url" in
    *quiknode*|*quicknode*)
      opu5_die "refusing ${label}: a metered URL is not allowed on this demo"
      ;;
  esac
}

opu5_l2_genesis_time() {
  local rollup="$1"
  [[ -f "$rollup" ]] || opu5_die "rollup config missing: $rollup"
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["genesis"]["l2_time"])' "$rollup"
}

# Sequence must be an L2 timestamp at or after rollup genesis l2_time.
# The pre-heal anchor is an L2 block number, which is far below genesis.
opu5_assert_anchor_timestamp() {
  local seq="$1"
  local rollup="$2"
  local genesis
  genesis="$(opu5_l2_genesis_time "$rollup")"
  if [[ "$seq" -lt "$genesis" ]]; then
    opu5_die "refusing Phase B: anchor sequence ${seq} is before L2 genesis timestamp ${genesis} (from ${rollup})"
  fi
  echo "anchor sequence ${seq} is at or after L2 genesis timestamp ${genesis}"
}

opu5_assert_fork_chain() {
  local url="$1"
  local cid
  opu5_assert_loopback "$url"
  cid="$(cast chain-id --rpc-url "$url")"
  if [[ "$cid" != "$OPU5_CHAIN_ID" ]]; then
    opu5_die "refusing to sign: loopback L1 reports chain id ${cid}"
  fi
}

BEACON="${OPU5_BEACON:-https://ethereum-sepolia-beacon-api.publicnode.com}"
UPSTREAM="${OPU5_UPSTREAM:-https://ethereum-sepolia-rpc.publicnode.com}"

if [[ -n "${OPU5_TEMP_ROOT:-}" ]]; then
  TEMP_ROOT="$OPU5_TEMP_ROOT"
  mkdir -p "$TEMP_ROOT"
else
  TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-opu5d.XXXXXX")"
fi
DATA_DIR="$TEMP_ROOT/data"
PID_DIR="${OPU5_PID_DIR:-$DATA_DIR/pids}"

opu5_assert_pid_dir "$PID_DIR" "$TEMP_ROOT"
opu5_assert_not_metered "upstream" "$UPSTREAM"
opu5_assert_not_metered "beacon" "$BEACON"

if [[ -n "${OPU5_L1_RPC_URL:-}" ]]; then
  opu5_assert_fork_chain "$OPU5_L1_RPC_URL"
fi
if [[ -n "${OPU5_ANCHOR_SEQUENCE:-}" ]]; then
  opu5_assert_anchor_timestamp "$OPU5_ANCHOR_SEQUENCE" \
    "${OPU5_ROLLUP_JSON:-$REPO_ROOT/deployments/sepolia/rollup.json}"
fi
if [[ "${OPU5_DRY_GUARD:-}" == "1" ]]; then
  opu5_phase "dry-guard ok"
  exit 0
fi

# --- live run (fork only) ---------------------------------------------------

# lib.sh loads the repo .env and overwrites DATA_DIR. Keep the temp tree.
_OPU5_DATA="$TEMP_ROOT/data"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
DATA_DIR="$_OPU5_DATA"
PID_DIR="$DATA_DIR/pids"
LOG_DIR="$DATA_DIR/logs"

STARTED_PIDS=()
opu5_track() {
  STARTED_PIDS+=("$1")
}

opu5_cleanup() {
  local pid
  if [[ -n "${PID_DIR:-}" && -f "$PID_DIR/op-challenger.pid" ]]; then
    pid="$(tr -d '[:space:]' < "$PID_DIR/op-challenger.pid" || true)"
    if [[ -n "$pid" ]]; then
      pkill -P "$pid" >/dev/null 2>&1 || true
      kill "$pid" >/dev/null 2>&1 || true
    fi
  fi
  if [[ ${#STARTED_PIDS[@]} -gt 0 ]]; then
    for pid in "${STARTED_PIDS[@]}"; do
      pkill -P "$pid" >/dev/null 2>&1 || true
      kill "$pid" >/dev/null 2>&1 || true
    done
  fi
}
trap opu5_cleanup EXIT

RUN_START=$SECONDS
NOTES="$TEMP_ROOT/notes"
mkdir -p "$DATA_DIR/pids" "$DATA_DIR/logs" "$NOTES" "$TEMP_ROOT/anvil-cache"
opu5_phase "temp $TEMP_ROOT"
opu5_assert_pid_dir "$PID_DIR" "$TEMP_ROOT"

ENV_SOURCE="${OPU5_ENV_SOURCE:-/Users/steveforte/ForteL2/.env.sepolia}"
[[ -f "$ENV_SOURCE" ]] || opu5_die "Sepolia env file is missing"
# Read the operator pid once, before any fork process starts. Do not print the env.
LIVE_PID_BEFORE="$(
  python3 - "$ENV_SOURCE" <<'PY'
import os, sys
data = ""
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("DATA_DIR="):
        data = line.split("=", 1)[1].strip().strip("'\"")
        break
pidfile = os.path.join(os.path.expanduser(data), "pids", "op-proposer.pid") if data else ""
if pidfile and os.path.isfile(pidfile):
    print(open(pidfile).read().strip())
PY
)"
opu5_phase "live-proposer-before ${LIVE_PID_BEFORE:-missing}"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
L1="http://127.0.0.1:${PORT}"
opu5_phase "anvil starting"
anvil \
  --host 127.0.0.1 \
  --port "$PORT" \
  --chain-id "$OPU5_CHAIN_ID" \
  --fork-url "$UPSTREAM" \
  --cache-path "$TEMP_ROOT/anvil-cache" \
  >"$NOTES/anvil.log" 2>&1 &
ANVIL_PID=$!
opu5_track "$ANVIL_PID"
if ! wait_for_rpc "$L1" "opu5-fork" 180; then
  opu5_die "fork RPC did not come up (PublicNode). Not using a metered URL."
fi
opu5_assert_fork_chain "$L1"
FORK_BLOCK="$(cast block-number --rpc-url "$L1")"
opu5_phase "anvil up chain=$OPU5_CHAIN_ID block=$FORK_BLOCK pid=$ANVIL_PID"

PRESTATE="${OPU5_PRESTATE:-}"
[[ -f "$PRESTATE" ]] || opu5_die "OPU5_PRESTATE must be the type-9 cannon prestate file"
CHALLENGER_BIN="${OPU5_CHALLENGER_BIN:-}"
[[ -x "$CHALLENGER_BIN" ]] || opu5_die "OPU5_CHALLENGER_BIN must be an executable named op-challenger"
[[ "$(basename "$CHALLENGER_BIN")" == "op-challenger" ]] || opu5_die "OPU5_CHALLENGER_BIN must be named op-challenger"
DEPLOYER_BIN="${OPU5_DEPLOYER_BIN:-}"
[[ -x "$DEPLOYER_BIN" ]] || opu5_die "OPU5_DEPLOYER_BIN must be op-deployer v0.8.1"
KONA_SERVER="${OPU5_KONA_SERVER:-$HOME/src/fortel2/bin/kona-host}"
[[ -x "$KONA_SERVER" ]] || opu5_die "kona host is not executable"

TEMP_ENV="$TEMP_ROOT/fork.env"
python3 - "$ENV_SOURCE" "$TEMP_ENV" "$DATA_DIR" "$L1" "$BEACON" "$PRESTATE" "$KONA_SERVER" <<'PY'
import sys
src, dst, data_dir, l1, beacon, prestate, kona = sys.argv[1:]
drop = {
    "L1_RPC_URL_RENDER",
    "CHALLENGER_L1_RPC_URL",
    "OP_NODE_SAFEDB_PATH",
}
replace = {
    "L1_RPC_URL": l1,
    "L1_BEACON_URL": beacon,
    "DATA_DIR": data_dir,
    "CHALLENGER_TRACE_TYPE": "super-cannon-kona",
    "CHALLENGER_PRESTATE": prestate,
    "CHALLENGER_KONA_SERVER": kona,
    "PROPOSER_GAME_TYPE": "9",
    "SEPOLIA_L1_RPC_KIND": "standard",
    "SEPOLIA_CHALLENGER_HTTP_POLL_INTERVAL": "2s",
    "SEPOLIA_CHALLENGER_MIN_UPDATE_INTERVAL": "1s",
    "SEPOLIA_CHALLENGER_CONFIRMATIONS": "1",
    "OP_CHALLENGER_GAME_WINDOW": "6h",
    "CHALLENGER_LOG_LEVEL": "info",
}
seen = set()
out = []
for raw in open(src, encoding="utf-8"):
    line = raw.rstrip("\n")
    low = line.lower()
    # Comments included. A metered URL must not be copied into the fork env.
    if "quiknode" in low or "quicknode" in low:
        continue
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or "=" not in line:
        out.append(line)
        continue
    key = line.split("=", 1)[0]
    if key in drop:
        continue
    if key in replace:
        if key in seen:
            continue
        seen.add(key)
        out.append(f"{key}={replace[key]}")
        continue
    out.append(line)
for key, value in replace.items():
    if key not in seen:
        out.append(f"{key}={value}")
text = "\n".join(out) + "\n"
low = text.lower()
if "quiknode" in low or "quicknode" in low:
    raise SystemExit("refusing to write a metered URL into the fork env")
open(dst, "w", encoding="utf-8").write(text)
import os
os.chmod(dst, 0o600)
PY

set -a
# shellcheck disable=SC1090
source "$TEMP_ENV"
set +a
PID_DIR="$DATA_DIR/pids"
LOG_DIR="$DATA_DIR/logs"
mkdir -p "$PID_DIR" "$LOG_DIR"
opu5_assert_pid_dir "$PID_DIR" "$TEMP_ROOT"
export FORTEL2_ENV="$TEMP_ENV"
export FORTEL2_ISOLATED_DATA_DIR="$DATA_DIR"
export FORTEL2_FORK_L1_RPC_URL="$L1"
export FORTEL2_FORK_L1_BEACON="$BEACON"
export OP_DEPLOYER_BIN="$DEPLOYER_BIN"
export FORTEL2_OP_CHALLENGER_BIN="$CHALLENGER_BIN"
export FORTEL2_CHALLENGER_TRACE_TYPE=super-cannon-kona

FACTORY="$(jq -r '.DisputeGameFactoryProxy' "$(deployments_json_path)")"
ASR="$(jq -r '.AnchorStateRegistryProxy' "$(deployments_json_path)")"
ROLLUP="${OPU5_ROLLUP_JSON:-$DEPLOY_DIR/rollup.json}"

opu5_word() {
  cast call "$1" "$2" "${@:3}" --rpc-url "$L1" | awk 'NR==1 { print $1 }'
}

opu5_fund() {
  local addr="$1"
  cast rpc anvil_setBalance "$addr" 0x56BC75E2D63100000 --rpc-url "$L1" >/dev/null
}

opu5_phase "fork-fund admin proposer challenger (anvil_setBalance, fork only)"
opu5_fund "$ADMIN_ADDRESS"
opu5_fund "$PROPOSER_ADDRESS"
opu5_fund "$CHALLENGER_ADDRESS"

opu5_warp_to() {
  local target="$1"
  local now
  now="$(cast block latest --rpc-url "$L1" -f timestamp)"
  if [[ "$now" -ge "$target" ]]; then
    echo "warp: timestamp $now already >= $target"
    return 0
  fi
  cast rpc anvil_setNextBlockTimestamp "$target" --rpc-url "$L1" >/dev/null
  cast rpc anvil_mine --rpc-url "$L1" >/dev/null
  now="$(cast block latest --rpc-url "$L1" -f timestamp)"
  echo "warp: timestamp $now target $target"
}

opu5_send() {
  local desc="$1"
  shift
  local err json hash
  err="$NOTES/send.err"
  json="$(cast send "$@" --private-key "$ADMIN_PRIVATE_KEY" --rpc-url "$L1" --json 2>"$err")" || {
    echo "ERROR: ${desc} failed" >&2
    # Revert text only. The key is not in cast's revert output.
    tail -n 20 "$err" >&2 || true
    return 1
  }
  hash="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["transactionHash"])' <<<"$json")"
  echo "tx ${desc} ${hash}" >&2
  printf '%s\n' "$hash"
}

opu5_anchor() {
  local game seq root
  game="$(opu5_word "$ASR" "anchorGame()(address)")"
  root="$(cast call "$ASR" "getAnchorRoot()(bytes32,uint256)" --rpc-url "$L1")"
  seq="$(printf '%s\n' "$root" | awk 'NR==2 { print $1 }')"
  root="$(printf '%s\n' "$root" | awk 'NR==1 { print $1 }')"
  echo "$game $seq $root"
}

opu5_game_count() {
  opu5_word "$FACTORY" "gameCount()(uint256)"
}

opu5_game_address() {
  local idx="$1"
  cast call "$FACTORY" "gameAtIndex(uint256)(uint32,uint64,address)" "$idx" --rpc-url "$L1" \
    | python3 -c 'import re,sys; t=sys.stdin.read(); ms=re.findall(r"0x[0-9a-fA-F]{40}", t); print(ms[-1] if ms else "")'
}

opu5_stop_challenger() {
  local pid="${CHALLENGER_PID:-}"
  local i
  [[ -n "$pid" ]] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    pkill -P "$pid" >/dev/null 2>&1 || true
    kill "$pid" >/dev/null 2>&1 || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.5
    done
  fi
  opu5_phase "challenger stopped after the false-game move pid=$pid"
}

opu5_resolve_game() {
  local game="$1"
  local label="$2"
  local n i status
  status="$(opu5_word "$game" "status()(uint8)")"
  if [[ "$status" != "0" ]]; then
    echo "resolve: $label already status=$status"
    return 0
  fi
  n="$(opu5_word "$game" "claimDataLen()(uint256)")"
  i=$((n - 1))
  while [[ "$i" -ge 0 ]]; do
    opu5_send "resolveClaim-${label}-${i}" "$game" "resolveClaim(uint256,uint256)" "$i" 0 >/dev/null
    i=$((i - 1))
  done
  opu5_send "resolve-${label}" "$game" "resolve()" >/dev/null
  status="$(opu5_word "$game" "status()(uint8)")"
  echo "resolve: $label status=$status"
}

opu5_phase "upgrade starting"
UPGRADE_LOG="$NOTES/upgrade.log"
if ! OP_DEPLOYER_BIN="$DEPLOYER_BIN" FORTEL2_ENV="$TEMP_ENV" \
  "$SCRIPT_DIR/opu-u20-upgrade-sepolia.sh" --fork "$L1" >"$UPGRADE_LOG" 2>&1; then
  tail -n 40 "$UPGRADE_LOG" >&2 || true
  opu5_die "U20 fork upgrade failed"
fi
opu5_phase "fork upgraded"
grep -E '^phase: |^state |^GAS ' "$UPGRADE_LOG" || true

read -r ANCHOR_BEFORE_GAME ANCHOR_BEFORE_SEQ ANCHOR_BEFORE_ROOT < <(opu5_anchor)
opu5_phase "anchor-before game=$ANCHOR_BEFORE_GAME sequence=$ANCHOR_BEFORE_SEQ (L2 block number, not a timestamp) root=$ANCHOR_BEFORE_ROOT"

propose_once() {
  local out="$1"
  (
    cd "$REPO_ROOT/proposer"
    go run ./cmd/propose-loop \
      -l1 "$L1" \
      -rollup "$L2_NODE_RPC_URL" \
      -factory "$FACTORY" \
      -game-type 9 \
      -proposal-interval 0s \
      -once
  ) >"$out" 2>&1
}

wait_new_game() {
  local before="$1"
  local out="$2"
  local label="$3"
  local count deadline
  deadline=$((SECONDS + 1500))
  while true; do
    count="$(opu5_game_count)"
    if [[ "$count" -gt "$before" ]]; then
      echo "$count"
      return 0
    fi
    if (( SECONDS > deadline )); then
      tail -n 30 "$out" >&2 || true
      opu5_die "${label}: no new type-9 game before the safe head moved"
    fi
    propose_once "$out" || true
    sleep 5
  done
}

COUNT_BEFORE_A="$(opu5_game_count)"
opu5_phase "phase-a propose starting count=$COUNT_BEFORE_A"
COUNT_AFTER_A="$(wait_new_game "$COUNT_BEFORE_A" "$NOTES/propose-a.log" "phase A")"
GAME_A_INDEX=$((COUNT_AFTER_A - 1))
GAME_A="$(opu5_game_address "$GAME_A_INDEX")"
GAME_A_TS="$(opu5_word "$GAME_A" "l2SequenceNumber()(uint256)")"
GAME_A_ROOT="$(opu5_word "$GAME_A" "rootClaim()(bytes32)")"
GAME_A_CREATED="$(opu5_word "$GAME_A" "createdAt()(uint64)")"
GAME_A_TX="$(awk -F= '/^broadcast l1_tx=/{print $2}' "$NOTES/propose-a.log" | tail -1)"
opu5_phase "phase-a game=$GAME_A index=$GAME_A_INDEX timestamp=$GAME_A_TS (L2 timestamp) root=$GAME_A_ROOT createdAt=$GAME_A_CREATED tx=$GAME_A_TX"

opu5_warp_to $((GAME_A_CREATED + OPU5_MAX_CLOCK))
RESOLVE_A_TX="$(opu5_send "resolve-a" "$GAME_A" "resolveClaim(uint256,uint256)" 0 0 | tail -1)"
RESOLVE_A2_TX="$(opu5_send "resolve-a-root" "$GAME_A" "resolve()" | tail -1)"
GAME_A_STATUS="$(opu5_word "$GAME_A" "status()(uint8)")"
GAME_A_RESOLVED="$(opu5_word "$GAME_A" "resolvedAt()(uint64)")"
opu5_phase "phase-a resolved status=$GAME_A_STATUS resolvedAt=$GAME_A_RESOLVED resolveClaim=$RESOLVE_A_TX resolve=$RESOLVE_A2_TX"
if [[ "$GAME_A_STATUS" != "2" ]]; then
  opu5_die "phase A did not resolve DEFENDER_WINS (status=$GAME_A_STATUS)"
fi

opu5_warp_to $((GAME_A_RESOLVED + OPU5_FINALITY + 1))
CLOSE_A_TX="$(opu5_send "close-a" "$GAME_A" "claimCredit(address)" "$PROPOSER_ADDRESS" | tail -1)"
read -r ANCHOR_AFTER_GAME ANCHOR_AFTER_SEQ ANCHOR_AFTER_ROOT < <(opu5_anchor)
opu5_phase "anchor-after game=$ANCHOR_AFTER_GAME sequence=$ANCHOR_AFTER_SEQ (L2 timestamp) root=$ANCHOR_AFTER_ROOT close=$CLOSE_A_TX"
if [[ "$(printf '%s' "$ANCHOR_AFTER_GAME" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$GAME_A" | tr '[:upper:]' '[:lower:]')" ]]; then
  opu5_die "anchor game did not become the phase-A game (anchor=$ANCHOR_AFTER_GAME phaseA=$GAME_A)"
fi
if [[ "$ANCHOR_AFTER_SEQ" != "$GAME_A_TS" ]]; then
  opu5_die "anchor sequence $ANCHOR_AFTER_SEQ is not the phase-A timestamp $GAME_A_TS"
fi
if [[ "$(printf '%s' "$ANCHOR_AFTER_ROOT" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$GAME_A_ROOT" | tr '[:upper:]' '[:lower:]')" ]]; then
  opu5_die "anchor root does not match the phase-A root claim"
fi
opu5_assert_anchor_timestamp "$ANCHOR_AFTER_SEQ" "$ROLLUP"
opu5_phase "anchor healed"

opu5_phase "challenger starting"
opu5_assert_pid_dir "$PID_DIR" "$TEMP_ROOT"
SCAN_START=$(date +%s)
if ! FORTEL2_ENV="$TEMP_ENV" \
  FORTEL2_ISOLATED_DATA_DIR="$DATA_DIR" \
  FORTEL2_FORK_L1_RPC_URL="$L1" \
  FORTEL2_FORK_L1_BEACON="$BEACON" \
  FORTEL2_CHALLENGER_TRACE_TYPE=super-cannon-kona \
  FORTEL2_OP_CHALLENGER_BIN="$CHALLENGER_BIN" \
  "$SCRIPT_DIR/09-start-challenger-sepolia.sh" >"$NOTES/challenger-start.log" 2>&1; then
  tail -n 40 "$NOTES/challenger-start.log" >&2 || true
  opu5_die "challenger failed to start"
fi
CHALLENGER_PID="$(tr -d '[:space:]' < "$PID_DIR/op-challenger.pid")"
opu5_phase "challenger started pid=$CHALLENGER_PID"
if ! grep -q "isolated PID_DIR=$PID_DIR" "$NOTES/challenger-start.log"; then
  opu5_die "challenger start did not confirm PID_DIR under the temp dir"
fi
CH_LOG="$LOG_DIR/op-challenger.log"
if grep -q "starting monitoring" "$CH_LOG" 2>/dev/null; then
  FIRST_SCAN_SEC=$(( $(date +%s) - SCAN_START ))
  opu5_phase "first-scan wall ${FIRST_SCAN_SEC}s (starting monitoring)"
fi

COUNT_BEFORE_B="$(opu5_game_count)"
opu5_phase "phase-b honest propose starting count=$COUNT_BEFORE_B"
COUNT_AFTER_H="$(wait_new_game "$COUNT_BEFORE_B" "$NOTES/propose-b.log" "phase B honest")"
GAME_H_INDEX=$((COUNT_AFTER_H - 1))
GAME_H="$(opu5_game_address "$GAME_H_INDEX")"
GAME_H_TS="$(opu5_word "$GAME_H" "l2SequenceNumber()(uint256)")"
GAME_H_TX="$(awk -F= '/^broadcast l1_tx=/{print $2}' "$NOTES/propose-b.log" | tail -1)"
opu5_phase "phase-b honest game=$GAME_H index=$GAME_H_INDEX timestamp=$GAME_H_TS (L2 timestamp) tx=$GAME_H_TX"

opu5_assert_pid_dir "$PID_DIR" "$TEMP_ROOT"
if ! FORTEL2_ENV="$TEMP_ENV" \
  FORTEL2_FORK_L1_RPC_URL="$L1" \
  CONFIRM_BAD_PROPOSAL_SEPOLIA=1 \
  PROPOSER_GAME_TYPE=9 \
  "$SCRIPT_DIR/create-bad-proposal-sepolia.sh" >"$NOTES/bad.log" 2>&1; then
  tail -n 40 "$NOTES/bad.log" >&2 || true
  opu5_die "false type-9 proposal failed"
fi
GAME_F="$(awk -F= '/^proxy=/{print $2}' "$NOTES/bad.log" | tail -1)"
GAME_F_TX="$(awk -F= '/^tx=/{print $2}' "$NOTES/bad.log" | tail -1)"
GAME_F_TS="$(opu5_word "$GAME_F" "l2SequenceNumber()(uint256)")"
opu5_phase "phase-b false game=$GAME_F timestamp=$GAME_F_TS (L2 timestamp) tx=$GAME_F_TX"

MOVE_DEADLINE=$((SECONDS + 900))
GAME_F_CLAIMS=1
while true; do
  if grep -q "starting monitoring" "$CH_LOG" 2>/dev/null; then
    if [[ -z "${FIRST_SCAN_SEC:-}" ]]; then
      FIRST_SCAN_SEC=$(( $(date +%s) - SCAN_START ))
      opu5_phase "first-scan wall ${FIRST_SCAN_SEC}s (starting monitoring)"
    fi
  fi
  GAME_F_CLAIMS="$(opu5_word "$GAME_F" "claimDataLen()(uint256)")"
  GAME_H_CLAIMS="$(opu5_word "$GAME_H" "claimDataLen()(uint256)")"
  if [[ "$GAME_H_CLAIMS" != "1" ]]; then
    opu5_die "negative control failed: honest phase-B game has $GAME_H_CLAIMS claims"
  fi
  if [[ "$GAME_F_CLAIMS" -gt 1 ]]; then
    # Stop before the clock warp. A later move would start a fresh clock in
    # the warped block, and a deeper step is not required for a clock win.
    opu5_stop_challenger
    break
  fi
  if (( SECONDS > MOVE_DEADLINE )); then
    tail -n 50 "$CH_LOG" >&2 || true
    opu5_die "challenger posted no move against the false game"
  fi
  if ! kill -0 "$CHALLENGER_PID" 2>/dev/null; then
    tail -n 50 "$CH_LOG" >&2 || true
    opu5_die "challenger exited before it moved"
  fi
  # op-challenger schedules work on new L1 heads. Anvil mines only when a
  # transaction arrives, so the game created on the latest block is not
  # scanned again until something else mines. One empty block per poll
  # wakes it after the live op-node's L1 head has passed the game's.
  cast rpc anvil_mine --rpc-url "$L1" >/dev/null
  sleep 2
done
GAME_H_CLAIMS="$(opu5_word "$GAME_H" "claimDataLen()(uint256)")"
GAME_F_CLAIMS="$(opu5_word "$GAME_F" "claimDataLen()(uint256)")"
if [[ "$GAME_H_CLAIMS" != "1" ]]; then
  opu5_die "negative control failed: honest phase-B game has $GAME_H_CLAIMS claims"
fi
opu5_phase "false game claims=$GAME_F_CLAIMS honest claims=$GAME_H_CLAIMS"

FROM_BLOCK="$(cast block-number --rpc-url "$L1")"
# The move is already mined. Scan a window back from the tip.
SCAN_FROM=$((FROM_BLOCK > 30 ? FROM_BLOCK - 30 : 0))
cast logs --from-block "$SCAN_FROM" --to-block latest \
  --address "$GAME_F" \
  "Move(uint256 indexed parentIndex, bytes32 indexed claim, address indexed claimant)" \
  --rpc-url "$L1" --json >"$NOTES/moves.json" || true
python3 - "$NOTES/moves.json" "$CHALLENGER_ADDRESS" <<'PY'
import json, sys
path, challenger = sys.argv[1:]
raw = open(path, encoding="utf-8").read().strip()
if not raw:
    raise SystemExit("no Move logs")
logs = json.loads(raw)
if isinstance(logs, dict):
    logs = [logs]
want = challenger.lower()
found = False
for n, ev in enumerate(logs, start=1):
    topics = [t.lower() for t in ev.get("topics", [])]
    claimant = "0x" + topics[-1][-40:]
    parent = int(topics[1], 16) if len(topics) > 1 else -1
    tx = ev.get("transactionHash", "")
    # Each Move appends one claim. Root is index 0, so the nth move is claim n.
    print(f"move tx={tx} claimIndex={n} parentIndex={parent} from={claimant}")
    if claimant == want:
        found = True
if not found:
    raise SystemExit("Move logs did not include the challenger address")
PY

# The countered claim's clock starts at the move's block, not at game creation.
# Warp a full max-clock from the tip so every claim already on chain has expired.
# The honest game is older, so the same warp expires its uncontested root too.
NOW="$(cast block latest --rpc-url "$L1" -f timestamp)"
opu5_warp_to $((NOW + OPU5_MAX_CLOCK))
opu5_resolve_game "$GAME_F" "false"
opu5_resolve_game "$GAME_H" "honest"
GAME_F_STATUS="$(opu5_word "$GAME_F" "status()(uint8)")"
GAME_H_STATUS="$(opu5_word "$GAME_H" "status()(uint8)")"
opu5_phase "resolved false=$GAME_F_STATUS honest=$GAME_H_STATUS"
if [[ "$GAME_F_STATUS" != "1" ]]; then
  opu5_die "false game status=$GAME_F_STATUS, want CHALLENGER_WINS (1)"
fi
if [[ "$GAME_H_STATUS" != "2" ]]; then
  opu5_die "honest phase-B status=$GAME_H_STATUS, want DEFENDER_WINS (2)"
fi
GAME_H_CLAIMS="$(opu5_word "$GAME_H" "claimDataLen()(uint256)")"
if [[ "$GAME_H_CLAIMS" != "1" ]]; then
  opu5_die "negative control failed after resolve: honest claims=$GAME_H_CLAIMS"
fi

GAME_F_RESOLVED="$(opu5_word "$GAME_F" "resolvedAt()(uint64)")"
opu5_warp_to $((GAME_F_RESOLVED + OPU5_FINALITY + 1))
VALID_F="$(opu5_word "$ASR" "isGameClaimValid(address)(bool)" "$GAME_F")"
opu5_phase "false isGameClaimValid=$VALID_F"
if [[ "$VALID_F" != "false" ]]; then
  opu5_die "false game isGameClaimValid=$VALID_F, want false"
fi
read -r ANCHOR_B_GAME ANCHOR_B_SEQ ANCHOR_B_ROOT < <(opu5_anchor)
if [[ "$(printf '%s' "$ANCHOR_B_GAME" | tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$GAME_F" | tr '[:upper:]' '[:lower:]')" ]]; then
  opu5_die "anchor became the false game"
fi

CLAIM1="$(opu5_send "claim-unlock" "$GAME_F" "claimCredit(address)" "$CHALLENGER_ADDRESS" | tail -1)"
WETH="$(opu5_word "$GAME_F" "weth()(address)")"
WETH_DELAY="$(opu5_word "$WETH" "delay()(uint256)")"
NOW="$(cast block latest --rpc-url "$L1" -f timestamp)"
opu5_warp_to $((NOW + WETH_DELAY + 1))
CLAIM2="$(opu5_send "claim-withdraw" "$GAME_F" "claimCredit(address)" "$CHALLENGER_ADDRESS" | tail -1)"
read -r ANCHOR_END_GAME ANCHOR_END_SEQ ANCHOR_END_ROOT < <(opu5_anchor)
opu5_phase "claims unlock=$CLAIM1 withdraw=$CLAIM2 wethDelay=$WETH_DELAY"
opu5_phase "anchor-end game=$ANCHOR_END_GAME sequence=$ANCHOR_END_SEQ root=$ANCHOR_END_ROOT"
if [[ "$(printf '%s' "$ANCHOR_END_GAME" | tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$GAME_F" | tr '[:upper:]' '[:lower:]')" ]]; then
  opu5_die "anchor became the false game after claimCredit"
fi

LIVE_PID_AFTER="$(
  python3 - "$ENV_SOURCE" <<'PY'
import os, sys
data = ""
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("DATA_DIR="):
        data = line.split("=", 1)[1].strip().strip("'\"")
        break
pidfile = os.path.join(os.path.expanduser(data), "pids", "op-proposer.pid") if data else ""
if pidfile and os.path.isfile(pidfile):
    print(open(pidfile).read().strip())
PY
)"
opu5_phase "live-proposer-after ${LIVE_PID_AFTER:-missing}"
if [[ -n "$LIVE_PID_BEFORE" && "$LIVE_PID_BEFORE" != "$LIVE_PID_AFTER" ]]; then
  opu5_die "live op-proposer pid changed ($LIVE_PID_BEFORE -> $LIVE_PID_AFTER)"
fi
ELAPSED=$((SECONDS - RUN_START))
opu5_phase "done seconds=$ELAPSED forkBlock=$FORK_BLOCK"
opu5_phase "summary anchorBefore=$ANCHOR_BEFORE_GAME/$ANCHOR_BEFORE_SEQ anchorAfter=$ANCHOR_AFTER_GAME/$ANCHOR_AFTER_SEQ phaseA=$GAME_A honest=$GAME_H/$GAME_H_STATUS false=$GAME_F/$GAME_F_STATUS"
