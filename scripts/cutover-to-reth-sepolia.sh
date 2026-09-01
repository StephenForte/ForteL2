#!/usr/bin/env bash
# Task 5 Phase B window orchestrator. Phase A ships the script; it does not
# mutate the live stack unless --execute (operator window only).
#
# Order: preflight → drain (admin_stop first) → record → stop geth → flip
# FORTEL2_EL → start reth stack → health. Pauses at each checkpoint.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
usage: cutover-to-reth-sepolia.sh --rehearse|--preflight-only|--execute

  --rehearse        print the ordered window steps; no RPCs, no process control
  --preflight-only  fail-closed decision-3 gates (fixture or live reads)
  --execute         operator window only — mutates the live Sepolia sequencer

Preflight (all must pass):
  D-0116 game 216 DEFENDER_WINS + withdrawal finalized (on-chain, not docs)
  candidate safe-head lag <= 2
  verify-reth-parity.sh / verify-reth-faultproof.sh / check-el-pins.sh exit 0
  batcher + proposer funded above floors
  check-launchd.sh green

CUTOVER_PREFLIGHT_FIXTURE=path.json  offline gates for helper tests.
FORTEL2_CUTOVER_GAME_L2_BLOCK=N       override latest-game L2 block lookup
FORTEL2_CUTOVER_SAFEDB_ENABLE_L1=N      override sidecar SafeDB enable L1 (default Task 4)
FORTEL2_CUTOVER_PRE_ENABLE_L1=N         override known-unrecorded L1 negative (default Task 4)
EOF
}

# Sidecar SafeDB first recorded L1 — Task 4 evidence (tasks/task4-op-reth-faultproof.md).
TASK5_SAFEDB_ENABLE_L1=11609837
# Known-unrecorded L1 for the required negative — NOT enable-1 (Task 4 rule).
TASK5_PRE_ENABLE_L1=11600000

# Latest proposed game L2 block: factory → gameAtIndex(count-1) → l2BlockNumber().
# Fail closed — preflight must not skip the faultproof gate silently.
resolve_cutover_game_l2_block() {
  if [[ -n "${FORTEL2_CUTOVER_GAME_L2_BLOCK:-}" ]]; then
    if ! [[ "${FORTEL2_CUTOVER_GAME_L2_BLOCK}" =~ ^[0-9]+$ ]]; then
      echo "ERROR: FORTEL2_CUTOVER_GAME_L2_BLOCK must be a non-negative integer" >&2
      return 1
    fi
    echo "$FORTEL2_CUTOVER_GAME_L2_BLOCK"
    return 0
  fi
  local factory count idx meta proxy l2
  factory="$(jq -r '.DisputeGameFactoryProxy // .disputeGameFactoryProxy // empty' "$(deployments_json_path)")"
  if ! is_eth_address "$factory"; then
    echo "ERROR: missing or invalid DisputeGameFactoryProxy in $(deployments_json_path)" >&2
    return 1
  fi
  if ! count="$(cast call "$factory" "gameCount()(uint256)" --rpc-url "$L1_RPC_URL" 2>/dev/null)"; then
    echo "ERROR: failed to read DisputeGameFactory gameCount from L1" >&2
    return 1
  fi
  count="${count%%[^0-9]*}"
  if ! [[ "$count" =~ ^[0-9]+$ ]] || (( count == 0 )); then
    echo "ERROR: DisputeGameFactory gameCount is zero or unreadable (got: ${count:-<empty>})" >&2
    return 1
  fi
  idx=$(( count - 1 ))
  if ! meta="$(cast call "$factory" "gameAtIndex(uint256)(uint32,uint64,address)" "$idx" --rpc-url "$L1_RPC_URL" 2>/dev/null)"; then
    echo "ERROR: failed to read gameAtIndex($idx) from DisputeGameFactory" >&2
    return 1
  fi
  proxy="$(python3 -c '
import re, sys
m = re.search(r"0x[a-fA-F0-9]{40}", sys.argv[1])
if not m:
    sys.exit(1)
print(m.group(0))
' "$meta")" || {
    echo "ERROR: could not parse game proxy from gameAtIndex($idx)" >&2
    return 1
  }
  if ! l2="$(cast call "$proxy" "l2BlockNumber()(uint256)" --rpc-url "$L1_RPC_URL" 2>/dev/null)"; then
    echo "ERROR: failed to read l2BlockNumber() from latest proposed game $proxy" >&2
    return 1
  fi
  l2="${l2%%[^0-9]*}"
  if ! [[ "$l2" =~ ^[0-9]+$ ]] || (( l2 == 0 )); then
    echo "ERROR: latest proposed game l2BlockNumber invalid (got: ${l2:-<empty>})" >&2
    return 1
  fi
  echo "$l2"
}

