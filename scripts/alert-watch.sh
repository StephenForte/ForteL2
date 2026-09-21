#!/usr/bin/env bash
# alert-watch.sh — notify the operator when funding-watch FAIL is sitting unnoticed
# or the hourly resolve-games recovery agent has gone silent.
#
# refresh_health.sh records funding-watch's verdict in data/funding-health.json and
# swallows the exit code (`|| true`) so the Morning Briefing snapshot cannot fail.
# com.steve.fortel2-resolve-games recovers bonds hourly; if launchd drops it or it
# starts exiting nonzero, the only symptom is silence in ~/Library/Logs. This
# watcher is the observer those two paths never had (R-12 was the proof).
#
# Conditions (each is a distinct cooldown key):
#   funding-fail          data/funding-health.json verdict is FAIL (reason is copied)
#   health-stale          that JSON is missing, unreadable, unknown-verdict, or >26 h
#   resolve-games-stale   recovery-agent logs older than 2 h (≤ 2 hourly cycles)
#   resolve-games-unloaded  launchctl print cannot find the job (read-only)
#   resolve-games-nonzero   last exit code nonzero on 2 consecutive watcher runs
#   stack-missing         Sepolia (L2_CHAIN_ID=852): some expected pids are up,
#                         at least one (incl. op-challenger) is not. Still
#                         fires on that trigger if no ExEx panic is found.
#                         When op-reth is among the missing processes, a
#                         current ExEx panic in the last 64 KiB of
#                         op-reth.log may enrich the body — the log is
#                         never the detector (cf_token_hint precedent).
#   stack-down            Sepolia: nothing is up outside the dev-sleep window
#                         (a failed wake). The window is the installed
#                         launchd sleep and wake jobs (D-0144), not a
#                         constant; absent plists assume 23:45–00:15 and say
#                         so. Same ExEx enrichment as stack-missing when
#                         op-reth is down.
#                         A historical panic (pid alive, or panic before
#                         the last start banner in that tail) is ignored.
#   cloudflared-failing   system LaunchDaemon com.cloudflare.cloudflared is
#                         installed (plist exists) and unhealthy: launchctl print
#                         missing/unparseable, or state is not running (any last
#                         exit code — KeepAlive SuccessfulExit=false, so a clean
#                         exit is a permanent silent outage). No overnight-sleep
#                         grace — KeepAlive 24/7. Plist absent is a deliberate
#                         no-tunnel host, never an alert. Err-log "Failed to
#                         read token file" may enrich the body; daemon state is
#                         the trigger (D-0107 F5).
#   cloudflared-no-edge   plist present, launchctl state is running, and the
#                         loopback metrics gauge cloudflared_tunnel_ha_connections
#                         is 0. The process is up and the hostname is dark. Do
#                         not probe 127.0.0.1:9555 or the write hostname — the
#                         origin is dark during the dev-sleep window by design
#                         (D-0034 / D-0035; currently 23:45–00:15, D-0144);
#                         edge count stays >0 across that window. No sleep grace.
#   cloudflared-restart-storm  plist present and the launchd `runs` counter grew
#                         by more than 1 (exclusive floor) since the last
#                         watcher observation, persisted as cloudflared_last_runs
#                         in alert-watch-state.json. +1 is a brew upgrade or
#                         kickstart (quiet); a crash loop is ~720/hour. First
#                         sample is a baseline, never an alert. No sleep grace.
#   cloudflared-metrics-unreachable  plist present, daemon running, and two
#                         consecutive failed loopback metrics reads (timeout /
#                         HTTP / garbage / missing gauge). One failure is quiet;
#                         a later success resets cloudflared_metrics_unreachable_streak.
#                         urllib + SIGALRM total deadline (default 5 s). Metrics
#                         URL from the err-log line "Starting metrics server on
#                         HOST:PORT/metrics" (last match); default
#                         http://127.0.0.1:20241/metrics. A moved port with no
#                         log line degrades to this condition, never to silence.
#                         Throw/timeout/garbage must not skip other conditions.
#   replica-losing-ground public replica head age grew by more than
#                         REPLICA_TREND_NOISE_SECS (default 600, exclusive) on
#                         two consecutive successful probes. One grown delta is
#                         quiet (redeploy replay: age up for one run, then
#                         collapses). A later delta at or below the floor
#                         resets replica_losing_streak. An L1-derived replica
#                         sawtooths by one batcher channel (~6 min at
#                         SEPOLIA_BATCHER_MAX_CHANNEL_DURATION=30); 600 s is
#                         one channel plus margin (D-0140). An hourly freeze
#                         grows ~3600 s. A probe whose growth interval
#                         [prev_obs, now] lies wholly or partly inside the
#                         dev-sleep window does not advance the streak — judged
#                         by in_dev_sleep_window on the INTERVAL, not "are we
#                         asleep right now" (both endpoints can be awake while
#                         the middle still spans the freeze). The first probe
#                         within one watcher cycle after the wake also does not
#                         advance (catch-up grace anchored to the window end,
#                         not to a fixed clock time). Render does not sleep;
#                         its Mac SOURCE does (D-0141 / D-0144).
#   replica-head-stale    a single successful probe shows head age >
#                         REPLICA_HEAD_STALE_SECS (default 10800, exclusive, same
#                         operator as health-stale). Backstop when trend has no
#                         prior sample (first run, wiped state, watcher down).
#                         Unchanged by D-0140 / D-0141; still fires during the
#                         sleep window (a late wake can trip it — noted, not
#                         fixed; needs its own decision).
#   replica-unreachable   two consecutive failed probes of the public-read
#                         gateway (timeout / HTTP / garbage JSON / missing
#                         timestamp). One failure is quiet; a later success
#                         resets the streak. Failed probes do not overwrite the
#                         last successful head sample. urllib socket timeout
#                         AND a SIGALRM total deadline of 15 s, body cap 65536 —
#                         never ALERT_WATCH_CURL (that shim is Resend). One
#                         eth_getBlockByNumber(latest); URL is the published
#                         public-read gateway, never QuickNode / Access / loopback.
#   proposer-overdue      the proposer's last DisputeGameFactory game, with any
#                         time inside the dev-sleep window excluded (however many
#                         windows the gap spans — reuses in_dev_sleep_window()),
#                         is older than the configured SEPOLIA_PROPOSER_INTERVAL
#                         (default 8h; legacy PROPOSER_INTERVAL is a Phase-1
#                         Anvil knob and is ignored) plus a 2 h grace (D-0142;
#                         ~60x the observed ~2 min proposer jitter). Exclusive:
#                         exactly at the threshold is quiet, one second past
#                         fires. This is the FIRST metered dependency in this
#                         watcher — its own hourly L1 read (gameCount() +
#                         gameAtIndex(), two eth_calls/run, ~48/day) against
#                         L1_RPC_URL, separate from the daily pipeline-snapshot
#                         scan. A failed/garbage read, an empty factory
#                         (game_count 0), or an unparseable interval cannot
#                         determine overdue-ness and is quiet once; the SAME
#                         condition id only fires (as "cannot verify") after two
#                         consecutive such reads, following the
#                         replica_unreachable_streak precedent — a later
#                         successful read resets that streak.
#
# Verdicts OK / WARN / INSUFFICIENT never alert (WARN is inside funding-watch's
# documented tolerance; alerting on it is the cry-wolf class #146 removed).
#
# Channels are independent: a macOS banner (osascript) and Resend email
# (POST https://api.resend.com/emails). Either fires even when the other is
# missing or broken. Any channel failure is logged and the process exits
# nonzero so launchd's err log records it. Missing RESEND_API_TOKEN skips
# email with a warning and still exits nonzero; the banner still fires.
#
# A persisting condition re-alerts every ALERT_REALERT_HOURS (default 6), not
# every cycle. A second distinct condition alerts immediately. Cooldown state:
# $FORTEL2_ROOT/data/alert-watch-state.json (gitignored).
#
# Overnight Mac-sleep: this watcher also does not run while the Mac is asleep,
# so a tight resolve-games log threshold does not false-alarm during the gap.
# On the first run after a long pause (state last_check older than 3 h) log
# mtime is granted one cycle of grace — launchd fires one missed calendar
# event on wake, and this watcher may race it. Unloaded / nonzero-exit still
# alert on that first run; those are not sleep artefacts. cloudflared-failing
# / cloudflared-no-edge / cloudflared-restart-storm /
# cloudflared-metrics-unreachable never take that last_check grace (the tunnel
# daemon is KeepAlive, not calendar). replica-head-stale / replica-unreachable
# never take that last_check grace either — the replica process is on Render.
# replica-losing-ground also does not take that last_check grace, but it does
# not advance replica_losing_streak when the growth interval overlaps the
# dev-sleep window or is within one watcher cycle after the wake: Render
# stays up, the Mac SOURCE does not, and head age grows 1 s/s by arithmetic
# (D-0141 / D-0144). The window is read from the installed launchd jobs.
#
# Usage: alert-watch.sh [--test]
#   --test     synthetic alert, tagged TEST, both channels (post-install shakeout)
#
# Env (fill in local .env.sepolia; the tracked example stays empty):
#   RESEND_API_TOKEN      Resend API token (secret). Never on argv or in output.
#   ALERT_EMAIL_FROM      default onboarding@resend.dev (account-owner inbox only)
#   ALERT_EMAIL_TO        recipient (required for email)
#   ALERT_REALERT_HOURS   default 6
#   REPLICA_HEAD_STALE_SECS    default 10800 (comment in .env.sepolia.example)
#   REPLICA_TREND_NOISE_SECS   default 600
#   SEPOLIA_PROPOSER_INTERVAL  proposer cadence for proposer-overdue, default 8h
#                              (D-0133/D-0142). Never the legacy PROPOSER_INTERVAL
#                              Phase-1 Anvil knob — that key is ignored here too.
#
# Test-only overrides (names never appear in env files, so they survive lib.sh
# `set -a` sourcing):
#   ALERT_WATCH_FUNDING_JSON   ALERT_WATCH_STATE
#   ALERT_WATCH_RESOLVE_OUT    ALERT_WATCH_RESOLVE_ERR
#   ALERT_WATCH_HEALTH_STALE_SECS   ALERT_WATCH_RESOLVE_STALE_SECS
#   ALERT_WATCH_SLEEP_GRACE_SECS
#   ALERT_WATCH_PID_DIR        ALERT_WATCH_EXPECT_STACK (1=up, 0=sleep window)
#   ALERT_WATCH_OP_RETH_LOG     canned op-reth.log path (skips the host log)
#   ALERT_WATCH_EXEX_THROW=1    raise inside the ExEx scan; other conditions
#                               must still evaluate
#   ALERT_WATCH_EXEX_TAIL_BYTES test-only tail window (default 65536)
#     When OP_RETH_LOG / EXEX_THROW / EXEX_TAIL_BYTES is set, or
#     ALERT_WATCH_CURL / ALERT_WATCH_LAUNCHCTL is set (evaluation
#     fixtures), the scan never opens the production log path. Unset
#     hooks plus CURL/LAUNCHCTL default to no ExEx text (HEALTHY/quiet).
#     Production launchd does not set those keys and reads the last
#     64 KiB of $LOG_DIR/op-reth.log. Recency is the op-reth pidfile
#     (must be down) plus a panic only after the last start banner in
#     that tail. mtime is not used — the file is appended constantly
#     by unrelated lines.
#   ALERT_WATCH_CURL  ALERT_WATCH_OSASCRIPT  ALERT_WATCH_LAUNCHCTL
#     (absolute shim paths — lib.sh prepends homebrew onto PATH)
#   ALERT_WATCH_CLOUDFLARED_PLIST  ALERT_WATCH_CLOUDFLARED_ERR
#     A launchctl shim without CLOUDFLARED_PLIST does not observe the host's
#     real tunnel plist (existing shims print resolve-games not-running/0).
#   ALERT_WATCH_CLOUDFLARED_METRICS   canned Prometheus text (skips the socket)
#   ALERT_WATCH_CLOUDFLARED_RUNS      canned launchd `runs` integer
#   ALERT_WATCH_CLOUDFLARED_UNREACHABLE=1  inject a failed metrics read
#   ALERT_WATCH_CLOUDFLARED_THROW=1        raise inside the metrics probe;
#                                         other conditions must still evaluate
#   ALERT_WATCH_CLOUDFLARED_TIMEOUT        test-only total deadline seconds
#     When METRICS/RUNS/UNREACHABLE/THROW is set, or ALERT_WATCH_CURL /
#     ALERT_WATCH_LAUNCHCTL is set (evaluation fixtures), the metrics probe
#     never opens a socket. Unset hooks plus CURL/LAUNCHCTL default to a
#     HEALTHY daemon (ha_connections=4, runs unchanged). Production launchd
#     does not set those keys and uses urllib against loopback only.
#   ALERT_WATCH_REPLICA_HEAD_NUMBER  canned block number (skips the network)
#   ALERT_WATCH_REPLICA_HEAD_TS     unix timestamp of that head
#   ALERT_WATCH_REPLICA_HEAD_AGE    seconds; timestamp = now - age at eval time
#     Prefer HEAD_AGE for "fresh" (age ≈ 0 each run). A fixed HEAD_TS is a
#     frozen head: two evaluations ~1 s apart would look like losing ground
#     if the noise floor were "any increase".
#   ALERT_WATCH_REPLICA_UNREACHABLE=1  inject a failed probe (no network)
#   ALERT_WATCH_REPLICA_THROW=1        raise inside the probe; other conditions
#                                      must still evaluate
#   ALERT_WATCH_REPLICA_RPC_URL        test-only live URL (does not skip urllib)
#   ALERT_WATCH_REPLICA_TIMEOUT        test-only total deadline seconds
#   ALERT_WATCH_NOW                    unix timestamp; pins evaluator "now" so
#                                      sleep-window cases are not wall-clock
#                                      flaky. Does not skip the probe.
#   FORTEL2_DEV_SLEEP_AGENTS_DIR       test-only directory of sleep/wake plists
#                                      (replaces ~/Library/LaunchAgents for
#                                      the dev-sleep window only). Never an
#                                      env-file key. Unset reads the installed
#                                      jobs; a directory with no parseable
#                                      pair falls back to 23:45–00:15 and is
#                                      labeled an assumed default.
#   When HEAD_*/UNREACHABLE/THROW is set, or ALERT_WATCH_CURL is set (Resend
#   shim), the probe never opens a socket. RPC_URL/TIMEOUT do not short-circuit.
#   Production launchd does not set those keys and uses urllib against the
#   hardcoded public-read gateway.
#   ALERT_WATCH_PROPOSER_FACTORY       canned DisputeGameFactory address (skips
#                                      deployments.json)
#   ALERT_WATCH_PROPOSER_GAME_COUNT    canned gameCount() result
#   ALERT_WATCH_PROPOSER_LATEST_INDEX  canned latest game index
#   ALERT_WATCH_PROPOSER_LATEST_TS     unix timestamp of the latest game
#   ALERT_WATCH_PROPOSER_LATEST_AGE    seconds; timestamp = now - age at eval
#                                      time. Prefer LATEST_AGE for "fresh",
#                                      same reasoning as REPLICA_HEAD_AGE.
#   ALERT_WATCH_PROPOSER_UNREACHABLE=1  inject a failed probe (no network)
#   ALERT_WATCH_PROPOSER_THROW=1        raise inside the probe; other
#                                       conditions must still evaluate
#   ALERT_WATCH_PROPOSER_TIMEOUT        test-only total deadline seconds
#     When FACTORY/GAME_COUNT/LATEST_*/UNREACHABLE/THROW is set, or
#     ALERT_WATCH_CURL is set (Resend shim), the probe never opens a socket
#     and never reads deployments.json. Production launchd sets none of
#     those keys and uses urllib against L1_RPC_URL plus the on-disk
#     deployments file (D-0142).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib.sh"

