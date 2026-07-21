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
echo "L1 RPC:     $L1_RPC_URL"
echo "DEPLOY_DIR: $DEPLOY_DIR"
echo "L2 chain:   $L2_CHAIN_ID"
echo "ADMIN:      $ADMIN_ADDRESS"
echo "Out JSON:   $SEPOLIA_DEPLOYMENTS_JSON"
echo

PROOF_MATURITY_DELAY_SECONDS="${PROOF_MATURITY_DELAY_SECONDS:-12}"
DISPUTE_GAME_FINALITY_DELAY_SECONDS="${DISPUTE_GAME_FINALITY_DELAY_SECONDS:-6}"
# Must keep maxClockDuration >= clockExtension (DeployImplementations check).
# Defaults stay learning-short; do NOT leave extension at mainnet 10800 while max=10.
FAULT_GAME_CLOCK_EXTENSION="${FAULT_GAME_CLOCK_EXTENSION:-5}"
FAULT_GAME_MAX_CLOCK_DURATION="${FAULT_GAME_MAX_CLOCK_DURATION:-10}"
FAULT_GAME_WITHDRAWAL_DELAY="${FAULT_GAME_WITHDRAWAL_DELAY:-1}"

if (( FAULT_GAME_MAX_CLOCK_DURATION < FAULT_GAME_CLOCK_EXTENSION )); then
  echo "ERROR: FAULT_GAME_MAX_CLOCK_DURATION ($FAULT_GAME_MAX_CLOCK_DURATION) must be >= FAULT_GAME_CLOCK_EXTENSION ($FAULT_GAME_CLOCK_EXTENSION)" >&2
  exit 1
fi

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

echo "Deploy overrides: proofMaturityDelaySeconds=${PROOF_MATURITY_DELAY_SECONDS} disputeGameFinalityDelaySeconds=${DISPUTE_GAME_FINALITY_DELAY_SECONDS} faultGameClockExtension=${FAULT_GAME_CLOCK_EXTENSION} faultGameMaxClockDuration=${FAULT_GAME_MAX_CLOCK_DURATION} faultGameWithdrawalDelay=${FAULT_GAME_WITHDRAWAL_DELAY}"
echo "fundDevAccounts=false (fund L2 via bridge in Phase 2c)"
echo
echo "Applying op-deployer intent to live Sepolia at $L1_RPC_URL ..."
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
  echo "l1_rpc=$L1_RPC_URL"
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
