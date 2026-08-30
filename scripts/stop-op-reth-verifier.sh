#!/usr/bin/env bash
# Stop the Task 2 op-reth sidecar (op-reth + op-reth-node). Does not stop live op-geth.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CALLER_DATA_DIR="${DATA_DIR:-}"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
restore_caller_data_dir "$_CALLER_DATA_DIR"

stop_reth_sidecar
echo "op-reth sidecar stopped (live op-geth untouched)."
