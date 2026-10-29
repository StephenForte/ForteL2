#!/usr/bin/env bash
# Assert the documented sequencer / op-reth pin against local binaries.
# Mini-only for a green live run (darwin/arm64 builds). CI covers the red
# path via stubs in scripts/test-helpers.sh — GitHub runners have no pin.
#
# Sequencer pins span two commits:
#   d6620202d4e563957830e688007a0cab29bd80f3: op-node, op-batcher, op-reth
#   0130abb2f07230ce01c904ba2fbb5d6338ba549f: op-proposer
# op-node/v1.20.0 and op-batcher/v1.18.0 report v1.20.0-d6620202-<unix>
# and v1.18.0-d6620202-<unix>, respectively. Their rc.1 tags share the
# release commit, so each version must immediately precede its commit.
# op-proposer/v1.17.0 is a tag-to-tag-to-commit peel: tag object bbaa87bf
# points to rc tag object d9285d4f, which points to commit 0130abb2.
# --version reports v1.17.0-0130abb2-<unix>, not either tag object.
# The rc.1 tag and an untagged build at 0130abb2 must still fail.
# op-reth/v2.8.0 tag object b0763e5798fa9a63d25a31a63afccdc18ae62b1c
# peels to d6620202d4e563957830e688007a0cab29bd80f3. Pin the commit,
# not the tag object. The old op-node v1.19.11-43c071cb and op-proposer
# untagged-43c071cb accept paths are now required failures.
# op-reth reports the whole line "op-reth Version: 2.8.0" and
# "Commit SHA: d6620202d4e563957830e688007a0cab29bd80f3".
# The tag string is not the --version line. Do not grep a bare "2.8"
# (that would accept 2.8.1 and later 2.8.x) or "op-reth/v2.8.0" by itself.
# Match the measured version line and the full commit, each on its own line.
# The D-0154 op-reth pin (2.6.1 / e16bffa18420c86dbab693097bc33117f74a5f7d)
# must still fail. So must the D-0150 set (2.6.0 /
# da6d3252491754837a778061db0cc47236ec13c6, v1.19.9 / v1.17.2 / untagged at
# da6d3252) and the D-0149/D-0147 set (2.5.0 /
# 9f76a9d216f2d9aa99c5f45d7aad674acde93c14, v1.19.8 / v1.17.1 / untagged at
# 9f76a9d2). A new op-reth with an older node, batcher, or proposer fails,
# and the reverse fails.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

# Pin measured version/commit pairs, not annotated tag objects.
PIN_OP_NODE_VERSION='v1.20.0'
PIN_OP_NODE_COMMIT='d6620202'
PIN_OP_BATCHER_VERSION='v1.18.0'
PIN_OP_BATCHER_COMMIT='d6620202'
PIN_OP_PROPOSER_VERSION='v1.17.0'
PIN_OP_PROPOSER_COMMIT='0130abb2'
PIN_RETH_VERSION='2.8.0'
PIN_RETH_COMMIT='d6620202d4e563957830e688007a0cab29bd80f3'

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

# Match version immediately followed by commit, then a non-alphanumeric
# boundary (or end). Separate greps would accept the rc tag at this commit.
if ! echo "$NODE_VER" | grep -qE "v1\\.20\\.0-${PIN_OP_NODE_COMMIT}([^0-9A-Za-z]|\$)"; then
  fail_mismatch "op-node" \
    "${PIN_OP_NODE_VERSION} (${PIN_OP_NODE_COMMIT})" \
    "$(oneline "$NODE_VER")"
fi

# v1.18.0-<commit>, not v1.18.00 and not v1.18.0-rc.1. The rc tag is on
# d6620202, so a version prefix plus a separate commit grep would accept
# "v1.18.0-rc.1-d6620202-…". The measured line is v1.18.0-d6620202-<unix>.
if ! echo "$BATCHER_VER" | grep -qE "v1\\.18\\.0-${PIN_OP_BATCHER_COMMIT}([^0-9A-Za-z]|\$)"; then
  fail_mismatch "op-batcher" \
    "${PIN_OP_BATCHER_VERSION} (${PIN_OP_BATCHER_COMMIT})" \
    "$(oneline "$BATCHER_VER")"
fi

# The release tag must immediately precede the commit; no untagged or rc build.
if ! echo "$PROPOSER_VER" | grep -qE "v1\\.17\\.0-${PIN_OP_PROPOSER_COMMIT}([^0-9A-Za-z]|\$)"; then
  fail_mismatch "op-proposer" \
    "${PIN_OP_PROPOSER_VERSION} (${PIN_OP_PROPOSER_COMMIT})" \
    "$(oneline "$PROPOSER_VER")"
fi

# Whole line, not a substring: "2.8.0" must not accept "2.8.1", "2.8.10",
# "2.6.1", or "2.8", and "op-reth Version:" must not accept the old
# "Reth Version:" line, the D-0154 "op-reth Version: 2.6.1" line, the
# D-0150 "op-reth Version: 2.6.0" line, or the bare tag "op-reth/v2.8.0".
if ! echo "$RETH_VER" | grep -qx "op-reth Version: ${PIN_RETH_VERSION}" \
  || ! echo "$RETH_VER" | grep -qx "Commit SHA: ${PIN_RETH_COMMIT}"; then
  fail_mismatch "op-reth" \
    "op-reth Version: ${PIN_RETH_VERSION} / Commit SHA: ${PIN_RETH_COMMIT}" \
    "$(oneline "$RETH_VER")"
fi

echo "ok op-node ${PIN_OP_NODE_VERSION} (${PIN_OP_NODE_COMMIT})"
echo "ok op-batcher ${PIN_OP_BATCHER_VERSION} (${PIN_OP_BATCHER_COMMIT})"
echo "ok op-proposer ${PIN_OP_PROPOSER_VERSION} (${PIN_OP_PROPOSER_COMMIT})"
echo "ok op-reth tag op-reth/v2.8.0 reports op-reth Version: ${PIN_RETH_VERSION} commit ${PIN_RETH_COMMIT}"
echo "ok FORTEL2_EL=${FORTEL2_EL}"
