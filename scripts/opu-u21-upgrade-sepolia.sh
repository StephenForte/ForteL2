#!/usr/bin/env bash
# U21 (op-contracts v9) rehearsal. Live execution requires operator approval.
# Reuses U20DelegateExecutor unchanged. Never writes a copy of .env.sepolia.
# Default work is --fork against a loopback Anvil. This file never prints keys.
#
# Existing respected type and starting anchor are loaded by OPCM from the ASR.
# PermittedProxyDeployment / bytes("ETHLockbox") permits the new proxy in v9.
# No anchor-root override or guardian mutation is made.
#
# Caller is a temporary EIP-7702 delegation to U20DelegateExecutor, then a
# revoke (authorize address(0)). The executor has no storage layout: under
# 7702 its code runs in ADMIN's context, and the OPCM delegatecall stays there.
#
# Signing route (a). op-deployer v0.9.0 signs with PrivateKeySignerFn bound to
# eth_chainId (bootstrap/implementations.go). It has no unsigned mode, so a
# throwaway key would still produce signatures that are valid on 11155111.
# --fork and the --live dry pass therefore run Anvil at U21_FORK_CHAIN_ID
# (900852) and refuse eth_chainId 11155111 before any signature. EIP-155 and
# EIP-7702 both commit to that chain id, so a rehearsal transcript cannot be
# broadcast to Sepolia. Real authorization signing happens only under --live,
# after the dry pass, and only against L1. The dry pass never passes --state
# to Anvil, and its directory is removed on every exit path.
#
# resolveSP1Verifier (implementations.go:134-152) runs only when the ZK
# dispute-game dev feature is on. This script leaves the dev bitmap at 0, and
# Check() rejects --sp1-verifier-address in that case (lines 128-129). The
# fork chain id does not take that flag.
#
# --live requires U21_LIVE_MAX_FEE_PER_GAS. Before the first live transaction
# the dry-pass gas total is multiplied by that cap. The script refuses unless
# ADMIN's balance is at least twice the product. cast sends use the cap as
# maxFeePerGas. op-deployer has no fee flag; its txmgr bids tip+2*base with a
# 1 gwei floor on each (3 gwei minimum). A loopback proxy rewrites the latest
# base fee so that bid stays within the cap, and it rejects any raw transaction
# whose maxFeePerGas is above the cap.
set -euo pipefail
# Never emit raw RPC errors: cast/op-deployer may repeat a credentialed URL.
# Stream filtering also covers early chain-id guards before lib.sh is sourced.
exec 2> >(python3 -u -c 'import re,sys; from urllib.parse import urlsplit
for line in sys.stdin:
 def red(m):
  try:
   p=urlsplit(m[0]); return p.scheme+"://"+(p.hostname or "[redacted]")+(":"+str(p.port) if p.port else "")
  except ValueError: return "[redacted-url]"
 print(re.sub(r"https?://[^\s\"<>]+",red,line),end="",flush=True)')

# Pinned by D-0169. test-helpers.sh greps these literals.
U21_TYPE8_PRESTATE=0x034c90f083e8c86bb6bf18236d653d4aa42fac0653f013c780448000b9796b8d
U21_TYPE9_PRESTATE=0x03284f1b70ad7525bcda6090685bc068e38f74c572132a0535ae5059b5d14792
U21_BOND_TYPE0_WEI=0
U21_BOND_TYPE1_WEI=80000000000000000
U21_BOND_TYPE8_WEI=1000000000000000
U21_BOND_TYPE5_WEI=0
U21_BOND_TYPE9_WEI=1000000000000000
U21_BOND_ZK_WEI=0
U21_PROOF_MATURITY=1800
U21_FINALITY_DELAY=1800
U21_MAX_CLOCK=7200
U21_CLOCK_EXT=600
U21_MAX_DEPTH=73
U21_SPLIT_DEPTH=30
U21_CONFIRM_PHRASE=I-UNDERSTAND-THIS-IS-IRREVERSIBLE
U21_INVALID_GAME_CONFIGS=0x7c165cd6
# Not Sepolia. Fork signatures are EIP-155 / EIP-7702 for this id only.
U21_FORK_CHAIN_ID=900852
# op-deployer floors tip and base at 1 gwei, then fee cap = tip + 2*base.
U21_DEPLOYER_MIN_FEE=3000000000

usage() {
  cat <<'EOF'
Usage:
  opu-u21-upgrade-sepolia.sh --fork <loopback-rpc> [--revoke-only]
  CONFIRM_U21_LIVE=I-UNDERSTAND-THIS-IS-IRREVERSIBLE FORTEL2_ENV=.env.sepolia \
    opu-u21-upgrade-sepolia.sh --live [--revoke-only]

--fork signs with ADMIN only after eth_chainId is 900852. Chain id 11155111
is refused before any signature. --live refuses without the confirm string,
FORTEL2_ENV=.env.sepolia, and U21_LIVE_MAX_FEE_PER_GAS (wei, at least 3000000000).
It runs a fresh --fork dry pass first, refuses unless ADMIN holds twice
dry-pass gas times that cap, then signs against L1 with the cap on every tx.
Set OP_DEPLOYER_BIN to op-deployer v0.9.0.
--revoke-only recovers a leftover ADMIN EIP-7702 delegation without upgrading
any contracts, including after a completed or partial upgrade. With --live it
uses the same confirmation/env/fee guards, fresh fork pass and funding check.
A normal upgrade requires pristine U20 versions, including SuperchainConfig
2.4.3; partial upgrades are refused.
EOF
}

# Guards run before lib.sh so a missing env file cannot hide a refusal.
MODE=""
REVOKE_ONLY=0
FORK_RPC=""
FUND_GAS=""
FUND_FEE=""
FUND_BAL=""
DRY_DIR=""
DRY_PID=""
FEE_DIR=""
FEE_PID=""
DRY_GAS=""
WORK=""
WORK_OWNED=0
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
    --revoke-only)
      REVOKE_ONLY=1
      shift
      ;;
    --check-funding)
      if [[ $# -lt 4 ]]; then
        echo "ERROR: --check-funding needs gas maxFeePerGas balance" >&2
        exit 1
      fi
      MODE=check-funding
      FUND_GAS="$2"
      FUND_FEE="$3"
      FUND_BAL="$4"
      shift 4
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

if [[ -z "$MODE" ]]; then
  echo "ERROR: choose --fork or --live" >&2
  exit 1
fi

if [[ "$MODE" == "live" ]]; then
  if [[ "${CONFIRM_U21_LIVE:-}" != "$U21_CONFIRM_PHRASE" ]]; then
    echo "ERROR: --live refused without CONFIRM_U21_LIVE=$U21_CONFIRM_PHRASE" >&2
    exit 1
  fi
  if [[ "${FORTEL2_ENV:-}" != ".env.sepolia" ]]; then
    echo "ERROR: --live requires FORTEL2_ENV=.env.sepolia" >&2
    exit 1
  fi
  if [[ ! "${U21_LIVE_MAX_FEE_PER_GAS:-}" =~ ^[0-9]+$ || "${U21_LIVE_MAX_FEE_PER_GAS}" == "0" ]]; then
    echo "ERROR: --live requires U21_LIVE_MAX_FEE_PER_GAS as a non-zero decimal wei value" >&2
    exit 1
  fi
  if [[ "$U21_LIVE_MAX_FEE_PER_GAS" -lt "$U21_DEPLOYER_MIN_FEE" ]]; then
    echo "ERROR: U21_LIVE_MAX_FEE_PER_GAS is below op-deployer's 3 gwei floor ($U21_DEPLOYER_MIN_FEE)" >&2
    exit 1
  fi
fi

assert_live_funding() {
  local gas="$1" maxfee="$2" balance="$3" projected twice below
  if [[ ! "$gas" =~ ^[0-9]+$ || ! "$maxfee" =~ ^[0-9]+$ || ! "$balance" =~ ^[0-9]+$ ]]; then
    echo "ERROR: funding check needs decimal gas, maxFeePerGas, and balance" >&2
    exit 1
  fi
  if [[ "$maxfee" == "0" || "$maxfee" -lt "$U21_DEPLOYER_MIN_FEE" ]]; then
    echo "ERROR: U21_LIVE_MAX_FEE_PER_GAS is below op-deployer's 3 gwei floor ($U21_DEPLOYER_MIN_FEE)" >&2
    exit 1
  fi
  projected="$(python3 -c "print(int('$gas')*int('$maxfee'))")"
  twice="$(python3 -c "print(int('$projected')*2)")"
  below="$(python3 -c "print('yes' if int('$balance') < int('$twice') else 'no')")"
  if [[ "$below" == "yes" ]]; then
    echo "ERROR: ADMIN balance $balance wei is below 2x projected live cost $twice wei (gas $gas * maxFeePerGas $maxfee)" >&2
    exit 1
  fi
  echo "funding ok balance=$balance projected=$projected twice=$twice maxFeePerGas=$maxfee"
}

if [[ "$MODE" == "check-funding" ]]; then
  assert_live_funding "$FUND_GAS" "$FUND_FEE" "$FUND_BAL"
  exit 0
fi

cleanup_u21_temps() {
  if [[ -n "${DRY_PID:-}" ]]; then
    kill "$DRY_PID" >/dev/null 2>&1 || true
    wait "$DRY_PID" >/dev/null 2>&1 || true
    DRY_PID=""
  fi
  if [[ -n "${FEE_PID:-}" ]]; then
    kill "$FEE_PID" >/dev/null 2>&1 || true
    wait "$FEE_PID" >/dev/null 2>&1 || true
    FEE_PID=""
  fi
  if [[ -n "${DRY_DIR:-}" && -d "${DRY_DIR}" ]]; then
    rm -rf "$DRY_DIR"
    DRY_DIR=""
  fi
  if [[ -n "${FEE_DIR:-}" && -d "${FEE_DIR}" ]]; then
    rm -rf "$FEE_DIR"
    FEE_DIR=""
  fi
}
# Exit path also removes a work dir this process created. An operator-supplied
# OPU_U21_WORK is kept. start_dry_fork calls cleanup_u21_temps on purpose so
# the dry Anvil is gone before the funding check, and that call must not
# delete the parent work dir.
cleanup_u21_exit() {
  # Signals and explicit exits also revoke a delegation installed by this run.
  if [[ "${DELEGATED:-0}" == 1 ]]; then
    revoke_delegation "exit" || echo "ERROR: exit revoke failed; ADMIN may remain delegated" >&2
  fi
  cleanup_u21_temps
  if [[ "${WORK_OWNED:-0}" == "1" && -n "${WORK:-}" && -d "${WORK}" ]]; then
    rm -rf "$WORK"
    WORK=""
    WORK_OWNED=0
  fi
}
trap cleanup_u21_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

# Anvil's log repeats --fork-url, query token included. Print the last lines
# with every URL reduced to scheme and host. A missing file is not an error.
redact_log_tail() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  python3 - "$file" << 'PY'
import re, sys, urllib.parse
path = sys.argv[1]
try:
    lines = open(path, errors="replace").read().splitlines()
except OSError:
    raise SystemExit(0)
url_re = re.compile(r"https?://[^\s\"'<>]+")

def red(match):
    raw = match.group(0).rstrip(".,);]")
    parsed = urllib.parse.urlparse(raw)
    host = parsed.hostname or ""
    if parsed.port:
        host = f"{host}:{parsed.port}"
    if not host:
        return "[redacted-url]"
    return f"{parsed.scheme}://{host}"

for line in lines[-20:]:
    sys.stdout.write(url_re.sub(red, line) + "\n")
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
  if ! command -v cast >/dev/null 2>&1; then
    echo "ERROR: cast is required to read the fork chain id before signing" >&2
    exit 1
  fi
  fork_cid="$(cast chain-id --rpc-url "$FORK_RPC")"
  if [[ "$fork_cid" == "11155111" ]]; then
    echo "ERROR: --fork refuses chain id 11155111; refusing to sign with ADMIN_PRIVATE_KEY" >&2
    exit 1
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin cast
require_bin jq
require_bin python3
require_bin forge

if [[ "${L2_CHAIN_ID:-}" != "852" ]]; then
  echo "ERROR: U21 upgrade requires the Sepolia env (L2_CHAIN_ID=852, got ${L2_CHAIN_ID:-<unset>})" >&2
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
  "op-deployer version 0.9.0-28dcc630"*) ;;
  *)
    echo "ERROR: op-deployer v0.9.0 required, got: $DEPLOYER_VERSION" >&2
    exit 1
    ;;
