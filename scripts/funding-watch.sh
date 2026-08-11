#!/usr/bin/env bash
# funding-watch.sh — detect failure of the EXTERNAL batcher-funding automation.
#
# The batcher's L1 balance is topped up by `chainbank-wallet-reconciler`, a Render cron
# built from the separate ChainBank repo (schedule `0 */6 * * *`). Nothing in this repo
# starts, monitors, or alerts on it. If it stops, ForteL2 keeps producing L2 blocks while
# batches quietly stop reaching L1 — the worst failure shape for a settlement rail.
#
# This script closes that blind spot using only the local gas samples file. It makes NO
# network calls and needs no Sepolia env, so it is testable offline and safe in CI.
# Take samples with `gas-runway.sh` (the daily health agent does this).
#
# Verdicts:
#   OK    balance at/above the funding policy minimum, or a top-up landed recently
#   WARN  below policy minimum, but for less than FUNDING_STALE_HOURS (funder may not
#         have reached its next cycle yet)
#   FAIL  below policy minimum for longer than FUNDING_STALE_HOURS with no top-up
#         (the external funder is likely broken)
#
# Detection latency is bounded by how often samples are taken: the daily health agent
# gives ~24 h. Runway/days-to-floor stays gas-runway.sh's job; this script only answers
# "is the external funder still doing its job?".
#
# Optionally corroborates against ChainBank's own /health/funding endpoint when
# CHAINBANK_FUNDING_HEALTH_URL + FUNDING_HEALTH_TOKEN are set (they live in .env.sepolia,
# never committed). That endpoint is authoritative about the funder's liveness, but it is
# a THIRD-PARTY dependency: if it is unreachable or erroring, this script says so and falls
# back to local sample inference. A broken ChainBank must never break ForteL2's own check.
#
# Usage: funding-watch.sh [--json <path>]
#   FUNDING_POLICY_MIN_ETH        default 0.6   level the external funder maintains
#   FUNDING_STALE_HOURS           default 12    two 6-hour funder cycles
#   GAS_RUNWAY_SAMPLES_FILE       default $DATA_DIR/gas-samples.jsonl
#   CHAINBANK_FUNDING_HEALTH_URL  optional      funder health endpoint
#   FUNDING_HEALTH_TOKEN          optional      bearer token for it (secret)
#   FUNDING_HEALTH_JSON           optional      read a local file instead of HTTP (tests)
#   FUNDING_HEALTH_TIMEOUT        default 10    seconds
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib.sh"

JSON_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON_OUT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

require_bin python3

DATA_DIR="${DATA_DIR:-$REPO_ROOT/data}"
SAMPLES_FILE="${GAS_RUNWAY_SAMPLES_FILE:-$DATA_DIR/gas-samples.jsonl}"
POLICY_MIN="${FUNDING_POLICY_MIN_ETH:-0.6}"
STALE_HOURS="${FUNDING_STALE_HOURS:-12}"
FLOOR_ETH="${BATCHER_FLOOR_ETH:-0.15}"

# --- optional: corroborate with the funder's own health endpoint ---------------
# Never fatal, never blocking beyond the timeout, and the token is never printed.
EP_BODY=""
EP_CODE="skipped"
if [ -n "${FUNDING_HEALTH_JSON:-}" ]; then
  EP_BODY="$FUNDING_HEALTH_JSON"
  EP_CODE="200"
elif [ -n "${CHAINBANK_FUNDING_HEALTH_URL:-}" ] && [ -n "${FUNDING_HEALTH_TOKEN:-}" ]; then
  if command -v curl >/dev/null 2>&1; then
    EP_BODY="$(mktemp "${TMPDIR:-/tmp}/fortel2-funding-ep.XXXXXX")"
    trap 'rm -f "$EP_BODY"' EXIT
    EP_CODE="$(curl -s -o "$EP_BODY" -w '%{http_code}' \
                 --max-time "${FUNDING_HEALTH_TIMEOUT:-10}" \
                 -H "Authorization: Bearer ${FUNDING_HEALTH_TOKEN}" \
                 "$CHAINBANK_FUNDING_HEALTH_URL" 2>/dev/null)" || EP_CODE="unreachable"
    [ -n "$EP_CODE" ] || EP_CODE="unreachable"
  else
    EP_CODE="no-curl"
  fi
fi

python3 - "$SAMPLES_FILE" "$POLICY_MIN" "$STALE_HOURS" "$FLOOR_ETH" "$JSON_OUT" "$EP_BODY" "$EP_CODE" <<'PY'
import json, sys, os, datetime

def ts_utc(ts, fmt="%Y-%m-%dT%H:%MZ"):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime(fmt)

samples_file, policy_min, stale_hours, floor_eth, json_out, ep_body, ep_code = sys.argv[1:8]
policy_min = float(policy_min); stale_hours = float(stale_hours)
floor_eth = float(floor_eth)

FUNDER = "chainbank-wallet-reconciler (ChainBank repo, Render cron, 0 */6 * * *)"
print("=== ForteL2 funding watch ===")
print("external funder: %s" % FUNDER)

