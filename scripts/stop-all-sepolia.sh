#!/usr/bin/env bash
# Phase 2c: stop Sepolia L2 processes only (uses DATA_DIR from .env.sepolia).
# Does not start/stop Anvil. Does not wipe Phase 1 ~/…/data.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_sepolia_env

# l2-rpc-filter first — it only dials loopback op-geth; stop before tearing EL down.
# op-challenger next — it dials L1 (or l1-batch-proxy) + loopback op-node/op-geth.
# l1-batch-proxy after challenger — challenger is its only consumer on this host.
for name in l2-rpc-filter op-challenger l1-batch-proxy op-proposer op-batcher op-node op-geth; do
  stop_bg "$name"
done
# Opt-in sidecar (Task 2). Keep this OUT of the `for name in` list — start/stop
# symmetry tests derive that list against start-all-sepolia.sh (still geth).
# stop_bg is a no-op without a pidfile; live geth is not this pair.
stop_reth_sidecar
echo "Sepolia L2 processes stopped (DATA_DIR=$DATA_DIR)."
echo "Phase 1 datadir untouched. Restart: FORTEL2_ENV=.env.sepolia ./scripts/start-all-sepolia.sh"