esac
export OP_DEPLOYER_BIN

if [[ -n "${OPU_U21_WORK:-}" ]]; then
  WORK="$OPU_U21_WORK"
  WORK_OWNED=0
else
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-opu21.XXXXXX")"
  WORK_OWNED=1
fi
mkdir -p "$WORK"
GAS_LOG="$WORK/gas.tsv"
: > "$GAS_LOG"
TOTAL_WEI=0
TOTAL_GAS=0
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
  TOTAL_GAS="$(python3 -c "print(int('$TOTAL_GAS')+int('$used'))")"
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

# Scan the entire nonce window, including bootstrap, after revocation. The
# bootstrap sender is ADMIN; reject a different boot key rather than undercount.
# EIP-7702 authorizations can consume a nonce without a transaction, so we scan
# full blocks and select transaction nonces, never assume one receipt per nonce.
measure_nonce_receipts() {
  local end_nonce end_block
  end_nonce="$(cast nonce "$ADMIN_ADDRESS" --rpc-url "$RPC")"
  end_block="$(cast block-number --rpc-url "$RPC")"
  python3 - "$RPC" "$ADMIN_ADDRESS" "$START_NONCE" "$end_nonce" "$START_BLOCK" "$end_block" > "$WORK/nonce-gas.tsv" <<'PYGAS'
import json, sys
from urllib.request import Request, urlopen
url, admin, first, last, start, end = sys.argv[1:]
first, last, start, end = map(int, (first, last, start, end))
def rpc(method, params):
    with urlopen(Request(url, json.dumps(dict(jsonrpc="2.0",id=1,method=method,params=params)).encode(), {"Content-Type":"application/json"}), timeout=120) as r:
        obj=json.load(r)
    if "error" in obj: raise SystemExit("gas accounting RPC failed")
    return obj["result"]
seen=set()
for n in range(start, end+1):
    block=rpc("eth_getBlockByNumber", [hex(n), True])
    if not block: raise SystemExit("gas accounting block missing")
    for tx in block["transactions"]:
        nonce=int(tx["nonce"],16)
        if tx["from"].lower()!=admin.lower() or not first<=nonce<last: continue
        if nonce in seen: raise SystemExit("duplicate transaction nonce")
        seen.add(nonce)
        receipt=rpc("eth_getTransactionReceipt", [tx["hash"]])
        if not receipt: raise SystemExit("gas accounting receipt missing")
        print(nonce, tx["hash"], int(receipt["gasUsed"],16), int(receipt["effectiveGasPrice"],16), sep="\t")
if not seen or min(seen)!=first: raise SystemExit("gas accounting missed bootstrap start nonce")
PYGAS
  TOTAL_GAS=0
  TOTAL_WEI=0
  while IFS=$'\t' read -r nonce hash used price; do
    record_gas_values "nonce-$nonce" "$used" "$price" "$hash"
  done < "$WORK/nonce-gas.tsv"
  echo "GAS nonce-range sender=$ADMIN_ADDRESS start=$START_NONCE end=$end_nonce receipts=$(wc -l < "$WORK/nonce-gas.tsv" | tr -d ' ') bootstrap-included=yes"
}

