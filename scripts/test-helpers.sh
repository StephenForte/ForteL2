#!/usr/bin/env bash
# Lightweight regression checks for scripts/lib.sh helpers (no chain required).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

fail=0
assert_true() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS $name"
  else
    echo "FAIL $name" >&2
    fail=1
  fi
}

assert_false() {
  local name="$1"
  shift
  if "$@"; then
    echo "FAIL $name (expected false)" >&2
    fail=1
  else
    echo "PASS $name"
  fi
}

assert_true "valid checksum-ish address" is_eth_address "0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc"
assert_true "valid lowercase address" is_eth_address "0x9965507d1a55bcc2695c58ba16fb37d819b0a4dc"
assert_false "reject short address" is_eth_address "0x9965507D1a55bcC2695C58ba16FB37d819"
assert_false "reject missing 0x" is_eth_address "9965507D1a55bcC2695C58ba16FB37d819B0A4dc"
assert_false "reject empty" is_eth_address ""

# assert_loopback_url exits on failure — probe in subshells
if (assert_loopback_url "http://127.0.0.1:9545" "t" >/dev/null); then
  echo "PASS loopback 127.0.0.1"
else
  echo "FAIL loopback 127.0.0.1" >&2
  fail=1
fi
if (assert_loopback_url "http://localhost:8080" "t" >/dev/null); then
  echo "PASS loopback localhost"
else
  echo "FAIL loopback localhost" >&2
  fail=1
fi
if (assert_loopback_url "http://192.168.1.2:8545" "t" >/dev/null 2>&1); then
  echo "FAIL should reject non-loopback" >&2
  fail=1
else
  echo "PASS reject non-loopback"
fi

# Block-time coupling
L1_BLOCK_TIME=2 L2_BLOCK_TIME=2
if (assert_block_times >/dev/null); then
  echo "PASS block times equal"
else
  echo "FAIL block times equal" >&2
  fail=1
fi
L1_BLOCK_TIME=1 L2_BLOCK_TIME=2
if (assert_block_times >/dev/null 2>&1); then
  echo "FAIL should reject L1 < L2 block time" >&2
  fail=1
else
  echo "PASS reject L1 < L2 block time"
fi

# Foundry default key detection + Phase 2 tripwire
DEMO_KEY="0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba"
assert_true "detect Foundry default key" is_foundry_default_private_key "$DEMO_KEY"
assert_false "reject random key as Foundry default" is_foundry_default_private_key \
  "0x1111111111111111111111111111111111111111111111111111111111111111"

L2_CHAIN_ID=901
if (refuse_foundry_defaults_unless_local_l2 "$DEMO_KEY" "DEMO" >/dev/null); then
  echo "PASS Foundry default allowed on chain 901"
else
  echo "FAIL Foundry default should be allowed on 901" >&2
  fail=1
fi
L2_CHAIN_ID=11155111
if (refuse_foundry_defaults_unless_local_l2 "$DEMO_KEY" "DEMO" >/dev/null 2>&1); then
  echo "FAIL should refuse Foundry default on Sepolia chain id" >&2
  fail=1
else
  echo "PASS refuse Foundry default when L2_CHAIN_ID != 901"
fi

if (( fail )); then
  echo "script helper tests FAILED" >&2
  exit 1
fi
echo "All script helper tests passed."
