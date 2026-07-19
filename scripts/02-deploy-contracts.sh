#!/usr/bin/env bash
# US-003: Deploy OP Stack L1 contracts to Anvil + generate L2 genesis/rollup.json.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin op-deployer
require_bin cast
require_bin jq
assert_local_rpc_urls
refuse_foundry_defaults_unless_local_l2 "${ADMIN_PRIVATE_KEY:-}" "ADMIN_PRIVATE_KEY"

wait_for_rpc "$L1_RPC_URL" "L1 Anvil"

# Chain id as 32-byte hex (901 = 0x385)
L2_ID_HEX=$(printf '0x%064x' "$L2_CHAIN_ID")

# Fresh workdir: init creates state.json + stub intent, then we overwrite intent
rm -rf "$DEPLOY_DIR"
mkdir -p "$DEPLOY_DIR"

op-deployer init \
  --l1-chain-id "$L1_CHAIN_ID" \
  --l2-chain-ids "$L2_CHAIN_ID" \
  --workdir "$DEPLOY_DIR" \
  --intent-type custom

# Phase 1b (US-011): shorten portal / dispute-game delays for local prove→finalize.
# Mainnet defaults are 7d / 3.5d. Some op-deployer builds ignore these (optimism#14869);
# scripts/withdraw-finalize.sh can Anvil time-warp as a fallback — still name the knobs in README.
PROOF_MATURITY_DELAY_SECONDS="${PROOF_MATURITY_DELAY_SECONDS:-12}"
DISPUTE_GAME_FINALITY_DELAY_SECONDS="${DISPUTE_GAME_FINALITY_DELAY_SECONDS:-6}"
FAULT_GAME_MAX_CLOCK_DURATION="${FAULT_GAME_MAX_CLOCK_DURATION:-10}"
FAULT_GAME_WITHDRAWAL_DELAY="${FAULT_GAME_WITHDRAWAL_DELAY:-1}"

cat > "$DEPLOY_DIR/intent.toml" << EOF
configType = "custom"
l1ChainID = ${L1_CHAIN_ID}
fundDevAccounts = true
l1ContractsLocator = "embedded"
l2ContractsLocator = "embedded"
useInterop = false

[globalDeployOverrides]
  proofMaturityDelaySeconds = ${PROOF_MATURITY_DELAY_SECONDS}
  disputeGameFinalityDelaySeconds = ${DISPUTE_GAME_FINALITY_DELAY_SECONDS}
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

echo "Deploy overrides: proofMaturityDelaySeconds=${PROOF_MATURITY_DELAY_SECONDS} disputeGameFinalityDelaySeconds=${DISPUTE_GAME_FINALITY_DELAY_SECONDS} faultGameMaxClockDuration=${FAULT_GAME_MAX_CLOCK_DURATION} faultGameWithdrawalDelay=${FAULT_GAME_WITHDRAWAL_DELAY}"

echo "Applying op-deployer intent to live L1 at $L1_RPC_URL ..."
op-deployer apply \
  --workdir "$DEPLOY_DIR" \
  --deployment-target live \
  --l1-rpc-url "$L1_RPC_URL" \
  --private-key "$ADMIN_PRIVATE_KEY"

echo "Writing genesis.json + rollup.json ..."
op-deployer inspect genesis --workdir "$DEPLOY_DIR" "$L2_CHAIN_ID" > "$DEPLOY_DIR/genesis.json"
op-deployer inspect rollup --workdir "$DEPLOY_DIR" "$L2_CHAIN_ID" > "$DEPLOY_DIR/rollup.json"
op-deployer inspect l1 --workdir "$DEPLOY_DIR" "$L2_CHAIN_ID" > "$FORTEL2_ROOT/deployments/deployments.json"

# Force an immediate Anvil state dump so a crash before the next interval is recoverable.
# Anvil writes --state on interval and on clean exit; give it a moment after deploy txs settle.
sleep 6
if [[ -f "$DATA_DIR/l1/anvil-state.json" ]]; then
  echo "L1 state persisted at $DATA_DIR/l1/anvil-state.json ($(wc -c < "$DATA_DIR/l1/anvil-state.json") bytes)"
else
  echo "WARN: Anvil state file not yet present — keep Anvil running; do not kill -9 it"
fi

# Ensure L2 block time matches learning preference if field is present
if jq -e '.block_time' "$DEPLOY_DIR/rollup.json" >/dev/null 2>&1; then
  jq --argjson t "${L2_BLOCK_TIME}" '.block_time = $t' "$DEPLOY_DIR/rollup.json" > "$DEPLOY_DIR/rollup.json.tmp"
  mv "$DEPLOY_DIR/rollup.json.tmp" "$DEPLOY_DIR/rollup.json"
fi

echo "Deploy artifacts:"
echo "  $DEPLOY_DIR/genesis.json"
echo "  $DEPLOY_DIR/rollup.json"
echo "  $FORTEL2_ROOT/deployments/deployments.json"
echo
echo "Key L1 addresses:"
jq '{OptimismPortalProxy, SystemConfigProxy, DisputeGameFactoryProxy, L2OutputOracleProxy, AddressManager, L1StandardBridgeProxy}' \
  "$FORTEL2_ROOT/deployments/deployments.json" 2>/dev/null || jq '.' "$FORTEL2_ROOT/deployments/deployments.json" | head -80
