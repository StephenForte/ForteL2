#!/usr/bin/env bash
# Initiate an ETH withdrawal on Sepolia L2 852.
# L2 stays loopback. Remote Sepolia L1 is allowed. Foundry default keys are refused.
# The local Anvil path remains scripts/withdraw-initiate.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin cast
require_bin jq
warn_if_missing_env_file
assert_l2_loopback_urls
assert_sepolia_rpc_urls
require_eth_address "ADMIN" "${ADMIN_ADDRESS:-}"
if [[ -z "${ADMIN_PRIVATE_KEY:-}" || ! "$ADMIN_PRIVATE_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
  echo "ERROR: ADMIN_PRIVATE_KEY missing or malformed" >&2
  exit 1
fi
refuse_foundry_defaults_unless_local_l2 "$ADMIN_PRIVATE_KEY" "ADMIN_PRIVATE_KEY"
if [[ "${L1_CHAIN_ID:-}" != "11155111" || "${L2_CHAIN_ID:-}" != "852" ]]; then
  echo "ERROR: withdraw-initiate-sepolia.sh stamps L1 11155111 and L2 852 (got L1=${L1_CHAIN_ID:-<unset>} L2=${L2_CHAIN_ID:-<unset>})" >&2
  exit 1
fi

AMOUNT="${WITHDRAW_AMOUNT:-0.05ether}"
GAS_LIMIT="${WITHDRAW_GAS_LIMIT:-100000}"
MESSAGE_PASSER="0x4200000000000000000000000000000000000016"
ARTIFACT_DIR="${BRIDGE_ARTIFACT_DIR:-$DATA_DIR/bridge}"
ARTIFACT="$ARTIFACT_DIR/last-withdrawal.json"

wait_for_rpc "$L2_RPC_URL" "L2"
mkdir -p "$ARTIFACT_DIR"

L2_BEFORE=$(cast balance "$ADMIN_ADDRESS" --rpc-url "$L2_RPC_URL")
echo "ADMIN L2 balance before: $L2_BEFORE wei"
echo "Initiating withdrawal of $AMOUNT to $ADMIN_ADDRESS via $MESSAGE_PASSER"

TX_JSON=$(cast send "$MESSAGE_PASSER" \
  "initiateWithdrawal(address,uint256,bytes)" \
  "$ADMIN_ADDRESS" \
  "$GAS_LIMIT" \
  "0x" \
  --value "$AMOUNT" \
  --private-key "$ADMIN_PRIVATE_KEY" \
  --rpc-url "$L2_RPC_URL" \
  --json)

L2_TX=$(echo "$TX_JSON" | jq -r '.transactionHash // .hash // empty')
if [[ -z "$L2_TX" || "$L2_TX" == "null" ]]; then
  echo "ERROR: L2 initiate tx failed" >&2
  echo "$TX_JSON" >&2
  exit 1
fi
echo "L2 initiate tx: $L2_TX"
RECEIPT=$(cast receipt "$L2_TX" --rpc-url "$L2_RPC_URL" --json)
BLOCK=$(echo "$RECEIPT" | jq -r .blockNumber)

jq -n \
  --arg l2TxHash "$L2_TX" \
  --arg l2BlockNumber "$BLOCK" \
  --arg target "$ADMIN_ADDRESS" \
  --arg amount "$AMOUNT" \
  --arg messagePasser "$MESSAGE_PASSER" \
  --argjson l1ChainId "$L1_CHAIN_ID" \
  --argjson l2ChainId "$L2_CHAIN_ID" \
  --argjson initiatedAt "$(date +%s)" \
  '{
    l2TxHash: $l2TxHash,
    l2BlockNumber: $l2BlockNumber,
    l1ChainId: $l1ChainId,
    l2ChainId: $l2ChainId,
    target: $target,
    amount: $amount,
    messagePasser: $messagePasser,
    initiatedAt: $initiatedAt
  }' > "$ARTIFACT"

L2_AFTER=$(cast balance "$ADMIN_ADDRESS" --rpc-url "$L2_RPC_URL")
echo "ADMIN L2 balance after:  $L2_AFTER wei"
echo "Artifact:                $ARTIFACT"
echo "Next: FORTEL2_ENV=.env.sepolia ./scripts/withdraw-prove-sepolia.sh  (type 9: the game sequence is a timestamp)"
echo "OK — withdrawal initiated on L2 852."
