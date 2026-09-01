#!/usr/bin/env bash
# Phase 2c: stop Sepolia L2 processes only (uses DATA_DIR from .env.sepolia).
# Does not start/stop Anvil. Does not wipe Phase 1 ~/…/data.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_sepolia_env

# l2-rpc-filter first — it only dials loopback EL; stop before tearing EL down.
# op-challenger next — it dials L1 (or l1-batch-proxy) + loopback op-node/EL.
# l1-batch-proxy after challenger — challenger is its only consumer on this host.
# Both EL pids: default geth; after the env flip, live is op-reth. stop_bg is a
# no-op without a pidfile. Symmetry parser reads this list statically.
for name in l2-rpc-filter op-challenger l1-batch-proxy op-proposer op-batcher op-node op-geth op-reth; do
  stop_bg "$name"
done
# Sidecar verifier node (not started by start-all). stop_reth_sidecar is a
# no-op without pidfiles; live op-reth was already stop_bg'd in the loop.
stop_reth_sidecar
echo "Sepolia L2 processes stopped (DATA_DIR=$DATA_DIR)."
echo "Phase 1 datadir untouched. Restart: FORTEL2_ENV=.env.sepolia ./scripts/start-all-sepolia.sh"