DO_TEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --test) DO_TEST=1; shift ;;
    -h|--help)
      awk 'NR==1{next} /^#/{print; next} {exit}' "$0"
      require_bin python3
      # Resolved window, after the static contract, so a reader can tell a
      # measurement from the documented fallback (D-0144). Same reader the
      # evaluator execs — the markers below are the one copy in this file.
      python3 - "$0" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
start = text.find("# <<<DEV_SLEEP_READER\n")
end = text.find("# >>>DEV_SLEEP_READER\n")
if start < 0 or end < 0 or end <= start:
    print("dev-sleep window: unreadable (reader markers missing)", file=sys.stderr)
    raise SystemExit(1)
ns = {"__name__": "dev_sleep_reader"}
exec(text[start + len("# <<<DEV_SLEEP_READER\n"):end], ns)
window = ns["dev_sleep_window"]()
if window["source"] == "launchd":
    how = "measured from installed launchd: %s" % window["agentsDir"]
else:
    how = "assumed default; installed sleep/wake plists absent or unparseable"
print(
    "dev-sleep window: %s-%s %s (%s)"
    % (window["startLocal"], window["endLocal"], window["tz"], how)
)
PY
      exit 0
      ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

require_bin python3

# Paths: refresh_health.sh writes repo-relative data/funding-health.json (not $DATA_DIR).
FUNDING_JSON="${ALERT_WATCH_FUNDING_JSON:-$FORTEL2_ROOT/data/funding-health.json}"
STATE_FILE="${ALERT_WATCH_STATE:-$FORTEL2_ROOT/data/alert-watch-state.json}"
RESOLVE_OUT="${ALERT_WATCH_RESOLVE_OUT:-$HOME/Library/Logs/fortel2-resolve-games.out.log}"
RESOLVE_ERR="${ALERT_WATCH_RESOLVE_ERR:-$HOME/Library/Logs/fortel2-resolve-games.err.log}"
HEALTH_STALE_SECS="${ALERT_WATCH_HEALTH_STALE_SECS:-$((26 * 3600))}"
RESOLVE_STALE_SECS="${ALERT_WATCH_RESOLVE_STALE_SECS:-$((2 * 3600))}"
# Agent :00, watcher :30. One miss → 01:30 sees ~1.5 h (quiet). Two misses →
# 02:30 sees ~2.5 h. A 2.5 h threshold misses that check (third cycle at 03:30).
SLEEP_GRACE_SECS="${ALERT_WATCH_SLEEP_GRACE_SECS:-$((3 * 3600))}"
REALERT_HOURS="${ALERT_REALERT_HOURS:-6}"
EMAIL_FROM="${ALERT_EMAIL_FROM:-onboarding@resend.dev}"
EMAIL_TO="${ALERT_EMAIL_TO:-}"
LABEL="com.steve.fortel2-resolve-games"
# System-domain tunnel (D-0034 / D-0035). Override paths are test-only.
# A launchctl shim plus no plist override must not see the host's real
# tunnel — older shims always print not-running/0 for every print target.
if [ -n "${ALERT_WATCH_LAUNCHCTL:-}" ] && [ -z "${ALERT_WATCH_CLOUDFLARED_PLIST:-}" ]; then
  CF_PLIST=""
else
  CF_PLIST="${ALERT_WATCH_CLOUDFLARED_PLIST:-/Library/LaunchDaemons/com.cloudflare.cloudflared.plist}"
fi
CF_ERR="${ALERT_WATCH_CLOUDFLARED_ERR:-/Library/Logs/com.cloudflare.cloudflared.err.log}"
CF_LABEL="com.cloudflare.cloudflared"

