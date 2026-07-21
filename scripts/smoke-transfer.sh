#!/usr/bin/env bash
# US-004 smoke: ETH transfer between two genesis-funded L2 accounts.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin cast
assert_loopback_url "$L2_RPC_URL" "L2_RPC_URL"
refuse_foundry_defaults_unless_local_l2 "${DEMO_A_PRIVATE_KEY:-}" "DEMO_A_PRIVATE_KEY"
wait_for_rpc "$L2_RPC_URL" "L2"

BEFORE_A=$(cast balance "$DEMO_A_ADDRESS" --rpc-url "$L2_RPC_URL")
BEFORE_B=$(cast balance "$DEMO_B_ADDRESS" --rpc-url "$L2_RPC_URL")
echo "Before: A=$BEFORE_A B=$BEFORE_B"

TX=$(cast send "$DEMO_B_ADDRESS" \
  --value 0.01ether \
  --private-key "$DEMO_A_PRIVATE_KEY" \
  --rpc-url "$L2_RPC_URL" \
  --json | jq -r '.transactionHash // .hash')

echo "Transfer tx: $TX"
cast receipt "$TX" --rpc-url "$L2_RPC_URL" | head -20

AFTER_A=$(cast balance "$DEMO_A_ADDRESS" --rpc-url "$L2_RPC_URL")
AFTER_B=$(cast balance "$DEMO_B_ADDRESS" --rpc-url "$L2_RPC_URL")
echo "After:  A=$AFTER_A B=$AFTER_B"

# Receipt success alone is not enough — require the value transfer landed.
if ! uint_gt "$AFTER_B" "$BEFORE_B"; then
  echo "ERROR: DEMO_B balance did not increase after transfer" >&2
  echo "  before=$BEFORE_B after=$AFTER_B tx=$TX" >&2
  exit 1
fi
if ! uint_gt "$BEFORE_A" "$AFTER_A"; then
  echo "ERROR: DEMO_A balance did not decrease after transfer (value + gas)" >&2
  echo "  before=$BEFORE_A after=$AFTER_A tx=$TX" >&2
  exit 1
fi

echo "OK — L2 transfer confirmed."