send_from_admin() {
  local name="$1"
  shift
  if [[ "$SIGN_MODE" == "live" ]]; then
    LAST_TX_JSON="$(cast send --private-key "$ADMIN_PRIVATE_KEY" --rpc-url "$RPC" \
      --gas-price "$U21_LIVE_MAX_FEE_PER_GAS" --priority-gas-price 1 --json "$@")"
  else
    LAST_TX_JSON="$(cast send --private-key "$ADMIN_PRIVATE_KEY" --rpc-url "$RPC" --json "$@")"
  fi
  record_gas_json "$name" "$LAST_TX_JSON"
}

send_from_boot() {
  local name="$1"
  shift
  if [[ "$SIGN_MODE" == "live" ]]; then
    LAST_TX_JSON="$(cast send --private-key "$BOOT_KEY" --rpc-url "$RPC" \
      --gas-price "$U21_LIVE_MAX_FEE_PER_GAS" --priority-gas-price 1 --json "$@")"
  else
    LAST_TX_JSON="$(cast send --private-key "$BOOT_KEY" --rpc-url "$RPC" --json "$@")"
  fi
  record_gas_json "$name" "$LAST_TX_JSON"
}

auth_flag_send() {
  local name="$1"
  local auth_addr="$2"
  shift 2
  # `to` must be an EOA: delegation is applied before the empty call.
  # Conditional cleanup calls disable bash errexit inside called functions.
  # Propagate send failures explicitly, before attempting to parse a receipt.
  if [[ "$SIGN_MODE" == "live" ]]; then
    LAST_TX_JSON="$(cast send --private-key "$ADMIN_PRIVATE_KEY" --auth "$auth_addr" --rpc-url "$RPC" \
      --gas-price "$U21_LIVE_MAX_FEE_PER_GAS" --priority-gas-price 1 --json "$@")" || return "$?"
  else
    LAST_TX_JSON="$(cast send --private-key "$ADMIN_PRIVATE_KEY" --auth "$auth_addr" --rpc-url "$RPC" --json "$@")" || return "$?"
  fi
  record_gas_json "$name" "$LAST_TX_JSON"
}