# Proposer DisputeGameFactory address (D-0142): read the checked-in
# deployments.json via lib.sh's deployments_json_path() — never discovered by
# a live RPC. Canned ALERT_WATCH_PROPOSER_FACTORY skips the file entirely
# (evaluation fixtures never need a real deployments.json on disk).
PROPOSER_FACTORY="${ALERT_WATCH_PROPOSER_FACTORY:-}"
if [ -z "$PROPOSER_FACTORY" ]; then
  PROPOSER_FACTORY="$(python3 - "$(deployments_json_path)" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
    print(str(data.get("DisputeGameFactoryProxy") or data.get("disputeGameFactoryProxy") or ""))
except (OSError, ValueError, TypeError, IndexError):
    print("")
PY
)"
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-alert-watch.XXXXXX")"
cleanup_aw() { rm -rf "$WORKDIR"; }
trap cleanup_aw EXIT

# --- channel sends ------------------------------------------------------------
# Token is passed to curl on stdin (--header @-), never argv. set +x in case an
# operator has xtrace on. env -u so `ps e` on the curl child does not show it.

send_banner() {
  set +x
  local title="$1" body="$2"
  if ! command -v "${ALERT_WATCH_OSASCRIPT:-osascript}" >/dev/null 2>&1; then
    echo "ERROR: osascript not found — banner not sent" >&2
    return 1
  fi
  "${ALERT_WATCH_OSASCRIPT:-osascript}" - "$title" "$body" <<'APPLESCRIPT'
on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
}

send_email() {
  set +x
  local subject="$1" body="$2"
  if [ -z "${RESEND_API_TOKEN:-}" ]; then
    echo "WARNING: RESEND_API_TOKEN is unset — email skipped" >&2
    return 1
  fi
  if [ -z "$EMAIL_TO" ]; then
    echo "WARNING: ALERT_EMAIL_TO is unset — email skipped" >&2
    return 1
  fi
  if ! command -v "${ALERT_WATCH_CURL:-curl}" >/dev/null 2>&1; then
    echo "ERROR: curl not found — email not sent" >&2
    return 1
  fi
  local token="$RESEND_API_TOKEN"
  local payload respfile http_code curl_rc
  payload="$(ALERT_EMAIL_FROM="$EMAIL_FROM" ALERT_EMAIL_TO="$EMAIL_TO" \
    ALERT_SUBJECT="$subject" ALERT_BODY="$body" python3 - <<'PY'
import json, os
print(json.dumps({
    "from": os.environ["ALERT_EMAIL_FROM"],
    "to": [os.environ["ALERT_EMAIL_TO"]],
    "subject": os.environ["ALERT_SUBJECT"],
    "text": os.environ["ALERT_BODY"],
}))
PY
)"
  respfile="$WORKDIR/resend-body"
  http_code=""
  curl_rc=0
  # stdin = Authorization header only; JSON body is --data (no secret).
  http_code="$(
    printf 'Authorization: Bearer %s\n' "$token" | env -u RESEND_API_TOKEN "${ALERT_WATCH_CURL:-curl}" -sS \
      --header @- \
      --header "Content-Type: application/json" \
      --data "$payload" \
      --max-time 20 \
      -o "$respfile" \
      -w '%{http_code}' \
      "https://api.resend.com/emails"
  )" || curl_rc=$?
  unset token
  if [ "$curl_rc" -ne 0 ] || [ -z "$http_code" ]; then
    echo "ERROR: Resend curl failed (exit $curl_rc, http=${http_code:-empty})" >&2
    return 1
  fi
  case "$http_code" in
    2??) return 0 ;;
    *)
      echo "ERROR: Resend HTTP $http_code" >&2
      return 1
      ;;
  esac
}

# Returns 0 if at least one channel was attempted. Sets BANNER_FAIL / EMAIL_FAIL.
BANNER_FAIL=0
EMAIL_FAIL=0

dispatch() {
  local title="$1" body="$2"
  local br=0 er=0
  send_banner "$title" "$body" || br=$?
  send_email "$title" "$body" || er=$?
  if [ "$br" -ne 0 ]; then BANNER_FAIL=1; fi
  if [ "$er" -ne 0 ]; then EMAIL_FAIL=1; fi
  if [ "$br" -eq 0 ]; then echo "banner sent: $title"; fi
  if [ "$er" -eq 0 ]; then echo "email sent: $title"; fi
  # Record per-channel success for cooldown (1 = sent).
  printf '%s\n' "banner $br" >> "$WORKDIR/dispatch.rc"
  printf '%s\n' "email $er" >> "$WORKDIR/dispatch.rc"
}

if [ "$DO_TEST" -eq 1 ]; then
  echo "=== ForteL2 alert-watch TEST ==="
  dispatch "ForteL2 TEST alert" "TEST: synthetic shakeout from alert-watch.sh --test. This is not a production condition."
  if [ "$BANNER_FAIL" -ne 0 ] || [ "$EMAIL_FAIL" -ne 0 ]; then
    echo "TEST alert finished with channel failure(s) banner_fail=$BANNER_FAIL email_fail=$EMAIL_FAIL" >&2
    exit 1
  fi
  echo "TEST alert sent on both channels"
  exit 0
fi

# --- evaluate + cooldown (python) --------------------------------------------
mkdir -p "$(dirname "$STATE_FILE")" "$WORKDIR"

# PID_DIR is assigned in lib.sh after `set +a`, so it is a shell variable, not
# an exported env var. Pass it on argv — Python never sees the shell binding.
python3 - "$FUNDING_JSON" "$STATE_FILE" "$RESOLVE_OUT" "$RESOLVE_ERR" \
  "$HEALTH_STALE_SECS" "$RESOLVE_STALE_SECS" "$SLEEP_GRACE_SECS" \
  "$REALERT_HOURS" "$LABEL" "$WORKDIR" "${ALERT_WATCH_LAUNCHCTL:-}" \
  "${ALERT_WATCH_PID_DIR:-$PID_DIR}" "$CF_PLIST" "$CF_ERR" "$CF_LABEL" \
  "${ALERT_WATCH_OP_RETH_LOG:-$LOG_DIR/op-reth.log}" \
  "${ALERT_WATCH_PROOFS_STORE:-${FORTEL2_RETH_DATADIR:-$DATA_DIR/l2/op-reth}/historical-proofs}" \
  "$PROPOSER_FACTORY" <<'PY'
import json, os, re, shutil, sys, time, subprocess, signal
import urllib.error
import urllib.parse
import urllib.request

funding_json, state_file, resolve_out, resolve_err = sys.argv[1:5]
health_stale = int(sys.argv[5])
resolve_stale = int(sys.argv[6])
sleep_grace = int(sys.argv[7])
realert_hours = float(sys.argv[8])
label = sys.argv[9]
workdir = sys.argv[10]
launchctl_bin = sys.argv[11] if len(sys.argv) > 11 else ""
pid_dir_arg = sys.argv[12] if len(sys.argv) > 12 else ""
cf_plist = sys.argv[13] if len(sys.argv) > 13 else ""
cf_err = sys.argv[14] if len(sys.argv) > 14 else ""
cf_label = sys.argv[15] if len(sys.argv) > 15 else "com.cloudflare.cloudflared"
reth_log_arg = sys.argv[16] if len(sys.argv) > 16 else ""
# Absolute path to the proofs store, resolved the same way
# 04-start-sequencer-sepolia.sh resolves it, so the two cannot drift. The
# alert must never print $DATADIR: that is script-local to the start script
# and unset in an operator shell, so the remedy would be a silent no-op.
proofs_store_arg = sys.argv[17] if len(sys.argv) > 17 else ""
PROOFS_STORE = proofs_store_arg or "$DATA_DIR/l2/op-reth/historical-proofs"
# Resolved by bash already (deployments.json or ALERT_WATCH_PROPOSER_FACTORY);
# Python never re-reads the file (D-0142).
proposer_factory_arg = sys.argv[18] if len(sys.argv) > 18 else ""
now = time.time()
_now_raw = os.environ.get("ALERT_WATCH_NOW")
if _now_raw not in (None, ""):
    try:
        now = float(_now_raw)
    except (TypeError, ValueError):
        pass
realert_secs = realert_hours * 3600.0

def load_state(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path) as fh:
            doc = json.load(fh)
        return doc if isinstance(doc, dict) else {}
    except (OSError, ValueError, TypeError):
        return {}

state = load_state(state_file)
last_check = state.get("last_check_ts")
try:
    last_check = float(last_check) if last_check is not None else None
except (TypeError, ValueError):
    last_check = None
slept = last_check is not None and (now - last_check) > sleep_grace

conditions = []

def add(cid, title, body):
    conditions.append({"id": cid, "title": title, "body": body})

# --- funding-health.json ---
if not os.path.exists(funding_json):
    add("health-stale",
        "ForteL2 health pipeline stale",
        "health pipeline stale: %s is missing — funding-watch has not written a verdict "
        "(dead health agent, or a crash before the JSON write)." % funding_json)
else:
    try:
        age = now - os.path.getmtime(funding_json)
    except OSError:
        age = health_stale + 1
    readable = True
    verdict = None
    reason = ""
    try:
        with open(funding_json) as fh:
            doc = json.load(fh)
        if not isinstance(doc, dict):
            readable = False
        else:
            verdict = doc.get("verdict")
            reason = doc.get("reason") or ""
    except (OSError, ValueError, TypeError):
        readable = False

    if not readable:
        add("health-stale",
            "ForteL2 health pipeline stale",
            "health pipeline stale: %s is unreadable — treating the verdict as unknown."
            % funding_json)
    elif age > health_stale:
        add("health-stale",
            "ForteL2 health pipeline stale",
            "health pipeline stale: %s is %.1f h old (threshold %.1f h)."
            % (funding_json, age / 3600.0, health_stale / 3600.0))
    elif verdict == "FAIL":
        add("funding-fail",
            "ForteL2 funding-watch FAIL",
            "funding-watch verdict FAIL: %s" % (reason or "(no reason in JSON)"))
    elif verdict in ("OK", "WARN", "INSUFFICIENT"):
        pass
    else:
        add("health-stale",
            "ForteL2 health pipeline stale",
            "health pipeline stale: %s has unrecognized verdict %r — treating as unknown."
            % (funding_json, verdict))

