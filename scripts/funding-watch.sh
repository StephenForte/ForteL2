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
#   FUNDING_WATCH_ADDRESS         optional      address to match in the wallet list;
#                                               defaults to BATCHER_ADDRESS from the env file
#   FUNDING_HEALTH_TIMEOUT        default 10    seconds
#
# Endpoint trust model: derive from FACTS the endpoint reports (last-run timestamp, our
# wallet's own entry) rather than its rollup labels. The rollup covers four wallets, three
# of which belong to ChainBank — a global "failing" may be about someone else's wallet, and
# a global "ok" cannot vouch for ours. ChainBank has also confirmed two label bugs that
# under-report severity (blocked/failed reported as below_policy; a new wallet reading
# degraded instead of failing), so labels are treated as advisory only. The wallet list
# covers every policy-holding wallet, including ones excluded from the reconciler
# (status `not_reconciled`) — harmless for others, serious for ours; see below.
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
# lib.sh sources the env file with `set -a`, so it OVERRIDES a caller-supplied
# BATCHER_ADDRESS (with no FORTEL2_ENV that means the local-901 Anvil address).
# FUNDING_WATCH_ADDRESS is never present in env files, so it survives as an explicit
# override — required for tests, and a guard against silently watching the wrong chain.
WATCH_ADDR="${FUNDING_WATCH_ADDRESS:-${BATCHER_ADDRESS:-}}"

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

python3 - "$SAMPLES_FILE" "$POLICY_MIN" "$STALE_HOURS" "$FLOOR_ETH" "$JSON_OUT" "$EP_BODY" "$EP_CODE" "$WATCH_ADDR" <<'PY'
import json, sys, os, datetime

def ts_utc(ts, fmt="%Y-%m-%dT%H:%MZ"):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime(fmt)

samples_file, policy_min, stale_hours, floor_eth, json_out, ep_body, ep_code, watch_addr = sys.argv[1:9]
policy_min = float(policy_min); stale_hours = float(stale_hours)
floor_eth = float(floor_eth)

FUNDER = "chainbank-wallet-reconciler (ChainBank repo, Render cron, 0 */6 * * *)"
print("=== ForteL2 funding watch ===")
print("external funder: %s" % FUNDER)

# Endpoint corroboration. Authoritative when it answers cleanly; advisory otherwise.
# It can escalate the verdict (it knows things local samples cannot) but never de-escalate:
# a local balance breach is evidence in its own right.
def parse_iso(v):
    if not isinstance(v, str):
        return None
    try:
        return datetime.datetime.fromisoformat(v.replace("Z", "+00:00"))
    except ValueError:
        return None

endpoint = {"queried": ep_code != "skipped", "http": ep_code, "status": None, "note": None,
            "run_stale": None, "our_wallet_status": None, "our_wallet_found": None}
# Facts we derive ourselves, immune to their label bugs.
ep_run_stale_h = None
ep_our_status = None
if ep_code == "200" and ep_body and os.path.exists(ep_body):
    try:
        doc = json.load(open(ep_body))
        endpoint["status"] = doc.get("status")
        endpoint["last_run"] = doc.get("lastRun")

        # (a) Is the job itself still running? Computed from the timestamp, not the label.
        fin = parse_iso(((doc.get("lastRun") or {}).get("finishedAt")))
        if fin is not None:
            now_utc = datetime.datetime.now(datetime.timezone.utc)
            ep_run_stale_h = (now_utc - fin).total_seconds() / 3600.0
            endpoint["run_stale"] = round(ep_run_stale_h, 2)

        # (b) Our wallet's own entry, matched by address. The rollup covers other wallets.
        if watch_addr:
            for w in (doc.get("wallets") or []):
                if str(w.get("address", "")).lower() == watch_addr.lower():
                    ep_our_status = str(w.get("status", "")).lower() or None
                    endpoint["our_wallet_status"] = ep_our_status
                    endpoint["our_wallet_found"] = True
                    break
            else:
                endpoint["our_wallet_found"] = False

        bits = ["status=%s" % endpoint["status"]]
        if ep_run_stale_h is not None:
            bits.append("last run %.1f h ago" % ep_run_stale_h)
        if endpoint["our_wallet_found"] is True:
            bits.append("our wallet=%s" % ep_our_status)
        elif endpoint["our_wallet_found"] is False:
            bits.append("OUR WALLET ABSENT from its wallet list")
        print("funder endpoint: %s" % ", ".join(bits))
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
# Derived fact 1: the job has not finished a run in longer than the tolerance. This is a
# global condition — if the cron is dead, our wallet stops being funded regardless of labels.
if ep_run_stale_h is not None and ep_run_stale_h > stale_hours:
    emit("FAIL", "the funder's last finished run was %.1f h ago (tolerance %.0f h) — %s has "
         "stopped or is erroring" % (ep_run_stale_h, stale_hours, FUNDER), extra)

# Derived fact 2: our specific wallet was attempted and could not be funded. `blocked` and
# `failed` both mean the funder tried and did not succeed, which no balance reading shows
# until the wallet has already drained.
if ep_our_status in ("blocked", "failed"):
    emit("FAIL", "the funder reports our batcher wallet as '%s' — funding is being attempted "
         "and not succeeding; check %s" % (ep_our_status, FUNDER), extra)

# `not_reconciled` means a policy-holding wallet is EXCLUDED from the reconciler
# (reconciliationEnabled=false, or a disabled wallet/project/environment). ChainBank's
# guidance is to treat it as inventory rather than a funding failure — correct for their
# own wallets. It is NOT correct for ours: if our batcher is excluded, auto-funding is off
# and the balance will never be replenished, which is exactly the silent death this script
# exists to catch. Proportionate response: loud warning while the balance still holds,
# FAIL once it is also under policy (draining with nothing coming).
if ep_our_status == "not_reconciled":
    if latest_bal < policy_min:
        emit("FAIL", "our batcher is marked 'not_reconciled' (excluded from the funder) AND "
             "is below the %.2f ETH policy — it is draining with no automation behind it"
             % policy_min, extra)
    print("WARNING: our batcher reads 'not_reconciled' — it holds a funding policy but is "
          "excluded from the reconciler, so this balance will NOT be topped up automatically")

# Our wallet missing entirely from a wallet list we believe covers it means we are not
# actually being watched — surface it rather than reading silence as health.
if endpoint.get("our_wallet_found") is False:
    print("WARNING: batcher address is absent from the funder's wallet list — "
          "it may not be covered by the funding policy at all")

# Their rollup label is advisory: it aggregates four wallets and is known to under-report.
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
