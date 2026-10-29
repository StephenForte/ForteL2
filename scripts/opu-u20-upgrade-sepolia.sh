#!/usr/bin/env bash
# U20 (op-contracts v8) upgrade. OPU-4 runs this same script with --live.
# Default work is --fork against a loopback Anvil. This file never prints keys.
#
# Respected game type 9 is the extra instruction
# overrides.cfg.startingRespectedGameType. OPContractsManagerV2._loadFullConfig
# reads it, and _apply passes it to AnchorStateRegistry.initialize. A guardian
# setRespectedGameType call runs only if that readback is not 9.
#
# Caller is a temporary EIP-7702 delegation to U20DelegateExecutor, then a
# revoke (authorize address(0)). The executor has no storage layout: under
# 7702 its code runs in ADMIN's context, and the OPCM delegatecall stays there.
# cast 1.7.1 signs the authorization locally, so an impersonated account cannot
# produce a type-4 signature. Fork mode therefore uses the same ADMIN signature
# as --live, and refuses any RPC that is not loopback.
set -euo pipefail

# Pinned by D-0159. test-helpers.sh greps these literals.
U20_TYPE8_PRESTATE=0x034c90f083e8c86bb6bf18236d653d4aa42fac0653f013c780448000b9796b8d
U20_TYPE9_PRESTATE=0x03284f1b70ad7525bcda6090685bc068e38f74c572132a0535ae5059b5d14792
U20_BOND_TYPE0_WEI=0
U20_BOND_TYPE1_WEI=80000000000000000
U20_BOND_TYPE8_WEI=1000000000000000
U20_BOND_TYPE5_WEI=0
U20_BOND_TYPE9_WEI=1000000000000000
U20_BOND_ZK_WEI=0
U20_PROOF_MATURITY=1800
U20_FINALITY_DELAY=1800
U20_MAX_CLOCK=7200
U20_CLOCK_EXT=600
U20_MAX_DEPTH=73
U20_SPLIT_DEPTH=30
U20_CONFIRM_PHRASE=I-UNDERSTAND-THIS-IS-IRREVERSIBLE
U20_INVALID_GAME_CONFIGS=0x7c165cd6

usage() {
  cat <<'EOF'
Usage:
  opu-u20-upgrade-sepolia.sh --fork <loopback-rpc>
  CONFIRM_U20_LIVE=I-UNDERSTAND-THIS-IS-IRREVERSIBLE FORTEL2_ENV=.env.sepolia \
    opu-u20-upgrade-sepolia.sh --live

--fork signs with ADMIN against a loopback Anvil (cast cannot sign a type-4
authorization for an impersonated account). --live refuses without the confirm
string and FORTEL2_ENV=.env.sepolia, runs a fresh --fork dry pass first, and
only then signs against L1. Set OP_DEPLOYER_BIN to op-deployer v0.8.1.
EOF
}

# Guards run before lib.sh so a missing env file cannot hide a refusal.
MODE=""
FORK_RPC=""
if [[ $# -eq 0 ]]; then
  usage >&2
  exit 1
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fork)
      MODE=fork
      FORK_RPC="${2:-}"
      shift 2
      ;;
    --live)
      MODE=live
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$MODE" == "live" ]]; then
  if [[ "${CONFIRM_U20_LIVE:-}" != "$U20_CONFIRM_PHRASE" ]]; then
    echo "ERROR: --live refused without CONFIRM_U20_LIVE=$U20_CONFIRM_PHRASE" >&2
    exit 1
  fi
  if [[ "${FORTEL2_ENV:-}" != ".env.sepolia" ]]; then
    echo "ERROR: --live requires FORTEL2_ENV=.env.sepolia" >&2
    exit 1
  fi
fi

# Same redaction as lib.sh. This check runs before source, so the function
# cannot be the shared one yet. lib.sh replaces it after source.
redact_rpc_url() {
  python3 - <<'PY' "${1:-}"
import sys, urllib.parse
u = sys.argv[1]
if not u:
    print("<empty>")
    raise SystemExit
p = urllib.parse.urlparse(u)
netloc = p.hostname or ""
if p.port:
    netloc = f"{netloc}:{p.port}"
path = "/…" if p.path and p.path != "/" else ""
print(f"{p.scheme}://{netloc}{path}")
PY
}

if [[ "$MODE" == "fork" ]]; then
  case "$FORK_RPC" in
    http://127.0.0.1:*|http://localhost:*|https://127.0.0.1:*|https://localhost:*)
      ;;
    *)
      echo "ERROR: --fork RPC must be loopback (127.0.0.1/localhost), got: $(redact_rpc_url "${FORK_RPC:-}")" >&2
      exit 1
      ;;
  esac
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin cast
require_bin jq
require_bin python3
require_bin forge

if [[ "${L2_CHAIN_ID:-}" != "852" ]]; then
  echo "ERROR: U20 upgrade requires the Sepolia env (L2_CHAIN_ID=852, got ${L2_CHAIN_ID:-<unset>})" >&2
  exit 1
fi

lc() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

call_raw() {
  local to="$1"
  local sig="$2"
  shift 2
  cast call "$to" "$sig" "$@" --rpc-url "$RPC"
}

call_str() {
  local out
  out="$(call_raw "$1" "$2")"
  out="${out#\"}"
  out="${out%\"}"
  printf '%s' "$out"
}