# --- resolve-games liveness ---
def log_mtime(path):
    try:
        return os.path.getmtime(path)
    except OSError:
        return None

out_m = log_mtime(resolve_out)
err_m = log_mtime(resolve_err)
newest = max([t for t in (out_m, err_m) if t is not None], default=None)

launchctl = None  # None = skipped (no binary); dict with keys found, exit_code
# Prefer ALERT_WATCH_LAUNCHCTL (test shim) so lib.sh's PATH prepend cannot
# hide it. Production: first launchctl on PATH. Never bootout/bootstrap/kickstart.
lc_bin = launchctl_bin or shutil.which("launchctl")
if lc_bin:
    uid = os.getuid()
    try:
        proc = subprocess.run(
            [lc_bin, "print", "gui/%d/%s" % (uid, label)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        proc = None
    if proc is not None:
        # Nonzero from print = "could not find service" (job unloaded).
        if proc.returncode != 0:
            launchctl = {"found": False, "exit_code": None}
        else:
            exit_code = None
            for line in proc.stdout.splitlines():
                line = line.strip()
                if line.startswith("last exit code"):
                    parts = line.split("=", 1)
                    if len(parts) == 2:
                        raw = parts[1].strip()
                        try:
                            exit_code = int(raw.split()[0])
                        except (ValueError, IndexError):
                            exit_code = None
                    break
            launchctl = {"found": True, "exit_code": exit_code}

unloaded = launchctl is not None and launchctl.get("found") is False
if unloaded:
    add("resolve-games-unloaded",
        "ForteL2 resolve-games agent unloaded",
        "resolve-games agent is not loaded in launchd (launchctl print could not "
        "find %s). Read-only check only — reload it by bootout + bootstrap of the plist."
        % label)
else:
    if newest is None:
        if not slept:
            add("resolve-games-stale",
                "ForteL2 resolve-games agent silent",
                "resolve-games agent appears dead: neither %s nor %s exists."
                % (resolve_out, resolve_err))
    elif (now - newest) > resolve_stale and not slept:
        add("resolve-games-stale",
            "ForteL2 resolve-games agent silent",
            "resolve-games agent appears dead: logs last updated %.1f h ago "
            "(threshold %.1f h, ≤ 2 hourly cycles)."
            % ((now - newest) / 3600.0, resolve_stale / 3600.0))

    streak = int(state.get("resolve_nonzero_streak") or 0)
    if launchctl is not None and launchctl.get("found") and launchctl.get("exit_code") not in (None, 0):
        streak += 1
        if streak >= 2:
            add("resolve-games-nonzero",
                "ForteL2 resolve-games agent failing",
                "resolve-games agent last exit code is %s on %d consecutive watcher "
                "runs (persistently nonzero)."
                % (launchctl.get("exit_code"), streak))
    elif launchctl is not None and launchctl.get("found"):
        streak = 0
    state["resolve_nonzero_streak"] = streak

# --- Sepolia stack presence (L2_CHAIN_ID=852 only; pidfiles, no env values) ---
def pid_running(pid_dir, name):
    path = os.path.join(pid_dir, name + ".pid")
    try:
        with open(path) as fh:
            raw = fh.read().strip()
        pid = int(raw)
    except (OSError, ValueError, TypeError):
        return False
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False

# <<<DEV_SLEEP_READER
# Installed launchd jobs are the source of truth (D-0144). This block is
# exec'd by --help as well as by the evaluator, so it carries its own
# constants and does not close over the surrounding script.
import os
_DEV_SLEEP_TZ = "America/Los_Angeles"
_DEV_SLEEP_DEFAULT_START_MIN = 23 * 60 + 45  # 23:45
_DEV_SLEEP_DEFAULT_END_MIN = 15  # 00:15
_DEV_SLEEP_LABEL_SLEEP = "com.steve.fortel2-sleep"
_DEV_SLEEP_LABEL_WAKE = "com.steve.fortel2-wake"
_DEV_SLEEP_CACHE = None

def _dev_sleep_hhmm(mins):
    hour, minute = divmod(int(mins), 60)
    return "%02d:%02d" % (hour, minute)

def _dev_sleep_plist_minutes(path):
    # Same acceptance rules as scripts/check-launchd.sh plist_calendar:
    # dict or single-element array. Missing Hour is a wildcard, not a
    # nightly boundary.
    import plistlib
    try:
        with open(path, "rb") as fh:
            data = plistlib.load(fh)
    except Exception:
        return None
    sci = data.get("StartCalendarInterval") if isinstance(data, dict) else None
    if isinstance(sci, list):
        if len(sci) != 1 or not isinstance(sci[0], dict):
            return None
        sci = sci[0]
    if not isinstance(sci, dict):
        return None
    hour = sci.get("Hour")
    minute = sci.get("Minute", 0)
    if hour is None:
        return None
    try:
        hour = int(hour)
        minute = int(minute)
    except (TypeError, ValueError):
        return None
    if hour < 0 or hour > 23 or minute < 0 or minute > 59:
        return None
    return hour * 60 + minute

def _dev_sleep_window_dict(start, end, source, agents_dir):
    if start == end:
        duration = 0
        wraps = False
    elif start > end:
        duration = (24 * 60 - start + end) * 60
        wraps = True
    else:
        duration = (end - start) * 60
        wraps = False
    return {
        "start_min": start,
        "end_min": end,
        "startLocal": _dev_sleep_hhmm(start),
        "endLocal": _dev_sleep_hhmm(end),
        "tz": _DEV_SLEEP_TZ,
        "source": source,
        "agentsDir": agents_dir,
        "wraps": wraps,
        "duration_sec": duration,
    }

def dev_sleep_window():
    global _DEV_SLEEP_CACHE
    override = os.environ.get("FORTEL2_DEV_SLEEP_AGENTS_DIR")
    if override:
        agents = override
    else:
        agents = os.path.join(os.path.expanduser("~"), "Library", "LaunchAgents")
    if _DEV_SLEEP_CACHE is not None and _DEV_SLEEP_CACHE[0] == agents:
        return _DEV_SLEEP_CACHE[1]
    sleep_min = _dev_sleep_plist_minutes(
        os.path.join(agents, _DEV_SLEEP_LABEL_SLEEP + ".plist")
    )
    wake_min = _dev_sleep_plist_minutes(
        os.path.join(agents, _DEV_SLEEP_LABEL_WAKE + ".plist")
    )
    if sleep_min is None or wake_min is None or sleep_min == wake_min:
        window = _dev_sleep_window_dict(
            _DEV_SLEEP_DEFAULT_START_MIN,
            _DEV_SLEEP_DEFAULT_END_MIN,
            "default",
            None,
        )
    else:
        window = _dev_sleep_window_dict(sleep_min, wake_min, "launchd", agents)
    _DEV_SLEEP_CACHE = (agents, window)
    return window

def _minutes_in_dev_sleep(mins, start, end):
    # Inclusive start, exclusive end. start > end wraps midnight.
    # start < end must NOT use `mins >= start or mins < end` — that is
    # true from `start` through the end of the day (D-0144 §7).
    if start == end:
        return False
    if start > end:
        return mins >= start or mins < end
    return mins >= start and mins < end

def in_dev_sleep_window(now_ts):
    try:
        from datetime import datetime
        from zoneinfo import ZoneInfo
        local = datetime.fromtimestamp(float(now_ts), ZoneInfo(_DEV_SLEEP_TZ))
    except Exception:
        return False
    window = dev_sleep_window()
    mins = local.hour * 60 + local.minute
    return _minutes_in_dev_sleep(mins, window["start_min"], window["end_min"])

def seconds_since_dev_sleep_end(now_ts):
    """Seconds since the most recent configured wake at or before now_ts."""
    from datetime import datetime, timedelta
    from zoneinfo import ZoneInfo
    window = dev_sleep_window()
    eh, em = divmod(window["end_min"], 60)
    tz = ZoneInfo(window["tz"])
    local = datetime.fromtimestamp(float(now_ts), tz)
    end_local = datetime(local.year, local.month, local.day, eh, em, tzinfo=tz)
    end_ts = end_local.timestamp()
    if end_ts > float(now_ts):
        prev = local.date() - timedelta(days=1)
        end_local = datetime(prev.year, prev.month, prev.day, eh, em, tzinfo=tz)
        end_ts = end_local.timestamp()
    return float(now_ts) - end_ts
# >>>DEV_SLEEP_READER

def interval_touches_dev_sleep(t0, t1):
    """True if [t0, t1] lies wholly or partly inside the resolved window.

    Endpoints-only is the D-0141 trap: both ends can be awake while the
    middle still spans the freeze.
    """
    try:
        lo = float(t0)
        hi = float(t1)
    except (TypeError, ValueError):
        return False
    if lo > hi:
        lo, hi = hi, lo
    if (hi - lo) >= 24 * 3600:
        return True
    t = lo
    while t <= hi:
        if in_dev_sleep_window(t):
            return True
        t += 60.0
    return in_dev_sleep_window(hi)

def replica_losing_sleep_suppressed(prev_obs, now_ts):
    """Do not advance replica_losing_streak (D-0141 / D-0144).

    Reuses in_dev_sleep_window. Recovery grace is one watcher cycle (the
    hourly probe, 3600 s) after the configured wake — the window's end —
    not a lookback that assumes the wake is 03:00. A 30-minute window
    ending at 00:15 does not contain 23:30, so `in_dev_sleep_window(now-3600)`
    misses the 00:30 probe.
    """
    if prev_obs is None:
        return False
    if interval_touches_dev_sleep(prev_obs, now_ts):
        return True
    try:
        since = seconds_since_dev_sleep_end(now_ts)
    except Exception:
        return False
    # Exclusive at one full cycle: exactly 3600 s after the wake is awake
    # for streak purposes, matching the old exclusive end+3600 boundary.
    if 0 <= since < 3600.0:
        return True
    return False

l2_chain = os.environ.get("L2_CHAIN_ID") or ""
# Argv from bash (ALERT_WATCH_PID_DIR override, else the shell's PID_DIR).
# Do not read PID_DIR from os.environ — lib.sh assigns it after set +a.
pid_dir = pid_dir_arg or ""
expect_override = os.environ.get("ALERT_WATCH_EXPECT_STACK") or ""
# Presence only — never print CHALLENGER_L1_RPC_URL (D-0049).
want_proxy = bool((os.environ.get("CHALLENGER_L1_RPC_URL") or "").strip())
# Existing helper tests inherit L2_CHAIN_ID=852 from earlier cases while
# pointing FORTEL2_ENV at a throwaway fixture. Production launchd sets
# FORTEL2_ENV=.env.sepolia. Test fixtures opt in via ALERT_WATCH_PID_DIR
# or ALERT_WATCH_EXPECT_STACK.
fortel2_env = os.environ.get("FORTEL2_ENV") or ""
sepolia_env = "sepolia" in fortel2_env.lower()
test_hook = bool(os.environ.get("ALERT_WATCH_PID_DIR") or expect_override)

EXEX_TAIL_DEFAULT = 65536
EXEX_PANIC_MARKERS = (
    "Critical task `exex` panicked",
    "ExEx proofs-history crashed",
)
_EXEX_START_RE = re.compile(r"reth\b.*\bstarting\b", re.IGNORECASE)

def _exex_tail_bytes():
    raw = os.environ.get("ALERT_WATCH_EXEX_TAIL_BYTES")
    if raw is None or str(raw).strip() == "":
        return EXEX_TAIL_DEFAULT
    try:
        n = int(str(raw).strip())
        return n if n > 0 else EXEX_TAIL_DEFAULT
    except (TypeError, ValueError):
        return EXEX_TAIL_DEFAULT

def _exex_log_path():
    # Canned path wins. Evaluation fixtures (CURL/LAUNCHCTL) must never
    # open the host op-reth.log — every existing runner sets those hooks.
    canned = os.environ.get("ALERT_WATCH_OP_RETH_LOG")
    if canned not in (None, ""):
        return canned
    if os.environ.get("ALERT_WATCH_CURL") or os.environ.get("ALERT_WATCH_LAUNCHCTL"):
        return None
    return reth_log_arg or None

def _exex_last_start(text):
    last = -1
    for m in _EXEX_START_RE.finditer(text):
        last = m.start()
    needle = "Starting op-reth"
    idx = 0
    while True:
        i = text.find(needle, idx)
        if i < 0:
            break
        if i > last:
            last = i
        idx = i + 1
    return last

def _exex_last_panic(text):
    last = -1
    for needle in EXEX_PANIC_MARKERS:
        idx = 0
        while True:
            i = text.find(needle, idx)
            if i < 0:
                break
            if i > last:
                last = i
            idx = i + 1
    return last

def _exex_quote(snippet):
    # Keep the END of the panic-local snippet. Classification still looks
    # 1500 bytes backward (reth prints the crash before "Critical task
    # `exex` panicked"); the quote must not start at that look-back, and
    # must not be the last 240 of a window that extends 500 bytes past
    # the marker (shutdown lines would displace the panic).
    one = re.sub(r"\s+", " ", snippet).strip()
    if len(one) > 240:
        one = "…" + one[-240:]
    return one

def _exex_body_from_region(region):
    idx = _exex_last_panic(region)
    if idx < 0:
        return ""
    lo = max(0, idx - 1500)
    hi = min(len(region), idx + 500)
    ctx = region[lo:hi]
    panic_at = idx - lo
    quote = _exex_quote(ctx[max(0, panic_at - 200): min(len(ctx), panic_at + 80)])
    # Opposite remedies (D-0114 F3 vs D-0138). Classify from the LAST panic
    # in the recency window, never from an earlier line in the same tail.
    if "Parent hash mismatch" in ctx:
        return (
            " ExEx cause: divergent historical-proofs store (Parent hash mismatch). "
            "Matched: %s. Remedy: stop the stack, delete %s, "
            "then start. Do not run op-reth proofs init — that is a no-op on a "
            "divergent store."
        ) % (quote, PROOFS_STORE)
    if "Proofs storage not initialized" in ctx:
        return (
            " ExEx cause: proofs store not initialized. "
            "Matched: %s. Remedy: op-reth proofs init (the start script already "
            "does this idempotently). Do not delete %s."
        ) % (quote, PROOFS_STORE)
    return (
        " ExEx cause: Critical task `exex` panicked (unclassified). "
        "Matched: %s. Do not guess between proofs init and deleting "
        "historical-proofs — read the matched line."
    ) % quote

def exex_hint(missing_names):
    """Symptom detail only — never the detector. Silent unless op-reth is down."""
    if (os.environ.get("ALERT_WATCH_EXEX_THROW") or "") == "1":
        raise RuntimeError("ALERT_WATCH_EXEX_THROW")
    el = (os.environ.get("FORTEL2_EL") or "geth").strip()
    if el != "reth":
        return ""
    if "op-reth" not in (missing_names or []):
        return ""
    path = _exex_log_path()
    if not path:
        return ""
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            window = _exex_tail_bytes()
            fh.seek(max(0, size - window))
            raw = fh.read(window)
    except OSError:
        return ""
    try:
        text = raw.decode("utf-8", "replace")
    except (ValueError, TypeError, UnicodeDecodeError):
        return ""
    start_at = _exex_last_start(text)
    region = text[start_at:] if start_at >= 0 else text
    return _exex_body_from_region(region)

stack_missing_names = []
if l2_chain == "852" and pid_dir and (sepolia_env or test_hook):
    el = (os.environ.get("FORTEL2_EL") or "geth").strip()
    el_pid = "op-reth" if el == "reth" else "op-geth"
    expected = [
        el_pid, "op-node", "op-batcher", "op-proposer",
        "l2-rpc-filter", "op-challenger",
    ]
    if want_proxy:
        expected.append("l1-batch-proxy")
    present = [n for n in expected if pid_running(pid_dir, n)]
    missing = [n for n in expected if n not in present]
    stack_missing_names = missing
    if expect_override == "1":
        want_up = True
    elif expect_override == "0":
        want_up = False
    else:
        want_up = not in_dev_sleep_window(now)
    if present and missing:
        add("stack-missing",
            "ForteL2 stack service missing",
            "Sepolia stack is partially up; not running: %s."
            % ", ".join(missing))
    elif missing and want_up:
        _sleep = dev_sleep_window()
        _sleep_how = (
            "measured from launchd" if _sleep["source"] == "launchd"
            else "assumed default"
        )
        add("stack-down",
            "ForteL2 stack is down",
            "Sepolia stack is not running outside the %s-%s PT sleep "
            "window (%s): %s."
            % (_sleep["startLocal"], _sleep["endLocal"], _sleep_how,
               ", ".join(missing)))

# Isolated so a missing/unreadable log or a throw cannot skip cloudflared,
# replica, or the stack conditions already recorded. Process state is the
# trigger; the log is never a standalone page.
try:
    _exex = exex_hint(stack_missing_names)
    if _exex:
        for _c in conditions:
            if _c["id"] in ("stack-missing", "stack-down"):
                _c["body"] = _c["body"] + _exex
except Exception:
    pass

# --- cloudflared system daemon (plist present = this host runs the tunnel) ---
# Absence is not an alert. Unparseable print with plist present fails toward
# alerting. No sleep-grace: KeepAlive 24/7, not a calendar agent.
def parse_cf_print(stdout):
    """Defensive parse of `launchctl print` (format varies across macOS).

    Returns (state, exit_code, runs) where state is 'running', 'not running',
    or None (unparseable), and exit_code / runs are int or None.
    """
    state = None
    exit_code = None
    runs = None
    if not stdout:
        return None, None, None
    for line in stdout.splitlines():
        line = line.strip()
        lower = line.lower()
        if lower.startswith("state =") or lower.startswith("state="):
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            raw = parts[1].strip().lower()
            if "not running" in raw:
                state = "not running"
            elif "running" in raw:
                state = "running"
            # other values (waiting, spawned, …) stay None → unparseable
        elif lower.startswith("last exit code"):
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            raw = parts[1].strip()
            try:
                exit_code = int(raw.split()[0])
            except (ValueError, IndexError):
                exit_code = None
        elif lower.startswith("runs =") or lower.startswith("runs="):
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            raw = parts[1].strip()
            try:
                runs = int(raw.split()[0])
            except (ValueError, IndexError):
                runs = None
    return state, exit_code, runs

def cf_token_hint(path):
    """Symptom detail only — never the detector. Token file itself is root-only."""
    if not path:
        return ""
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - 65536))
            text = fh.read().decode("utf-8", "replace")
    except OSError:
        return ""
    if "Failed to read token file" in text:
        return (
            " Likely cause: token file missing (err log: Failed to read token file)."
        )
    return ""

