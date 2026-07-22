#!/usr/bin/env bash
# Phase 2b: show Sepolia role balances + recommended funding from harvest.
# Does not broadcast. Does not print private keys.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin cast
require_sepolia_env
require_eth_address "HARVEST_ADDRESS" "${HARVEST_ADDRESS:-}"

# Recommended floors for disposable 2b deploy + short 2c headroom (ether).
ADMIN_MIN="${SEPOLIA_ADMIN_MIN_ETH:-0.70}"
BATCHER_MIN="${SEPOLIA_BATCHER_MIN_ETH:-0.15}"
PROPOSER_MIN="${SEPOLIA_PROPOSER_MIN_ETH:-0.15}"
# Sequencer / challenger / demos: not required for 2b apply
OPTIONAL_MIN="0.00"

# Exit non-zero only when Phase 2c gas roles (BATCHER/PROPOSER) print NEED.
# ADMIN/HARVEST floors stay advisory: after 2b apply ADMIN is often below 0.70
# while the stack is healthy; 02-deploy-contracts-sepolia.sh gates ADMIN itself.
fund_needs=0

print_row() {
  local label="$1"
  local addr="$2"
  local min="$3"
  # 1 = counts toward exit status (BATCHER/PROPOSER); 0 = advisory OK/NEED only.
  local blocking="${4:-0}"
  local bal_eth
  bal_eth="$(cast balance "$addr" --rpc-url "$L1_RPC_URL" --ether)"
  local ok="NEED"
  if python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) + 1e-18 >= float(sys.argv[2]) else 1)' "$bal_eth" "$min"; then
    ok="OK"
  elif (( blocking )); then
    fund_needs=1
  fi
  printf '%-12s %-42s %18s  min=%-6s %s\n' "$label" "$addr" "$bal_eth" "$min" "$ok"
}

echo "=== ForteL2 Sepolia fund check (L1=$(cast chain-id --rpc-url "$L1_RPC_URL")) ==="
echo "RPC: $L1_RPC_URL"
echo
print_row "HARVEST" "$HARVEST_ADDRESS" "0.05" 0
print_row "ADMIN" "$ADMIN_ADDRESS" "$ADMIN_MIN" 0
print_row "BATCHER" "$BATCHER_ADDRESS" "$BATCHER_MIN" 1
print_row "PROPOSER" "$PROPOSER_ADDRESS" "$PROPOSER_MIN" 1
print_row "SEQUENCER" "$SEQUENCER_ADDRESS" "$OPTIONAL_MIN" 0
print_row "CHALLENGER" "$CHALLENGER_ADDRESS" "$OPTIONAL_MIN" 0
if [[ -n "${DEMO_A_ADDRESS:-}" ]]; then
  print_row "DEMO_A" "$DEMO_A_ADDRESS" "$OPTIONAL_MIN" 0
fi
if [[ -n "${DEMO_B_ADDRESS:-}" ]]; then
  print_row "DEMO_B" "$DEMO_B_ADDRESS" "$OPTIONAL_MIN" 0
fi

echo
echo "Phase 2b needs ADMIN funded first (op-deployer gas). BATCHER/PROPOSER can wait until 2c."
echo "Fund FROM harvest using MetaMask or cast offline — never paste the harvest private key into chat."
echo
echo "Example cast sends (run in a shell that has HARVEST_PRIVATE_KEY; not stored in this repo):"
cat <<EOF
cast send ${ADMIN_ADDRESS} --value ${ADMIN_MIN}ether --private-key \$HARVEST_PRIVATE_KEY --rpc-url ${L1_RPC_URL}
cast send ${BATCHER_ADDRESS} --value ${BATCHER_MIN}ether --private-key \$HARVEST_PRIVATE_KEY --rpc-url ${L1_RPC_URL}
cast send ${PROPOSER_ADDRESS} --value ${PROPOSER_MIN}ether --private-key \$HARVEST_PRIVATE_KEY --rpc-url ${L1_RPC_URL}
EOF
echo
echo "When ADMIN shows OK, run:"
echo "  FORTEL2_ENV=.env.sepolia ./scripts/02-deploy-contracts-sepolia.sh"

if (( fund_needs )); then
  echo "Fund check: BATCHER and/or PROPOSER below recommended floors (NEED)." >&2
  exit 1
fi