# Sidecar SafeDB enable L1: committed Task 4 constant, env-overridable.
resolve_cutover_safedb_enable_l1() {
  local val="${FORTEL2_CUTOVER_SAFEDB_ENABLE_L1:-$TASK5_SAFEDB_ENABLE_L1}"
  if ! [[ "$val" =~ ^[0-9]+$ ]] || (( val == 0 )); then
    echo "ERROR: unresolved safedb-enable-l1 (set FORTEL2_CUTOVER_SAFEDB_ENABLE_L1 or TASK5_SAFEDB_ENABLE_L1)" >&2
    return 1
  fi
  echo "$val"
}

# Pre-enable negative L1: committed Task 4 constant, env-overridable; must not be enable-1.
resolve_cutover_pre_enable_l1() {
  local val enable
  val="${FORTEL2_CUTOVER_PRE_ENABLE_L1:-$TASK5_PRE_ENABLE_L1}"
  if ! [[ "$val" =~ ^[0-9]+$ ]] || (( val == 0 )); then
    echo "ERROR: unresolved pre-enable-l1 (set FORTEL2_CUTOVER_PRE_ENABLE_L1 or TASK5_PRE_ENABLE_L1)" >&2
    return 1
  fi
  if ! enable="$(resolve_cutover_safedb_enable_l1)"; then
    return 1
  fi
  if (( val == enable - 1 )); then
    echo "ERROR: pre-enable-l1 must not be safedb-enable-l1 minus 1 (enable-1 trap)" >&2
    return 1
  fi
  echo "$val"
}

MODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rehearse) MODE=rehearse; shift ;;
    --preflight-only) MODE=preflight; shift ;;
    --execute) MODE=execute; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "ERROR: refuse to run without --rehearse, --preflight-only, or --execute" >&2
  usage >&2
  exit 2
fi

print_plan() {
  cat <<'EOF'
PLAN cutover-to-reth-sepolia
  1. preflight (decision 3) — abort on any red (abort is success)
  2. operator disables external write path (Access / write filter) — blocks continue
  3. sequencer-admin.sh stop  (PAUSE FIRST — op-node mints empty unsafe every 2s)
     wait unsafe == safe at the intended height AFTER pause
     CHECKPOINT 1 — proceed / abort (abort = zero-impact restart)
  4. record cutover number/hash, safe/finalized, output root, versions, L1 nonces
     stop geth stack in documented order (stop-all-sepolia; op-geth datadir read-only)
  5. flip FORTEL2_EL=reth (+ FORTEL2_RETH_PROFILE=sequencer_faultproof) in .env.sepolia
     start: op-reth → op-node enginekind=reth → write filter → batcher → proposer → challenger
     live SafeDB stays $DATA_DIR/safedb; sidecar SafeDB stays with the sidecar
  6. health: first reth block extends recorded parent; batcher channel; proposer root;
     challenger; smoke-transfer; deposit; viewer; status; alert-watch expected-stack
     CHECKPOINT 2 — re-enable writes / rollback
  NEVER debug_setHead. NEVER wipe either datadir. NEVER karst_time.
EOF
}

if [[ "$MODE" == "rehearse" ]]; then
  print_plan
  exit 0
fi

# --- preflight -------------------------------------------------------------
# Fixture shape (every key required). Live mode fills the same keys from chain.
# Tests flip one key to prove each gate can go red.

preflight_eval() {
  python3 - "$@" <<'PY'
import json, sys
path = sys.argv[1]
want = {
    "game216_status": 2,
    "withdrawal_finalized": True,
    "safe_head_lag": 2,  # max inclusive
    "verify_reth_parity": 0,
    "verify_reth_faultproof": 0,
    "check_el_pins": 0,
    "batcher_funded": True,
    "proposer_funded": True,
    "check_launchd": 0,
}
with open(path, encoding="utf-8") as fh:
    got = json.load(fh)
errors = []
if int(got.get("game216_status", -1)) != want["game216_status"]:
    errors.append("game216_status want 2 DEFENDER_WINS got %s" % got.get("game216_status"))
if got.get("withdrawal_finalized") is not True:
    errors.append("withdrawal_finalized want true got %s" % got.get("withdrawal_finalized"))
try:
    lag = int(got.get("safe_head_lag"))
except (TypeError, ValueError):
    errors.append("safe_head_lag missing or not an int")
    lag = 99
if lag > want["safe_head_lag"]:
    errors.append("safe_head_lag %s > 2" % lag)
for key in ("verify_reth_parity", "verify_reth_faultproof", "check_el_pins", "check_launchd"):
    if int(got.get(key, 1)) != 0:
        errors.append("%s want exit 0 got %s" % (key, got.get(key)))
for key in ("batcher_funded", "proposer_funded"):
    if got.get(key) is not True:
        errors.append("%s want true got %s" % (key, got.get(key)))
if errors:
    sys.stderr.write("PREFLIGHT FAIL\n" + "\n".join(errors) + "\n")
    sys.exit(1)
print("PREFLIGHT PASS")
PY
}