if cf_plist and os.path.exists(cf_plist):
    cf_print_ok = False
    cf_stdout = ""
    cf_lc = launchctl_bin or shutil.which("launchctl")
    if cf_lc:
        try:
            cf_proc = subprocess.run(
                [cf_lc, "print", "system/%s" % cf_label],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                universal_newlines=True, timeout=10,
            )
        except (OSError, subprocess.TimeoutExpired):
            cf_proc = None
        if cf_proc is not None and cf_proc.returncode == 0:
            cf_print_ok = True
            cf_stdout = cf_proc.stdout or ""
    cf_state, cf_exit, cf_runs = parse_cf_print(cf_stdout)
    # Unhealthy: print missing/unparseable, or any not-running state.
    # KeepAlive SuccessfulExit=false: a clean exit is never restarted.
    # Last exit code is body detail, not a gate.
    cf_unhealthy = False
    if not cf_print_ok:
        cf_unhealthy = True
        cf_why = (
            "launchctl print system/%s missing or failed — cannot determine "
            "daemon state." % cf_label
        )
    elif cf_state is None:
        cf_unhealthy = True
        cf_why = (
            "launchctl print system/%s output unparseable — cannot determine "
            "daemon state (fail toward alerting)." % cf_label
        )
    elif cf_state == "not running":
        cf_unhealthy = True
        if cf_exit is None:
            cf_exit_disp = "unparseable"
        else:
            cf_exit_disp = str(cf_exit)
        cf_why = (
            "system/%s is not running (last exit code %s)."
            % (cf_label, cf_exit_disp)
        )
    elif cf_state not in ("running", "not running"):
        cf_unhealthy = True
        cf_why = (
            "system/%s state %r is not a known running/not-running value."
            % (cf_label, cf_state)
        )
    if cf_unhealthy:
        add("cloudflared-failing",
            "ForteL2 cloudflared tunnel failing",
            "cloudflared system daemon is unhealthy: %s%s"
            % (cf_why, cf_token_hint(cf_err)))

    # Distinct cooldown keys. Never sleep-grace. Never probe :9555 or the
    # write hostname — edge count is the predicate while origin is asleep.
    CF_RESTART_FLOOR = 1  # exclusive: delta > 1 fires; +1 is a legit restart
    CF_METRICS_DEFAULT = "http://127.0.0.1:20241/metrics"
    _cf_metrics_re = re.compile(
        r"Starting metrics server on (\S+):(\d+)/metrics"
    )

    def _cf_env_int(name, default):
        raw = os.environ.get(name)
        if raw is None or str(raw).strip() == "":
            return default
        try:
            return int(str(raw).strip())
        except (TypeError, ValueError):
            return default

    def _cf_test_offline():
        return bool(
            os.environ.get("ALERT_WATCH_CURL")
            or os.environ.get("ALERT_WATCH_LAUNCHCTL")
            or os.environ.get("ALERT_WATCH_CLOUDFLARED_METRICS") not in (None, "")
            or os.environ.get("ALERT_WATCH_CLOUDFLARED_RUNS") not in (None, "")
            or (os.environ.get("ALERT_WATCH_CLOUDFLARED_UNREACHABLE") or "") == "1"
            or (os.environ.get("ALERT_WATCH_CLOUDFLARED_THROW") or "") == "1"
        )

    def parse_ha_connections(text):
        """Last cloudflared_tunnel_ha_connections sample, or None if missing/garbage."""
        if not text:
            return None
        found = None
        for line in text.splitlines():
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            name = s.split("{", 1)[0].split()[0]
            if name != "cloudflared_tunnel_ha_connections":
                continue
            try:
                found = int(float(s.split()[-1]))
            except (ValueError, IndexError, TypeError):
                return None
        return found

    def cf_metrics_url_from_err(path):
        """Loopback metrics URL from the err-log start line; else the default.

        A moved port with no matching log line keeps the default; the GET then
        fails and degrades to cloudflared-metrics-unreachable (two consecutive).
        Non-loopback hosts in the log are rewritten to 127.0.0.1 on the same
        port so this watcher never leaves loopback.
        """
        text = ""
        if path:
            try:
                with open(path, "rb") as fh:
                    fh.seek(0, os.SEEK_END)
                    size = fh.tell()
                    fh.seek(max(0, size - 65536))
                    text = fh.read().decode("utf-8", "replace")
            except OSError:
                text = ""
        matches = _cf_metrics_re.findall(text)
        if not matches:
            return CF_METRICS_DEFAULT
        host, port = matches[-1]
        host = host.strip("[]")
        if host in ("0.0.0.0", "::", ""):
            host = "127.0.0.1"
        elif host not in ("127.0.0.1", "localhost", "::1"):
            host = "127.0.0.1"
        if host == "::1":
            return "http://[::1]:%s/metrics" % port
        return "http://%s:%s/metrics" % (host, port)

    def probe_cf_metrics():
        """Return ha_connections int, or None on a failed read. THROW raises."""
        if (os.environ.get("ALERT_WATCH_CLOUDFLARED_THROW") or "") == "1":
            raise RuntimeError("ALERT_WATCH_CLOUDFLARED_THROW")
        if (os.environ.get("ALERT_WATCH_CLOUDFLARED_UNREACHABLE") or "") == "1":
            return None
        canned = os.environ.get("ALERT_WATCH_CLOUDFLARED_METRICS")
        if canned not in (None, "") or _cf_test_offline():
            if canned in (None, ""):
                canned = "cloudflared_tunnel_ha_connections 4"
            return parse_ha_connections(canned)

        url = cf_metrics_url_from_err(cf_err)
        timeout = _cf_env_int("ALERT_WATCH_CLOUDFLARED_TIMEOUT", 5)
        req = urllib.request.Request(
            url,
            headers={"Accept": "text/plain"},
            method="GET",
        )

        def _cf_deadline(signum, frame):
            raise TimeoutError("cloudflared metrics total deadline")

        prev_handler = signal.signal(signal.SIGALRM, _cf_deadline)
        signal.setitimer(signal.ITIMER_REAL, timeout)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read(65536)
        except (urllib.error.URLError, TimeoutError, OSError, ValueError):
            return None
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, prev_handler)
        try:
            text = raw.decode("utf-8", "replace")
        except (ValueError, TypeError, UnicodeDecodeError):
            return None
        return parse_ha_connections(text)

    runs_raw = os.environ.get("ALERT_WATCH_CLOUDFLARED_RUNS")
    observed_runs = cf_runs
    if runs_raw not in (None, ""):
        try:
            observed_runs = int(str(runs_raw).strip())
        except (TypeError, ValueError):
            observed_runs = None
    prev_runs = state.get("cloudflared_last_runs")
    try:
        prev_runs = int(prev_runs) if prev_runs is not None else None
    except (TypeError, ValueError):
        prev_runs = None
    if observed_runs is not None and prev_runs is not None:
        delta = observed_runs - prev_runs
        if delta > CF_RESTART_FLOOR:
            add("cloudflared-restart-storm",
                "ForteL2 cloudflared restart storm",
                "cloudflared launchd runs counter climbed by %d between watcher "
                "runs (floor %d, exclusive; a single legitimate restart is quiet). "
                "previous %s current %s. KeepAlive 24/7, no Mac-sleep grace."
                % (delta, CF_RESTART_FLOOR, prev_runs, observed_runs))
    if observed_runs is not None:
        state["cloudflared_last_runs"] = observed_runs

    # Metrics / zero-edge only while the job reports running — down daemons
    # are already cloudflared-failing; probing them would double-page as
    # metrics-unreachable. Isolated so throw/timeout cannot skip replica etc.
    if not cf_unhealthy and cf_state == "running":
        try:
            ha = probe_cf_metrics()
            if ha is None:
                streak = int(state.get("cloudflared_metrics_unreachable_streak") or 0) + 1
                state["cloudflared_metrics_unreachable_streak"] = streak
                if streak >= 2:
                    add("cloudflared-metrics-unreachable",
                        "ForteL2 cloudflared metrics unreachable",
                        "cloudflared loopback metrics failed %d consecutive watcher "
                        "runs (timeout, HTTP failure, garbage, or missing "
                        "cloudflared_tunnel_ha_connections). last successful edge "
                        "sample is not required. KeepAlive 24/7, no Mac-sleep grace."
                        % streak)
            else:
                state["cloudflared_metrics_unreachable_streak"] = 0
                if ha == 0:
                    add("cloudflared-no-edge",
                        "ForteL2 cloudflared has no edge connections",
                        "cloudflared is running but cloudflared_tunnel_ha_connections "
                        "is 0 — the process is up and the write hostname is dark. "
                        "loopback metrics only; origin :9555 is not probed (nightly "
                        "sleep window is expected). KeepAlive 24/7, no Mac-sleep grace.")
        except Exception:
            streak = int(state.get("cloudflared_metrics_unreachable_streak") or 0) + 1
            state["cloudflared_metrics_unreachable_streak"] = streak
            if streak >= 2:
                add("cloudflared-metrics-unreachable",
                    "ForteL2 cloudflared metrics unreachable",
                    "cloudflared loopback metrics raised on %d consecutive watcher "
                    "runs. other conditions still evaluated. KeepAlive 24/7, no "
                    "Mac-sleep grace." % streak)
