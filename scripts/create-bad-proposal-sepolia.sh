#!/usr/bin/env bash
# US-074: one-shot bad proposal against Sepolia DisputeGameFactory.
# Isolated — never started by start-all-sepolia.sh / launchd. Operator-only, post-wipe.
# Signs with PROPOSER_PRIVATE_KEY (the factory proposer role), never CHALLENGER_PRIVATE_KEY.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin go
require_bin jq
require_sepolia_env
refuse_foundry_defaults_unless_local_l2 "${PROPOSER_PRIVATE_KEY:-}" "PROPOSER_PRIVATE_KEY"

if [[ "${CONFIRM_BAD_PROPOSAL_SEPOLIA:-}" != "1" ]]; then
  echo "ERROR: Sepolia bad-proposal is opt-in only." >&2
  echo "  Set CONFIRM_BAD_PROPOSAL_SEPOLIA=1 after reading proposer/README.md (US-074)." >&2
  echo "  Signs with PROPOSER_PRIVATE_KEY (factory proposer role), never CHALLENGER_PRIVATE_KEY." >&2
  echo "  Stop stock op-proposer first to avoid a nonce race with this key." >&2
  exit 1
fi

if [[ -z "${PROPOSER_PRIVATE_KEY:-}" ]]; then
  echo "ERROR: PROPOSER_PRIVATE_KEY is required (factory proposer role — not CHALLENGER_PRIVATE_KEY)" >&2
  exit 1
fi

DEPLOYMENTS="$(deployments_json_path)"
if [[ ! -f "$DEPLOYMENTS" ]]; then
  echo "ERROR: missing $DEPLOYMENTS — run Phase 2b / post-wipe deploy first" >&2
  exit 1
fi

wait_for_rpc "$L1_RPC_URL" "L1 Sepolia"
wait_for_rpc "$L2_NODE_RPC_URL" "op-node"

echo "WARN: stop stock op-proposer first (shared PROPOSER_PRIVATE_KEY nonce). See proposer/README.md US-074." >&2

(cd "$FORTEL2_ROOT/proposer" && go run ./cmd/bad-proposal \
  -l1 "$L1_RPC_URL" \
  -rollup "$L2_NODE_RPC_URL" \
  -deployments "$DEPLOYMENTS" \
  -game-type "${PROPOSER_GAME_TYPE:-1}" \
  -i-understand-this-posts-a-false-claim=true \
  "$@")