DELEGATED=0

revoke_delegation() {
  local why="$1" code
  if [[ "$DELEGATED" != "1" ]]; then
    return 0
  fi
  # Keep the cleanup obligation until code is confirmed empty. ERR disables
  # its own trap before retrying, and EXIT gets one final bounded attempt.
  # Read first: a prior send may have mined despite a receipt/RPC failure.
  code="$(cast code "$ADMIN_ADDRESS" --rpc-url "$RPC")" || return "$?"
  if [[ "$code" == "0x" ]]; then
    DELEGATED=0
    return 0
  fi
  echo "phase: revoke delegation ($why)"
  if ! auth_flag_send "eip7702-revoke" "0x0000000000000000000000000000000000000000" "$PROPOSER_ADDRESS" --value 0; then
    echo "ERROR: revoke send failed; delegation cleanup remains required" >&2
    return 1
  fi
  code="$(cast code "$ADMIN_ADDRESS" --rpc-url "$RPC")" || return "$?"
  if [[ "$code" != "0x" ]]; then
    echo "ERROR: revoke left code on ADMIN" >&2
    return 1
  fi
  DELEGATED=0
}

run_revoke_only() {
  local code
  code="$(cast code "$ADMIN_ADDRESS" --rpc-url "$RPC")"
  case "$code" in
    0x)
      echo "phase: ADMIN already has no delegation; no transaction needed"
      print_gas_total
      return 0
      ;;
    0xef0100*) ;;
    *) echo "ERROR: ADMIN has non-delegation code; refusing recovery" >&2; return 1 ;;
  esac
  prepare_boot_key
  DELEGATED=1
  trap on_upgrade_err ERR
  revoke_delegation "explicit recovery" || on_upgrade_err
  trap - ERR
  check_eq "ADMIN.code" "$(cast code "$ADMIN_ADDRESS" --rpc-url "$RPC")" "0x"
  [[ "$ASSERT_FAIL" == 0 ]] || return 1
  measure_nonce_receipts
  print_gas_total
}

on_upgrade_err() {
  rc=$?
  trap - ERR
  if [[ "$DELEGATED" == "1" ]]; then
    revoke_delegation "cleanup" || echo "ERROR: cleanup revoke failed" >&2
  fi
  exit "$rc"
}


build_upgrade_calldata() {
  local pre9="$1" bond5="$2" pre1="$3" prop="$4" chal="$5"
  local ga1 ga8 ga5 ga9 res tuple
  ga1="$(cast abi-encode "f(bytes32,address,address)" "$pre1" "$prop" "$chal")"
  ga8="$(cast abi-encode "f(bytes32)" "$U21_TYPE8_PRESTATE")"
  ga5="$(cast abi-encode "f(address)" "$PROPOSER_ADDRESS")"
  ga9="$(cast abi-encode "f(bytes32)" "$pre9")"
  res=0x4554484c6f636b626f78 # bytes("ETHLockbox"), not ABI-encoded string
  tuple="($SYSTEM_CONFIG,[(false,$U21_BOND_TYPE0_WEI,0,0x),(true,$U21_BOND_TYPE1_WEI,1,$ga1),(true,$U21_BOND_TYPE8_WEI,8,$ga8),(true,$bond5,5,$ga5),(true,$U21_BOND_TYPE9_WEI,9,$ga9),(false,$U21_BOND_ZK_WEI,10,0x)],[(\"PermittedProxyDeployment\",$res)])"
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
  if ! printf '%s\n' "$err" | grep -q "$U21_INVALID_GAME_CONFIGS"; then
    echo "ERROR: $label did not revert OPContractsManagerV2_InvalidGameConfigs" >&2
    printf '%s\n' "$err" >&2
    exit 1
  fi
  after="$(snapshot_config)"
  if [[ "$before" != "$after" ]]; then
    echo "ERROR: $label changed state ($before -> $after)" >&2
    exit 1
  fi
  echo "ASSERT ok $label reverted $U21_INVALID_GAME_CONFIGS state=$after"
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
  check_eq "SystemConfig.version" "$(call_str "$SYSTEM_CONFIG" "version()(string)")" "4.3.0"
  check_eq "SuperchainConfig.version" "$(call_str "$SUPERCHAIN" "version()(string)")" "2.5.0"
  check_eq "OptimismPortal.version" "$(call_str "$PORTAL" "version()(string)")" "6.1.0"
  check_eq "DisputeGameFactory.version" "$(call_str "$DGF" "version()(string)")" "1.6.1"
  check_eq "AnchorStateRegistry.version" "$(call_str "$ASR" "version()(string)")" "4.0.0"
  check_eq "portal.proofMaturityDelaySeconds" "$(call_word "$PORTAL" "proofMaturityDelaySeconds()(uint256)")" "$U21_PROOF_MATURITY"
  check_eq "asr.disputeGameFinalityDelaySeconds" "$(call_word "$ASR" "disputeGameFinalityDelaySeconds()(uint256)")" "$U21_FINALITY_DELAY"
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
  check_eq "type8.maxClockDuration" "$g8clock" "$U21_MAX_CLOCK"
  check_eq "type8.clockExtension" "$g8ext" "$U21_CLOCK_EXT"
  check_eq "type8.maxGameDepth" "$g8depth" "$U21_MAX_DEPTH"
  check_eq "type8.splitDepth" "$g8split" "$U21_SPLIT_DEPTH"
  check_eq "type9.maxClockDuration" "$g9clock" "$U21_MAX_CLOCK"
  check_eq "type9.clockExtension" "$g9ext" "$U21_CLOCK_EXT"
  check_eq "type9.maxGameDepth" "$g9depth" "$U21_MAX_DEPTH"
  check_eq "type9.splitDepth" "$g9split" "$U21_SPLIT_DEPTH"
  check_eq "gameArgs8.prestate" "$(prestate_of 8)" "$U21_TYPE8_PRESTATE"
  check_eq "gameArgs9.prestate" "$(prestate_of 9)" "$U21_TYPE9_PRESTATE"
  check_eq "initBonds(0)" "$(call_word "$DGF" "initBonds(uint32)(uint256)" 0)" "$U21_BOND_TYPE0_WEI"
  check_eq "initBonds(1)" "$(call_word "$DGF" "initBonds(uint32)(uint256)" 1)" "$U21_BOND_TYPE1_WEI"
  check_eq "initBonds(8)" "$(call_word "$DGF" "initBonds(uint32)(uint256)" 8)" "$U21_BOND_TYPE8_WEI"
  check_eq "initBonds(5)" "$(call_word "$DGF" "initBonds(uint32)(uint256)" 5)" "$U21_BOND_TYPE5_WEI"
  check_eq "initBonds(9)" "$(call_word "$DGF" "initBonds(uint32)(uint256)" 9)" "$U21_BOND_TYPE9_WEI"
  check_eq "initBonds(10)" "$(call_word "$DGF" "initBonds(uint32)(uint256)" 10)" "$U21_BOND_ZK_WEI"
  check_eq "respectedGameType" "$(call_word "$ASR" "respectedGameType()(uint32)")" "9"
  assert_preserved_state
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
opcmV2Address|9.0.3
systemConfigImplAddress|4.3.0
optimismPortalImplAddress|6.1.0
anchorStateRegistryImplAddress|4.0.0
delayedWETHImplAddress|2.0.0
ethLockboxImplAddress|2.0.0
l1CrossDomainMessengerImplAddress|2.13.0
superchainConfigImplAddress|2.5.0
EOF
  fi
  if [[ "$ASSERT_FAIL" -ne 0 ]]; then
    echo "ERROR: post-state assertions failed" >&2
    exit 1
  fi
}