else:
    state["cloudflared_last_runs"] = None
    state["cloudflared_metrics_unreachable_streak"] = 0

# --- public replica liveness (Render; no Mac-sleep grace) ---
# Head-timestamp age and its trend only. Do not compare to the sequencer.
# One eth_getBlockByNumber(latest). Never QuickNode, Access, or loopback.
_replica_url_override = (os.environ.get("ALERT_WATCH_REPLICA_RPC_URL") or "").strip()
REPLICA_RPC_URL = _replica_url_override or "https://fortel2-replica-rpc.onrender.com"

def _env_int(name, default):
    raw = os.environ.get(name)
    if raw is None or str(raw).strip() == "":
        return default
    try:
        return int(str(raw).strip())
    except (TypeError, ValueError):
        return default

def _rpc_int(raw):
    if raw is None:
        return None
    if isinstance(raw, bool):
        return None
    if isinstance(raw, int):
        return raw
    s = str(raw).strip()
    if s == "":
        return None
    try:
        if s.startswith("0x") or s.startswith("0X"):
            return int(s, 16)
        return int(s)
    except (TypeError, ValueError):
        return None

replica_stale_secs = _env_int(
    "ALERT_WATCH_REPLICA_STALE_SECS",
    _env_int("REPLICA_HEAD_STALE_SECS", 10800),
)
replica_noise_secs = _env_int(
    "ALERT_WATCH_REPLICA_NOISE_SECS",
    _env_int("REPLICA_TREND_NOISE_SECS", 600),
)
REPLICA_RPC_TIMEOUT = _env_int("ALERT_WATCH_REPLICA_TIMEOUT", 15)