call_word() {
  call_raw "$@" | awk 'NR==1 { print $1 }'
}

require_eth_address "ADMIN" "${ADMIN_ADDRESS:-}"
require_eth_address "PROPOSER" "${PROPOSER_ADDRESS:-}"
require_eth_address "CHALLENGER" "${CHALLENGER_ADDRESS:-}"

DEP_JSON="$(deployments_json_path)"
if [[ ! -f "$DEP_JSON" ]]; then
  echo "ERROR: deployments json missing: $DEP_JSON" >&2
  exit 1
fi
SYSTEM_CONFIG="$(jq -r .SystemConfigProxy "$DEP_JSON")"
PORTAL="$(jq -r .OptimismPortalProxy "$DEP_JSON")"
DGF="$(jq -r .DisputeGameFactoryProxy "$DEP_JSON")"
ASR="$(jq -r .AnchorStateRegistryProxy "$DEP_JSON")"
SUPERCHAIN="$(jq -r .SuperchainConfigProxy "$DEP_JSON")"
for label_addr in \
  "SystemConfig:$SYSTEM_CONFIG" \
  "OptimismPortal:$PORTAL" \
  "DisputeGameFactory:$DGF" \
  "AnchorStateRegistry:$ASR" \
  "SuperchainConfig:$SUPERCHAIN"
do
  require_eth_address "${label_addr%%:*}" "${label_addr#*:}"
done

if [[ -z "${OP_DEPLOYER_BIN:-}" ]]; then
  if command -v op-deployer >/dev/null 2>&1; then
    OP_DEPLOYER_BIN="$(command -v op-deployer)"
  else
    echo "ERROR: OP_DEPLOYER_BIN is unset and op-deployer is not on PATH" >&2
    exit 1
  fi
fi
if [[ ! -x "$OP_DEPLOYER_BIN" ]]; then
  echo "ERROR: OP_DEPLOYER_BIN is not executable: $OP_DEPLOYER_BIN" >&2
  exit 1
fi
DEPLOYER_VERSION="$("$OP_DEPLOYER_BIN" --version 2>&1 || true)"
case "$DEPLOYER_VERSION" in
  *0.8.1*) ;;
  *)
    echo "ERROR: op-deployer v0.8.1 required, got: $DEPLOYER_VERSION" >&2
    exit 1
    ;;
esac
export OP_DEPLOYER_BIN

WORK="${OPU_U20_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/fortel2-opu20.XXXXXX")}"
mkdir -p "$WORK"
GAS_LOG="$WORK/gas.tsv"
: > "$GAS_LOG"
TOTAL_WEI=0
LAST_TX_JSON=""
SIGN_MODE=""
RPC=""
BOOT_KEY=""
BOOT_ADDR=""
EXECUTOR=""
IMPL_JSON=""
WETH_DELAY=""
CHALLENGE_PERIOD=""
MIN_PROPOSAL=""

record_gas_values() {
  local name="$1" used="$2" price="$3" hash="$4"
  local wei eth
  used="$(cast --to-dec "$used")"
  price="$(cast --to-dec "$price")"
  wei="$(python3 -c "print(int('$used')*int('$price'))")"
  eth="$(python3 -c "print(format(int('$wei')/1e18, '.12f'))")"
  TOTAL_WEI="$(python3 -c "print(int('$TOTAL_WEI')+int('$wei'))")"
  echo "GAS $name hash=$hash gasUsed=$used gasPrice=$price wei=$wei eth=$eth"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$hash" "$used" "$price" "$wei" "$eth" >> "$GAS_LOG"
}

record_gas_json() {
  local name="$1" json="$2"
  local used price hash
  used="$(jq -r '.gasUsed // .gas_used' <<<"$json")"
  price="$(jq -r '.effectiveGasPrice // .effective_gas_price' <<<"$json")"
  hash="$(jq -r '.transactionHash // .hash' <<<"$json")"
  record_gas_values "$name" "$used" "$price" "$hash"
}

record_blocks_between() {
  # On Sepolia the blocks between the bootstrap start and end contain other
  # people's transactions. Count only receipts sent by the bootstrap key.
  local name_prefix="$1" start="$2" end="$3"
  local n hash receipt used price bn txcount i from
  if [[ -z "${BOOT_ADDR:-}" ]]; then
    echo "ERROR: bootstrap sender is unset; refusing to attribute gas" >&2
    exit 1
  fi
  n=0
  bn="$start"
  while [[ "$(python3 -c "print(int('$bn') < int('$end'))")" == "True" ]]; do
    bn="$(python3 -c "print(int('$bn')+1)")"
    txcount="$(cast block "$bn" --rpc-url "$RPC" --json | jq '.transactions | length')"
    i=0
    while [[ "$i" -lt "$txcount" ]]; do
      hash="$(cast block "$bn" --rpc-url "$RPC" --json | jq -r ".transactions[$i]")"
      receipt="$(cast receipt "$hash" --rpc-url "$RPC" --json)"
      from="$(jq -r '.from // empty' <<<"$receipt")"
      i=$((i + 1))
      if [[ "$(lc "$from")" != "$(lc "$BOOT_ADDR")" ]]; then
        continue
      fi
      used="$(jq -r .gasUsed <<<"$receipt")"
      price="$(jq -r .effectiveGasPrice <<<"$receipt")"
      n=$((n + 1))
      record_gas_values "${name_prefix}-${n}" "$used" "$price" "$hash"
    done
  done
  echo "phase: recorded $n $name_prefix transactions"
}

