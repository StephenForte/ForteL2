#!/usr/bin/env bash
# Phase 2b / US-023: Disposable OP Stack L1 contract deploy on Ethereum Sepolia.
# Writes artifacts under deployments/sepolia/ only — never touches Phase 1 Anvil deploy tree.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin op-deployer
require_bin cast
require_bin jq
require_sepolia_env
warn_if_missing_env_file
refuse_foundry_defaults_unless_local_l2 "${ADMIN_PRIVATE_KEY:-}" "ADMIN_PRIVATE_KEY"
require_eth_address "ADMIN_ADDRESS" "${ADMIN_ADDRESS:-}"
# This is the one place the key touches argv before apply, for a single
# short-lived `cast` process. `cast wallet address` has no env-var form
# (ETH_PRIVATE_KEY is not accepted). That bounded exposure is deliberately
# accepted to close a silent-wrong-signer failure; apply already passes the
# same key on argv to op-deployer, so this adds no new class of exposure.
require_admin_key_matches_address() {
  if [[ -z "${ADMIN_PRIVATE_KEY:-}" ]]; then
    echo "ERROR: ADMIN_PRIVATE_KEY is required (must derive ADMIN_ADDRESS)" >&2
    exit 1
  fi
  local derived derived_lc configured_lc
  derived="$(cast wallet address --private-key "$ADMIN_PRIVATE_KEY")"
  derived_lc="$(printf '%s' "$derived" | tr '[:upper:]' '[:lower:]')"
  configured_lc="$(printf '%s' "$ADMIN_ADDRESS" | tr '[:upper:]' '[:lower:]')"
  if [[ "$derived_lc" != "$configured_lc" ]]; then
    echo "ERROR: ADMIN_PRIVATE_KEY does not match ADMIN_ADDRESS" >&2
    echo "  derived:    $derived" >&2
    echo "  configured: $ADMIN_ADDRESS" >&2
    exit 1
  fi
}
require_admin_key_matches_address
require_eth_address "BATCHER_ADDRESS" "${BATCHER_ADDRESS:-}"
require_eth_address "PROPOSER_ADDRESS" "${PROPOSER_ADDRESS:-}"
require_eth_address "SEQUENCER_ADDRESS" "${SEQUENCER_ADDRESS:-}"
require_eth_address "CHALLENGER_ADDRESS" "${CHALLENGER_ADDRESS:-}"
# Validate before any Sepolia ETH spend / rollup.json block_time patch (set -u).
assert_block_times

# Deploy needs ADMIN gas; default floor matches sepolia-fund-check.sh
ADMIN_MIN="${SEPOLIA_ADMIN_MIN_ETH:-0.70}"
require_min_balance_eth "$ADMIN_ADDRESS" "$ADMIN_MIN" "ADMIN"

SEPOLIA_DEPLOYMENTS_JSON="${SEPOLIA_DEPLOYMENTS_JSON:-$FORTEL2_ROOT/deployments/sepolia/deployments.json}"

# Refuse clobbering Phase 1 checked-in deployments.json
if [[ "$SEPOLIA_DEPLOYMENTS_JSON" == "$FORTEL2_ROOT/deployments/deployments.json" ]]; then
  echo "ERROR: refusing to write Phase 1 deployments/deployments.json from Sepolia deploy" >&2
  exit 1
fi

wait_for_rpc "$L1_RPC_URL" "L1 Sepolia"
L1_ID="$(cast chain-id --rpc-url "$L1_RPC_URL")"
if [[ "$L1_ID" != "11155111" ]]; then
  echo "ERROR: L1 RPC chain-id is $L1_ID (expected 11155111 Sepolia)" >&2
  exit 1
fi

L2_ID_HEX=$(printf '0x%064x' "$L2_CHAIN_ID")

echo "=== Phase 2b disposable Sepolia deploy ==="
echo "L1 RPC:     $(redact_rpc_url "$L1_RPC_URL")"
echo "DEPLOY_DIR: $DEPLOY_DIR"
echo "L2 chain:   $L2_CHAIN_ID"
echo "ADMIN:      $ADMIN_ADDRESS"
echo "Out JSON:   $SEPOLIA_DEPLOYMENTS_JSON"
echo