def probe_replica_head():
    """Return {number, timestamp} or None on a failed probe. THROW raises."""
    if (os.environ.get("ALERT_WATCH_REPLICA_THROW") or "") == "1":
        raise RuntimeError("ALERT_WATCH_REPLICA_THROW")
    if (os.environ.get("ALERT_WATCH_REPLICA_UNREACHABLE") or "") == "1":
        return None
    num_raw = os.environ.get("ALERT_WATCH_REPLICA_HEAD_NUMBER")
    ts_raw = os.environ.get("ALERT_WATCH_REPLICA_HEAD_TS")
    age_raw = os.environ.get("ALERT_WATCH_REPLICA_HEAD_AGE")
    canned = (
        num_raw not in (None, "")
        or ts_raw not in (None, "")
        or age_raw not in (None, "")
    )
    # Resend test shim on PATH/ALERT_WATCH_CURL returns {"id":"mock-resend"}
    # for every URL. Never live-curl the gateway from an evaluation fixture.
    test_offline = bool(os.environ.get("ALERT_WATCH_CURL"))
    if canned or test_offline:
        if age_raw not in (None, ""):
            try:
                ts = now - float(age_raw)
            except (TypeError, ValueError):
                return None
        elif ts_raw in (None, "", "now"):
            ts = now
        else:
            try:
                ts = float(ts_raw)
            except (TypeError, ValueError):
                return None
        number = _rpc_int(num_raw)
        if number is None:
            number = 1
        return {"number": number, "timestamp": ts}

    payload = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_getBlockByNumber",
        "params": ["latest", False],
    }).encode("utf-8")
    req = urllib.request.Request(
        REPLICA_RPC_URL,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="POST",
    )
    def _replica_deadline(signum, frame):
        raise TimeoutError("replica probe total deadline")
    prev_handler = signal.signal(signal.SIGALRM, _replica_deadline)
    signal.setitimer(signal.ITIMER_REAL, REPLICA_RPC_TIMEOUT)
    try:
        with urllib.request.urlopen(req, timeout=REPLICA_RPC_TIMEOUT) as resp:
            raw = resp.read(65536)
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        return None
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, prev_handler)
    try:
        doc = json.loads(raw.decode("utf-8"))
    except (ValueError, TypeError, UnicodeDecodeError):
        return None
    if not isinstance(doc, dict):
        return None
    result = doc.get("result")
    if not isinstance(result, dict):
        return None
    ts = _rpc_int(result.get("timestamp"))
    if ts is None:
        return None
    number = _rpc_int(result.get("number"))
    if number is None:
        number = 0
    return {"number": number, "timestamp": float(ts)}

def replica_fail(why):
    # Do not overwrite replica_last_ok — trend depends on the last success.
    streak = int(state.get("replica_unreachable_streak") or 0) + 1
    state["replica_unreachable_streak"] = streak
    if streak >= 2:
        add("replica-unreachable",
            "ForteL2 public replica unreachable",
            "public replica JSON-RPC failed %d consecutive watcher runs (%s). "
            "gateway %s. last successful head sample is unchanged."
            % (streak, why, REPLICA_RPC_URL))

def replica_ok(sample):
    state["replica_unreachable_streak"] = 0
    head_ts = float(sample["timestamp"])
    number = sample.get("number")
    age = now - head_ts
    prev = state.get("replica_last_ok")
    prev_obs = prev_ts = None
    if isinstance(prev, dict):
        try:
            prev_obs = float(prev.get("observed_at"))
            prev_ts = float(prev.get("head_ts"))
        except (TypeError, ValueError):
            prev_obs = prev_ts = None
    lg_streak = int(state.get("replica_losing_streak") or 0)
    if prev_obs is not None and prev_ts is not None:
        prev_age = prev_obs - prev_ts
        delta = age - prev_age
        # Exclusive: jitter of exactly the floor is not losing ground.
        # Floor sits above one batcher channel (~360 s sawtooth) and far
        # below an hourly freeze (~3600 s). One grown delta is a redeploy
        # replay, not an outage; two consecutive such deltas are. A
        # recovery (delta <= floor) resets the streak.
        if delta > replica_noise_secs:
            if replica_losing_sleep_suppressed(prev_obs, now):
                pass
            else:
                lg_streak = lg_streak + 1
        else:
            lg_streak = 0
        state["replica_losing_streak"] = lg_streak
        if lg_streak >= 2:
            add("replica-losing-ground",
                "ForteL2 public replica losing ground",
                "public replica head age grew by %.0f s on %d consecutive "
                "successful probes (noise floor %d s, exclusive; intervals "
                "that overlap %s-%s PT and the first probe within one "
                "watcher cycle after the wake do not count). current age "
                "%.0f s (head %s); previous age %.0f s. gateway %s."
                % (delta, lg_streak, replica_noise_secs,
                   dev_sleep_window()["startLocal"],
                   dev_sleep_window()["endLocal"],
                   age, number, prev_age, REPLICA_RPC_URL))
    else:
        state["replica_losing_streak"] = 0
    if age > replica_stale_secs:
        add("replica-head-stale",
            "ForteL2 public replica head stale",
            "public replica head is %.0f s old (threshold %d s, exclusive). "
            "head %s. gateway %s. backstop when trend has no prior sample."
            % (age, replica_stale_secs, number, REPLICA_RPC_URL))
    state["replica_last_ok"] = {
        "observed_at": now,
        "head_ts": head_ts,
        "head_number": number,
    }

try:
    replica_sample = probe_replica_head()
    if replica_sample is None:
        replica_fail("timeout, HTTP failure, or garbage JSON")
    else:
        replica_ok(replica_sample)
except Exception as exc:
    replica_fail("probe error: %s" % type(exc).__name__)

# --- proposer overdue liveness (D-0142) — own hourly L1 read, own metered dep ---
# The FIRST metered dependency in this watcher (disclosed in D-0142): two
# eth_calls per run against L1_RPC_URL (gameCount + gameAtIndex), separate
# from pipeline-snapshot.py's daily scan. Never QuickNode-specific and never
# a claim about which provider is configured — L1_RPC_URL is whatever the
# active env already points at.
_PROPOSER_DURATION_RE = re.compile(r"^(\d+)(h|m|s)$")

def parse_proposer_interval(raw):
    """'8h' / '30m' / '12s' -> seconds. None if unparseable — never a silent
    default that disagrees with what the proposer is actually running."""
    if raw is None:
        return None
    m = _PROPOSER_DURATION_RE.match(str(raw).strip())
    if not m:
        return None
    unit_secs = {"h": 3600, "m": 60, "s": 1}[m.group(2)]
    return int(m.group(1)) * unit_secs

# SEPOLIA_PROPOSER_INTERVAL only — the legacy PROPOSER_INTERVAL key is a
# Phase-1 Anvil knob that 06-start-proposer-sepolia.sh already ignores.
PROPOSER_INTERVAL_RAW = os.environ.get("SEPOLIA_PROPOSER_INTERVAL") or "8h"
PROPOSER_INTERVAL_SECS = parse_proposer_interval(PROPOSER_INTERVAL_RAW)
# Assigned, not derived (D-0142): observed jitter ~2 min; 2 h is ~60x that.
PROPOSER_OVERDUE_GRACE_SECS = 2 * 3600
PROPOSER_RPC_TIMEOUT = _env_int("ALERT_WATCH_PROPOSER_TIMEOUT", 15)

# <<<AWAKE_SECONDS
def awake_seconds(t0, t1):
    """[t0, t1] minus every resolved nightly window it overlaps (the §7
    trap — a proposer silent for 30h must have TWO windows removed, not
    one). Reuses in_dev_sleep_window(), already defined above. Window
    length comes from those boundaries (D-0144), not a fixed 3 h 15 m.
    """
    try:
        lo = float(t0)
        hi = float(t1)
    except (TypeError, ValueError):
        return 0.0
    if lo > hi:
        lo, hi = hi, lo
    total = hi - lo
    if total <= 0:
        return 0.0
    if total >= 30 * 24 * 3600:
        return total  # defensive cap; never seen in practice
    step = 60.0
    t = lo
    sleep_secs = 0.0
    while t < hi:
        seg_end = t + step if t + step < hi else hi
        if in_dev_sleep_window(t):
            sleep_secs += seg_end - t
        t = seg_end
    return max(0.0, total - sleep_secs)
# >>>AWAKE_SECONDS

def _redact_l1_url(url):
    try:
        p = urllib.parse.urlparse(url or "")
    except Exception:
        return "<unparseable>"
    netloc = p.hostname or ""
    if p.port:
        netloc = "%s:%s" % (netloc, p.port)
    path = "/…" if p.path and p.path != "/" else ""
    return "%s://%s%s" % (p.scheme, netloc, path)

L1_RPC_URL = os.environ.get("L1_RPC_URL") or ""

def proposer_eth_call(data):
    payload = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_call",
        "params": [{"to": proposer_factory_arg, "data": data}, "latest"],
    }).encode("utf-8")
    req = urllib.request.Request(
        L1_RPC_URL,
        data=payload,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    def _proposer_deadline(signum, frame):
        raise TimeoutError("proposer L1 read total deadline")
    prev_handler = signal.signal(signal.SIGALRM, _proposer_deadline)
    signal.setitimer(signal.ITIMER_REAL, PROPOSER_RPC_TIMEOUT)
    try:
        with urllib.request.urlopen(req, timeout=PROPOSER_RPC_TIMEOUT) as resp:
            raw = resp.read(65536)
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, prev_handler)
    doc = json.loads(raw.decode("utf-8"))
    if not isinstance(doc, dict) or doc.get("error"):
        return None
    return doc.get("result")