send_from_admin() {
  local name="$1"
  shift
  LAST_TX_JSON="$(cast send --private-key "$ADMIN_PRIVATE_KEY" --rpc-url "$RPC" --json "$@")"
  record_gas_json "$name" "$LAST_TX_JSON"
}

send_from_boot() {
  local name="$1"
  shift
  LAST_TX_JSON="$(cast send --private-key "$BOOT_KEY" --rpc-url "$RPC" --json "$@")"
  record_gas_json "$name" "$LAST_TX_JSON"
}

auth_flag_send() {
  local name="$1"
  local auth_addr="$2"
  shift 2
  # `to` must be an EOA. A type-4 tx applies the delegation before the call, so
  # sending it to ADMIN would execute the new code with empty calldata and revert.
  LAST_TX_JSON="$(cast send --private-key "$ADMIN_PRIVATE_KEY" --auth "$auth_addr" --rpc-url "$RPC" --json "$@")"
  record_gas_json "$name" "$LAST_TX_JSON"
}

DELEGATED=0

revoke_delegation() {
  local why="$1" code
  if [[ "$DELEGATED" != "1" ]]; then
    return 0
  fi
  # Clear the flag before the send so a failed revoke cannot re-enter this
  # function from the ERR trap. A later run clears a leftover 0xef0100 designator.
  DELEGATED=0
  echo "phase: revoke delegation ($why)"
  auth_flag_send "eip7702-revoke" "0x0000000000000000000000000000000000000000" "$PROPOSER_ADDRESS" --value 0
  code="$(cast code "$ADMIN_ADDRESS" --rpc-url "$RPC")"
  if [[ "$code" != "0x" ]]; then
    echo "ERROR: revoke left code on ADMIN" >&2
    return 1
  fi
}

on_upgrade_err() {
  rc=$?
  trap - ERR
  if [[ "$DELEGATED" == "1" ]]; then
    revoke_delegation "cleanup" || echo "ERROR: cleanup revoke failed" >&2
  fi
  exit "$rc"
}

clear_leftover_delegation() {
  local code
  code="$(lc "$(cast code "$ADMIN_ADDRESS" --rpc-url "$RPC")")"
  if [[ "$code" == "0x" ]]; then
    return 0
  fi
  case "$code" in
    0xef0100*) ;;
    *)
      echo "ERROR: ADMIN has non-delegation code; refusing" >&2
      exit 1
      ;;
  esac
  echo "phase: clearing leftover EIP-7702 delegation"
  prepare_boot_key
  DELEGATED=1
  revoke_delegation "leftover"
}

build_upgrade_calldata() {
  local pre9="$1" bond5="$2" pre1="$3" prop="$4" chal="$5"
  local ga1 ga8 ga5 ga9 res tuple
  ga1="$(cast abi-encode "f(bytes32,address,address)" "$pre1" "$prop" "$chal")"
  ga8="$(cast abi-encode "f(bytes32)" "$U20_TYPE8_PRESTATE")"
  ga5="$(cast abi-encode "f(address)" "$PROPOSER_ADDRESS")"
  ga9="$(cast abi-encode "f(bytes32)" "$pre9")"
  res="$(cast abi-encode "f(uint32)" 9)"
  tuple="($SYSTEM_CONFIG,[(false,$U20_BOND_TYPE0_WEI,0,0x),(true,$U20_BOND_TYPE1_WEI,1,$ga1),(true,$U20_BOND_TYPE8_WEI,8,$ga8),(true,$bond5,5,$ga5),(true,$U20_BOND_TYPE9_WEI,9,$ga9),(false,$U20_BOND_ZK_WEI,10,0x)],[(\"overrides.cfg.startingRespectedGameType\",$res)])"
  cast calldata "upgrade((address,(bool,uint256,uint32,bytes)[],(string,bytes)[]))" "$tuple"
}

execute_calldata() {
  local inner="$1"
  cast calldata "execute(address,bytes)" "$OPCM" "$inner"
}

snapshot_config() {
  printf '%s|%s|%s|%s' \
    "$(call_str "$SYSTEM_CONFIG" "version()(string)")" \
    "$(call_str "$SUPERCHAIN" "version()(string)")" \
    "$(call_word "$ASR" "respectedGameType()(uint32)")" \
    "$(call_word "$DGF" "initBonds(uint32)(uint256)" 8)"
}

expect_revert_invalid() {
  local label="$1" inner="$2" before after err rc data
  before="$(snapshot_config)"
  data="$(execute_calldata "$inner")"
  set +e
  err="$(cast call "$ADMIN_ADDRESS" "$data" --from "$ADMIN_ADDRESS" --rpc-url "$RPC" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "ERROR: $label was expected to revert" >&2
    exit 1
  fi
  if ! printf '%s\n' "$err" | grep -q "$U20_INVALID_GAME_CONFIGS"; then
    echo "ERROR: $label did not revert OPContractsManagerV2_InvalidGameConfigs" >&2
    printf '%s\n' "$err" >&2
    exit 1
  fi
  after="$(snapshot_config)"
  if [[ "$before" != "$after" ]]; then
    echo "ERROR: $label changed state ($before -> $after)" >&2
    exit 1
  fi
  echo "ASSERT ok $label reverted $U20_INVALID_GAME_CONFIGS state=$after"
}