capture_pre_state() {
  PRE_ANCHOR_GAME="$(call_word "$ASR" "anchorGame()(address)")"
  PRE_ANCHOR_ROOT="$(call_raw "$ASR" "getAnchorRoot()(bytes32,uint256)")"
  PRE_START_ROOT="$(call_raw "$ASR" "getStartingAnchorRoot()((bytes32,uint256))")"
  PRE_RETIREMENT="$(call_word "$ASR" "retirementTimestamp()(uint64)")"
  PRE_PORTAL_BALANCE="$(cast balance "$PORTAL" --rpc-url "$RPC")"
  local type got want
  for type in 0 1 8 5 9 10; do
    got="$(call_word "$DGF" "initBonds(uint32)(uint256)" "$type")"
    case "$type" in
      1) want=$U21_BOND_TYPE1_WEI;;
      8) want=$U21_BOND_TYPE8_WEI;;
      9) want=$U21_BOND_TYPE9_WEI;;
      *) want=0;;
    esac
    check_eq "pre.initBonds($type)" "$got" "$want"
  done
  check_eq "pre.type9.prestate" "$(prestate_of 9)" "$U21_TYPE9_PRESTATE"
  check_eq "pre.respectedGameType" "$(call_word "$ASR" "respectedGameType()(uint32)")" 9
  [[ "$ASSERT_FAIL" == 0 ]] || { echo "ERROR: pre-state mismatch" >&2; exit 1; }
}

assert_preserved_state() {
  local lockbox weth messenger addr label enough
  lockbox="$(call_word "$PORTAL" "ethLockbox()(address)")"
  require_eth_address "ETHLockbox" "$lockbox"
  [[ "$(lc "$lockbox")" != 0x0000000000000000000000000000000000000000 ]] || { echo "ERROR: zero lockbox" >&2; exit 1; }
  check_eq "ASR.ethLockbox" "$(call_word "$ASR" "ethLockbox()(address)")" "$lockbox"
  check_eq "ETHLockbox.version" "$(call_str "$lockbox" "version()(string)")" 2.0.0
  enough="$(python3 -c "print(int('$(cast balance "$lockbox" --rpc-url "$RPC")') >= int('$PRE_PORTAL_BALANCE'))")"
  check_eq "lockbox.balance>=pre.portal.balance($PRE_PORTAL_BALANCE)" "$enough" True
  check_eq "portal.balance" "$(cast balance "$PORTAL" --rpc-url "$RPC")" 0
  check_eq "anchorGame.preserved" "$(call_word "$ASR" "anchorGame()(address)")" "$PRE_ANCHOR_GAME"
  check_eq "getAnchorRoot.preserved" "$(call_raw "$ASR" "getAnchorRoot()(bytes32,uint256)")" "$PRE_ANCHOR_ROOT"
  check_eq "getStartingAnchorRoot.preserved" "$(call_raw "$ASR" "getStartingAnchorRoot()((bytes32,uint256))")" "$PRE_START_ROOT"
  check_eq "retirementTimestamp.preserved" "$(call_word "$ASR" "retirementTimestamp()(uint64)")" "$PRE_RETIREMENT"
  weth="$(call_word "$SYSTEM_CONFIG" "delayedWETH()(address)")"
  messenger="$(call_word "$SYSTEM_CONFIG" "l1CrossDomainMessenger()(address)")"
  check_eq "DelayedWETH.version" "$(call_str "$weth" "version()(string)")" 2.0.0
  check_eq "DelayedWETH.delay.preserved" "$(call_word "$weth" "delay()(uint256)")" "$WETH_DELAY"
  check_eq "L1CrossDomainMessenger.version" "$(call_str "$messenger" "version()(string)")" 2.13.0
  for addr in "$SYSTEM_CONFIG" "$SUPERCHAIN" "$PORTAL" "$ASR" "$DGF" "$weth" "$lockbox"; do
    check_eq "$addr.proxyAdminOwner" "$(call_word "$addr" "proxyAdminOwner()(address)")" "$ADMIN_ADDRESS"
  done
}

