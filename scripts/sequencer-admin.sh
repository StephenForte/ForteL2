#!/usr/bin/env bash
# Loopback op-node admin helper (PRD §12 / Task 5).
# admin_sequencerActive / admin_stopSequencer / admin_startSequencer.
# Never dials a non-loopback URL. Never prints keys or provider URLs.
#
# Sidecar start is refused by default: admin_startSequencer on the candidate
# verifier would enable sequencing against $DATA_DIR/l2/op-reth while live
# geth is still the producer.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
usage: sequencer-admin.sh status|stop|start [--rpc URL] [--dry-run]

Talk to a loopback op-node admin RPC (--rpc.enable-admin).

  status    admin_sequencerActive
  stop      admin_stopSequencer   (pause first — unsafe never catches safe otherwise)
  start     admin_startSequencer
  --rpc     default L2_NODE_RPC_URL (live :9547) or FORTEL2_ADMIN_RPC
  --dry-run print method + redacted URL; do not send

Sidecar default :19547: status/stop allowed; start refused unless
FORTEL2_ADMIN_ALLOW_SIDECAR_START=1 (candidate protection).
EOF
}

CMD=""
RPC=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    status|stop|start) CMD="$1"; shift ;;
    --rpc) RPC="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$CMD" ]]; then
  usage >&2
  exit 2
fi

RPC="${RPC:-${FORTEL2_ADMIN_RPC:-${L2_NODE_RPC_URL:-http://127.0.0.1:9547}}}"
assert_loopback_url "$RPC" "op-node admin RPC"

SIDECAR_PORT="$(reth_node_rpc_port)"
RPC_PORT=""
case "$RPC" in
  *:[0-9]*) RPC_PORT="${RPC##*:}" ;;
esac
RPC_PORT="${RPC_PORT%%/*}"

if [[ "$CMD" == "start" && "$RPC_PORT" == "$SIDECAR_PORT" \
   && "${FORTEL2_ADMIN_ALLOW_SIDECAR_START:-}" != "1" ]]; then
  echo "ERROR: refusing admin_startSequencer on sidecar :$SIDECAR_PORT — that would sequence the candidate datadir" >&2
  echo "Live admin RPC is L2_NODE_RPC_URL (default :9547). Override with FORTEL2_ADMIN_ALLOW_SIDECAR_START=1 only in a throwaway fixture." >&2
  exit 1
fi

case "$CMD" in
  status) METHOD=admin_sequencerActive ;;
  stop) METHOD=admin_stopSequencer ;;
  start) METHOD=admin_startSequencer ;;
esac

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "METHOD=${METHOD}"
  echo "RPC=$(redact_rpc_url "$RPC")"
  echo "CMD=${CMD}"
  exit 0
fi

require_bin cast
echo "admin ${CMD} → $(redact_rpc_url "$RPC") (${METHOD})"
RESULT="$(cast rpc "$METHOD" --rpc-url "$RPC")"
echo "result=${RESULT}"
if [[ "$CMD" == "status" ]]; then
  case "$RESULT" in
    true|false) ;;
    *)
      echo "ERROR: admin_sequencerActive returned ${RESULT} (want true|false)" >&2
      exit 1
      ;;
  esac
fi
