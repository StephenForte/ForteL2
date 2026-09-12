#!/usr/bin/env bash
# Stop the Task 2 op-reth sidecar (op-reth-verifier + op-reth-verifier-node).
# Does not stop the live EL (op-reth / op-geth). Never signals those pid names.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CALLER_DATA_DIR="${DATA_DIR:-}"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
restore_caller_data_dir "$_CALLER_DATA_DIR"

stop_reth_sidecar
echo "op-reth sidecar stopped (live EL pid names untouched)."