run_standard_validator() {
  local validator pre1
  pre1="$(prestate_of 1)"
  validator="$(call_word "$OPCM" "opcmStandardValidator()(address)")"
  require_eth_address "StandardValidator" "$validator"
  echo "StandardValidator address=$validator (our OPCM $OPCM)"
  call_raw "$validator" "validate((address,bytes32,bytes32,uint256,address),bool)(string)" \
    "($SYSTEM_CONFIG,$pre1,$U21_TYPE9_PRESTATE,852,$PROPOSER_ADDRESS)" true
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
  check_eq "pre.proofMaturity" "$maturity" "$U21_PROOF_MATURITY"
  check_eq "pre.finality" "$finality" "$U21_FINALITY_DELAY"
  check_eq "pre.maxClock" "$clock" "$U21_MAX_CLOCK"
  check_eq "pre.clockExt" "$ext" "$U21_CLOCK_EXT"
  check_eq "pre.maxDepth" "$depth" "$U21_MAX_DEPTH"
  check_eq "pre.splitDepth" "$split" "$U21_SPLIT_DEPTH"
  check_eq "pre.initBonds(1)" "$bond1" "$U21_BOND_TYPE1_WEI"
  check_eq "pre.gameArgs8.prestate" "$(prestate_of 8)" "$U21_TYPE8_PRESTATE"
  if [[ "$ASSERT_FAIL" -ne 0 ]]; then
    echo "ERROR: live delays do not match the pinned U21 values; refusing" >&2
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
    --proof-maturity-delay-seconds "$U21_PROOF_MATURITY" \
    --dispute-game-finality-delay-seconds "$U21_FINALITY_DELAY" \
    --dispute-max-game-depth "$U21_MAX_DEPTH" \
    --dispute-split-depth "$U21_SPLIT_DEPTH" \
    --dispute-clock-extension "$U21_CLOCK_EXT" \
    --dispute-max-clock-duration "$U21_MAX_CLOCK" \
    --superchain-config-proxy "$SUPERCHAIN" \
    --l1-proxy-admin-owner "$ADMIN_ADDRESS" \
    --superchain-proxy-admin "$spa" \
    --challenger "$CHALLENGER_ADDRESS" \
    --no-verify \
    --outfile "$IMPL_JSON"
  end="$(cast block-number --rpc-url "$RPC")"
  echo "phase: bootstrap blocks $start..$end (included by nonce receipt scan)"
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
  check_eq "new.portal.proofMaturity" "$(call_word "$portal_impl" "proofMaturityDelaySeconds()(uint256)")" "$U21_PROOF_MATURITY"
  check_eq "new.asr.finality" "$(call_word "$asr_impl" "disputeGameFinalityDelaySeconds()(uint256)")" "$U21_FINALITY_DELAY"
  check_eq "new.weth.delay" "$(call_word "$weth_impl" "delay()(uint256)")" "$WETH_DELAY"
  check_eq "new.oracle.challengePeriod" "$(call_word "$oracle" "challengePeriod()(uint256)")" "$CHALLENGE_PERIOD"
  check_eq "new.fault.maxClock" "$(call_word "$fault_impl" "maxClockDuration()(uint64)")" "$U21_MAX_CLOCK"
  check_eq "new.super.maxClock" "$(call_word "$super_impl" "maxClockDuration()(uint64)")" "$U21_MAX_CLOCK"
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

assert_pristine_u20() {
  check_eq "pre.SystemConfig.version" "$(call_str "$SYSTEM_CONFIG" "version()(string)")" "4.0.0"
  check_eq "pre.SuperchainConfig.version" "$(call_str "$SUPERCHAIN" "version()(string)")" "2.4.3"
  check_eq "pre.Portal.version" "$(call_str "$PORTAL" "version()(string)")" "5.8.0"
  check_eq "pre.ADMIN.code" "$(cast code "$ADMIN_ADDRESS" --rpc-url "$RPC")" "0x"
  [[ "$ASSERT_FAIL" == 0 ]] || { echo "ERROR: expected pristine U20 state; refusing (use --revoke-only for delegation recovery)" >&2; exit 1; }
}

run_upgrade() {
  local cid pre1 prop chal map inner super_inner respected
  cid="$(cast chain-id --rpc-url "$RPC")"
  if [[ "$SIGN_MODE" == "fork" ]]; then
    if [[ "$cid" == "11155111" ]]; then
      echo "ERROR: --fork refuses chain id 11155111; refusing to sign with ADMIN_PRIVATE_KEY" >&2
      exit 1
    fi
    if [[ "$cid" != "$U21_FORK_CHAIN_ID" ]]; then
      echo "ERROR: --fork chain id is $cid, want $U21_FORK_CHAIN_ID" >&2
      exit 1
    fi
  elif [[ "$cid" != "11155111" ]]; then
    echo "ERROR: --live chain id is $cid, want Sepolia 11155111" >&2
    exit 1
  fi
  if [[ "$SIGN_MODE" == "fork" ]]; then
    assert_loopback_url "$RPC" "--fork"
  fi
  START_NONCE="$(cast nonce "$ADMIN_ADDRESS" --rpc-url "$RPC")"
  START_BLOCK="$(cast block-number --rpc-url "$RPC")"
  if [[ "$REVOKE_ONLY" == 1 ]]; then
    run_revoke_only
    return
  fi
  assert_pristine_u20
  capture_pre_state
  read_preserved_delays
  print_state
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
  DELEGATED=1
  trap on_upgrade_err ERR
  auth_flag_send "eip7702-delegate" "$EXECUTOR" "$PROPOSER_ADDRESS" --value 0 || on_upgrade_err
  local admin_code
  admin_code="$(cast code "$ADMIN_ADDRESS" --rpc-url "$RPC")"
  if [[ "$admin_code" == "0x" ]]; then
    echo "ERROR: EIP-7702 delegation did not install code on ADMIN" >&2
    exit 1
  fi
  echo "state admin delegated codeBytes=$(((${#admin_code} - 2) / 2))"
  if [[ "${OPU_U21_REHEARSE_FAULTS:-}" == "1" ]]; then
    echo "phase: fault rehearsal"
    local bad_pre bad_bond
    bad_pre="$(build_upgrade_calldata "0x0000000000000000000000000000000000000000000000000000000000000000" "$U21_BOND_TYPE5_WEI" "$pre1" "$prop" "$chal")"
    expect_revert_invalid "bad-type9-prestate" "$bad_pre"
    bad_bond="$(build_upgrade_calldata "$U21_TYPE9_PRESTATE" 1 "$pre1" "$prop" "$chal")"
    expect_revert_invalid "bad-type5-bond" "$bad_bond"
  fi
  super_inner="$(cast calldata "upgradeSuperchain((address,(string,bytes)[]))" "($SUPERCHAIN,[])")"
  echo "phase: upgradeSuperchain"
  send_from_admin "upgradeSuperchain" "$ADMIN_ADDRESS" "$(execute_calldata "$super_inner")"
  echo "phase: upgrade"
  inner="$(build_upgrade_calldata "$U21_TYPE9_PRESTATE" "$U21_BOND_TYPE5_WEI" "$pre1" "$prop" "$chal")"
  case "$inner" in
    0x8a847e2e*) ;;
    *)
      echo "ERROR: upgrade calldata selector is not upgrade()" >&2
      exit 1
      ;;
  esac
  send_from_admin "upgrade" "$ADMIN_ADDRESS" "$(execute_calldata "$inner")"
  revoke_delegation "upgrade" || on_upgrade_err
  trap - ERR
  echo "phase: upgrade done"
  assert_post_state
  run_standard_validator
  measure_nonce_receipts
  print_gas_total
  echo "work dir: $WORK"
}