# Endpoint corroboration. Authoritative when it answers cleanly; advisory otherwise.
# It can escalate the verdict (it knows things local samples cannot) but never de-escalate:
# a local balance breach is evidence in its own right.
endpoint = {"queried": ep_code != "skipped", "http": ep_code, "status": None, "note": None}
if ep_code == "200" and ep_body and os.path.exists(ep_body):
    try:
        doc = json.load(open(ep_body))
        endpoint["status"] = doc.get("status")
        endpoint["last_run"] = doc.get("lastRun")
        print("funder endpoint: status=%s" % endpoint["status"])
    except (ValueError, OSError) as exc:
        endpoint["note"] = "unparseable response: %s" % exc.__class__.__name__
        print("funder endpoint: UNPARSEABLE (%s) — falling back to local samples"
              % exc.__class__.__name__)
elif ep_code == "skipped":
    pass
else:
    endpoint["note"] = "endpoint unavailable (%s)" % ep_code
    print("funder endpoint: UNAVAILABLE (%s) — falling back to local samples; "
          "funder liveness is unconfirmed from its own side" % ep_code)

def emit(verdict, reason, extra=None):
    print("VERDICT: %s — %s" % (verdict, reason))
    if json_out:
        doc = {"verdict": verdict, "reason": reason, "funder": FUNDER,
               "policy_min_eth": policy_min, "tooling_floor_eth": floor_eth,
               "stale_hours": stale_hours, "samples_file": samples_file,
               "funder_endpoint": endpoint}
        if extra:
            doc.update(extra)
        tmp = json_out + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(doc, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, json_out)
    sys.exit(0 if verdict in ("OK", "WARN", "INSUFFICIENT") else 1)

if not os.path.exists(samples_file):
    emit("INSUFFICIENT", "no samples file at %s — run gas-runway.sh first" % samples_file)

rows = []
for line in open(samples_file):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
        rows.append((int(d["ts"]), int(d["batcher_wei"]) / 1e18))
    except (ValueError, KeyError):
        continue
rows.sort()
if not rows:
    emit("INSUFFICIENT", "samples file has no usable rows")

latest_ts, latest_bal = rows[-1]
age_h = None
stamp = ts_utc(latest_ts)
print("samples: %d (latest %s)" % (len(rows), stamp))
print("batcher: %.4f ETH   policy_min: %.2f   tooling_floor: %.2f"
      % (latest_bal, policy_min, floor_eth))

# Most recent top-up = most recent interval where the balance rose.
# A top-up is only localised to the interval between two samples, never to an instant.
# last_topup = (interval_start_ts, interval_end_ts, delta); we age it from interval_end
# (the conservative choice: it treats the top-up as recent as possible).
last_topup = None
for i in range(len(rows) - 1, 0, -1):
    delta = rows[i][1] - rows[i - 1][1]
    if delta > 0:
        last_topup = (rows[i - 1][0], rows[i][0], delta)
        break
if last_topup:
    hrs = (latest_ts - last_topup[1]) / 3600.0
    print("last top-up: +%.4f ETH somewhere in %s .. %s (interval ended %.1f h ago)"
          % (last_topup[2], ts_utc(last_topup[0]), ts_utc(last_topup[1]), hrs))
else:
    print("last top-up: none observed in this samples file")

extra = {"batcher_eth": round(latest_bal, 6), "samples": len(rows),
         "latest_sample_utc": stamp,
         "last_topup_interval_utc": ([ts_utc(last_topup[0]), ts_utc(last_topup[1])]
                                     if last_topup else None),
         "last_topup_eth": round(last_topup[2], 6) if last_topup else None}

# The funder declaring itself broken outranks a healthy-looking local balance: the wallet
# can sit above policy for hours after the job dies.
if endpoint.get("status") == "failing":
    emit("FAIL", "the funder's own health endpoint reports status=failing — %s has stopped "
         "or is erroring; check its recent runs" % FUNDER, extra)

if latest_bal >= policy_min:
    if endpoint.get("status") == "degraded":
        emit("WARN", "balance is above policy, but the funder's endpoint reports "
             "status=degraded", extra)
    emit("OK", "balance at or above the funding policy minimum", extra)

# Below policy: how long has it been continuously below?
below_since = latest_ts
for ts, bal in reversed(rows):
    if bal < policy_min:
        below_since = ts
    else:
        break
below_h = (latest_ts - below_since) / 3600.0
extra["below_policy_hours"] = round(below_h, 2)
# below_h is a lower bound: the true crossing happened somewhere between the last
# above-policy sample and `below_since`, so coarse sampling under-reports it.
print("confirmed below policy for %.1f h (lower bound — sampling granularity; "
      "stale threshold %.0f h)" % (below_h, stale_hours))

# A top-up inside the stale window proves the funder is alive even if below policy now.
if last_topup and (latest_ts - last_topup[1]) / 3600.0 <= stale_hours:
    emit("WARN", "below policy minimum, but the funder topped up within the last %.0f h"
         % stale_hours, extra)

if below_h > stale_hours:
    emit("FAIL",
         "batcher has been below the %.2f ETH funding policy for %.1f h with no top-up — "
         "the external funder (%s) has probably stopped; check its recent runs"
         % (policy_min, below_h, FUNDER), extra)

emit("WARN", "below policy minimum for at least %.1f h — still inside the %.0f h tolerance; "
     "the funder may not have reached its next cycle yet" % (below_h, stale_hours), extra)
PY
