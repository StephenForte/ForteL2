#!/usr/bin/env bash
# US-073: native op-challenger against Sepolia DisputeGameFactory.
# Isolated — never started by start-all-sepolia.sh / launchd. Operator-only, post-wipe.
# Signs with CHALLENGER_PRIVATE_KEY (the factory challenger role), never PROPOSER_PRIVATE_KEY.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

usage() {
  echo "usage: 09-start-challenger-sepolia.sh"
  echo "  Isolated US-073 start. Signs with CHALLENGER_PRIVATE_KEY, never PROPOSER_PRIVATE_KEY."
  echo "  Requires FORTEL2_ENV=.env.sepolia, L1_BEACON_URL, CHALLENGER_TRACE_TYPE, and a Cannon-family prestate."
  echo "  No extra flags are accepted (guarded RPC/key/factory values cannot be overridden)."
}

VALID_TRACE_TYPES="alphabet, cannon, cannon-kona, permissioned, fast, super-cannon-kona, zk"
VALID_L1_RPC_KINDS="alchemy, quicknode, infura, parity, nethermind, debug_geth, erigon, basic, any, standard"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unsupported argument: $1" >&2
      echo "  This wrapper accepts no flags other than -h/--help." >&2
      echo "  Guarded values (RPCs, factory, private key, datadir) cannot be overridden on argv." >&2
      usage >&2
      exit 2
      ;;
  esac
done

# Resolve a path against the caller's cwd, then to an absolute path.
# start_bg's daemonizer runs os.chdir("/") before execvp (scripts/lib.sh), so a
# relative path that exists here would be looked up under / inside the daemon.
canonical_abs_path() {
  python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$1"
}

is_zero_hex() {
  local h
  h="$(printf '%s' "${1:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  [[ -z "$h" || "$h" =~ ^0x0+$ ]]
}

needs_cannon_bin() {
  case "$1" in
    cannon|permissioned|cannon-kona|super-cannon-kona) return 0 ;;
    *) return 1 ;;
  esac
}

# Cannon VM prestates (--cannon-prestate / --cannon-prestates-url).
needs_cannon_prestate() {
  case "$1" in
    cannon|permissioned) return 0 ;;
    *) return 1 ;;
  esac
}

# Kona prestates (--cannon-kona-prestate / --cannon-kona-prestates-url).
needs_kona_prestate() {
  case "$1" in
    cannon-kona|super-cannon-kona) return 0 ;;
    *) return 1 ;;
  esac
}

needs_any_prestate() {
  needs_cannon_prestate "$1" || needs_kona_prestate "$1"
}

# CheckCannonFlags (cannon + permissioned) wants --cannon-rollup-config + --cannon-l2-genesis.
needs_cannon_rollup_genesis() {
  case "$1" in
    cannon|permissioned) return 0 ;;
    *) return 1 ;;
  esac
}

# CheckCannonKonaFlags wants --cannon-kona-rollup-config + --cannon-kona-l2-genesis.
needs_kona_rollup_genesis() {
  case "$1" in
    cannon-kona) return 0 ;;
    *) return 1 ;;
  esac
}

# CheckCannonFlags (cannon only — not permissioned) requires --cannon-server.
needs_cannon_server() {
  case "$1" in
    cannon) return 0 ;;
    *) return 1 ;;
  esac
}

# CheckCannonKonaFlags requires --cannon-kona-server. super-cannon-kona is
# refused outright (supernode + depset); do not extend this to it (D-0054).
needs_kona_server() {
  case "$1" in
    cannon-kona) return 0 ;;
    *) return 1 ;;
  esac
}

# gameImpls(uint32) mapping we will look up. Anything else is skipped, not guessed.
# cannon-kona=8 is on-chain fact post step 8b (D-0077). Local optimism tree also
# has super-cannon-kona=9, fast=254, alphabet=255, zk=10 — not applied here.
game_impls_type_number() {
  case "$1" in
    cannon) echo 0 ;;
    permissioned) echo 1 ;;
    cannon-kona) echo 8 ;;
    *) echo "" ;;
  esac
}

