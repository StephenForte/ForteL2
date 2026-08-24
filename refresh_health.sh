#!/bin/zsh
# ForteL2 pipeline health snapshot for the Morning Briefing.
# Runs pipeline-snapshot.py locally (where L2 RPCs on 127.0.0.1 are reachable)
# and writes data/pipeline-health.json atomically. Read-only: never starts/stops the chain.
cd "$(dirname "$0")" || exit 1
mkdir -p data
run_snapshot() {
  if [ -f .env.sepolia ]; then
    FORTEL2_ENV=.env.sepolia python3 scripts/pipeline-snapshot.py -o data/pipeline-health.json.tmp
  else
    python3 scripts/pipeline-snapshot.py -o data/pipeline-health.json.tmp
  fi
}
# pipeline-snapshot.py writes the JSON *before* returning 1 when both L2 panels
# fail (stack down after a failed wake). Keep that file — deleting it leaves
# the Morning Briefing on yesterday's healthy snapshot. Still run the funder
# watch either way; exit with the snapshot status so launchd records the miss.
snap_rc=0
run_snapshot 2> data/pipeline-health.err.log || snap_rc=$?
if [ -f data/pipeline-health.json.tmp ]; then
  mv data/pipeline-health.json.tmp data/pipeline-health.json
fi

# --- Gas sample + external-funder watch -------------------------------------
# Records one L1 balance sample, then checks whether the EXTERNAL funder
# (chainbank-wallet-reconciler, ChainBank repo, Render cron) is still doing its
# job. Both are strictly additive: a failure here must never fail the pipeline
# health snapshot above, which the Morning Briefing depends on.
if [ -f .env.sepolia ]; then
  FORTEL2_ENV=.env.sepolia ./scripts/gas-runway.sh > data/gas-runway.out 2>&1 || true
  FORTEL2_ENV=.env.sepolia ./scripts/funding-watch.sh --json data/funding-health.json \
    > data/funding-watch.out 2>&1 || true
fi

if [ ! -f data/pipeline-health.json ]; then
  exit 1
fi
exit "$snap_rc"
