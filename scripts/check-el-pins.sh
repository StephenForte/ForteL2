#!/usr/bin/env bash
# Assert the documented sequencer / op-reth pin against local binaries.
# Mini-only for a green live run (darwin/arm64 builds). CI covers the red
# path via stubs in scripts/test-helpers.sh — GitHub runners have no pin.
#
# Live sequencer pin (D-0150), all four built from monorepo commit da6d3252
# (tags op-node/v1.19.9 and op-reth/v2.6.0):
#   op-node     v1.19.9-da6d3252-…
#   op-batcher  v1.17.2-da6d3252-…   (component version, same monorepo commit)
#   op-proposer untagged-da6d3252-…  (no op-proposer tag on that commit)
# The annotated op-node tag object is d643cea0b218; --version prints the
# commit, so the pin is da6d3252. A green op-node with a v1.19.8 batcher
# or proposer is a failure. op-reth: tag op-reth/v2.6.0 reports
# "op-reth Version: 2.6.0" and commit
# da6d3252491754837a778061db0cc47236ec13c6. The tag string is not the
# --version line (it has never matched). Do not grep a bare "2.6"
# (that would accept unpinned later 2.6.x builds) or the tag
# "op-reth/v2.6.0" by itself. Match the measured version line and the
# full commit, each on its own line. The D-0149/D-0147 set
# (2.5.0 / 9f76a9d216f2d9aa99c5f45d7aad674acde93c14, v1.19.8 / v1.17.1 /
# untagged at 9f76a9d2) must fail.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

# Pin tokens as measured on the Mini. Tag op-reth/v2.6.0 ≠ reported version.
PIN_OP_NODE_VERSION='v1.19.9'
PIN_OP_NODE_COMMIT='da6d3252'
PIN_OP_BATCHER_VERSION='v1.17.2'
PIN_OP_BATCHER_COMMIT='da6d3252'
PIN_OP_PROPOSER_VERSION='untagged'
PIN_OP_PROPOSER_COMMIT='da6d3252'
PIN_RETH_VERSION='2.6.0'
PIN_RETH_COMMIT='da6d3252491754837a778061db0cc47236ec13c6'

FORTEL2_EL="${FORTEL2_EL:-geth}"
OP_NODE_BIN="${OP_NODE_BIN:-$BIN_DIR/op-node}"
OP_BATCHER_BIN="${OP_BATCHER_BIN:-$BIN_DIR/op-batcher}"
OP_PROPOSER_BIN="${OP_PROPOSER_BIN:-$BIN_DIR/op-proposer}"
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
require_executable "op-batcher" "$OP_BATCHER_BIN"
require_executable "op-proposer" "$OP_PROPOSER_BIN"
require_executable "op-reth" "$OP_RETH_BIN"

NODE_VER="$(version_of "$OP_NODE_BIN")"
BATCHER_VER="$(version_of "$OP_BATCHER_BIN")"
PROPOSER_VER="$(version_of "$OP_PROPOSER_BIN")"
RETH_VER="$(version_of "$OP_RETH_BIN")"

assert_macho_arm64_if_macho "op-node" "$OP_NODE_BIN"
assert_macho_arm64_if_macho "op-batcher" "$OP_BATCHER_BIN"
assert_macho_arm64_if_macho "op-proposer" "$OP_PROPOSER_BIN"
assert_macho_arm64_if_macho "op-reth" "$OP_RETH_BIN"

if [[ "$FORTEL2_EL" == "reth" ]] && looks_like_geth "$RETH_VER" "$OP_RETH_BIN"; then
  fail_mismatch "op-reth (FORTEL2_EL=reth)" \
    "op-reth reporting op-reth Version: ${PIN_RETH_VERSION} commit ${PIN_RETH_COMMIT}" \
    "op-geth binary ($OP_RETH_BIN): $(oneline "$RETH_VER")"
fi

# v1.19.9 not v1.19.90, v1.17.2 not v1.17.20: next char must be non-digit (or end).
# Proposer --version says "untagged" because the build tag is op-node/v1.19.9,
# not an op-proposer tag. The commit is what distinguishes it from 9f76a9d2.
if ! echo "$NODE_VER" | grep -qE "v1\\.19\\.9([^0-9]|\$)" \
  || ! echo "$NODE_VER" | grep -q "$PIN_OP_NODE_COMMIT"; then
  fail_mismatch "op-node" \
    "${PIN_OP_NODE_VERSION} (${PIN_OP_NODE_COMMIT})" \
    "$(oneline "$NODE_VER")"
fi

if ! echo "$BATCHER_VER" | grep -qE "v1\\.17\\.2([^0-9]|\$)" \
  || ! echo "$BATCHER_VER" | grep -q "$PIN_OP_BATCHER_COMMIT"; then
  fail_mismatch "op-batcher" \
    "${PIN_OP_BATCHER_VERSION} (${PIN_OP_BATCHER_COMMIT})" \
    "$(oneline "$BATCHER_VER")"
fi

if ! echo "$PROPOSER_VER" | grep -qE "(^|[^A-Za-z])untagged([^A-Za-z]|$)" \
  || ! echo "$PROPOSER_VER" | grep -q "$PIN_OP_PROPOSER_COMMIT"; then
  fail_mismatch "op-proposer" \
    "${PIN_OP_PROPOSER_VERSION} (${PIN_OP_PROPOSER_COMMIT})" \
    "$(oneline "$PROPOSER_VER")"
fi

# Whole line, not a substring: "2.6.0" must not accept "2.6.0-dev" or
# "2.6.00", and "op-reth Version:" must not accept the old "Reth Version:"
# line, the previous "op-reth Version: 2.5.0" line, or the bare tag
# "op-reth/v2.6.0".
if ! echo "$RETH_VER" | grep -qx "op-reth Version: ${PIN_RETH_VERSION}" \
  || ! echo "$RETH_VER" | grep -qx "Commit SHA: ${PIN_RETH_COMMIT}"; then
  fail_mismatch "op-reth" \
    "op-reth Version: ${PIN_RETH_VERSION} / Commit SHA: ${PIN_RETH_COMMIT}" \
    "$(oneline "$RETH_VER")"
fi

echo "ok op-node ${PIN_OP_NODE_VERSION} (${PIN_OP_NODE_COMMIT})"
echo "ok op-batcher ${PIN_OP_BATCHER_VERSION} (${PIN_OP_BATCHER_COMMIT})"
echo "ok op-proposer ${PIN_OP_PROPOSER_VERSION} (${PIN_OP_PROPOSER_COMMIT})"
echo "ok op-reth tag op-reth/v2.6.0 reports op-reth Version: ${PIN_RETH_VERSION} commit ${PIN_RETH_COMMIT}"
echo "ok FORTEL2_EL=${FORTEL2_EL}"