print_state() {
  local sc_ver portal_ver dgf_ver asr_ver super_ver respected maturity finality
  local bond0 bond1 bond8 bond5 bond9 bondzk admin_code impl8 impl9
  sc_ver="$(call_str "$SYSTEM_CONFIG" "version()(string)")"
  portal_ver="$(call_str "$PORTAL" "version()(string)")"
  dgf_ver="$(call_str "$DGF" "version()(string)")"
  asr_ver="$(call_str "$ASR" "version()(string)")"
  super_ver="$(call_str "$SUPERCHAIN" "version()(string)")"
  respected="$(call_word "$ASR" "respectedGameType()(uint32)")"
  maturity="$(call_word "$PORTAL" "proofMaturityDelaySeconds()(uint256)")"
  finality="$(call_word "$ASR" "disputeGameFinalityDelaySeconds()(uint256)")"
  bond0="$(call_word "$DGF" "initBonds(uint32)(uint256)" 0)"
  bond1="$(call_word "$DGF" "initBonds(uint32)(uint256)" 1)"
  bond8="$(call_word "$DGF" "initBonds(uint32)(uint256)" 8)"
  bond5="$(call_word "$DGF" "initBonds(uint32)(uint256)" 5)"
  bond9="$(call_word "$DGF" "initBonds(uint32)(uint256)" 9)"
  bondzk="$(call_word "$DGF" "initBonds(uint32)(uint256)" 10)"
  impl8="$(call_word "$DGF" "gameImpls(uint32)(address)" 8)"
  impl9="$(call_word "$DGF" "gameImpls(uint32)(address)" 9)"
  admin_code="$(cast code "$ADMIN_ADDRESS" --rpc-url "$RPC")"
  echo "state systemConfig=$sc_ver portal=$portal_ver dgf=$dgf_ver asr=$asr_ver superchain=$super_ver"
  echo "state respectedGameType=$respected proofMaturity=$maturity finality=$finality"
  echo "state bonds type0=$bond0 type1=$bond1 type8=$bond8 type5=$bond5 type9=$bond9 zk=$bondzk"
  echo "state gameImpls8=$impl8 gameImpls9=$impl9 adminCodeBytes=$(((${#admin_code} - 2) / 2))"
  echo "state admin=$ADMIN_ADDRESS proposer=$PROPOSER_ADDRESS challenger=$CHALLENGER_ADDRESS"
  echo "state wethDelay=$WETH_DELAY challengePeriod=$CHALLENGE_PERIOD minProposal=$MIN_PROPOSAL"
}

upgrade_markers_present() {
  local super_ver impl9 admin_code sc_ver
  sc_ver="$(call_str "$SYSTEM_CONFIG" "version()(string)")"
  super_ver="$(call_str "$SUPERCHAIN" "version()(string)")"
  impl9="$(lc "$(call_word "$DGF" "gameImpls(uint32)(address)" 9)")"
  admin_code="$(cast code "$ADMIN_ADDRESS" --rpc-url "$RPC")"
  [[ "$sc_ver" == "4.0.0" || "$super_ver" == "2.4.3" || "$impl9" != "0x0000000000000000000000000000000000000000" || "$admin_code" != "0x" ]]
}

ASSERT_FAIL=0
check_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "$(lc "$got")" == "$(lc "$want")" ]]; then
    echo "ASSERT ok $name=$got"
  else
    echo "ASSERT FAIL $name got=$got want=$want" >&2
    ASSERT_FAIL=1
  fi
}

prestate_of() {
  local raw hex
  raw="$(call_word "$DGF" "gameArgs(uint32)(bytes)" "$1")"
  hex="${raw#0x}"
  printf '0x%s' "${hex:0:64}"
}

