#!/usr/bin/env bash
# Phase 3 / US-030: copy Sepolia genesis + rollup into replica/config/ for verifier deploy.
# Does not print private keys. Does not touch Phase 1 datadir.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_sepolia_env
require_bin openssl

OUT_DIR="${REPLICA_CONFIG_DIR:-$FORTEL2_ROOT/replica/config}"
GENESIS_SRC="$DEPLOY_DIR/genesis.json"
ROLLUP_SRC="$DEPLOY_DIR/rollup.json"
JWT_OUT="${REPLICA_JWT_FILE:-$FORTEL2_ROOT/replica/jwt.txt}"

if [[ ! -f "$GENESIS_SRC" ]]; then
  echo "ERROR: missing $GENESIS_SRC — run Phase 2b deploy first" >&2
  exit 1
fi
if [[ ! -f "$ROLLUP_SRC" ]]; then
  echo "ERROR: missing $ROLLUP_SRC — run Phase 2b deploy first" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
cp "$GENESIS_SRC" "$OUT_DIR/genesis.json"
cp "$ROLLUP_SRC" "$OUT_DIR/rollup.json"

# Local compose shares this JWT between op-geth and op-node.
if [[ ! -f "$JWT_OUT" ]]; then
  openssl rand -hex 32 > "$JWT_OUT"
  chmod 600 "$JWT_OUT"
  echo "Wrote $JWT_OUT"
else
  echo "Keeping existing $JWT_OUT"
fi

# Sanity: rollup L2 chain id
if command -v jq >/dev/null 2>&1; then
  RID="$(jq -r '.l2_chain_id // empty' "$OUT_DIR/rollup.json")"
  if [[ -n "$RID" && "$RID" != "$L2_CHAIN_ID" ]]; then
    echo "WARN: rollup l2_chain_id=$RID but L2_CHAIN_ID=$L2_CHAIN_ID" >&2
  fi
fi

echo "Packed replica artifacts → $OUT_DIR"
echo "  genesis.json  ($(wc -c < "$OUT_DIR/genesis.json" | tr -d ' ') bytes)"
echo "  rollup.json   ($(wc -c < "$OUT_DIR/rollup.json" | tr -d ' ') bytes)"
echo
echo "Next: copy $OUT_DIR/{genesis,rollup}.json into https://github.com/StephenForte/fortel2-replica config/ and push"
echo "Friends/Render use that repo (root Dockerfile) — not this monorepo."
echo "Sync check: FORTEL2_ENV=.env.sepolia REPLICA_L2_RPC_URL=… ./scripts/replica-sync-check.sh"
