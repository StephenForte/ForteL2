#!/usr/bin/env bash
# Gas runway readout for Sepolia batcher/proposer L1 balances.
#
# Sample path (default): append one balance sample to data/gas-samples.jsonl via cast.
# Analyze path: pure computation over the samples file (no network / cast / Sepolia env).
#
#   FORTEL2_ENV=.env.sepolia ./scripts/gas-runway.sh
#   GAS_RUNWAY_SAMPLES_FILE=/tmp/x.jsonl ./scripts/gas-runway.sh --analyze-only
#
# Exit 0: runway OK, or INSUFFICIENT SAMPLES (< 1 h of history).
# Exit 2: either role has fewer than GAS_RUNWAY_MIN_DAYS (default 3) days to floor.
# Exit 1: usage / I/O / env errors.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
Usage: gas-runway.sh [--analyze-only]

  Default: sample BATCHER/PROPOSER L1 balances (requires FORTEL2_ENV=.env.sepolia + cast),
           append one JSONL line, then analyze.

  --analyze-only  Skip sampling; compute burn/day and days-to-floor from the samples file only.
                  No network, cast, or Sepolia env required.

Env:
  GAS_RUNWAY_SAMPLES_FILE  Samples JSONL path (default: $DATA_DIR/gas-samples.jsonl)
  GAS_RUNWAY_MIN_DAYS      Exit 2 threshold (default: 3)
  SEPOLIA_BATCHER_MIN_ETH  Floor for batcher (default: 0.15 — same as sepolia-fund-check.sh)
  SEPOLIA_PROPOSER_MIN_ETH Floor for proposer (default: 0.15)
EOF
}

ANALYZE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --analyze-only) ANALYZE_ONLY=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

SAMPLES_FILE="${GAS_RUNWAY_SAMPLES_FILE:-$DATA_DIR/gas-samples.jsonl}"
MIN_DAYS="${GAS_RUNWAY_MIN_DAYS:-3}"
# Mirror scripts/sepolia-fund-check.sh floors (do not edit that script).
BATCHER_MIN="${SEPOLIA_BATCHER_MIN_ETH:-0.15}"
PROPOSER_MIN="${SEPOLIA_PROPOSER_MIN_ETH:-0.15}"

require_bin python3

append_sample() {
  require_bin cast
  require_sepolia_env
  require_eth_address "BATCHER_ADDRESS" "${BATCHER_ADDRESS:-}"
  require_eth_address "PROPOSER_ADDRESS" "${PROPOSER_ADDRESS:-}"

  local samples_dir
  samples_dir="$(dirname "$SAMPLES_FILE")"
  mkdir -p "$samples_dir"

  echo "=== ForteL2 gas runway (sample) ==="
  echo "RPC: $(redact_rpc_url "$L1_RPC_URL")"
  echo "Samples file: $SAMPLES_FILE"

  local ts batcher_wei proposer_wei l2_block
  ts="$(date +%s)"
  batcher_wei="$(cast balance "$BATCHER_ADDRESS" --rpc-url "$L1_RPC_URL")"
  proposer_wei="$(cast balance "$PROPOSER_ADDRESS" --rpc-url "$L1_RPC_URL")"
  l2_block="$(cast block-number --rpc-url "$L2_RPC_URL")"

  python3 - "$SAMPLES_FILE" "$ts" "$batcher_wei" "$proposer_wei" "$l2_block" <<'PY'
import json, sys
path, ts, b, p, l2 = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], int(sys.argv[5])
rec = {"ts": ts, "batcher_wei": str(b), "proposer_wei": str(p), "l2_block": l2}
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(rec, separators=(",", ":")) + "\n")
print("appended sample ts=%d l2_block=%d" % (ts, l2))
PY
}

