#!/usr/bin/env bash
# Clean shutdown of all Phase 1 processes (keeps datadir + deployment artifacts).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

# Reverse order of start
for name in op-proposer op-batcher op-node op-geth anvil; do
  stop_bg "$name"
done
# Opt-in sidecar (Task 2). Not in the default list — alert-watch/status default
# path must not expect op-reth until Task 5. stop_bg is a no-op without a pidfile.
stop_reth_sidecar
echo "All Phase 1 processes stopped."
