#!/usr/bin/env bash
# Task 5 / PRD §9 rollback. VERIFIER-FIRST — never stock
# 04-start-sequencer-sepolia.sh (sequencer.stopped=false) as step one.
# That would build an alternate unsafe branch on the pre-cutover geth db.
#
# Order: stop writes → stop op-reth pair (datadir untouched) → start preserved
# op-geth + op-node --verifier-only → wait safe == canonical (incl. batched
# op-reth blocks) → sequencer-admin.sh start → verify continuity → writes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
usage: rollback-to-geth-sepolia.sh --rehearse|--execute

  --rehearse   print §9 verifier-first order; no process control
  --execute    operator window only — mutates the live stack

NEVER debug_setHead. NEVER delete or mutate either datadir.
NEVER call stock 04-start-sequencer-sepolia.sh as the first start
(must pass --verifier-only so sequencer.stopped=true).
EOF
}

MODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rehearse) MODE=rehearse; shift ;;
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
  echo "ERROR: refuse to run without --rehearse or --execute" >&2
  usage >&2
  exit 2
fi

print_plan() {
  cat <<'EOF'
PLAN rollback-to-geth-sepolia
  1. stop authenticated writes (Access / write filter)
  2. stop the op-reth pair (stop_bg op-node; stop_bg op-reth). datadir untouched
  3. START_GETH=04-start-sequencer-sepolia.sh --verifier-only
     (FORTEL2_EL=geth; --sequencer.enabled=true --sequencer.stopped=true)
     FORBIDDEN_FIRST_START=04-start-sequencer-sepolia.sh
     (stock stopped=false would mint an alternate unsafe branch on the geth db)
  4. wait rollback safe number+hash == canonical safe (L1-derived, including
     post-cutover op-reth blocks the batcher already published)
  5. sequencer-admin.sh start   (admin_startSequencer — only after safe catch-up)
  6. verify hash continuity; re-enable writes
  NEVER debug_setHead. NEVER wipe $DATA_DIR/l2/op-geth or $DATA_DIR/l2/op-reth.
EOF
}

if [[ "$MODE" == "rehearse" ]]; then
  print_plan
  exit 0
fi

if [[ "${FORTEL2_ROLLBACK_EXECUTE:-}" != "1" ]]; then
  echo "ERROR: --execute refused — set FORTEL2_ROLLBACK_EXECUTE=1 only after a §9 trigger and Steve's go" >&2
  echo "Phase A: use --rehearse (verifier-first order is the test)." >&2
  exit 2
fi
if [[ ! -t 0 ]]; then
  echo "ERROR: --execute requires a tty for operator checkpoints" >&2
  exit 2
fi

require_sepolia_env
print_plan

confirm() {
  local ans
  echo
  echo "CHECKPOINT: $1"
  echo -n "Type proceed to continue, or abort: "
  read -r ans
  if [[ "$ans" != "proceed" ]]; then
    echo "Aborted. Neither datadir was deleted."
    exit 3
  fi
}

confirm "stop authenticated writes, then stop the op-reth pair (datadirs untouched)?"
"$SCRIPT_DIR/sequencer-admin.sh" stop || true
stop_bg l2-rpc-filter || true
stop_bg op-challenger || true
stop_bg l1-batch-proxy || true
stop_bg op-proposer || true
stop_bg op-batcher || true
stop_bg op-node || true
stop_bg op-reth || true
stop_bg op-reth-node || true
echo "op-reth pair stopped. datadir $DATA_DIR/l2/op-reth untouched. op-geth datadir untouched."

confirm "start preserved geth VERIFIER-FIRST (--verifier-only, not stock 04-start)?"
export FORTEL2_EL=geth
# Stock 04-start-sequencer-sepolia.sh (no --verifier-only) is FORBIDDEN here.
"$SCRIPT_DIR/04-start-sequencer-sepolia.sh" --verifier-only

echo "Waiting for geth+op-node to derive canonical safe from L1 (incl. batched op-reth blocks)..."
python3 - "$L2_NODE_RPC_URL" <<'PY'
import json, subprocess, sys, time
url = sys.argv[1]
def snap():
    raw = subprocess.check_output(["cast", "rpc", "optimism_syncStatus", "--rpc-url", url], text=True)
    st = json.loads(raw)
    if isinstance(st, dict) and "result" in st:
        st = st["result"]
    s = st.get("safe_l2") or {}
    return int(s.get("number") or -1), s.get("hash")
deadline = time.time() + 60 * 60
last_n, last_h, stable = -1, None, 0
while time.time() < deadline:
    n, h = snap()
    print("rollback safe=%s %s" % (n, h), flush=True)
    if n >= 0 and n == last_n and h == last_h:
        stable += 1
        if stable >= 3:
            sys.exit(0)
    else:
        stable = 0
    last_n, last_h = n, h
    time.sleep(10)
sys.stderr.write("ERROR: rollback safe did not stabilize on a canonical head\n")
sys.exit(1)
PY

confirm "safe matches canonical — admin_startSequencer on live geth op-node?"
"$SCRIPT_DIR/sequencer-admin.sh" start
echo "Rollback sequencing enabled. Verify hash continuity, then re-enable writes."
echo "Operator: set FORTEL2_EL=geth in .env.sepolia if it was reth (monitors follow the selector)."