require_bin op-challenger
require_bin jq
require_bin cast
require_sepolia_env
CHALLENGER_L1_RPC_URL="${CHALLENGER_L1_RPC_URL:-$L1_RPC_URL}"
refuse_foundry_defaults_unless_local_l2 "${CHALLENGER_PRIVATE_KEY:-}" "CHALLENGER_PRIVATE_KEY"

if [[ -z "${CHALLENGER_PRIVATE_KEY:-}" ]]; then
  echo "ERROR: CHALLENGER_PRIVATE_KEY is required (challenger role — not PROPOSER_PRIVATE_KEY)" >&2
  exit 1
fi

require_eth_address "CHALLENGER_ADDRESS" "${CHALLENGER_ADDRESS:-}"

# This is the one place the key touches argv, for a single short-lived `cast`
# process. `cast wallet address` has no env-var form (ETH_PRIVATE_KEY is not
# accepted). That bounded exposure is deliberately accepted to close a
# silent-wrong-signer failure; the long-running daemon still gets the key via
# OP_CHALLENGER_PRIVATE_KEY, never argv.
derived="$(cast wallet address --private-key "$CHALLENGER_PRIVATE_KEY")"
derived_lc="$(printf '%s' "$derived" | tr '[:upper:]' '[:lower:]')"
configured_lc="$(printf '%s' "$CHALLENGER_ADDRESS" | tr '[:upper:]' '[:lower:]')"
if [[ "$derived_lc" != "$configured_lc" ]]; then
  echo "ERROR: CHALLENGER_PRIVATE_KEY does not match CHALLENGER_ADDRESS" >&2
  echo "  derived:    $derived" >&2
  echo "  configured: $CHALLENGER_ADDRESS" >&2
  echo "  This script signs as the challenger role, never PROPOSER_PRIVATE_KEY." >&2
  exit 1
fi

TRACE_TYPE="${CHALLENGER_TRACE_TYPE:-}"
if [[ -z "$TRACE_TYPE" ]]; then
  echo "ERROR: CHALLENGER_TRACE_TYPE is required (no default — set it from the post-wipe factory)" >&2
  echo "  Valid options: $VALID_TRACE_TYPES" >&2
  echo "  See README.md § Phase 7 challenger (US-073)." >&2
  exit 1
fi
case "$TRACE_TYPE" in
  alphabet|cannon|cannon-kona|permissioned|fast|super-cannon-kona|zk) ;;
  *)
    echo "ERROR: unknown CHALLENGER_TRACE_TYPE=$TRACE_TYPE" >&2
    echo "  Valid options: $VALID_TRACE_TYPES" >&2
    exit 1
    ;;
esac

# CheckSuperCannonKonaFlags also requires --supernode-rpc and --cannon-kona-depset-config.
# ForteL2 has neither; do not guess a mapping (D-0053 / F7-2b).
if [[ "$TRACE_TYPE" == "super-cannon-kona" ]]; then
  echo "ERROR: CHALLENGER_TRACE_TYPE=super-cannon-kona is not supported by this wrapper" >&2
  echo "  This build's CheckSuperCannonKonaFlags requires --supernode-rpc and --cannon-kona-depset-config." >&2
  echo "  ForteL2 has no supernode and no interop depset to map; refusing to guess." >&2
  echo "  Set CHALLENGER_TRACE_TYPE from the post-wipe factory to a type this script can start." >&2
  exit 1
fi

