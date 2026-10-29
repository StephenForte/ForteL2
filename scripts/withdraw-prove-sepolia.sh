#!/usr/bin/env bash
# Sepolia (L2 852) prove: remote L1 OK, cwd-independent viem resolve, optional --dry-run.
# Does not time-warp. Pair with withdraw-finalize-sepolia.sh — not the Anvil wrappers.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Captured before lib.sh sources the env file. Fork prove signs against
# chain id 900852 on a loopback Anvil. Unset, this script is unchanged.
_FORTEL2_FORK_L1_RPC_URL="${FORTEL2_FORK_L1_RPC_URL:-}"
_FORTEL2_FORK_L1_CHAIN_ID="${FORTEL2_FORK_L1_CHAIN_ID:-}"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

if [[ -n "$_FORTEL2_FORK_L1_RPC_URL" ]]; then
  assert_loopback_url "$_FORTEL2_FORK_L1_RPC_URL" "FORTEL2_FORK_L1_RPC_URL"
  restore_caller_l1_rpc_url "$_FORTEL2_FORK_L1_RPC_URL"
  if [[ "$_FORTEL2_FORK_L1_CHAIN_ID" != "900852" ]]; then
    echo "ERROR: fork prove requires FORTEL2_FORK_L1_CHAIN_ID=900852" >&2
    exit 1
  fi
  L1_CHAIN_ID=900852
  export L1_CHAIN_ID
fi

require_bin node
require_bin jq
warn_if_missing_env_file
assert_sepolia_rpc_urls
refuse_foundry_defaults_unless_local_l2 "${ADMIN_PRIVATE_KEY:-}" "ADMIN_PRIVATE_KEY"

DRY_RUN=0
ARTIFACT=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --help|-h)
      cat <<'EOF'
Usage: withdraw-prove-sepolia.sh [--dry-run] [artifact.json]

  FORTEL2_ENV=.env.sepolia ./scripts/withdraw-prove-sepolia.sh
  FORTEL2_ENV=.env.sepolia ./scripts/withdraw-prove-sepolia.sh --dry-run

--dry-run reads on-chain state, simulates the portal prove call, prints
readiness (not-proven / proven-waiting-until-<ts> / finalizable /
already-finalized), and sends nothing. Exit 0 only when the next step is
not-proven.

Live prove waits for a covering dispute game. Sepolia posts hourly, so this
wrapper defaults PROVE_WAIT_MS=3900000 (65 min). Override to shorten/lengthen.
EOF
      exit 0
      ;;
    -*)
      echo "ERROR: unknown option $arg" >&2
      exit 1
      ;;
    *) ARTIFACT="$arg" ;;
  esac
done

ARTIFACT_DIR="${BRIDGE_ARTIFACT_DIR:-$DATA_DIR/bridge}"
ARTIFACT="${ARTIFACT:-$ARTIFACT_DIR/last-withdrawal.json}"
if [[ "$ARTIFACT" != /* ]]; then
  ARTIFACT="$(pwd)/$ARTIFACT"
fi
BRIDGE_DIR="$SCRIPT_DIR/bridge"

if [[ ! -f "$ARTIFACT" ]]; then
  echo "ERROR: missing $ARTIFACT — initiate a withdrawal first" >&2
  exit 1
fi

ART_L1="$(jq -r '.l1ChainId // .l1_chain_id // empty' "$ARTIFACT")"
ART_L2="$(jq -r '.l2ChainId // .l2_chain_id // empty' "$ARTIFACT")"
if [[ -n "$ART_L2" && "$ART_L2" != "$L2_CHAIN_ID" ]]; then
  echo "ERROR: artifact l2ChainId=$ART_L2 does not match L2_CHAIN_ID=$L2_CHAIN_ID" >&2
  exit 1
fi
if ! allow_fork_artifact_l1 "$ART_L1" "$ART_L2"; then
  echo "ERROR: artifact l1ChainId=$ART_L1 does not match L1_CHAIN_ID=$L1_CHAIN_ID" >&2
  echo "  A 11155111 artifact on fork chain 900852 needs FORTEL2_ALLOW_FORK_PROVE=1 and a loopback L1." >&2
  exit 1
fi

ensure_bridge_deps "$BRIDGE_DIR"

wait_for_rpc "$L1_RPC_URL" "L1"
wait_for_rpc "$L2_RPC_URL" "L2"

export DEPLOYMENTS_JSON
DEPLOYMENTS_JSON="$(deployments_json_path)"
export L1_RPC_URL L2_RPC_URL L1_CHAIN_ID L2_CHAIN_ID ADMIN_ADDRESS ADMIN_PRIVATE_KEY
# Hourly Sepolia proposer: 180s Anvil default would time out. Operator can override.
export PROVE_WAIT_MS="${PROVE_WAIT_MS:-3900000}"

NODE_ARGS=("$ARTIFACT")
if [[ "$DRY_RUN" -eq 1 ]]; then
  NODE_ARGS+=(--dry-run)
fi

# viem resolves from scripts/bridge/package.json — must not inherit caller cwd.
(cd "$BRIDGE_DIR" && node prove.mjs "${NODE_ARGS[@]}")
if [[ "$DRY_RUN" -eq 0 ]]; then
  echo "Next: FORTEL2_ENV=.env.sepolia ./scripts/withdraw-finalize-sepolia.sh"
fi
