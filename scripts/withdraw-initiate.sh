#!/usr/bin/env bash
# US-011 step 1: Initiate ETH withdrawal on L2 via L2ToL1MessagePasser → ADMIN on L1.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin cast
require_bin jq
warn_if_missing_env_file
assert_local_rpc_urls
require_eth_address "ADMIN" "${ADMIN_ADDRESS:-}"
if [[ -z "${ADMIN_PRIVATE_KEY:-}" || ! "$ADMIN_PRIVATE_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
  echo "ERROR: ADMIN_PRIVATE_KEY missing or malformed" >&2
  exit 1
fi
refuse_foundry_defaults_unless_local_l2 "$ADMIN_PRIVATE_KEY" "ADMIN_PRIVATE_KEY"

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
  --argjson initiatedAt "$(date +%s)" \
  '{
    l2TxHash: $l2TxHash,
    l2BlockNumber: $l2BlockNumber,
    target: $target,
    amount: $amount,
    messagePasser: $messagePasser,
    initiatedAt: $initiatedAt
  }' > "$ARTIFACT"

L2_AFTER=$(cast balance "$ADMIN_ADDRESS" --rpc-url "$L2_RPC_URL")
echo "ADMIN L2 balance after:  $L2_AFTER wei"
echo "Artifact:                $ARTIFACT"
echo "Next: ./scripts/withdraw-prove.sh  (needs proposer game covering L2 block $BLOCK)"
echo "OK — withdrawal initiated on L2."
