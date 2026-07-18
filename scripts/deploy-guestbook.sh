#!/usr/bin/env bash
# US-008: Deploy Guestbook to L2 and write dapp/config.js
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin forge
require_bin cast
wait_for_rpc "$L2_RPC_URL" "L2"

cd "$FORTEL2_ROOT/contracts"
forge build

ADDR=$(forge create src/Guestbook.sol:Guestbook \
  --rpc-url "$L2_RPC_URL" \
  --private-key "$DEMO_A_PRIVATE_KEY" \
  --broadcast \
  --json | jq -r '.deployedTo // .address')

if [[ -z "$ADDR" || "$ADDR" == "null" ]]; then
  # Fallback parse from forge create text output
  OUT=$(forge create src/Guestbook.sol:Guestbook \
    --rpc-url "$L2_RPC_URL" \
    --private-key "$DEMO_A_PRIVATE_KEY" \
    --broadcast)
  echo "$OUT"
  ADDR=$(echo "$OUT" | awk '/Deployed to:/ {print $3}')
fi

echo "Guestbook deployed at $ADDR"
cat > "$FORTEL2_ROOT/dapp/config.js" << EOF
export const GUESTBOOK_ADDRESS = "${ADDR}";
export const GUESTBOOK_ABI = [
  "function sign(string calldata text)",
  "function count() view returns (uint256)",
  "function getMessage(uint256 index) view returns (string)",
  "event MessageSigned(address indexed author, string text, uint256 index)",
];
EOF

echo "$ADDR" > "$FORTEL2_ROOT/deployments/guestbook.txt"
cast call "$ADDR" "count()(uint256)" --rpc-url "$L2_RPC_URL"
echo "dapp/config.js updated. Serve with: scripts/serve-dapp.sh"
