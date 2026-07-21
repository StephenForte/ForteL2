#!/usr/bin/env bash
# Initialize op-geth datadir from L2 genesis (run once per chain life; reset.sh clears it).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin op-geth

GENESIS="$DEPLOY_DIR/genesis.json"
DATADIR="$DATA_DIR/l2/op-geth"
JWT="$DATA_DIR/jwt/jwt.txt"

if [[ ! -f "$GENESIS" ]]; then
  echo "ERROR: missing $GENESIS — run scripts/02-deploy-contracts.sh (Phase 1) or 02-deploy-contracts-sepolia.sh (Phase 2b)" >&2
  exit 1
fi

mkdir -p "$(dirname "$JWT")" "$DATADIR"
if [[ ! -f "$JWT" ]]; then
  openssl rand -hex 32 > "$JWT"
  chmod 600 "$JWT"
  echo "Wrote JWT secret $JWT"
fi

if [[ -d "$DATADIR/geth" ]]; then
  echo "op-geth datadir already initialized at $DATADIR (skipping). Use scripts/reset.sh (Phase 1) or reset-sepolia.sh (Phase 2c) to wipe."
  exit 0
fi

echo "Initializing op-geth with $GENESIS"
op-geth init --datadir="$DATADIR" --state.scheme=hash "$GENESIS"
echo "Done."