def probe_proposer_latest():
    """Return {'index', 'timestamp'} or None ("cannot determine"). THROW raises."""
    if (os.environ.get("ALERT_WATCH_PROPOSER_THROW") or "") == "1":
        raise RuntimeError("ALERT_WATCH_PROPOSER_THROW")
    if (os.environ.get("ALERT_WATCH_PROPOSER_UNREACHABLE") or "") == "1":
        return None
    canned_count = os.environ.get("ALERT_WATCH_PROPOSER_GAME_COUNT")
    canned_idx = os.environ.get("ALERT_WATCH_PROPOSER_LATEST_INDEX")
    canned_ts = os.environ.get("ALERT_WATCH_PROPOSER_LATEST_TS")
    canned_age = os.environ.get("ALERT_WATCH_PROPOSER_LATEST_AGE")
    canned = any(
        v not in (None, "") for v in (canned_count, canned_idx, canned_ts, canned_age)
    )
    # Resend test shim on PATH/ALERT_WATCH_CURL returns {"id":"mock-resend"}
    # for every URL; never live-eth_call from an evaluation fixture.
    test_offline = bool(os.environ.get("ALERT_WATCH_CURL"))
    if canned or test_offline:
        count = _rpc_int(canned_count)
        if count is None:
            count = 1
        if count == 0:
            return None
        idx = _rpc_int(canned_idx)
        if idx is None:
            idx = count - 1
        if canned_age not in (None, ""):
            try:
                ts = now - float(canned_age)
            except (TypeError, ValueError):
                return None
        elif canned_ts in (None, "", "now"):
            ts = now
        else:
            try:
                ts = float(canned_ts)
            except (TypeError, ValueError):
                return None
        return {"index": idx, "timestamp": ts}
    if not proposer_factory_arg:
        return None
    try:
        raw_count = proposer_eth_call("0x4d1975b4")
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        return None
    count = _rpc_int(raw_count)
    if not count:
        return None
    idx = count - 1
    data = "0xbb8aa1fc" + ("%064x" % idx)
    try:
        raw_game = proposer_eth_call(data)
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        return None
    if not raw_game or raw_game == "0x" or len(raw_game) < 2 + 64 * 3:
        return None
    h = raw_game[2:]
    try:
        ts = int(h[64:128], 16)
    except ValueError:
        return None
    return {"index": idx, "timestamp": float(ts)}

def proposer_fail(why):
    streak = int(state.get("proposer_unreachable_streak") or 0) + 1
    state["proposer_unreachable_streak"] = streak
    if streak >= 2:
        add("proposer-overdue",
            "ForteL2 proposer liveness unverifiable",
            "proposer-overdue could not be evaluated on %d consecutive "
            "watcher runs (%s). L1 read against %s; configured interval %s. "
            "This is not a claim the proposer IS overdue — only that "
            "liveness could not be verified."
            % (streak, why, _redact_l1_url(L1_RPC_URL), PROPOSER_INTERVAL_RAW))

def proposer_ok(sample):
    if PROPOSER_INTERVAL_SECS is None:
        # Unparseable interval is also "cannot determine" (P1's third state);
        # route it through the same quiet-then-fire streak as a failed read.
        # Do NOT reset the streak first — that would erase the very count
        # this failure path is supposed to grow.
        proposer_fail(
            "configured SEPOLIA_PROPOSER_INTERVAL=%r is unparseable"
            % PROPOSER_INTERVAL_RAW
        )
        return
    state["proposer_unreachable_streak"] = 0
    idx = sample["index"]
    ts = sample["timestamp"]
    age = now - ts
    awake_age = awake_seconds(ts, now)
    threshold = PROPOSER_INTERVAL_SECS + PROPOSER_OVERDUE_GRACE_SECS
    # Exclusive: exactly at the threshold is quiet, one second past fires.
    if awake_age > threshold:
        add("proposer-overdue",
            "ForteL2 proposer overdue",
            "proposer game index %d is %.0f s old (%.0f s excluding the "
            "nightly %s-%s PT sleep window, however many windows that "
            "spans; %s). threshold is configured interval %s (%d s) + 2 h grace "
            "= %d s, exclusive."
            % (idx, age, awake_age,
               dev_sleep_window()["startLocal"], dev_sleep_window()["endLocal"],
               "measured from launchd" if dev_sleep_window()["source"] == "launchd"
               else "assumed default",
               PROPOSER_INTERVAL_RAW, PROPOSER_INTERVAL_SECS, threshold))

try:
    proposer_sample = probe_proposer_latest()
    if proposer_sample is None:
        proposer_fail("no games proposed yet, missing factory, or a garbage/timeout L1 read")
    else:
        proposer_ok(proposer_sample)
except Exception as exc:
    proposer_fail("probe error: %s" % type(exc).__name__)

# --- cooldown filter (per condition × channel) ---
cd = state.get("cooldown")
if not isinstance(cd, dict):
    cd = {}

def cooled(cid, channel):
    rec = cd.get(cid)
    if not isinstance(rec, dict):
        return False
    ts = rec.get(channel)
    try:
        ts = float(ts)
    except (TypeError, ValueError):
        return False
    return (now - ts) < realert_secs

to_send = []
for c in conditions:
    entry = {"id": c["id"], "title": c["title"], "body": c["body"],
             "banner": not cooled(c["id"], "banner"),
             "email": not cooled(c["id"], "email")}
    if entry["banner"] or entry["email"]:
        to_send.append(entry)

active_ids = set(c["id"] for c in conditions)
cd = {k: v for k, v in cd.items() if k in active_ids}
state["last_check_ts"] = now
state["cooldown"] = cd

with open(os.path.join(workdir, "to_send.json"), "w") as fh:
    json.dump(to_send, fh)
with open(os.path.join(workdir, "state_next.json"), "w") as fh:
    json.dump(state, fh)
with open(os.path.join(workdir, "active.json"), "w") as fh:
    json.dump(conditions, fh)
PY

python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1])), sys.stdout, indent=2); print()' \
  "$WORKDIR/active.json" > "$WORKDIR/active.pretty" 2>/dev/null || true

ACTIVE_N="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$WORKDIR/active.json")"
SEND_N="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$WORKDIR/to_send.json")"

echo "=== ForteL2 alert-watch ==="
echo "active conditions: $ACTIVE_N  to send (after cooldown): $SEND_N"

if [ "$ACTIVE_N" -eq 0 ]; then
  python3 -c 'import json,sys,os,shutil
src, dst = sys.argv[1], sys.argv[2]
shutil.copyfile(src, dst)' "$WORKDIR/state_next.json" "$STATE_FILE"
  echo "no alert"
  exit 0
fi

# Dispatch each to-send condition. Per-channel flags from python: skip a
# channel that is inside its own cooldown (the other channel may still fire).
SENT_LOG="$WORKDIR/sent.log"
: > "$SENT_LOG"

python3 - "$WORKDIR/to_send.json" <<'PY' > "$WORKDIR/send_lines"
import json, sys
for c in json.load(open(sys.argv[1])):
    print("%s\t%s\t%s\t%s\t%s" % (
        c["id"],
        "1" if c.get("banner") else "0",
        "1" if c.get("email") else "0",
        c["title"].replace("\t", " ").replace("\n", " "),
        c["body"].replace("\t", " ").replace("\n", " "),
    ))
PY

# bash 3.2: do not expand an empty array under set -u. Loop the file instead.
while IFS="$(printf '\t')" read -r cid do_banner do_email title body; do
  [ -n "$cid" ] || continue
  echo "condition $cid"
  br=0
  er=0
  if [ "$do_banner" = "1" ]; then
    send_banner "$title" "$body" || br=$?
    if [ "$br" -eq 0 ]; then
      echo "banner sent: $title"
      echo "$cid banner" >> "$SENT_LOG"
    else
      BANNER_FAIL=1
    fi
  fi
  if [ "$do_email" = "1" ]; then
    send_email "$title" "$body" || er=$?
    if [ "$er" -eq 0 ]; then
      echo "email sent: $title"
      echo "$cid email" >> "$SENT_LOG"
    else
      EMAIL_FAIL=1
    fi
  fi
done < "$WORKDIR/send_lines"

python3 - "$WORKDIR/state_next.json" "$STATE_FILE" "$SENT_LOG" <<'PY'
import json, os, sys, time
src, dst, sent_path = sys.argv[1:4]
state = json.load(open(src))
cd = state.get("cooldown")
if not isinstance(cd, dict):
    cd = {}
now = time.time()
_now_raw = os.environ.get("ALERT_WATCH_NOW")
if _now_raw not in (None, ""):
    try:
        now = float(_now_raw)
    except (TypeError, ValueError):
        pass
try:
    with open(sent_path) as fh:
        lines = [ln.strip() for ln in fh if ln.strip()]
except OSError:
    lines = []
for line in lines:
    parts = line.split()
    if len(parts) != 2:
        continue
    cid, channel = parts
    rec = cd.get(cid)
    if not isinstance(rec, dict):
        rec = {}
    rec[channel] = now
    cd[cid] = rec
state["cooldown"] = cd
tmp = dst + ".tmp"
with open(tmp, "w") as fh:
    json.dump(state, fh, indent=2)
    fh.write("\n")
os.replace(tmp, dst)
PY

if [ "$BANNER_FAIL" -ne 0 ] || [ "$EMAIL_FAIL" -ne 0 ]; then
  echo "alert-watch finished with channel failure(s) banner_fail=$BANNER_FAIL email_fail=$EMAIL_FAIL" >&2
  exit 1
fi
exit 0
