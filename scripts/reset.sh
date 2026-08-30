#!/usr/bin/env bash
# Full reset: stop processes, wipe L1/L2 data + deployment artifacts (re-genesis on next start).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_fortel2_el
if [[ "$(fortel2_el)" == "reth" ]]; then
  echo "FORTEL2_EL=reth — stopping sidecar and wiping reth datadir only (op-geth / Anvil untouched)"
  stop_reth_sidecar
  wipe_reth_datadir
  echo "Reth datadir reset complete. Mid-chain rewind is this wipe + re-derive; never debug_setHead."
  echo "op-geth at $DATA_DIR/l2/op-geth was not touched."
  exit 0
fi

"$SCRIPT_DIR/stop-all.sh"

echo "Wiping data + deployment artifacts (including Anvil L1 state) ..."
rm -rf "$DATA_DIR/l1" "$DATA_DIR/l2" "$DATA_DIR/pids" "$DATA_DIR/jwt"
rm -f "$LOG_DIR"/*.log
rm -rf "$DEPLOY_DIR"
rm -f "$FORTEL2_ROOT/deployments/deployments.json"
rm -f "$FORTEL2_ROOT/deployments/guestbook.txt"
mkdir -p "$DEPLOY_DIR" "$LOG_DIR" "$PID_DIR" "$DATA_DIR/l1"
echo "Reset complete. Next: scripts/start-all.sh (will redeploy contracts)."