# CheckCannonFlags / CheckCannonKonaFlags require a pre-image oracle server.
# start_bg returns 0 whether the daemon survives, so an unset server would
# print "started" and die on CheckRequired (D-0054). Gate here, before any RPC wait.
CANNON_SERVER=""
KONA_SERVER=""
if needs_cannon_server "$TRACE_TYPE"; then
  if [[ -z "${CHALLENGER_CANNON_SERVER:-}" ]]; then
    echo "ERROR: CHALLENGER_TRACE_TYPE=cannon is not startable without --cannon-server" >&2
    echo "  This build's CheckCannonFlags requires --cannon-server (set CHALLENGER_CANNON_SERVER)." >&2
    echo "  No pre-image server binary exists on this host today (D-0052 / D-0054); refusing to start a daemon that would die on CheckRequired." >&2
    echo "  Set CHALLENGER_TRACE_TYPE from the post-wipe factory to a type this script can start, or supply CHALLENGER_CANNON_SERVER." >&2
    exit 1
  fi
  CANNON_SERVER="$(canonical_abs_path "$CHALLENGER_CANNON_SERVER")"
  if [[ ! -f "$CANNON_SERVER" || ! -x "$CANNON_SERVER" ]]; then
    echo "ERROR: CHALLENGER_CANNON_SERVER is missing or not executable (resolved): $CANNON_SERVER" >&2
    exit 1
  fi
elif needs_kona_server "$TRACE_TYPE"; then
  if [[ -z "${CHALLENGER_KONA_SERVER:-}" ]]; then
    echo "ERROR: CHALLENGER_TRACE_TYPE=cannon-kona is not startable without --cannon-kona-server" >&2
    echo "  This build's CheckCannonKonaFlags requires --cannon-kona-server (set CHALLENGER_KONA_SERVER)." >&2
    echo "  No pre-image server binary exists on this host today (D-0052 / D-0054); refusing to start a daemon that would die on CheckRequired." >&2
    echo "  Set CHALLENGER_TRACE_TYPE from the post-wipe factory to a type this script can start, or supply CHALLENGER_KONA_SERVER." >&2
    exit 1
  fi
  KONA_SERVER="$(canonical_abs_path "$CHALLENGER_KONA_SERVER")"
  if [[ ! -f "$KONA_SERVER" || ! -x "$KONA_SERVER" ]]; then
    echo "ERROR: CHALLENGER_KONA_SERVER is missing or not executable (resolved): $KONA_SERVER" >&2
    exit 1
  fi
fi

L1_RPC_KIND="${SEPOLIA_L1_RPC_KIND:-standard}"
case "$L1_RPC_KIND" in
  alchemy|quicknode|infura|parity|nethermind|debug_geth|erigon|basic|any|standard) ;;
  *)
    echo "ERROR: SEPOLIA_L1_RPC_KIND=$L1_RPC_KIND is not valid" >&2
    echo "  Valid options: $VALID_L1_RPC_KINDS" >&2
    exit 1
    ;;
esac