TASK5_GAME216_PROXY="${TASK5_GAME216_PROXY:-0xbD43A40dED613aabf89e14d2a91CE6E194A3e2Ed}"
TASK5_WITHDRAWAL_HASH="${TASK5_WITHDRAWAL_HASH:-0x06de34692e590ce003bddfa4dcbe9fe78c7360d753773b9804d6f3f9074a8abd}"

run_live_preflight() {
  require_sepolia_env
  require_bin cast
  require_bin python3
  local portal status finalized lag tmp
  portal="$(jq -r '.OptimismPortalProxy // empty' "$(deployments_json_path)")"
  [[ -n "$portal" ]] || { echo "ERROR: missing OptimismPortalProxy" >&2; exit 1; }
  tmp="$(mktemp)"
  status="$(cast call "$TASK5_GAME216_PROXY" "status()(uint8)" --rpc-url "$L1_RPC_URL")"
  finalized="$(cast call "$portal" "finalizedWithdrawals(bytes32)(bool)" \
    "$TASK5_WITHDRAWAL_HASH" --rpc-url "$L1_RPC_URL" 2>/dev/null || echo false)"
  case "$finalized" in
    true|false) ;;
    *) finalized=false ;;
  esac
  lag=99
  if cand="$(cast rpc optimism_syncStatus --rpc-url "${FORTEL2_RETH_NODE_RPC:-http://127.0.0.1:19547}" 2>/dev/null)" \
     && live="$(cast rpc optimism_syncStatus --rpc-url "${L2_NODE_RPC_URL}" 2>/dev/null)"; then
    lag="$(python3 -c '
import json, sys
def n(blob, key):
    d = json.loads(blob)
    if isinstance(d, dict) and "result" in d:
        d = d["result"]
    h = d.get(key) or {}
    return int(h.get("number") or 0)
c, l = sys.argv[1], sys.argv[2]
print(abs(n(l, "safe_l2") - n(c, "safe_l2")))
' "$cand" "$live")"
  fi
  local parity_ec=1 fp_ec=1 pins_ec=1 launchd_ec=1
  local game_l2_block safedb_enable_l1 pre_enable_l1
  if ! game_l2_block="$(resolve_cutover_game_l2_block)"; then
    echo "ERROR: could not resolve --game-l2-block for verify-reth-faultproof" >&2
    exit 1
  fi
  if ! safedb_enable_l1="$(resolve_cutover_safedb_enable_l1)"; then
    echo "ERROR: could not resolve --safedb-enable-l1 for verify-reth-faultproof" >&2
    exit 1
  fi
  if ! pre_enable_l1="$(resolve_cutover_pre_enable_l1)"; then
    echo "ERROR: could not resolve --pre-enable-l1 for verify-reth-faultproof" >&2
    exit 1
  fi
  "$SCRIPT_DIR/verify-reth-parity.sh" >/tmp/fortel2-cutover-parity.out 2>&1 && parity_ec=0 || parity_ec=$?
  "$SCRIPT_DIR/verify-reth-faultproof.sh" \
    --game-l2-block "$game_l2_block" \
    --safedb-enable-l1 "$safedb_enable_l1" \
    --pre-enable-l1 "$pre_enable_l1" \
    >/tmp/fortel2-cutover-fp.out 2>&1 && fp_ec=0 || fp_ec=$?
  "$SCRIPT_DIR/check-el-pins.sh" >/tmp/fortel2-cutover-pins.out 2>&1 && pins_ec=0 || pins_ec=$?
  "$SCRIPT_DIR/check-launchd.sh" >/tmp/fortel2-cutover-launchd.out 2>&1 && launchd_ec=0 || launchd_ec=$?
  local batcher_ok=false proposer_ok=false
  if require_min_balance_eth "$BATCHER_ADDRESS" "${SEPOLIA_BATCHER_MIN_ETH:-0.15}" "BATCHER"; then
    batcher_ok=true
  fi
  if require_min_balance_eth "$PROPOSER_ADDRESS" "${SEPOLIA_PROPOSER_MIN_ETH:-0.15}" "PROPOSER"; then
    proposer_ok=true
  fi
  python3 -c '
import json, sys
json.dump({
  "game216_status": int(sys.argv[1]),
  "withdrawal_finalized": sys.argv[2] == "true",
  "safe_head_lag": int(sys.argv[3]),
  "verify_reth_parity": int(sys.argv[4]),
  "verify_reth_faultproof": int(sys.argv[5]),
  "check_el_pins": int(sys.argv[6]),
  "batcher_funded": sys.argv[7] == "true",
  "proposer_funded": sys.argv[8] == "true",
  "check_launchd": int(sys.argv[9]),
}, open(sys.argv[10], "w"))
' "${status:-0}" "$finalized" "$lag" "$parity_ec" "$fp_ec" "$pins_ec" \
    "$batcher_ok" "$proposer_ok" "$launchd_ec" "$tmp"
  preflight_eval "$tmp"
  rm -f "$tmp"
}