PROOF_MATURITY_DELAY_SECONDS="${PROOF_MATURITY_DELAY_SECONDS:-12}"
DISPUTE_GAME_FINALITY_DELAY_SECONDS="${DISPUTE_GAME_FINALITY_DELAY_SECONDS:-6}"
# Fault-game clocks must satisfy BOTH:
#   DeployImplementations: maxClockDuration >= clockExtension
#   PermissionedDisputeGame.initialize: maxClockDuration >= max(2*clockExtension, clockExtension+preimageOracleChallengePeriod)
# Stock op-deployer default preimageOracleChallengePeriod=86400. The 2026-07-22
# pinned deploy left that sixth parameter implicit, so learning-short clocks
# (5/10) cannot create() a game (InvalidClockExtension). Phase 7 must choose
# this with the other five knobs — default here stays 86400 (honest about the
# live chain) so a wipe that only bumps extension/max fails closed before apply.
FAULT_GAME_CLOCK_EXTENSION="${FAULT_GAME_CLOCK_EXTENSION:-5}"
FAULT_GAME_MAX_CLOCK_DURATION="${FAULT_GAME_MAX_CLOCK_DURATION:-10}"
FAULT_GAME_WITHDRAWAL_DELAY="${FAULT_GAME_WITHDRAWAL_DELAY:-1}"
PREIMAGE_ORACLE_CHALLENGE_PERIOD="${PREIMAGE_ORACLE_CHALLENGE_PERIOD:-86400}"

if (( FAULT_GAME_MAX_CLOCK_DURATION < FAULT_GAME_CLOCK_EXTENSION )); then
  echo "ERROR: FAULT_GAME_MAX_CLOCK_DURATION ($FAULT_GAME_MAX_CLOCK_DURATION) must be >= FAULT_GAME_CLOCK_EXTENSION ($FAULT_GAME_CLOCK_EXTENSION)" >&2
  exit 1
fi
_min_init=$(( FAULT_GAME_CLOCK_EXTENSION * 2 ))
_min_oracle=$(( FAULT_GAME_CLOCK_EXTENSION + PREIMAGE_ORACLE_CHALLENGE_PERIOD ))
_min_needed=$_min_init
if (( _min_oracle > _min_needed )); then _min_needed=$_min_oracle; fi
if (( FAULT_GAME_MAX_CLOCK_DURATION < _min_needed )); then
  echo "ERROR: FAULT_GAME_MAX_CLOCK_DURATION ($FAULT_GAME_MAX_CLOCK_DURATION) must be >= max(2*clockExtension, clockExtension+preimageOracleChallengePeriod) = $_min_needed" >&2
  echo "  (clockExtension=$FAULT_GAME_CLOCK_EXTENSION preimageOracleChallengePeriod=$PREIMAGE_ORACLE_CHALLENGE_PERIOD)" >&2
  echo "  Choose all six Phase 7 knobs in .env.sepolia before FORCE_SEPOLIA_REDEPLOY=1 (D-0046)." >&2
  exit 1
fi