assert_post_state() {
  local pa spa impl8 impl9 g8clock g8ext g8depth g8split g9clock g9ext g9depth g9split
  local admin_code key ver
  ASSERT_FAIL=0
  check_eq "SystemConfig.version" "$(call_str "$SYSTEM_CONFIG" "version()(string)")" "4.0.0"
  check_eq "SuperchainConfig.version" "$(call_str "$SUPERCHAIN" "version()(string)")" "2.4.3"
  check_eq "OptimismPortal.version" "$(call_str "$PORTAL" "version()(string)")" "5.8.0"
  check_eq "DisputeGameFactory.version" "$(call_str "$DGF" "version()(string)")" "1.6.1"
  check_eq "AnchorStateRegistry.version" "$(call_str "$ASR" "version()(string)")" "3.9.0"
  check_eq "portal.proofMaturityDelaySeconds" "$(call_word "$PORTAL" "proofMaturityDelaySeconds()(uint256)")" "$U20_PROOF_MATURITY"
  check_eq "asr.disputeGameFinalityDelaySeconds" "$(call_word "$ASR" "disputeGameFinalityDelaySeconds()(uint256)")" "$U20_FINALITY_DELAY"
  impl8="$(call_word "$DGF" "gameImpls(uint32)(address)" 8)"
  impl9="$(call_word "$DGF" "gameImpls(uint32)(address)" 9)"
  g8clock="$(call_word "$impl8" "maxClockDuration()(uint64)")"
  g8ext="$(call_word "$impl8" "clockExtension()(uint64)")"
  g8depth="$(call_word "$impl8" "maxGameDepth()(uint256)")"
  g8split="$(call_word "$impl8" "splitDepth()(uint256)")"
  g9clock="$(call_word "$impl9" "maxClockDuration()(uint64)")"
  g9ext="$(call_word "$impl9" "clockExtension()(uint64)")"
  g9depth="$(call_word "$impl9" "maxGameDepth()(uint256)")"
  g9split="$(call_word "$impl9" "splitDepth()(uint256)")"
  check_eq "type8.maxClockDuration" "$g8clock" "$U20_MAX_CLOCK"
  check_eq "type8.clockExtension" "$g8ext" "$U20_CLOCK_EXT"
  check_eq "type8.maxGameDepth" "$g8depth" "$U20_MAX_DEPTH"
  check_eq "type8.splitDepth" "$g8split" "$U20_SPLIT_DEPTH"
  check_eq "type9.maxClockDuration" "$g9clock" "$U20_MAX_CLOCK"
  check_eq "type9.clockExtension" "$g9ext" "$U20_CLOCK_EXT"
  check_eq "type9.maxGameDepth" "$g9depth" "$U20_MAX_DEPTH"
  check_eq "type9.splitDepth" "$g9split" "$U20_SPLIT_DEPTH"
  check_eq "gameArgs8.prestate" "$(prestate_of 8)" "$U20_TYPE8_PRESTATE"
  check_eq "gameArgs9.prestate" "$(prestate_of 9)" "$U20_TYPE9_PRESTATE"
  check_eq "initBonds(0)" "$(call_word "$DGF" "initBonds(uint32)(uint256)" 0)" "$U20_BOND_TYPE0_WEI"
  check_eq "initBonds(1)" "$(call_word "$DGF" "initBonds(uint32)(uint256)" 1)" "$U20_BOND_TYPE1_WEI"
  check_eq "initBonds(8)" "$(call_word "$DGF" "initBonds(uint32)(uint256)" 8)" "$U20_BOND_TYPE8_WEI"
  check_eq "initBonds(5)" "$(call_word "$DGF" "initBonds(uint32)(uint256)" 5)" "$U20_BOND_TYPE5_WEI"
  check_eq "initBonds(9)" "$(call_word "$DGF" "initBonds(uint32)(uint256)" 9)" "$U20_BOND_TYPE9_WEI"
  check_eq "initBonds(10)" "$(call_word "$DGF" "initBonds(uint32)(uint256)" 10)" "$U20_BOND_ZK_WEI"
  check_eq "respectedGameType" "$(call_word "$ASR" "respectedGameType()(uint32)")" "9"
  pa="$(call_word "$PORTAL" "proxyAdmin()(address)")"
  spa="$(call_word "$SUPERCHAIN" "proxyAdmin()(address)")"
  check_eq "ProxyAdmin.owner" "$(call_word "$pa" "owner()(address)")" "$ADMIN_ADDRESS"
  check_eq "DisputeGameFactory.owner" "$(call_word "$DGF" "owner()(address)")" "$ADMIN_ADDRESS"
  check_eq "SuperchainConfig.ProxyAdmin.owner" "$(call_word "$spa" "owner()(address)")" "$ADMIN_ADDRESS"
  admin_code="$(cast code "$ADMIN_ADDRESS" --rpc-url "$RPC")"
  check_eq "ADMIN.code" "$admin_code" "0x"
  if [[ -n "$IMPL_JSON" && -f "$IMPL_JSON" ]]; then
    while IFS='|' read -r key ver; do
      addr="$(jq -r ".$key" "$IMPL_JSON")"
      check_eq "$key.version" "$(call_str "$addr" "version()(string)")" "$ver"
    done <<'EOF'
opcmV2Address|8.0.1
systemConfigImplAddress|4.0.0
optimismPortalImplAddress|5.8.0
anchorStateRegistryImplAddress|3.9.0
delayedWETHImplAddress|1.5.1
ethLockboxImplAddress|1.3.1
disputeGameFactoryImplAddress|1.6.1
preimageOracleSingletonAddress|1.1.5
mipsSingletonAddress|1.10.1
l1CrossDomainMessengerImplAddress|2.11.1
l1ERC721BridgeImplAddress|2.9.1
l1StandardBridgeImplAddress|2.8.2
optimismMintableERC20FactoryImplAddress|1.11.0
faultDisputeGameImplAddress|2.4.2
permissionedDisputeGameImplAddress|2.4.0
superchainConfigImplAddress|2.4.3
EOF
  fi
  if [[ "$ASSERT_FAIL" -ne 0 ]]; then
    echo "ERROR: post-state assertions failed" >&2
    exit 1
  fi
}

