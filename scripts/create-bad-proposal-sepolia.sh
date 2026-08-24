#!/usr/bin/env bash
# US-074: one-shot bad proposal against Sepolia DisputeGameFactory.
# Isolated — never started by start-all-sepolia.sh / launchd. Operator-only, post-wipe.
# Signs with PROPOSER_PRIVATE_KEY (the factory proposer role), never CHALLENGER_PRIVATE_KEY.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

usage() {
  echo "usage: create-bad-proposal-sepolia.sh [-block N]"
  echo "  Isolated US-074 one-shot. Requires CONFIRM_BAD_PROPOSAL_SEPOLIA=1 to broadcast."
  echo "  Only -block is accepted; -l1/-rollup/-factory/-private-key/-deployments cannot be overridden."
}

# Allowlist extra args. Go's flag parser last-wins on duplicates, so forwarding "$@"
# would let a trailing -l1/-rollup/-factory/-private-key bypass require_sepolia_env
# and the loopback/role gates. Guarded flags are also placed after -block so they win
# if this allowlist is ever loosened.
FORWARD=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -block|--block)
      if [[ $# -lt 2 || -z "${2:-}" || "$2" == -* ]]; then
        echo "ERROR: -block requires a value" >&2
        usage >&2
        exit 2
      fi
      FORWARD+=(-block "$2")
      shift 2
      ;;
    -block=*|--block=*)
      val="${1#*=}"
      if [[ -z "$val" ]]; then
        echo "ERROR: -block requires a value" >&2
        usage >&2
        exit 2
      fi
      FORWARD+=(-block "$val")
      shift
      ;;
    *)
      echo "ERROR: unsupported argument: $1" >&2
      echo "  This wrapper only accepts -block N." >&2
      echo "  Guarded flags (-l1, -rollup, -factory, -private-key, -deployments) cannot be overridden." >&2
      usage >&2
      exit 2
      ;;
  esac
done

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
wait_for_opnode_rpc "$L2_NODE_RPC_URL" "op-node"

echo "WARN: stop stock op-proposer first (shared PROPOSER_PRIVATE_KEY nonce). See proposer/README.md US-074." >&2

# -block first (allowlisted); guarded endpoints last so they cannot be overridden.
(cd "$FORTEL2_ROOT/proposer" && go run ./cmd/bad-proposal \
  "${FORWARD[@]}" \
  -l1 "$L1_RPC_URL" \
  -rollup "$L2_NODE_RPC_URL" \
  -deployments "$DEPLOYMENTS" \
  -game-type "${PROPOSER_GAME_TYPE:-1}" \
  -i-understand-this-posts-a-false-claim=true)
