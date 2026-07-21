#!/usr/bin/env bash
# Phase 2d: verify L1_RPC_URL reaches Ethereum Sepolia (11155111).
# Safe to run with QuickNode URLs that embed tokens — prints a redacted host only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin cast
require_sepolia_env

URL="$L1_RPC_URL"
echo "=== Sepolia L1 RPC check ==="
echo "L1_RPC_URL (redacted): $(redact_rpc_url "$URL")"

# wait_for_rpc logs a redacted URL (shared redact_rpc_url in lib.sh).
wait_for_rpc "$URL" "L1" 30
CHAIN="$(cast chain-id --rpc-url "$URL")"
BLOCK="$(cast block-number --rpc-url "$URL")"

if [[ "$CHAIN" != "11155111" ]]; then
  echo "ERROR: expected Ethereum Sepolia chain id 11155111, got $CHAIN" >&2
  echo "Check that the QuickNode endpoint is Sepolia, not mainnet / Base Sepolia." >&2
  exit 1
fi

echo "OK  chain_id=$CHAIN  block=$BLOCK"
echo
echo "To use this endpoint for Phase 2c stack:"
echo "  1. Set L1_RPC_URL in .env.sepolia to your QuickNode HTTPS URL"
echo "  2. FORTEL2_ENV=.env.sepolia ./scripts/stop-all-sepolia.sh"
echo "  3. FORTEL2_ENV=.env.sepolia ./scripts/start-all-sepolia.sh"
echo "No redeploy. No new keys. Render is not an L1 (see Phase 3)."