read_preserved_delays() {
  local weth oracle mips impl8
  weth="$(call_word "$SYSTEM_CONFIG" "delayedWETH()(address)")"
  WETH_DELAY="$(call_word "$weth" "delay()(uint256)")"
  impl8="$(call_word "$DGF" "gameImpls(uint32)(address)" 8)"
  # VM, ASR and WETH live in the factory game args, not in the implementation.
  local args hex
  args="$(call_word "$DGF" "gameArgs(uint32)(bytes)" 8)"
  hex="${args#0x}"
  mips="0x${hex:64:40}"
  oracle="$(call_word "$mips" "oracle()(address)")"
  CHALLENGE_PERIOD="$(call_word "$oracle" "challengePeriod()(uint256)")"
  MIN_PROPOSAL="$(call_word "$oracle" "minProposalSize()(uint256)")"
  local maturity finality clock ext depth split bond1
  maturity="$(call_word "$PORTAL" "proofMaturityDelaySeconds()(uint256)")"
  finality="$(call_word "$ASR" "disputeGameFinalityDelaySeconds()(uint256)")"
  clock="$(call_word "$impl8" "maxClockDuration()(uint64)")"
  ext="$(call_word "$impl8" "clockExtension()(uint64)")"
  depth="$(call_word "$impl8" "maxGameDepth()(uint256)")"
  split="$(call_word "$impl8" "splitDepth()(uint256)")"
  bond1="$(call_word "$DGF" "initBonds(uint32)(uint256)" 1)"
  check_eq "pre.proofMaturity" "$maturity" "$U20_PROOF_MATURITY"
  check_eq "pre.finality" "$finality" "$U20_FINALITY_DELAY"
  check_eq "pre.maxClock" "$clock" "$U20_MAX_CLOCK"
  check_eq "pre.clockExt" "$ext" "$U20_CLOCK_EXT"
  check_eq "pre.maxDepth" "$depth" "$U20_MAX_DEPTH"
  check_eq "pre.splitDepth" "$split" "$U20_SPLIT_DEPTH"
  check_eq "pre.initBonds(1)" "$bond1" "$U20_BOND_TYPE1_WEI"
  check_eq "pre.gameArgs8.prestate" "$(prestate_of 8)" "$U20_TYPE8_PRESTATE"
  if [[ "$ASSERT_FAIL" -ne 0 ]]; then
    echo "ERROR: live delays do not match the pinned U20 values; refusing" >&2
    exit 1
  fi
  ASSERT_FAIL=0
}

decode_type1() {
  local raw
  raw="$(call_word "$DGF" "gameArgs(uint32)(bytes)" 1)"
  python3 - "$raw" <<'PY'
import sys
h = sys.argv[1].lower().removeprefix("0x")
if len(h) != 328:
    raise SystemExit(f"type1 gameArgs length {len(h)} hex chars, want 328")
print("0x" + h[0:64])
print("0x" + h[248:288])
print("0x" + h[288:328])
PY
}

prepare_boot_key() {
  require_key_matches_address ADMIN_PRIVATE_KEY ADMIN_ADDRESS
  refuse_foundry_defaults_unless_local_l2 "$ADMIN_PRIVATE_KEY" "ADMIN_PRIVATE_KEY"
  BOOT_KEY="$ADMIN_PRIVATE_KEY"
  BOOT_ADDR="$ADMIN_ADDRESS"
  echo "bootstrap deployer: $BOOT_ADDR"
}

deploy_executor() {
  local artifact bytecode
  (cd "$FORTEL2_ROOT/contracts" && forge build --skip test >/dev/null)
  artifact="$FORTEL2_ROOT/contracts/out/U20DelegateExecutor.sol/U20DelegateExecutor.json"
  bytecode="$(jq -r .bytecode.object "$artifact")"
  if [[ -z "$bytecode" || "$bytecode" == "null" ]]; then
    echo "ERROR: executor bytecode missing" >&2
    exit 1
  fi
  send_from_boot "deploy-executor" --create "$bytecode"
  EXECUTOR="$(jq -r .contractAddress <<<"$LAST_TX_JSON")"
  require_eth_address "executor" "$EXECUTOR"
  echo "executor: $EXECUTOR"
}

