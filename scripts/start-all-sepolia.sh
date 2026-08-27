#!/usr/bin/env bash
# Phase 2c: cold-start L2 against Sepolia L1 (no Anvil, no redeploy).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_sepolia_env
assert_block_times
assert_l2_ports_free
# T5-D1: L2_WRITE_RPC_PORT is not in assert_l2_ports_free (lib.sh CODEOWNERS).
# Check it here — before the ERR trap — so a squat on :9555 fails closed
# without starting the sequencer and then tearing it down mid-start.
# Also refuse collisions with the six ports assert_l2_ports_free already covers
# (filter binding first would otherwise leave batcher/proposer absent while
# start-all reports success — D-0027 failure mode).
WRITE_PORT="${L2_WRITE_RPC_PORT:-9555}"
require_http_port "$WRITE_PORT" "L2_WRITE_RPC_PORT"
for occupied in \
  "${L2_EL_HTTP_PORT}" \
  "${L2_EL_WS_PORT}" \
  "${L2_EL_AUTH_PORT}" \
  "${L2_NODE_RPC_PORT}" \
  "${BATCHER_RPC_PORT}" \
  "${PROPOSER_RPC_PORT}"
do
  if [[ "$WRITE_PORT" == "$occupied" ]]; then
    echo "ERROR: L2_WRITE_RPC_PORT ($WRITE_PORT) collides with an L2 stack port ($occupied)" >&2
    exit 1
  fi
done
if ! command -v lsof >/dev/null 2>&1; then
  echo "ERROR: lsof is required to verify L2 write filter port is free (install lsof)" >&2
  exit 1
fi
if lsof -nP -iTCP:"${WRITE_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "ERROR: port ${WRITE_PORT} already in use — stop Phase 1 (./scripts/stop-all.sh) or free the port" >&2
  exit 1
fi
warn_if_missing_env_file

DEPLOYMENTS="$(deployments_json_path)"
# Require L1 proxy JSON too — batcher/proposer read it; without this check the
# sequencer can start and then 05-start-batcher-sepolia.sh exits, leaving
# op-geth + op-node orphaned.
if [[ ! -f "$DEPLOY_DIR/genesis.json" || ! -f "$DEPLOY_DIR/rollup.json" || ! -f "$DEPLOYMENTS" ]]; then
  echo "ERROR: missing Sepolia genesis/rollup under $DEPLOY_DIR or L1 proxies at $DEPLOYMENTS" >&2
  echo "Run: FORTEL2_ENV=.env.sepolia ./scripts/02-deploy-contracts-sepolia.sh" >&2
  exit 1
fi

# Preflight gas floors before touching the sequencer. A mid-start fail on
# require_min_balance_eth otherwise leaves op-geth holding :9545 and the next
# wake (launchd) dies on assert_l2_ports_free.
require_eth_address "BATCHER_ADDRESS" "${BATCHER_ADDRESS:-}"
require_eth_address "PROPOSER_ADDRESS" "${PROPOSER_ADDRESS:-}"
require_min_balance_eth "$BATCHER_ADDRESS" "${SEPOLIA_BATCHER_MIN_ETH:-0.15}" "BATCHER"
require_min_balance_eth "$PROPOSER_ADDRESS" "${SEPOLIA_PROPOSER_MIN_ETH:-0.15}" "PROPOSER"

echo "=== ForteL2 Phase 2c — Sepolia-backed L2 ==="
echo "L1 RPC:  $(redact_rpc_url "$L1_RPC_URL")"
echo "DATA_DIR: $DATA_DIR"
echo "DEPLOY:  $DEPLOY_DIR"
echo "(Phase 1 Anvil/datadir not started or modified)"
echo

# If batcher/proposer still fail after the sequencer is up, tear down so wake
# does not leave orphans on L2 ports.
sepolia_start_cleanup() {
  echo "ERROR: Sepolia start failed after sequencer — stopping partial stack" >&2
  "$SCRIPT_DIR/stop-all-sepolia.sh" || true
}

# Optional fault-proof services. Call AFTER `trap - ERR`: a challenger (or
# proxy) failure — including D-0103 "balance could not be established" — must
# not fire sepolia_start_cleanup. Core stack stays up; we yell on stderr.
# Test-only overrides (names never appear in env files, so they survive
# lib.sh `set -a` sourcing): FORTEL2_START_L1_BATCH_PROXY_SH,
# FORTEL2_START_CHALLENGER_SH.
start_optional_sepolia_fault_proofs() {
  local proxy_sh challenger_sh
  proxy_sh="${FORTEL2_START_L1_BATCH_PROXY_SH:-$SCRIPT_DIR/start-l1-batch-proxy-sepolia.sh}"
  challenger_sh="${FORTEL2_START_CHALLENGER_SH:-$SCRIPT_DIR/09-start-challenger-sepolia.sh}"
  if [[ -n "${CHALLENGER_L1_RPC_URL:-}" ]]; then
    echo "Starting l1-batch-proxy (CHALLENGER_L1_RPC_URL is set; D-0081)"
    "$proxy_sh" || return $?
  else
    echo "Skipping l1-batch-proxy (CHALLENGER_L1_RPC_URL unset; challenger dials L1_RPC_URL)"
  fi
  echo "Starting op-challenger"
  "$challenger_sh" || return $?
  return 0
}

trap sepolia_start_cleanup ERR

"$SCRIPT_DIR/04-start-sequencer-sepolia.sh"
sleep 3
# T5-D1: narrow write-facing door (eth/net/web3 allowlist). Full op-geth stays on L2_RPC_URL.
"$SCRIPT_DIR/07-start-rpc-filter-sepolia.sh"
"$SCRIPT_DIR/05-start-batcher-sepolia.sh"
"$SCRIPT_DIR/06-start-proposer-sepolia.sh"
trap - ERR

# Capture status — a plain assignment aborts under set -e (bash 3.2 / D-0103).
optional_rc=0
start_optional_sepolia_fault_proofs || optional_rc=$?
if [[ "$optional_rc" -ne 0 ]]; then
  echo "ERROR: optional fault-proof services failed (exit $optional_rc) — sequencer, batcher, and proposer left running" >&2
  echo "ERROR: fault-proof defense is OFF until op-challenger is restored" >&2
fi

WRITE_PORT="${L2_WRITE_RPC_PORT:-9555}"
echo
echo "=== Sepolia L2 stack is up ==="
echo "L2 RPC (full/operator):  $(redact_rpc_url "$L2_RPC_URL")  (chain $L2_CHAIN_ID)"
echo "L2 write filter:         http://127.0.0.1:${WRITE_PORT}  (eth/net/web3 only; tunnel target)"
if is_running op-challenger; then
  echo "Challenger:              RUNNING"
else
  echo "Challenger:              not running (optional; core stack is up)"
fi
echo "Status:  FORTEL2_ENV=.env.sepolia $SCRIPT_DIR/status.sh"
echo "Stop:    FORTEL2_ENV=.env.sepolia $SCRIPT_DIR/stop-all-sepolia.sh"