NUM_CONFS="${SEPOLIA_CHALLENGER_CONFIRMATIONS:-3}"
if ! [[ "$NUM_CONFS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: SEPOLIA_CHALLENGER_CONFIRMATIONS must be an integer (got $NUM_CONFS)" >&2
  exit 1
fi
LOG_LEVEL="${CHALLENGER_LOG_LEVEL:-info}"

# Always required by this binary's CheckRequired (requiredFlags includes l1-beacon).
# Passing --l1-beacon is NOT a DA change: op-node still uses --l1.beacon.ignore (D-0037 / D-0053).
if [[ -z "${L1_BEACON_URL:-}" ]]; then
  echo "ERROR: L1_BEACON_URL is required (this binary's CheckRequired gate — not a DA change; see D-0037 / D-0053)" >&2
  echo "  Set it in .env.sepolia (QuickNode beacon endpoint). op-node still uses --l1.beacon.ignore." >&2
  exit 1
fi

PRESTATE_PATH="${CHALLENGER_PRESTATE:-}"
PRESTATES_URL="${CHALLENGER_PRESTATES_URL:-}"

if needs_any_prestate "$TRACE_TYPE"; then
  if [[ -z "$PRESTATE_PATH" && -z "$PRESTATES_URL" ]]; then
    echo "ERROR: Cannon-family CHALLENGER_TRACE_TYPE=$TRACE_TYPE needs a prestate" >&2
    echo "  Set CHALLENGER_PRESTATE (local file) and/or CHALLENGER_PRESTATES_URL (base URL)." >&2
    echo "  See README.md § Phase 7 challenger (US-073)." >&2
    exit 1
  fi
fi

if [[ -n "$PRESTATE_PATH" ]]; then
  if ! needs_cannon_prestate "$TRACE_TYPE" && ! needs_kona_prestate "$TRACE_TYPE"; then
    echo "ERROR: CHALLENGER_PRESTATE is set but CHALLENGER_TRACE_TYPE=$TRACE_TYPE has no local prestate flag" >&2
    echo "  Use CHALLENGER_PRESTATES_URL, or pick a Cannon-family type (cannon, permissioned, cannon-kona, super-cannon-kona)." >&2
    exit 1
  fi
  PRESTATE_PATH="$(canonical_abs_path "$PRESTATE_PATH")"
  if [[ ! -f "$PRESTATE_PATH" || ! -r "$PRESTATE_PATH" ]]; then
    echo "ERROR: CHALLENGER_PRESTATE is missing or not readable (resolved): $PRESTATE_PATH" >&2
    exit 1
  fi
  echo "Using absolute prestate path: $PRESTATE_PATH"
fi

if needs_cannon_bin "$TRACE_TYPE"; then
  require_bin cannon
  CANNON_BIN="$(canonical_abs_path "$BIN_DIR/cannon")"
  if [[ ! -x "$CANNON_BIN" ]]; then
    echo "ERROR: cannon binary not executable at $CANNON_BIN" >&2
    exit 1
  fi
fi

# CheckCannonFlags / CheckCannonKonaFlags: custom chain 852 cannot use --network.
# start_bg's daemonizer chdirs to /, so these must be absolute.
CANNON_ROLLUP=""
CANNON_GENESIS=""
if needs_cannon_rollup_genesis "$TRACE_TYPE" || needs_kona_rollup_genesis "$TRACE_TYPE"; then
  CANNON_ROLLUP="$(canonical_abs_path "$DEPLOY_DIR/rollup.json")"
  CANNON_GENESIS="$(canonical_abs_path "$DEPLOY_DIR/genesis.json")"
  if [[ ! -f "$CANNON_ROLLUP" ]]; then
    echo "ERROR: missing Cannon rollup config (resolved): $CANNON_ROLLUP" >&2
    echo "  Expected \$DEPLOY_DIR/rollup.json from the Sepolia deploy tree." >&2
    exit 1
  fi
  if [[ ! -f "$CANNON_GENESIS" ]]; then
    echo "ERROR: missing Cannon L2 genesis (resolved): $CANNON_GENESIS" >&2
    echo "  Expected \$DEPLOY_DIR/genesis.json from the Sepolia deploy tree." >&2
    exit 1
  fi
fi

DEPLOYMENTS="$(deployments_json_path)"
GAME_FACTORY=$(jq -r '.DisputeGameFactoryProxy // .disputeGameFactoryProxy // empty' "$DEPLOYMENTS")
if [[ -z "$GAME_FACTORY" || "$GAME_FACTORY" == "null" ]]; then
  echo "ERROR: DisputeGameFactoryProxy not found in $DEPLOYMENTS" >&2
  jq 'keys' "$DEPLOYMENTS" || true
  exit 1
fi

CHALLENGER_DATADIR="$(canonical_abs_path "$DATA_DIR/challenger")"
mkdir -p "$CHALLENGER_DATADIR"

wait_for_rpc "$CHALLENGER_L1_RPC_URL" "L1 Sepolia"
wait_for_opnode_rpc "$L2_NODE_RPC_URL" "op-node"
wait_for_rpc "$L2_RPC_URL" "L2"

require_min_balance_eth "$CHALLENGER_ADDRESS" "${SEPOLIA_CHALLENGER_MIN_ETH:-0.15}" "CHALLENGER"

run_preflight() {
  local type_num impl vm_addr prestate args args_hex preflight_source
  type_num="$(game_impls_type_number "$TRACE_TYPE")"
  if [[ -z "$type_num" ]]; then
    echo "Preflight: no confident gameImpls(uint32) mapping for CHALLENGER_TRACE_TYPE=$TRACE_TYPE (mapped: cannon=0, permissioned=1, cannon-kona=8); skipping factory lookup."
    return 0
  fi
  echo "Preflight: DisputeGameFactory.gameImpls($type_num) for CHALLENGER_TRACE_TYPE=$TRACE_TYPE"
  impl="$(cast call "$GAME_FACTORY" "gameImpls(uint32)(address)" "$type_num" --rpc-url "$CHALLENGER_L1_RPC_URL")"
  impl="$(printf '%s' "$impl" | tr -d '[:space:]')"
  if is_zero_hex "$impl"; then
    echo "ERROR: factory $GAME_FACTORY has no implementation registered for game type $type_num ($TRACE_TYPE)" >&2
    echo "  gameImpls($type_num) returned the zero address. op-challenger has nothing to play." >&2
    echo "  Re-read the post-wipe factory before retrying (D-0055)." >&2
    exit 1
  fi
  echo "Preflight: game impl $impl"

  # gameArgs is the CWIA implArgs tail. FaultDisputeGame reads
  # absolutePrestate at clone offset 120 and vm at 152; create() writes a
  # 120-byte header (creator‖rootClaim‖parentHash‖gameType‖extraData) ahead
  # of implArgs, so the tail offsets are [0,32) and [32,52). Bound-check
  # (≥52 bytes); do not length-match — permissioned args are 164 bytes, a
  # non-permissioned game's args are shorter (D-0055).
  # Under set -e, a bare assignment aborts on a reverted call before we can
  # name the failure. `if ! args="$(…)"` captures status without swallowing a
  # successful empty (`0x`) result, which is legitimate data and must still
  # reach the impl-getter fallback. A failed call is not an empty result —
  # predating-gameArgs and RPC failure are indistinguishable here, so refuse
  # rather than guess (D-0055).
  if ! args="$(cast call "$GAME_FACTORY" "gameArgs(uint32)(bytes)" "$type_num" --rpc-url "$CHALLENGER_L1_RPC_URL")"; then
    echo "ERROR: factory $GAME_FACTORY gameArgs($type_num) call failed" >&2
    echo "  Either this factory predates the gameArgs function, or the RPC call failed." >&2
    echo "  Those two cannot be distinguished from here; refusing rather than guessing (D-0055)." >&2
    echo "  Bypass only if you mean it: CHALLENGER_SKIP_PREFLIGHT=1" >&2
    exit 1
  fi
  args="$(printf '%s' "$args" | tr -d '[:space:]"')"
  args_hex="${args#0x}"
  args_hex="${args_hex#0X}"

  if [[ -n "$args_hex" ]]; then
    if (( ${#args_hex} % 2 != 0 )) || (( ${#args_hex} < 104 )); then
      echo "ERROR: factory $GAME_FACTORY gameArgs($type_num) is too short to contain absolutePrestate + vm" >&2
      echo "  got ${#args_hex} hex chars (need ≥104 for 32-byte prestate + 20-byte vm)." >&2
      echo "  A truncated blob is not a pass (D-0055). Do not spend gas on a game the challenger cannot step." >&2
      echo "  Bypass only if you mean it: CHALLENGER_SKIP_PREFLIGHT=1" >&2
      exit 1
    fi
    preflight_source="gameArgs($type_num)"
    prestate="0x${args_hex:0:64}"
    vm_addr="0x${args_hex:64:40}"
    echo "Preflight: decoded $preflight_source (CWIA implArgs tail; D-0055)"
  else
    preflight_source="implementation getters"
    echo "Preflight: gameArgs($type_num) empty — falling back to implementation vm()/absolutePrestate() (older immutable layout; D-0055)"
    vm_addr="$(cast call "$impl" "vm()(address)" --rpc-url "$CHALLENGER_L1_RPC_URL")"
    prestate="$(cast call "$impl" "absolutePrestate()(bytes32)" --rpc-url "$CHALLENGER_L1_RPC_URL")"
    vm_addr="$(printf '%s' "$vm_addr" | tr -d '[:space:]')"
    prestate="$(printf '%s' "$prestate" | tr -d '[:space:]')"
  fi

  if is_zero_hex "$vm_addr"; then
    echo "ERROR: deployed game has no VM — op-challenger cannot play a Cannon-family game against it" >&2
    echo "  impl:   $impl" >&2
    echo "  source: $preflight_source" >&2
    echo "  vm:     $vm_addr" >&2
    if [[ "$preflight_source" == "implementation getters" ]]; then
      echo "  gameArgs empty and implementation vm() is zero (D-0055). Do not spend gas on a game the challenger cannot step." >&2
    else
      echo "  Decoded vm from gameArgs is zero (D-0055). Do not spend gas on a game the challenger cannot step." >&2
    fi
    echo "  Bypass only if you mean it: CHALLENGER_SKIP_PREFLIGHT=1" >&2
    exit 1
  fi
  if is_zero_hex "$prestate"; then
    echo "ERROR: deployed game has no absolute prestate — op-challenger cannot play a Cannon-family game against it" >&2
    echo "  impl:             $impl" >&2
    echo "  source:           $preflight_source" >&2
    echo "  absolutePrestate: $prestate" >&2
    if [[ "$preflight_source" == "implementation getters" ]]; then
      echo "  gameArgs empty and implementation absolutePrestate() is zero (D-0055). Do not spend gas on a game the challenger cannot step." >&2
    else
      echo "  Decoded absolutePrestate from gameArgs is zero (D-0055). Do not spend gas on a game the challenger cannot step." >&2
    fi
    echo "  Bypass only if you mean it: CHALLENGER_SKIP_PREFLIGHT=1" >&2
    exit 1
  fi
  echo "Preflight: source=$preflight_source vm=$vm_addr absolutePrestate=$prestate"

  if [[ -n "${PRESTATE_PATH:-}" ]]; then
    local witness_json local_hash chain_lc local_lc witness_rc
    witness_rc=0
    witness_json="$("$CANNON_BIN" witness --input "$PRESTATE_PATH" 2>&1)" || witness_rc=$?
    if (( witness_rc != 0 )); then
      echo "WARN: cannot compute CHALLENGER_PRESTATE witness hash (cannon witness exited $witness_rc) — proceeding without local prestate comparison (D-0057)." >&2
      echo "  path: $PRESTATE_PATH" >&2
      echo "  cannon witness accepts only stateVersion-8 binary prestates; .json and other formats op-challenger accepts may be unhashable here." >&2
    else
      local_hash="$(printf '%s' "$witness_json" | jq -r '.witnessHash // empty')"
      if [[ -z "$local_hash" ]]; then
        echo "WARN: cannot compute CHALLENGER_PRESTATE witness hash (cannon witness did not yield witnessHash) — proceeding without local prestate comparison (D-0057)." >&2
        echo "  path: $PRESTATE_PATH" >&2
      else
        chain_lc="$(printf '%s' "$prestate" | tr '[:upper:]' '[:lower:]')"
        local_lc="$(printf '%s' "$local_hash" | tr '[:upper:]' '[:lower:]')"
        if [[ "$local_lc" != "$chain_lc" ]]; then
          echo "ERROR: CHALLENGER_PRESTATE witness hash does not match on-chain absolutePrestate" >&2
          echo "  local (cannon witness):  $local_hash" >&2
          echo "  on-chain (gameArgs):     $prestate" >&2
          echo "  A challenger started with the wrong prestate disagrees with every honest root claim." >&2
          echo "  Bypass only if you mean it: CHALLENGER_SKIP_PREFLIGHT=1" >&2
          exit 1
        fi
        echo "Preflight: CHALLENGER_PRESTATE witness hash matches on-chain absolutePrestate"
      fi
    fi
  fi
}

if [[ "${CHALLENGER_SKIP_PREFLIGHT:-}" == "1" ]]; then
  echo "WARN: CHALLENGER_SKIP_PREFLIGHT=1 — skipping gameImpls/vm/absolutePrestate checks (D-0055)." >&2
else
  run_preflight
fi

# Long-running daemon gets the key via env, never --private-key (unlike
# 06-start-proposer-sepolia.sh, which puts the secret on argv / ps).
export OP_CHALLENGER_PRIVATE_KEY="$CHALLENGER_PRIVATE_KEY"

challenger_args=(
  --l1-eth-rpc="$CHALLENGER_L1_RPC_URL"
  --l1-beacon="$L1_BEACON_URL"
  --rollup-rpc="$L2_NODE_RPC_URL"
  --l2-eth-rpc="$L2_RPC_URL"
  --game-factory-address="$GAME_FACTORY"
  --game-types="$TRACE_TYPE"
  --datadir="$CHALLENGER_DATADIR"
  --l1-rpc-kind="$L1_RPC_KIND"
  --num-confirmations="$NUM_CONFS"
  --log.level="$LOG_LEVEL"
)

if needs_cannon_bin "$TRACE_TYPE"; then
  challenger_args+=(--cannon-bin="$CANNON_BIN")
fi

if needs_cannon_rollup_genesis "$TRACE_TYPE"; then
  challenger_args+=(
    --cannon-rollup-config="$CANNON_ROLLUP"
    --cannon-l2-genesis="$CANNON_GENESIS"
  )
elif needs_kona_rollup_genesis "$TRACE_TYPE"; then
  challenger_args+=(
    --cannon-kona-rollup-config="$CANNON_ROLLUP"
    --cannon-kona-l2-genesis="$CANNON_GENESIS"
  )
fi

if needs_cannon_server "$TRACE_TYPE"; then
  challenger_args+=(--cannon-server="$CANNON_SERVER")
elif needs_kona_server "$TRACE_TYPE"; then
  challenger_args+=(--cannon-kona-server="$KONA_SERVER")
fi

if [[ -n "$PRESTATE_PATH" ]]; then
  if needs_kona_prestate "$TRACE_TYPE"; then
    challenger_args+=(--cannon-kona-prestate="$PRESTATE_PATH")
  else
    challenger_args+=(--cannon-prestate="$PRESTATE_PATH")
  fi
fi
if [[ -n "$PRESTATES_URL" ]]; then
  if needs_kona_prestate "$TRACE_TYPE"; then
    challenger_args+=(--cannon-kona-prestates-url="$PRESTATES_URL")
  elif needs_cannon_prestate "$TRACE_TYPE"; then
    challenger_args+=(--cannon-prestates-url="$PRESTATES_URL")
  else
    challenger_args+=(--prestates-url="$PRESTATES_URL")
  fi
fi

# --l1-beacon satisfies CheckRequired; it does not enable blob DA (D-0037 / D-0053).
# Chain 852 is not in the superchain registry — never pass --network.

echo "Sepolia challenger starting against DisputeGameFactory=$GAME_FACTORY game-types=$TRACE_TYPE"
echo "  L1=$(redact_rpc_url "$CHALLENGER_L1_RPC_URL")  beacon=$(redact_rpc_url "$L1_BEACON_URL")  op-node=$(redact_rpc_url "$L2_NODE_RPC_URL")  L2=$(redact_rpc_url "$L2_RPC_URL")"
echo "  challenger=$CHALLENGER_ADDRESS  datadir=$CHALLENGER_DATADIR  l1-rpc-kind=$L1_RPC_KIND"
if [[ -n "$CANNON_ROLLUP" ]]; then
  echo "  rollup=$CANNON_ROLLUP  genesis=$CANNON_GENESIS"
fi
if [[ -n "$CANNON_SERVER" ]]; then
  echo "  cannon-server=$CANNON_SERVER"
fi
if [[ -n "$KONA_SERVER" ]]; then
  echo "  cannon-kona-server=$KONA_SERVER"
fi
if [[ -n "$PRESTATES_URL" ]]; then
  echo "  prestates-url=$(redact_rpc_url "$PRESTATES_URL")"
fi

start_bg op-challenger op-challenger "${challenger_args[@]}"

echo "Sepolia challenger started (pid file $PID_DIR/op-challenger.pid). Signs as CHALLENGER, never PROPOSER."
echo "Known-good: 'starting monitoring' in $LOG_DIR/op-challenger.log — it should not attack a valid game"