# F7-6 / D-0061: type-8 additional game is a *second* apply after the network
# is healthy. Unset FAULT_GAME_ABSOLUTE_PRESTATE keeps intent byte-identical
# (the wipe). Must refuse before any write — including rm -rf "$DEPLOY_DIR".
refuse_fault_game_absolute_prestate() {
  local prestate="${FAULT_GAME_ABSOLUTE_PRESTATE:-}"
  if [[ -z "$prestate" ]]; then
    return 0
  fi
  if [[ "${FORCE_SEPOLIA_REDEPLOY:-}" == "1" ]]; then
    echo "ERROR: FAULT_GAME_ABSOLUTE_PRESTATE is set while FORCE_SEPOLIA_REDEPLOY=1." >&2
    echo "  A prestate present at wipe time commits to the old rollup config (D-0061)." >&2
    echo "  Unset FAULT_GAME_ABSOLUTE_PRESTATE, run the wipe, then set it from the" >&2
    echo "  CI-built Kona artifact for the post-wipe rollup.json at step 8b." >&2
    exit 1
  fi
  if [[ ! "$prestate" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    echo "ERROR: FAULT_GAME_ABSOLUTE_PRESTATE must be exactly 0x followed by 64 hex characters." >&2
    echo "  Got: $prestate" >&2
    echo "  Set it to the CI prestate build's commitment (D-0059 / D-0061), not a guessed hash." >&2
    exit 1
  fi
  # op-deployer standard.DisputeAbsolutePrestate — a cannon32 artifact the
  # MIPS64 VM cannot execute (D-0056). Compare case-insensitively.
  local prestate_lc cannon32_default
  prestate_lc="$(printf '%s' "$prestate" | tr '[:upper:]' '[:lower:]')"
  cannon32_default="0x038512e02c4c3f7bdaec27d00edf55b7155e0905301e1a88083e4e0a6764d54c"
  if [[ "$prestate_lc" == "$cannon32_default" ]]; then
    echo "ERROR: FAULT_GAME_ABSOLUTE_PRESTATE is op-deployer's built-in default ($cannon32_default)." >&2
    echo "  That hash is a cannon32 artifact; the MIPS64 VM requires stateVersion 8 (D-0056)." >&2
    echo "  Set FAULT_GAME_ABSOLUTE_PRESTATE to the CI-built Kona prestate commitment instead." >&2
    exit 1
  fi
}
refuse_fault_game_absolute_prestate

if [[ -f "$DEPLOY_DIR/state.json" && "${FORCE_SEPOLIA_REDEPLOY:-}" != "1" ]]; then
  echo "Resuming existing Sepolia deploy workdir at $DEPLOY_DIR (set FORCE_SEPOLIA_REDEPLOY=1 to wipe)"
else
  rm -rf "$DEPLOY_DIR"
  mkdir -p "$DEPLOY_DIR"
fi
mkdir -p "$(dirname "$SEPOLIA_DEPLOYMENTS_JSON")"

if [[ ! -f "$DEPLOY_DIR/intent.toml" ]]; then
  op-deployer init \
    --l1-chain-id "$L1_CHAIN_ID" \
    --l2-chain-ids "$L2_CHAIN_ID" \
    --workdir "$DEPLOY_DIR" \
    --intent-type custom
fi

# Always rewrite intent from current env so logged overrides/roles match apply
# (resume keeps state.json; stale intent.toml must not win over .env.sepolia).
cat > "$DEPLOY_DIR/intent.toml" << EOF
configType = "custom"
l1ChainID = ${L1_CHAIN_ID}
fundDevAccounts = false
l1ContractsLocator = "embedded"
l2ContractsLocator = "embedded"
useInterop = false

[globalDeployOverrides]
  proofMaturityDelaySeconds = ${PROOF_MATURITY_DELAY_SECONDS}
  disputeGameFinalityDelaySeconds = ${DISPUTE_GAME_FINALITY_DELAY_SECONDS}
  faultGameClockExtension = ${FAULT_GAME_CLOCK_EXTENSION}
  faultGameMaxClockDuration = ${FAULT_GAME_MAX_CLOCK_DURATION}
  faultGameWithdrawalDelay = ${FAULT_GAME_WITHDRAWAL_DELAY}
  preimageOracleChallengePeriod = ${PREIMAGE_ORACLE_CHALLENGE_PERIOD}

[superchainRoles]
  SuperchainProxyAdminOwner = "${ADMIN_ADDRESS}"
  SuperchainGuardian = "${ADMIN_ADDRESS}"
  Challenger = "${CHALLENGER_ADDRESS}"

[[chains]]
  id = "${L2_ID_HEX}"
  baseFeeVaultRecipient = "${ADMIN_ADDRESS}"
  l1FeeVaultRecipient = "${ADMIN_ADDRESS}"
  sequencerFeeVaultRecipient = "${ADMIN_ADDRESS}"
  operatorFeeVaultRecipient = "${ADMIN_ADDRESS}"
  eip1559DenominatorCanyon = 250
  eip1559Denominator = 50
  eip1559Elasticity = 6
  gasLimit = 60000000
  operatorFeeScalar = 0
  operatorFeeConstant = 0
  minBaseFee = 0
  daFootprintGasScalar = 0
  [chains.roles]
    l1ProxyAdminOwner = "${ADMIN_ADDRESS}"
    l2ProxyAdminOwner = "${ADMIN_ADDRESS}"
    systemConfigOwner = "${ADMIN_ADDRESS}"
    unsafeBlockSigner = "${SEQUENCER_ADDRESS}"
    batcher = "${BATCHER_ADDRESS}"
    proposer = "${PROPOSER_ADDRESS}"
    challenger = "${CHALLENGER_ADDRESS}"
EOF

# Nested under [[chains]] *after* that table's scalar keys (and [chains.roles]).
# Placing [[chains.dangerousAdditionalDisputeGames]] before the scalars silently
# reparents them. Depths are op-deployer standard.DisputeMaxGameDepth=73 /
# DisputeSplitDepth=30 (standard/standard.go:27-28); live type-1
# maxGameDepth()/splitDepth() match. Additional-game clocks come only from this
# stanza (omitted = 0); reuse the already-validated FAULT_GAME_CLOCK_* so the
# initialize refusal covers type 8 too. Game type / VMType / MakeRespected are
# fixed: a configurable type invites setting 1, which D-0060 established can never play.
if [[ -n "${FAULT_GAME_ABSOLUTE_PRESTATE:-}" ]]; then
  cat >> "$DEPLOY_DIR/intent.toml" << EOF

  [[chains.dangerousAdditionalDisputeGames]]
    respectedGameType = 8
    faultGameAbsolutePrestate = "${FAULT_GAME_ABSOLUTE_PRESTATE}"
    faultGameMaxDepth = 73
    faultGameSplitDepth = 30
    faultGameClockExtension = ${FAULT_GAME_CLOCK_EXTENSION}
    faultGameMaxClockDuration = ${FAULT_GAME_MAX_CLOCK_DURATION}
    VMType = "CANNON"
    MakeRespected = true
EOF
fi

echo "Deploy overrides: proofMaturityDelaySeconds=${PROOF_MATURITY_DELAY_SECONDS} disputeGameFinalityDelaySeconds=${DISPUTE_GAME_FINALITY_DELAY_SECONDS} faultGameClockExtension=${FAULT_GAME_CLOCK_EXTENSION} faultGameMaxClockDuration=${FAULT_GAME_MAX_CLOCK_DURATION} faultGameWithdrawalDelay=${FAULT_GAME_WITHDRAWAL_DELAY} preimageOracleChallengePeriod=${PREIMAGE_ORACLE_CHALLENGE_PERIOD}"
if [[ -n "${FAULT_GAME_ABSOLUTE_PRESTATE:-}" ]]; then
  echo "Additional dispute game: type 8 (cannon-kona) will be registered with prestate=${FAULT_GAME_ABSOLUTE_PRESTATE}"
else
  echo "Additional dispute game: none (FAULT_GAME_ABSOLUTE_PRESTATE unset)"
fi
echo "fundDevAccounts=false (fund L2 via bridge in Phase 2c)"
echo
echo "Applying op-deployer intent to live Sepolia at $(redact_rpc_url "$L1_RPC_URL") ..."
echo "(This spends real Sepolia ETH from ADMIN — disposable learning deploy.)"

ADMIN_BAL_BEFORE="$(cast balance "$ADMIN_ADDRESS" --rpc-url "$L1_RPC_URL")"

op-deployer apply \
  --workdir "$DEPLOY_DIR" \
  --deployment-target live \
  --l1-rpc-url "$L1_RPC_URL" \
  --private-key "$ADMIN_PRIVATE_KEY"

# Persist artifacts before spend accounting so a balance quirk cannot skip them.
echo "Writing genesis.json + rollup.json + deployments.json ..."
op-deployer inspect genesis --workdir "$DEPLOY_DIR" "$L2_CHAIN_ID" > "$DEPLOY_DIR/genesis.json"
op-deployer inspect rollup --workdir "$DEPLOY_DIR" "$L2_CHAIN_ID" > "$DEPLOY_DIR/rollup.json"
op-deployer inspect l1 --workdir "$DEPLOY_DIR" "$L2_CHAIN_ID" > "$SEPOLIA_DEPLOYMENTS_JSON"

if jq -e '.block_time' "$DEPLOY_DIR/rollup.json" >/dev/null 2>&1; then
  jq --argjson t "${L2_BLOCK_TIME}" '.block_time = $t' "$DEPLOY_DIR/rollup.json" > "$DEPLOY_DIR/rollup.json.tmp"
  mv "$DEPLOY_DIR/rollup.json.tmp" "$DEPLOY_DIR/rollup.json"
fi

ADMIN_BAL_AFTER="$(cast balance "$ADMIN_ADDRESS" --rpc-url "$L1_RPC_URL")"
# Clamp at 0: incoming transfer/refund during apply must not yield negative wei
# (cast --to-unit fails under set -e on signed values).
SPENT_WEI="$(python3 -c 'import sys; print(max(0, int(sys.argv[1]) - int(sys.argv[2])))' "$ADMIN_BAL_BEFORE" "$ADMIN_BAL_AFTER")"
SPENT_ETH="$(cast --to-unit "$SPENT_WEI" ether)"
echo "ADMIN gas spent this apply: ~${SPENT_ETH} ETH"

# Record spend for the runbook (no secrets)
SPEND_LOG="$FORTEL2_ROOT/deployments/sepolia/deploy-spend.txt"
{
  echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "admin=$ADMIN_ADDRESS"
  echo "spent_eth≈$SPENT_ETH"
  echo "l1_rpc=$(redact_rpc_url "$L1_RPC_URL")"
  echo "l2_chain_id=$L2_CHAIN_ID"
} > "$SPEND_LOG"

echo
echo "Deploy artifacts:"
echo "  $DEPLOY_DIR/genesis.json"
echo "  $DEPLOY_DIR/rollup.json"
echo "  $SEPOLIA_DEPLOYMENTS_JSON"
echo "  $SPEND_LOG"
echo
echo "Key L1 addresses:"
jq '{OptimismPortalProxy, SystemConfigProxy, DisputeGameFactoryProxy, L2OutputOracleProxy, AddressManager, L1StandardBridgeProxy}' \
  "$SEPOLIA_DEPLOYMENTS_JSON" 2>/dev/null || jq '.' "$SEPOLIA_DEPLOYMENTS_JSON" | head -80
echo
echo "Phase 2b apply complete. Phase 1 Anvil tree untouched. Next: Phase 2c (start L2 against Sepolia)."
