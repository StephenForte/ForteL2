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
echo "All Phase 1 processes stopped."
