#!/usr/bin/env bash
# Phase 2c: L1→L2 deposit on Sepolia-backed learning chain (ADMIN).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin cast
require_bin jq
require_sepolia_env
warn_if_missing_env_file
require_eth_address "ADMIN" "${ADMIN_ADDRESS:-}"
if [[ -z "${ADMIN_PRIVATE_KEY:-}" || ! "$ADMIN_PRIVATE_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
  echo "ERROR: ADMIN_PRIVATE_KEY missing or malformed" >&2
  exit 1
fi
refuse_foundry_defaults_unless_local_l2 "$ADMIN_PRIVATE_KEY" "ADMIN_PRIVATE_KEY"

AMOUNT="${DEPOSIT_AMOUNT:-0.01ether}"
MIN_GAS="${DEPOSIT_MIN_GAS:-200000}"
# Sepolia L1 ~12s + public RPC + L1-origin catch-up after cold start can take several minutes
POLL_TRIES="${DEPOSIT_POLL_TRIES:-600}"
DEPLOYMENTS_JSON="$(deployments_json_path)"

if [[ ! -f "$DEPLOYMENTS_JSON" ]]; then
  echo "ERROR: missing $DEPLOYMENTS_JSON — run Phase 2b deploy first" >&2
  exit 1
fi

BRIDGE=$(jq -r '.L1StandardBridgeProxy // empty' "$DEPLOYMENTS_JSON")
PORTAL=$(jq -r '.OptimismPortalProxy // empty' "$DEPLOYMENTS_JSON")
require_eth_address "L1StandardBridgeProxy" "$BRIDGE"
require_eth_address "OptimismPortalProxy" "$PORTAL"

wait_for_rpc "$L1_RPC_URL" "L1 Sepolia"
wait_for_rpc "$L2_RPC_URL" "L2"

BEFORE=$(cast balance "$ADMIN_ADDRESS" --rpc-url "$L2_RPC_URL")
echo "ADMIN L2 balance before: $BEFORE wei"
echo "Depositing $AMOUNT via L1StandardBridge $BRIDGE → portal $PORTAL"

TX_JSON=$(cast send "$BRIDGE" \
  "bridgeETH(uint32,bytes)" \
  "$MIN_GAS" \
  "0x" \
  --value "$AMOUNT" \
  --private-key "$ADMIN_PRIVATE_KEY" \
  --rpc-url "$L1_RPC_URL" \
  --json)

L1_TX=$(echo "$TX_JSON" | jq -r '.transactionHash // .hash // empty')
if [[ -z "$L1_TX" || "$L1_TX" == "null" ]]; then
  echo "ERROR: L1 deposit tx failed" >&2
  echo "$TX_JSON" >&2
  exit 1
fi
echo "L1 deposit tx: $L1_TX"
cast receipt "$L1_TX" --rpc-url "$L1_RPC_URL" >/dev/null

echo "Waiting for L2 balance to increase (derivation; up to ${POLL_TRIES}s) ..."
AFTER="$BEFORE"
for ((i = 0; i < POLL_TRIES; i++)); do
  AFTER=$(cast balance "$ADMIN_ADDRESS" --rpc-url "$L2_RPC_URL")
  if uint_gt "$AFTER" "$BEFORE"; then
    break
  fi
  sleep 1
done

if ! uint_gt "$AFTER" "$BEFORE"; then
  echo "ERROR: L2 balance did not increase after ${POLL_TRIES}s — is sequencer+op-node deriving?" >&2
  echo "L1 tx: $L1_TX" >&2
  echo "L2 balance before=${BEFORE} after=${AFTER}" >&2
  exit 1
fi

L2_TX=""
TIP=$(cast block-number --rpc-url "$L2_RPC_URL")
START=$((TIP > 40 ? TIP - 40 : 0))
ADMIN_LC=$(echo "$ADMIN_ADDRESS" | tr '[:upper:]' '[:lower:]')
for ((bn = TIP; bn >= START; bn--)); do
  BLOCK_JSON=$(cast block "$bn" --full --rpc-url "$L2_RPC_URL" --json 2>/dev/null || true)
  [[ -z "$BLOCK_JSON" ]] && continue
  CAND=$(echo "$BLOCK_JSON" | jq -r --arg admin "$ADMIN_LC" '
    .transactions[]?
    | select((.from // "" | ascii_downcase) == $admin)
    | select(.type == "0x7e" or .type == "126")
    | .hash' | head -1 || true)
  if [[ -n "${CAND:-}" ]]; then
    L2_TX="$CAND"
    break
  fi
done

echo "ADMIN L2 balance after:  $AFTER wei"
echo "L1 bridge tx:            $L1_TX"
if [[ -n "$L2_TX" ]]; then
  echo "L2 deposit tx:           $L2_TX"
else
  echo "L2 deposit tx:           (not found in recent tip — L2 balance rise confirms inclusion)"
fi
echo "OK — Phase 2c deposit dry-run confirmed."
