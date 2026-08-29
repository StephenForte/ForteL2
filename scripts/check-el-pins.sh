#!/usr/bin/env bash
# Assert the documented op-node / op-reth pin against local binaries.
# Mini-only for a green live run (darwin/arm64 builds). CI covers the red
# path via stubs in scripts/test-helpers.sh — GitHub runners have no pin.
#
# Proven floor (P:0 sidecar 2026-08-29): op-node v1.19.2 (da197e45) + tag
# op-reth/v2.3.3, which reports "Reth Version: 2.3.0-dev" and commit
# 9384bc53d8c0c77e59cac83fdaaf3b372c6d2216. Do not grep the tag string
# "2.3.3" in --version output (it is absent). Do not grep a bare "2.3"
# (that would accept unpinned later 2.3.x builds).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

# Pin tokens as measured on the Mini. Tag op-reth/v2.3.3 ≠ reported version.
PIN_OP_NODE_VERSION='v1.19.2'
PIN_OP_NODE_COMMIT='da197e45'
PIN_RETH_VERSION='2.3.0-dev'
PIN_RETH_COMMIT='9384bc53d8c0c77e59cac83fdaaf3b372c6d2216'

FORTEL2_EL="${FORTEL2_EL:-geth}"
OP_NODE_BIN="${OP_NODE_BIN:-$BIN_DIR/op-node}"
OP_RETH_BIN="${OP_RETH_BIN:-$BIN_DIR/op-reth}"

fail_mismatch() {
  local name="$1" expected="$2" got="$3"
  echo "ERROR: $name pin mismatch" >&2
  echo "  expected: $expected" >&2
  echo "  got: $got" >&2
  exit 1
}

# Collapse --version to a single line for the "got:" message (no env dump).
oneline() {
  printf '%s' "$1" | tr '\n' ' ' | sed 's/[[:space:]]\{1,\}/ /g' | sed 's/[[:space:]]*$//'
}

require_executable() {
  local label="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    fail_mismatch "$label" "executable at $path" "missing"
  fi
  if [[ ! -x "$path" ]]; then
    fail_mismatch "$label" "executable at $path" "not executable"
  fi
}

version_of() {
  local path="$1"
  # Some wrappers accept `node --version`; pin is `--version` as measured.
  "$path" --version 2>&1 || true
}

looks_like_geth() {
  local out="$1" path="$2"
  local base
  base="$(basename "$path")"
  if [[ "$base" == *geth* ]]; then
    return 0
  fi
  if echo "$out" | grep -qiE 'op-geth|[[:space:]]geth[[:space:]]|geth version' \
    && ! echo "$out" | grep -q 'Reth Version'; then
    return 0
  fi
  return 1
}

assert_macho_arm64_if_macho() {
  local label="$1" path="$2"
  command -v file >/dev/null 2>&1 || return 0
  local ft
  # -L: follow BIN_DIR symlinks. GNU file otherwise reports the link and
  # skips the Mach-O arm64 check (macOS file follows by default).
  ft="$(file -L "$path" 2>/dev/null || true)"
  if echo "$ft" | grep -q 'Mach-O'; then
    if ! echo "$ft" | grep -q 'arm64'; then
      fail_mismatch "$label architecture" "Mach-O arm64" "$(oneline "$ft")"
    fi
  fi
}

case "$FORTEL2_EL" in
  geth|reth) ;;
  *)
    fail_mismatch "FORTEL2_EL" "geth|reth" "$FORTEL2_EL"
    ;;
esac

require_executable "op-node" "$OP_NODE_BIN"
require_executable "op-reth" "$OP_RETH_BIN"

NODE_VER="$(version_of "$OP_NODE_BIN")"
RETH_VER="$(version_of "$OP_RETH_BIN")"

assert_macho_arm64_if_macho "op-node" "$OP_NODE_BIN"
assert_macho_arm64_if_macho "op-reth" "$OP_RETH_BIN"

if [[ "$FORTEL2_EL" == "reth" ]] && looks_like_geth "$RETH_VER" "$OP_RETH_BIN"; then
  fail_mismatch "op-reth (FORTEL2_EL=reth)" \
    "op-reth reporting Reth Version: ${PIN_RETH_VERSION} commit ${PIN_RETH_COMMIT}" \
    "op-geth binary ($OP_RETH_BIN): $(oneline "$RETH_VER")"
fi

# v1.19.2 not v1.19.20: next char must be non-digit (or end).
if ! echo "$NODE_VER" | grep -qE "v1\\.19\\.2([^0-9]|\$)" \
  || ! echo "$NODE_VER" | grep -q "$PIN_OP_NODE_COMMIT"; then
  fail_mismatch "op-node" \
    "${PIN_OP_NODE_VERSION} (${PIN_OP_NODE_COMMIT})" \
    "$(oneline "$NODE_VER")"
fi

if ! echo "$RETH_VER" | grep -q "Reth Version: ${PIN_RETH_VERSION}" \
  || ! echo "$RETH_VER" | grep -q "$PIN_RETH_COMMIT"; then
  fail_mismatch "op-reth" \
    "Reth Version: ${PIN_RETH_VERSION} commit ${PIN_RETH_COMMIT}" \
    "$(oneline "$RETH_VER")"
fi

echo "ok op-node ${PIN_OP_NODE_VERSION} (${PIN_OP_NODE_COMMIT})"
echo "ok op-reth tag op-reth/v2.3.3 reports Reth Version: ${PIN_RETH_VERSION} commit ${PIN_RETH_COMMIT}"
echo "ok FORTEL2_EL=${FORTEL2_EL}"
