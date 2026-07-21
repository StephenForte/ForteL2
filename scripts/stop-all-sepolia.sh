#!/usr/bin/env bash
# Phase 2c: stop Sepolia L2 processes only (uses DATA_DIR from .env.sepolia).
# Does not start/stop Anvil. Does not wipe Phase 1 ~/…/data.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_sepolia_env

for name in op-proposer op-batcher op-node op-geth; do
  stop_bg "$name"
done
echo "Sepolia L2 processes stopped (DATA_DIR=$DATA_DIR)."
echo "Phase 1 datadir untouched. Restart: FORTEL2_ENV=.env.sepolia ./scripts/start-all-sepolia.sh"
