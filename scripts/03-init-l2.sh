#!/usr/bin/env bash
# Initialize L2 EL datadir from genesis (run once per chain life; reset.sh clears it).
# Default FORTEL2_EL=geth: op-geth from $DEPLOY_DIR/genesis.json (Phase 1 901 or Sepolia 852).
# FORTEL2_EL=reth: op-reth from 852 genesis only — refuse 901 and $DATA_DIR/l2/op-geth.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Snapshot before lib.sh sources .env (Phase 1 DATA_DIR / FORTEL2_EL clobber).
_CALLER_DATA_DIR="${DATA_DIR:-}"
_CALLER_EL="${FORTEL2_EL:-}"
_CALLER_RETH_GENESIS="${FORTEL2_RETH_GENESIS:-}"
_CALLER_RETH_DATADIR="${FORTEL2_RETH_DATADIR:-}"
_CALLER_RETH_PROFILE="${FORTEL2_RETH_PROFILE:-}"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
restore_caller_data_dir "$_CALLER_DATA_DIR"
[[ -n "$_CALLER_EL" ]] && { FORTEL2_EL="$_CALLER_EL"; export FORTEL2_EL; }
[[ -n "$_CALLER_RETH_GENESIS" ]] && { FORTEL2_RETH_GENESIS="$_CALLER_RETH_GENESIS"; export FORTEL2_RETH_GENESIS; }
[[ -n "$_CALLER_RETH_DATADIR" ]] && { FORTEL2_RETH_DATADIR="$_CALLER_RETH_DATADIR"; export FORTEL2_RETH_DATADIR; }
[[ -n "$_CALLER_RETH_PROFILE" ]] && { FORTEL2_RETH_PROFILE="$_CALLER_RETH_PROFILE"; export FORTEL2_RETH_PROFILE; }

require_fortel2_el

if [[ "$(fortel2_el)" == "reth" ]]; then
  require_bin op-reth
  require_bin jq
  require_bin openssl
  GENESIS="$(resolve_reth_genesis)"
  ROLLUP="${FORTEL2_RETH_ROLLUP:-$FORTEL2_ROOT/deployments/sepolia/rollup.json}"
  require_genesis_852 "$GENESIS" "$ROLLUP"
  DATADIR="$(require_reth_datadir)"
  JWT="$(reth_jwt_path "$DATADIR")"
  mkdir -p "$DATADIR"
  write_reth_jwt "$JWT"
  if [[ -d "$DATADIR/db" || -d "$DATADIR/static_files" ]]; then
    echo "op-reth datadir already initialized at $DATADIR (skipping). Wipe with FORTEL2_EL=reth reset (never touches op-geth)."
    exit 0
  fi
  echo "Initializing op-reth with $GENESIS (852; genesis hash $FORTEL2_L2_GENESIS_HASH_852)"
  echo "Mid-chain rewind: wipe this datadir and re-derive — never debug_setHead on a keeper."
  op-reth init --datadir="$DATADIR" --chain="$GENESIS"
  echo "Done."
  exit 0
fi

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