bootstrap_impls() {
  local pa spa start end
  pa="$(call_word "$PORTAL" "proxyAdmin()(address)")"
  spa="$(call_word "$SUPERCHAIN" "proxyAdmin()(address)")"
  IMPL_JSON="$WORK/implementations.json"
  start="$(cast block-number --rpc-url "$RPC")"
  echo "phase: bootstrap implementations (op-deployer $($OP_DEPLOYER_BIN --version))"
  "$OP_DEPLOYER_BIN" bootstrap implementations \
    --l1-rpc-url "$RPC" \
    --private-key "$BOOT_KEY" \
    --artifacts-locator "embedded" \
    --mips-version 8 \
    --withdrawal-delay-seconds "$WETH_DELAY" \
    --min-proposal-size-bytes "$MIN_PROPOSAL" \
    --challenge-period-seconds "$CHALLENGE_PERIOD" \
    --proof-maturity-delay-seconds "$U20_PROOF_MATURITY" \
    --dispute-game-finality-delay-seconds "$U20_FINALITY_DELAY" \
    --dispute-max-game-depth "$U20_MAX_DEPTH" \
    --dispute-split-depth "$U20_SPLIT_DEPTH" \
    --dispute-clock-extension "$U20_CLOCK_EXT" \
    --dispute-max-clock-duration "$U20_MAX_CLOCK" \
    --superchain-config-proxy "$SUPERCHAIN" \
    --l1-proxy-admin-owner "$ADMIN_ADDRESS" \
    --superchain-proxy-admin "$spa" \
    --challenger "$CHALLENGER_ADDRESS" \
    --no-verify \
    --outfile "$IMPL_JSON"
  end="$(cast block-number --rpc-url "$RPC")"
  record_blocks_between "bootstrap" "$start" "$end"
  OPCM="$(jq -r .opcmV2Address "$IMPL_JSON")"
  require_eth_address "OPCM" "$OPCM"
  echo "opcm: $OPCM"
  # Fail closed before any upgrade if our impls did not keep the delays.
  local portal_impl asr_impl weth_impl oracle fault_impl super_impl
  portal_impl="$(jq -r .optimismPortalImplAddress "$IMPL_JSON")"
  asr_impl="$(jq -r .anchorStateRegistryImplAddress "$IMPL_JSON")"
  weth_impl="$(jq -r .delayedWETHImplAddress "$IMPL_JSON")"
  oracle="$(jq -r .preimageOracleSingletonAddress "$IMPL_JSON")"
  fault_impl="$(jq -r .faultDisputeGameImplAddress "$IMPL_JSON")"
  super_impl="$(jq -r .superFaultDisputeGameImplAddress "$IMPL_JSON")"
  check_eq "new.portal.proofMaturity" "$(call_word "$portal_impl" "proofMaturityDelaySeconds()(uint256)")" "$U20_PROOF_MATURITY"
  check_eq "new.asr.finality" "$(call_word "$asr_impl" "disputeGameFinalityDelaySeconds()(uint256)")" "$U20_FINALITY_DELAY"
  check_eq "new.weth.delay" "$(call_word "$weth_impl" "delay()(uint256)")" "$WETH_DELAY"
  check_eq "new.oracle.challengePeriod" "$(call_word "$oracle" "challengePeriod()(uint256)")" "$CHALLENGE_PERIOD"
  check_eq "new.fault.maxClock" "$(call_word "$fault_impl" "maxClockDuration()(uint64)")" "$U20_MAX_CLOCK"
  check_eq "new.super.maxClock" "$(call_word "$super_impl" "maxClockDuration()(uint64)")" "$U20_MAX_CLOCK"
  if [[ "$(jq -r .superFaultDisputeGameImplAddress "$IMPL_JSON")" == "0x0000000000000000000000000000000000000000" ]]; then
    echo "ERROR: bootstrap did not deploy a super fault dispute game" >&2
    exit 1
  fi
  if [[ "$ASSERT_FAIL" -ne 0 ]]; then
    echo "ERROR: bootstrapped impl delays do not match; not upgrading" >&2
    exit 1
  fi
  ASSERT_FAIL=0
  # The chain ProxyAdmin must stay the one the upgrade will call. The flag
  # above is the superchain proxy admin; the chain proxy admin is loaded by OPCM.
  echo "chain ProxyAdmin: $pa"
}

run_upgrade() {
  local cid pre1 prop chal map inner super_inner respected
  cid="$(cast chain-id --rpc-url "$RPC")"
  if [[ "$cid" != "11155111" ]]; then
    echo "ERROR: RPC chain id is $cid, want Sepolia 11155111" >&2
    exit 1
  fi
  if [[ "$SIGN_MODE" == "fork" ]]; then
    assert_loopback_url "$RPC" "--fork"
  fi
  read_preserved_delays
  print_state
  clear_leftover_delegation
  if assert_post_state_quiet; then
    echo "phase: already at U20 post-state; no-op"
    assert_post_state
    print_gas_total
    exit 0
  fi
  if upgrade_markers_present; then
    echo "ERROR: partial U20 state on $(redact_rpc_url "$RPC"); refusing to continue" >&2
    print_state
    exit 1
  fi
  map="$(decode_type1)"
  pre1="$(sed -n '1p' <<<"$map")"
  prop="$(sed -n '2p' <<<"$map")"
  chal="$(sed -n '3p' <<<"$map")"
  check_eq "type1.proposer" "$prop" "$PROPOSER_ADDRESS"
  check_eq "type1.challenger" "$chal" "$CHALLENGER_ADDRESS"
  if [[ "$ASSERT_FAIL" -ne 0 ]]; then
    echo "ERROR: type-1 game args do not match PROPOSER_ADDRESS / CHALLENGER_ADDRESS" >&2
    exit 1
  fi
  ASSERT_FAIL=0
  echo "type1 prestate=$pre1 proposer=$prop challenger=$chal"
  prepare_boot_key
  bootstrap_impls
  echo "phase: bootstrap done"
  deploy_executor
  echo "phase: delegating ADMIN to $EXECUTOR"
  auth_flag_send "eip7702-delegate" "$EXECUTOR" "$PROPOSER_ADDRESS" --value 0
  local admin_code
  admin_code="$(cast code "$ADMIN_ADDRESS" --rpc-url "$RPC")"
  if [[ "$admin_code" == "0x" ]]; then
    echo "ERROR: EIP-7702 delegation did not install code on ADMIN" >&2
    exit 1
  fi
  DELEGATED=1
  trap on_upgrade_err ERR
  echo "state admin delegated codeBytes=$(((${#admin_code} - 2) / 2))"
  if [[ "${OPU_U20_REHEARSE_FAULTS:-}" == "1" ]]; then
    echo "phase: fault rehearsal"
    local bad_pre bad_bond
    bad_pre="$(build_upgrade_calldata "0x0000000000000000000000000000000000000000000000000000000000000000" "$U20_BOND_TYPE5_WEI" "$pre1" "$prop" "$chal")"
    expect_revert_invalid "bad-type9-prestate" "$bad_pre"
    bad_bond="$(build_upgrade_calldata "$U20_TYPE9_PRESTATE" 1 "$pre1" "$prop" "$chal")"
    expect_revert_invalid "bad-type5-bond" "$bad_bond"
  fi
  super_inner="$(cast calldata "upgradeSuperchain((address,(string,bytes)[]))" "($SUPERCHAIN,[])")"
  echo "phase: upgradeSuperchain"
  send_from_admin "upgradeSuperchain" "$ADMIN_ADDRESS" "$(execute_calldata "$super_inner")"
  echo "phase: upgrade"
  inner="$(build_upgrade_calldata "$U20_TYPE9_PRESTATE" "$U20_BOND_TYPE5_WEI" "$pre1" "$prop" "$chal")"
  case "$inner" in
    0x8a847e2e*) ;;
    *)
      echo "ERROR: upgrade calldata selector is not upgrade()" >&2
      exit 1
      ;;
  esac
  send_from_admin "upgrade" "$ADMIN_ADDRESS" "$(execute_calldata "$inner")"
  respected="$(call_word "$ASR" "respectedGameType()(uint32)")"
  if [[ "$respected" != "9" ]]; then
    echo "phase: respected game type is $respected; guardian setRespectedGameType(9)"
    send_from_admin "setRespectedGameType" "$ASR" "setRespectedGameType(uint32)" 9
  else
    echo "phase: respected game type 9 was set by the upgrade override"
  fi
  revoke_delegation "upgrade"
  trap - ERR
  echo "phase: upgrade done"
  assert_post_state
  print_gas_total
  echo "work dir: $WORK"
}

