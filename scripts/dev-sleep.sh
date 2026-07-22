#!/usr/bin/env bash
# Overnight / idle "development sleep" — stop credit & gas burners; wake later.
#
# Usage:
#   FORTEL2_ENV=.env.sepolia ./scripts/dev-sleep.sh sleep
#   FORTEL2_ENV=.env.sepolia ./scripts/dev-sleep.sh wake
#   FORTEL2_ENV=.env.sepolia ./scripts/dev-sleep.sh status
#   ./scripts/dev-sleep.sh sleep|wake|status          # Phase 1 Anvil stack
#
# What to turn OFF while sleeping (Sepolia / QuickNode):
#   ✓ Mac sequencer stack (op-geth, op-node, batcher, proposer) — main QN + ETH burn
#   ✓ Pipeline viewer / dApp HTTP if running — viewer polls L1
#   ✓ Render fortel2-replica (dashboard Suspend) — optional but recommended
# What to leave alone:
#   • QuickNode endpoints (keep URLs; stopping clients is enough)
#   • Datadir / deployments (not wiped)
#   • Once-daily launchd health snapshot (negligible credits)
#
# Does not edit start_bg/stop_bg. Does not wipe DATA_DIR.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} /^set -euo/{exit}' "$0"
}

CMD="${1:-}"
case "$CMD" in
  -h|--help|help)
    usage
    exit 0
    ;;
  sleep|wake|status) ;;
  *)
    echo "Usage: $0 sleep|wake|status   (see --help)" >&2
    exit 1
    ;;
esac

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

IS_SEPOLIA=0
if [[ "${L2_CHAIN_ID:-}" == "852" ]] || [[ "${FORTEL2_ENV:-}" == *sepolia* ]]; then
  require_sepolia_env
  IS_SEPOLIA=1
fi

stop_loopback_port() {
  local port="$1"
  local label="$2"
  require_http_port "$port" "$label"
  if ! command -v lsof >/dev/null 2>&1; then
    echo "WARN: lsof missing — cannot free :$port ($label)" >&2
    return 0
  fi
  local pids
  pids="$(lsof -nP -iTCP:"${port}" -sTCP:LISTEN -t 2>/dev/null || true)"
  if [[ -z "$pids" ]]; then
    echo "$label :$port not listening"
    return 0
  fi
  echo "Stopping $label on :$port (pids: $(echo "$pids" | tr '\n' ' '))"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  sleep 0.5
  # shellcheck disable=SC2086
  kill -9 $pids 2>/dev/null || true
}

cmd_sleep() {
  echo "=== ForteL2 dev-sleep ==="
  if (( IS_SEPOLIA )); then
    echo "Mode: Sepolia (L2 $L2_CHAIN_ID) — stopping metered L1 clients"
    "$SCRIPT_DIR/stop-all-sepolia.sh"
  else
    echo "Mode: Phase 1 local Anvil — stopping native stack"
    "$SCRIPT_DIR/stop-all.sh"
  fi

  stop_loopback_port "${DAPP_HTTP_PORT:-8080}" "dApp HTTP"
  stop_loopback_port "${VIEWER_HTTP_PORT:-8081}" "pipeline viewer HTTP"

  echo
  echo "Mac stack is down. Datadir kept ($DATA_DIR)."
  if (( IS_SEPOLIA )); then
    echo
    echo "Also recommended (saves Render QuickNode credits):"
    echo "  Render → fortel2-replica → Suspend"
    echo "  (or leave running if you need overnight L1-derived sync)"
    echo
    echo "Wake tomorrow:"
    echo "  FORTEL2_ENV=.env.sepolia $SCRIPT_DIR/dev-sleep.sh wake"
    echo "  # then resume Render if you suspended it"
  else
    echo
    echo "Wake:  $SCRIPT_DIR/dev-sleep.sh wake"
  fi
}

cmd_wake() {
  echo "=== ForteL2 dev-wake ==="
  if (( IS_SEPOLIA )); then
    echo "Starting Sepolia stack (credit-budget poll/channel defaults)…"
    "$SCRIPT_DIR/start-all-sepolia.sh"
    echo
    echo "Optional demos (do not leave viewer open overnight):"
    echo "  FORTEL2_ENV=.env.sepolia $SCRIPT_DIR/serve-viewer.sh"
    echo "  FORTEL2_ENV=.env.sepolia $SCRIPT_DIR/serve-dapp.sh"
    echo "  FORTEL2_ENV=.env.sepolia $SCRIPT_DIR/demo-live.sh --sepolia"
    echo
    echo "If you suspended Render: resume fortel2-replica in the dashboard."
  else
    echo "Starting Phase 1 Anvil stack…"
    "$SCRIPT_DIR/start-all.sh"
    echo
    echo "Optional: $SCRIPT_DIR/demo-live.sh --local"
  fi
  echo
  "$SCRIPT_DIR/status.sh"
}

cmd_status() {
  echo "=== ForteL2 sleep/wake status ==="
  if (( IS_SEPOLIA )); then
    echo "Mode: Sepolia  DATA_DIR=$DATA_DIR"
  else
    echo "Mode: Phase 1  DATA_DIR=$DATA_DIR"
  fi
  "$SCRIPT_DIR/status.sh"
  if command -v lsof >/dev/null 2>&1; then
    for pair in "dApp:${DAPP_HTTP_PORT:-8080}" "viewer:${VIEWER_HTTP_PORT:-8081}"; do
      local name="${pair%%:*}"
      local port="${pair##*:}"
      if lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "  $name HTTP: LISTEN :$port"
      else
        echo "  $name HTTP: stopped"
      fi
    done
  fi
}

case "$CMD" in
  sleep) cmd_sleep ;;
  wake) cmd_wake ;;
  status) cmd_status ;;
esac