analyze_samples() {
  if [[ ! -f "$SAMPLES_FILE" ]]; then
    echo "ERROR: samples file not found: $SAMPLES_FILE" >&2
    echo "Run without --analyze-only once to record a sample, or set GAS_RUNWAY_SAMPLES_FILE." >&2
    exit 1
  fi

  # Pure computation: no cast, no RPC, no Sepolia env. Wei math in python3.
  python3 - "$SAMPLES_FILE" "$BATCHER_MIN" "$PROPOSER_MIN" "$MIN_DAYS" <<'PY'
import json
import sys

path = sys.argv[1]
batcher_floor_eth = float(sys.argv[2])
proposer_floor_eth = float(sys.argv[3])
min_days = float(sys.argv[4])
WEI = 10**18
HOUR = 3600
DAY = 86400

def load_samples(p):
    out = []
    with open(p, encoding="utf-8") as f:
        for line_no, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError as e:
                raise SystemExit("ERROR: bad JSONL at %s:%d: %s" % (p, line_no, e))
            for key in ("ts", "batcher_wei", "proposer_wei", "l2_block"):
                if key not in rec:
                    raise SystemExit("ERROR: missing %s at %s:%d" % (key, p, line_no))
            out.append({
                "ts": int(rec["ts"]),
                "batcher_wei": int(rec["batcher_wei"]),
                "proposer_wei": int(rec["proposer_wei"]),
                "l2_block": int(rec["l2_block"]),
            })
    out.sort(key=lambda r: r["ts"])
    return out

def burn_stats(window, key):
    """Sum decreases over adjacent pairs; skip top-up pairs (balance increased)."""
    burned = 0
    elapsed = 0
    for i in range(len(window) - 1):
        a = window[i]
        b = window[i + 1]
        dt = b["ts"] - a["ts"]
        if dt <= 0:
            continue
        if b[key] > a[key]:
            # Top-up interval — skip rather than report negative burn.
            continue
        burned += a[key] - b[key]
        elapsed += dt
    return burned, elapsed

def fmt_eth(wei):
    return "%.6f" % (wei / WEI)

samples = load_samples(path)
print("=== ForteL2 gas runway (analyze) ===")
print("Samples file: %s (%d sample(s))" % (path, len(samples)))

if len(samples) < 2:
    print("INSUFFICIENT SAMPLES")
    raise SystemExit(0)

newest = samples[-1]
# Oldest sample that is at least an hour older than the newest.
start_idx = None
for i, s in enumerate(samples):
    if newest["ts"] - s["ts"] >= HOUR:
        start_idx = i
        break
if start_idx is None:
    print("INSUFFICIENT SAMPLES")
    raise SystemExit(0)

window = samples[start_idx:]
roles = (
    ("BATCHER", "batcher_wei", batcher_floor_eth),
    ("PROPOSER", "proposer_wei", proposer_floor_eth),
)
exit_code = 0

for label, key, floor_eth in roles:
    burned, elapsed = burn_stats(window, key)
    current_wei = newest[key]
    floor_wei = int(round(floor_eth * WEI))
    if elapsed > 0:
        burn_wei_per_day = burned * DAY / float(elapsed)
        burn_eth_per_day = burn_wei_per_day / WEI
    else:
        burn_wei_per_day = 0.0
        burn_eth_per_day = 0.0

    surplus_wei = current_wei - floor_wei
    if burn_wei_per_day > 0:
        days = surplus_wei / burn_wei_per_day
        days_s = "%.3f" % days
        if days < min_days:
            exit_code = 2
    else:
        days_s = "inf"
        if surplus_wei < 0:
            exit_code = 2

    print(
        "role=%s balance_eth=%s burn_eth_per_day=%.6f days_to_floor=%s floor_eth=%s"
        % (label, fmt_eth(current_wei), burn_eth_per_day, days_s, sys.argv[2] if key == "batcher_wei" else sys.argv[3])
    )

raise SystemExit(exit_code)
PY
}

if [[ "$ANALYZE_ONLY" -eq 0 ]]; then
  append_sample
else
  echo "=== ForteL2 gas runway (analyze-only) ==="
  echo "Samples file: $SAMPLES_FILE"
fi

analyze_samples