print_gas_total() {
  local eth
  eth="$(python3 -c "print(format(int('$TOTAL_WEI')/1e18, '.12f'))")"
  echo "GAS total gas=$TOTAL_GAS wei=$TOTAL_WEI eth=$eth"
}

start_dry_fork() {
  local port upstream url rc child_out
  local -a child_args
  require_bin anvil
  upstream="${OPU_U21_FORK_UPSTREAM:-https://ethereum-sepolia-rpc.publicnode.com}"
  case "$upstream" in
    http://127.0.0.1:*|http://localhost:*|https://127.0.0.1:*|https://localhost:*)
      echo "ERROR: dry-run upstream must be the Sepolia endpoint, not a loopback URL" >&2
      exit 1
      ;;
  esac
  DRY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-opu21-anvil.XXXXXX")"
  port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
  url="http://127.0.0.1:${port}"
  echo "phase: --live dry fork $url chain-id $U21_FORK_CHAIN_ID"
  # never pass --state. The temp dir is removed on every exit path.
  anvil \
    --host 127.0.0.1 \
    --fork-url "$upstream" \
    --port "$port" \
    --chain-id "$U21_FORK_CHAIN_ID" \
    --cache-path "$DRY_DIR/cache" \
    >"$DRY_DIR/anvil.log" 2>&1 &
  DRY_PID=$!
  if ! wait_for_rpc "$url" "u21-dry-fork" 180; then
    echo "ERROR: dry-run fork failed to start" >&2
    redact_log_tail "$DRY_DIR/anvil.log" >&2 || true
    exit 1
  fi
  child_args=(--fork "$url")
  if [[ "$REVOKE_ONLY" == 1 ]]; then
    child_args+=(--revoke-only)
  fi
  set +e
  child_out="$(
    FORTEL2_ENV=".env.sepolia" \
      OP_DEPLOYER_BIN="$OP_DEPLOYER_BIN" \
      OPU_U21_REHEARSE_FAULTS="${OPU_U21_REHEARSE_FAULTS:-}" \
      "$0" "${child_args[@]}" 2>&1
  )"
  rc=$?
  set -e
  printf '%s\n' "$child_out"
  cleanup_u21_temps
  if [[ "$rc" -ne 0 ]]; then
    echo "ERROR: --live dry fork failed; not sending a live transaction" >&2
    exit 1
  fi
  DRY_GAS="$(printf '%s\n' "$child_out" | sed -n 's/^GAS total gas=\([0-9][0-9]*\).*/\1/p' | tail -1)"
  if [[ -z "${DRY_GAS}" || "$DRY_GAS" == "0" ]]; then
    echo "ERROR: dry pass did not report a gas total; not sending a live transaction" >&2
    exit 1
  fi
  echo "phase: dry pass gas=$DRY_GAS"
}