assert_post_state_quiet() {
  local respected sc_ver super_ver admin_code pre8 pre9
  sc_ver="$(call_str "$SYSTEM_CONFIG" "version()(string)")"
  super_ver="$(call_str "$SUPERCHAIN" "version()(string)")"
  respected="$(call_word "$ASR" "respectedGameType()(uint32)")"
  admin_code="$(cast code "$ADMIN_ADDRESS" --rpc-url "$RPC")"
  if [[ "$sc_ver" != "4.0.0" || "$super_ver" != "2.4.3" || "$respected" != "9" || "$admin_code" != "0x" ]]; then
    return 1
  fi
  pre8="$(prestate_of 8)"
  pre9="$(prestate_of 9)"
  [[ "$(lc "$pre8")" == "$(lc "$U20_TYPE8_PRESTATE")" && "$(lc "$pre9")" == "$(lc "$U20_TYPE9_PRESTATE")" ]]
}

print_gas_total() {
  local eth
  eth="$(python3 -c "print(format(int('$TOTAL_WEI')/1e18, '.12f'))")"
  echo "GAS total wei=$TOTAL_WEI eth=$eth"
}

start_dry_fork() {
  local port dir upstream url pid
  require_bin anvil
  upstream="${OPU_U20_FORK_UPSTREAM:-https://ethereum-sepolia-rpc.publicnode.com}"
  case "$upstream" in
    http://127.0.0.1:*|http://localhost:*|https://127.0.0.1:*|https://localhost:*)
      echo "ERROR: dry-run upstream must be the Sepolia endpoint, not a loopback URL" >&2
      exit 1
      ;;
  esac
  dir="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-opu20-anvil.XXXXXX")"
  port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
  url="http://127.0.0.1:${port}"
  echo "phase: --live dry fork $url"
  anvil \
    --fork-url "$upstream" \
    --port "$port" \
    --chain-id 11155111 \
    --block-time 2 \
    --auto-impersonate \
    --cache-path "$dir/cache" \
    --state "$dir/state.json" \
    >"$dir/anvil.log" 2>&1 &
  pid=$!
  if ! wait_for_rpc "$url" "u20-dry-fork" 180; then
    kill "$pid" >/dev/null 2>&1 || true
    echo "ERROR: dry-run fork failed to start; see $dir/anvil.log" >&2
    exit 1
  fi
  set +e
  FORTEL2_ENV=".env.sepolia" \
    OP_DEPLOYER_BIN="$OP_DEPLOYER_BIN" \
    OPU_U20_REHEARSE_FAULTS="${OPU_U20_REHEARSE_FAULTS:-}" \
    "$0" --fork "$url"
  local rc=$?
  set -e
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
  if [[ "$rc" -ne 0 ]]; then
    echo "ERROR: --live dry fork failed; not sending a live transaction" >&2
    exit 1
  fi
  echo "dry-run anvil dir: $dir"
}

if [[ "$MODE" == "live" ]]; then
  start_dry_fork
  SIGN_MODE=key
  RPC="${L1_RPC_URL:-}"
  assert_remote_l1_rpc_url "$RPC" "L1_RPC_URL"
  echo "phase: live upgrade against L1"
  run_upgrade
else
  SIGN_MODE=fork
  RPC="$FORK_RPC"
  assert_loopback_url "$RPC" "--fork"
  wait_for_rpc "$RPC" "u20-fork" 30
  run_upgrade
fi
