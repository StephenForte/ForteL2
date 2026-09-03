#!/usr/bin/env bash
# Sepolia (L2 852) finalize: remote L1 OK, real-clock wait, cwd-independent viem.
# No Anvil warp / evm_mine. Pair with withdraw-prove-sepolia.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin node
require_bin cast
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
Usage: withdraw-finalize-sepolia.sh [--dry-run] [artifact.json]

  FORTEL2_ENV=.env.sepolia ./scripts/withdraw-finalize-sepolia.sh
  FORTEL2_ENV=.env.sepolia ./scripts/withdraw-finalize-sepolia.sh --dry-run

--dry-run reads on-chain state, simulates OptimismPortal.finalizeWithdrawalTransaction,
prints readiness (not-proven / proven-waiting-until-<ts> / finalizable /
already-finalized), and sends nothing. Exit 0 only when the next step is
finalizable.

Live finalize polls the L1 head until the game is DEFENDER_WINS and
resolvedAt + disputeGameFinalityDelaySeconds (both on-chain) have passed.
Max wait: FINALIZE_REAL_CLOCK_MAX_WAIT_MS (default 7200000 = 2h).
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
DEPLOYMENTS_JSON="$(deployments_json_path)"

if [[ ! -f "$ARTIFACT" ]]; then
  echo "ERROR: missing $ARTIFACT — run withdraw-prove-sepolia.sh first" >&2
  exit 1
fi

ART_L1="$(jq -r '.l1ChainId // .l1_chain_id // empty' "$ARTIFACT")"
ART_L2="$(jq -r '.l2ChainId // .l2_chain_id // empty' "$ARTIFACT")"
if [[ -n "$ART_L2" && "$ART_L2" != "$L2_CHAIN_ID" ]]; then
  echo "ERROR: artifact l2ChainId=$ART_L2 does not match L2_CHAIN_ID=$L2_CHAIN_ID" >&2
  exit 1
fi
if [[ -n "$ART_L1" && "$ART_L1" != "$L1_CHAIN_ID" ]]; then
  echo "ERROR: artifact l1ChainId=$ART_L1 does not match L1_CHAIN_ID=$L1_CHAIN_ID" >&2
  exit 1
fi

if [[ ! -d "$BRIDGE_DIR/node_modules/viem" ]]; then
  echo "Installing bridge helper deps (viem) ..."
  (cd "$BRIDGE_DIR" && npm ci --omit=dev)
fi

wait_for_rpc "$L1_RPC_URL" "L1"

PORTAL=$(jq -r '.OptimismPortalProxy' "$DEPLOYMENTS_JSON")
require_eth_address "OptimismPortalProxy" "$PORTAL"
echo "Live portal delays:"
echo -n "  proofMaturityDelaySeconds= "
cast call "$PORTAL" "proofMaturityDelaySeconds()(uint64)" --rpc-url "$L1_RPC_URL"
echo -n "  disputeGameFinalityDelaySeconds= "
cast call "$PORTAL" "disputeGameFinalityDelaySeconds()(uint64)" --rpc-url "$L1_RPC_URL"

export DEPLOYMENTS_JSON
export L1_RPC_URL L2_RPC_URL L1_CHAIN_ID L2_CHAIN_ID ADMIN_ADDRESS ADMIN_PRIVATE_KEY
export PROOF_MATURITY_DELAY_SECONDS DISPUTE_GAME_FINALITY_DELAY_SECONDS
export FAULT_GAME_MAX_CLOCK_DURATION
export FINALIZE_REAL_CLOCK_MAX_WAIT_MS FINALIZE_REAL_CLOCK_POLL_MS

NODE_ARGS=("$ARTIFACT")
if [[ "$DRY_RUN" -eq 1 ]]; then
  NODE_ARGS+=(--dry-run)
fi

# viem resolves from scripts/bridge/package.json — must not inherit caller cwd.
(cd "$BRIDGE_DIR" && node finalize.mjs "${NODE_ARGS[@]}")

if [[ "$DRY_RUN" -eq 0 && -f "$ARTIFACT" ]]; then
  echo "Recorded hashes in $ARTIFACT:"
  jq '{l2TxHash, proveTxHash, finalizeTxHash, gameIndex, gameProxy}' "$ARTIFACT" || true
fi
