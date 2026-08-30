#!/usr/bin/env bash
# Stop the Task 2 op-reth sidecar (op-reth + op-reth-node). Does not stop live op-geth.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

stop_reth_sidecar
echo "op-reth sidecar stopped (live op-geth untouched)."