if [[ "$MODE" == "preflight" ]]; then
  if [[ -n "${CUTOVER_PREFLIGHT_FIXTURE:-}" ]]; then
    preflight_eval "$CUTOVER_PREFLIGHT_FIXTURE"
    exit 0
  fi
  run_live_preflight
  exit 0
fi

# --execute is Phase B only.
if [[ "${FORTEL2_CUTOVER_EXECUTE:-}" != "1" ]]; then
  echo "ERROR: --execute refused — set FORTEL2_CUTOVER_EXECUTE=1 only in the announced window after Steve's go" >&2
  echo "Phase A: use --rehearse or --preflight-only." >&2
  exit 2
fi
if [[ ! -t 0 ]]; then
  echo "ERROR: --execute requires a tty for operator checkpoints" >&2
  exit 2
fi

require_sepolia_env
print_plan
run_live_preflight

confirm() {
  local prompt="$1"
  local ans
  echo
  echo "CHECKPOINT: $prompt"
  echo -n "Type proceed to continue, or abort: "
  read -r ans
  if [[ "$ans" != "proceed" ]]; then
    echo "Aborted at checkpoint (zero-impact if sequencing was not yet stopped, or restart geth if already stopped)."
    exit 3
  fi
}

confirm "preflight green — disable the external write path, then proceed to admin_stopSequencer?"
echo "Operator: disable Access / write path now, then continue."
confirm "writes disabled — run sequencer-admin.sh stop and drain?"
"$SCRIPT_DIR/sequencer-admin.sh" stop
echo "Waiting for unsafe == safe (drain; batcher publishes remaining channels)..."
# Drain bound: one batcher channel interval + L1 inclusion. Poll syncStatus.
python3 - "$L2_NODE_RPC_URL" <<'PY'
import json, subprocess, sys, time
url = sys.argv[1]
deadline = time.time() + 20 * 60
while time.time() < deadline:
    raw = subprocess.check_output(["cast", "rpc", "optimism_syncStatus", "--rpc-url", url], text=True)
    st = json.loads(raw)
    if isinstance(st, dict) and "result" in st:
        st = st["result"]
    u = int((st.get("unsafe_l2") or {}).get("number") or -1)
    s = int((st.get("safe_l2") or {}).get("number") or -2)
    print("drain unsafe=%s safe=%s" % (u, s), flush=True)
    if u == s and u >= 0:
        sys.exit(0)
    time.sleep(5)
sys.stderr.write("ERROR: drain timed out (unsafe != safe)\n")
sys.exit(1)
PY

confirm "CHECKPOINT 1 — unsafe==safe. Record + stop geth + flip FORTEL2_EL=reth? (abort here = restart geth, zero-impact)"
echo "Record cutover heads (redacted):"
cast block-number --rpc-url "$L2_RPC_URL"
cast rpc optimism_syncStatus --rpc-url "$L2_NODE_RPC_URL" | python3 -c '
import json,sys
st=json.loads(sys.stdin.read())
if isinstance(st,dict) and "result" in st: st=st["result"]
for k in ("unsafe_l2","safe_l2","finalized_l2"):
    h=st.get(k) or {}
    print("%s number=%s hash=%s" % (k, h.get("number"), h.get("hash")))
'
echo "Stop Sepolia stack (op-geth datadir left intact)."
"$SCRIPT_DIR/stop-all-sepolia.sh"
echo "Operator: set FORTEL2_EL=reth and FORTEL2_RETH_PROFILE=sequencer_faultproof in .env.sepolia (this script does not edit it)."
confirm "env flipped — start reth sequencer path?"
export FORTEL2_EL=reth
export FORTEL2_RETH_PROFILE=sequencer_faultproof
"$SCRIPT_DIR/start-all-sepolia.sh"
echo "Health next: first reth block must extend the recorded parent. Then CHECKPOINT 2."
confirm "CHECKPOINT 2 — health green? Type proceed to leave writes for the operator to re-enable (or abort → rollback-to-geth-sepolia.sh)"
echo "Cutover execute steps completed. Re-enable writes only after health is pasted into tasks/task5-op-reth-cutover.md."