start_fee_proxy() {
  local upstream="$1" cap="$2" port
  FEE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-opu21-fee.XXXXXX")"
  printf '%s\n' "$upstream" > "$FEE_DIR/upstream"
  chmod 600 "$FEE_DIR/upstream"
  port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
  cat > "$FEE_DIR/proxy.py" << 'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import Request, urlopen

upstream = open(sys.argv[1], "r", encoding="utf-8").read().strip()
port = int(sys.argv[2])
cap = int(sys.argv[3])
GWEI = 10 ** 9

def rlp_decode(b, i=0):
    if i >= len(b):
        raise ValueError("short rlp")
    p = b[i]
    if p <= 0x7F:
        return b[i:i + 1], i + 1
    if p <= 0xB7:
        n = p - 0x80
        return b[i + 1:i + 1 + n], i + 1 + n
    if p <= 0xBF:
        ln = p - 0xB7
        n = int.from_bytes(b[i + 1:i + 1 + ln], "big")
        start = i + 1 + ln
        return b[start:start + n], start + n
    if p <= 0xF7:
        n = p - 0xC0
        return decode_list(b, i + 1, i + 1 + n)
    ln = p - 0xF7
    n = int.from_bytes(b[i + 1:i + 1 + ln], "big")
    start = i + 1 + ln
    return decode_list(b, start, start + n)

def decode_list(b, start, end):
    out = []
    i = start
    while i < end:
        item, i = rlp_decode(b, i)
        out.append(item)
    if i != end:
        raise ValueError("list overrun")
    return out, end

def max_fee(raw_hex):
    h = raw_hex[2:] if raw_hex.startswith("0x") else raw_hex
    buf = bytes.fromhex(h)
    if not buf or buf[0] not in (2, 4):
        raise ValueError("unsupported tx type")
    items, _ = rlp_decode(buf[1:], 0)
    if not isinstance(items, list) or len(items) < 4 or isinstance(items[3], list):
        raise ValueError("short typed tx")
    fee_b = items[3]
    return int.from_bytes(fee_b, "big") if fee_b else 0

def estimator_fee(base):
    padded_base = base + base // 2
    base_for = padded_base if padded_base > GWEI else GWEI
    return GWEI + 2 * base_for

def clamp_base(cap_wei):
    lo, hi, best = 0, cap_wei, 0
    while lo <= hi:
        mid = (lo + hi) // 2
        padded = mid + mid // 2
        base_for = padded if padded > GWEI else GWEI
        fee = GWEI + 2 * base_for
        if fee <= cap_wei:
            best = mid
            lo = mid + 1
        else:
            hi = mid - 1
    return best

def forward(payload):
    req = Request(upstream, data=json.dumps(payload).encode(), headers={"content-type": "application/json"})
    try:
        with urlopen(req, timeout=120) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return {"jsonrpc": "2.0", "id": payload.get("id") if isinstance(payload, dict) else None,
                "error": {"code": -32000, "message": "upstream request failed"}}

def handle(msg):
    method = msg.get("method")
    if method == "eth_sendRawTransaction":
        try:
            fee = max_fee(msg["params"][0])
        except Exception as exc:
            return {"jsonrpc": "2.0", "id": msg.get("id"), "error": {"code": -32000, "message": "refusing raw tx: %s" % exc}}
        if fee > cap:
            return {"jsonrpc": "2.0", "id": msg.get("id"), "error": {"code": -32000, "message": "maxFeePerGas exceeds cap"}}
        return forward(msg)
    if method == "eth_maxPriorityFeePerGas":
        return {"jsonrpc": "2.0", "id": msg.get("id"), "result": "0x1"}
    if method == "eth_getBlockByNumber":
        resp = forward(msg)
        params = msg.get("params") or []
        tag = params[0] if params else None
        result = resp.get("result") if isinstance(resp, dict) else None
        if tag in ("latest", "pending") and isinstance(result, dict) and result.get("baseFeePerGas"):
            real = int(result["baseFeePerGas"], 16)
            if estimator_fee(real) > cap:
                result["baseFeePerGas"] = hex(clamp_base(cap))
                resp["result"] = result
        return resp
    return forward(msg)

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("content-length", "0"))
        try:
            payload = json.loads(self.rfile.read(n).decode())
        except Exception:
            self.send_error(400)
            return
        out = [handle(x) for x in payload] if isinstance(payload, list) else handle(payload)
        raw = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, fmt, *args):
        return

ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PY
  python3 "$FEE_DIR/proxy.py" "$FEE_DIR/upstream" "$port" "$cap" >"$FEE_DIR/proxy.log" 2>&1 &
  FEE_PID=$!
  FEE_URL="http://127.0.0.1:${port}"
  if ! wait_for_rpc "$FEE_URL" "u21-fee-proxy" 30; then
    echo "ERROR: fee proxy failed to start" >&2
    redact_log_tail "$FEE_DIR/proxy.log" >&2 || true
    exit 1
  fi
  echo "phase: live fee proxy $FEE_URL cap=$cap"
}

if [[ "$MODE" == "live" ]]; then
  start_dry_fork
  RPC="${L1_RPC_URL:-}"
  assert_remote_l1_rpc_url "$RPC" "L1_RPC_URL"
  base_fee="$(cast base-fee --rpc-url "$RPC")"
  if [[ "$(python3 -c "print('yes' if int('$U21_LIVE_MAX_FEE_PER_GAS') < int('$base_fee') else 'no')")" == "yes" ]]; then
    echo "ERROR: U21_LIVE_MAX_FEE_PER_GAS is below the current L1 base fee; a capped transaction cannot be included" >&2
    exit 1
  fi
  admin_bal="$(cast balance "$ADMIN_ADDRESS" --rpc-url "$RPC")"
  assert_live_funding "$DRY_GAS" "$U21_LIVE_MAX_FEE_PER_GAS" "$admin_bal"
  start_fee_proxy "$RPC" "$U21_LIVE_MAX_FEE_PER_GAS"
  # "live", not a third mode: the three cast send sites attach the fee cap
  # only when SIGN_MODE is live. A different value would broadcast uncapped.
  SIGN_MODE=live
  RPC="$FEE_URL"
  echo "phase: live upgrade against L1"
  run_upgrade
else
  SIGN_MODE=fork
  RPC="$FORK_RPC"
  assert_loopback_url "$RPC" "--fork"
  wait_for_rpc "$RPC" "u21-fork" 30
  run_upgrade
fi
