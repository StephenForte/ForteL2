#!/usr/bin/env bash
# Phase 3 / US-031: compare Render (or remote) replica heads to local Sepolia sequencer.
# Requires local Phase 2c stack up. Does not print private keys or raw tokenized RPC URLs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin cast
require_bin jq
require_sepolia_env

REPLICA_L2="${REPLICA_L2_RPC_URL:-}"
REPLICA_NODE="${REPLICA_NODE_RPC_URL:-}"
MAX_LAG="${REPLICA_MAX_SAFE_LAG:-50}"

if [[ -z "$REPLICA_L2" ]]; then
  echo "ERROR: set REPLICA_L2_RPC_URL to the replica EL HTTP endpoint" >&2
  exit 1
fi

echo "=== Replica sync check ==="
echo "Local L2:    $(redact_rpc_url "$L2_RPC_URL")"
echo "Replica L2:  $(redact_rpc_url "$REPLICA_L2")"
if [[ -n "$REPLICA_NODE" ]]; then
  echo "Replica node: $(redact_rpc_url "$REPLICA_NODE")"
fi
echo

wait_for_rpc "$L2_RPC_URL" "local L2" 20
wait_for_rpc "$REPLICA_L2" "replica L2" 30

LOCAL_CHAIN="$(cast chain-id --rpc-url "$L2_RPC_URL")"
REPLICA_CHAIN="$(cast chain-id --rpc-url "$REPLICA_L2")"
if [[ "$LOCAL_CHAIN" != "$REPLICA_CHAIN" ]]; then
  echo "ERROR: chain id mismatch local=$LOCAL_CHAIN replica=$REPLICA_CHAIN" >&2
  exit 1
fi
if [[ "$REPLICA_CHAIN" != "852" ]]; then
  echo "ERROR: expected L2 chain 852, got $REPLICA_CHAIN" >&2
  exit 1
fi

LOCAL_BN="$(cast block-number --rpc-url "$L2_RPC_URL")"
REPLICA_BN="$(cast block-number --rpc-url "$REPLICA_L2")"
echo "EL tip:  local=$LOCAL_BN  replica=$REPLICA_BN"

LOCAL_SAFE=""
REPLICA_SAFE=""
if [[ -n "${L2_NODE_RPC_URL:-}" ]]; then
  LOCAL_SAFE="$(cast rpc optimism_syncStatus --rpc-url "$L2_NODE_RPC_URL" 2>/dev/null \
    | jq -r '.safe_l2.number // .safe_l2 // empty' || true)"
fi
if [[ -n "$REPLICA_NODE" ]]; then
  REPLICA_SAFE="$(cast rpc optimism_syncStatus --rpc-url "$REPLICA_NODE" 2>/dev/null \
    | jq -r '.safe_l2.number // .safe_l2 // empty' || true)"
fi

if [[ -n "$LOCAL_SAFE" && -n "$REPLICA_SAFE" ]]; then
  echo "Safe L2: local=$LOCAL_SAFE  replica=$REPLICA_SAFE"
  LAG=$((LOCAL_SAFE - REPLICA_SAFE))
  if (( LAG < 0 )); then LAG=$((-LAG)); fi
  echo "Safe lag (abs): $LAG (max allowed $MAX_LAG)"
  if (( LAG > MAX_LAG )); then
    echo "ERROR: replica safe head lag $LAG exceeds REPLICA_MAX_SAFE_LAG=$MAX_LAG" >&2
    exit 1
  fi
else
  # Fallback: EL tip lag (replica may trail unsafe head until batches land on L1)
  LAG=$((LOCAL_BN - REPLICA_BN))
  if (( LAG < 0 )); then LAG=$((-LAG)); fi
  echo "EL tip lag (abs): $LAG (max allowed $MAX_LAG) — op-node RPC not both available"
  if (( REPLICA_BN < 1 )); then
    echo "ERROR: replica tip is still genesis — not syncing?" >&2
    exit 1
  fi
  if (( LAG > MAX_LAG )); then
    echo "ERROR: replica EL tip lag $LAG exceeds REPLICA_MAX_SAFE_LAG=$MAX_LAG" >&2
    echo "Note: L1-derived replicas trail unsafe head until batches are on Sepolia." >&2
    exit 1
  fi
fi

echo "OK — replica appears synced within lag budget."
