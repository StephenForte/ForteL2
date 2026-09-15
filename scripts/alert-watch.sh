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
#                         at least one (incl. op-challenger) is not
#   stack-down            Sepolia: nothing is up outside the 23:45–03:00 PT
#                         sleep window (a failed 03:00 wake)
#   cloudflared-failing   system LaunchDaemon com.cloudflare.cloudflared is
#                         installed (plist exists) and unhealthy: launchctl print
#                         missing/unparseable, or state is not running (any last
#                         exit code — KeepAlive SuccessfulExit=false, so a clean
#                         exit is a permanent silent outage). No overnight-sleep
#                         grace — KeepAlive 24/7. Plist absent is a deliberate
#                         no-tunnel host, never an alert. Err-log "Failed to
#                         read token file" may enrich the body; daemon state is
#                         the trigger (D-0107 F5).
#   replica-losing-ground public replica head age grew across consecutive
#                         successful probes by more than REPLICA_TREND_NOISE_SECS
#                         (default 120). One sample cannot compute a trend; the
#                         first successful probe only stores state. A following
#                         node jitters by seconds; an hourly freeze grows ~3600 s.
#                         Comparison is exclusive (delta > floor). No Mac-sleep
#                         grace — the replica is on Render (D-0135).
#   replica-head-stale    a single successful probe shows head age >
#                         REPLICA_HEAD_STALE_SECS (default 10800, exclusive, same
#                         operator as health-stale). Backstop when trend has no
#                         prior sample (first run, wiped state, watcher down).
#   replica-unreachable   two consecutive failed probes of the public-read
#                         gateway (timeout / HTTP / garbage JSON / missing
#                         timestamp). One failure is quiet; a later success
#                         resets the streak. Failed probes do not overwrite the
#                         last successful head sample. urllib timeout 15 s —
#                         never ALERT_WATCH_CURL (that shim is Resend). One
#                         eth_getBlockByNumber(latest); URL is the published
#                         public-read gateway, never QuickNode / Access / loopback.
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
# never takes that grace (the tunnel daemon is KeepAlive, not calendar).
# replica-losing-ground / replica-head-stale / replica-unreachable never take
# that grace either — Render does not sleep at 23:45.
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
#   REPLICA_TREND_NOISE_SECS   default 120
#
# Test-only overrides (names never appear in env files, so they survive lib.sh
# `set -a` sourcing):
#   ALERT_WATCH_FUNDING_JSON   ALERT_WATCH_STATE
#   ALERT_WATCH_RESOLVE_OUT    ALERT_WATCH_RESOLVE_ERR
#   ALERT_WATCH_HEALTH_STALE_SECS   ALERT_WATCH_RESOLVE_STALE_SECS
#   ALERT_WATCH_SLEEP_GRACE_SECS
#   ALERT_WATCH_PID_DIR        ALERT_WATCH_EXPECT_STACK (1=up, 0=sleep window)
#   ALERT_WATCH_CURL  ALERT_WATCH_OSASCRIPT  ALERT_WATCH_LAUNCHCTL
#     (absolute shim paths — lib.sh prepends homebrew onto PATH)
#   ALERT_WATCH_CLOUDFLARED_PLIST  ALERT_WATCH_CLOUDFLARED_ERR
#     A launchctl shim without CLOUDFLARED_PLIST does not observe the host's
#     real tunnel plist (existing shims print resolve-games not-running/0).
#   ALERT_WATCH_REPLICA_HEAD_NUMBER  canned block number (skips the network)
#   ALERT_WATCH_REPLICA_HEAD_TS     unix timestamp of that head
#   ALERT_WATCH_REPLICA_HEAD_AGE    seconds; timestamp = now - age at eval time
#     Prefer HEAD_AGE for "fresh" (age ≈ 0 each run). A fixed HEAD_TS is a
#     frozen head: two evaluations ~1 s apart would look like losing ground
#     if the noise floor were "any increase".
#   ALERT_WATCH_REPLICA_UNREACHABLE=1  inject a failed probe (no network)
#   ALERT_WATCH_REPLICA_THROW=1        raise inside the probe; other conditions
#                                      must still evaluate
#   When any replica hook is set, or ALERT_WATCH_CURL is set (Resend test
#   shim), the probe never opens a socket. Production launchd does not set
#   those keys and uses urllib against the hardcoded public-read gateway.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib.sh"

DO_TEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --test) DO_TEST=1; shift ;;
    -h|--help) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
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
  "${ALERT_WATCH_PID_DIR:-$PID_DIR}" "$CF_PLIST" "$CF_ERR" "$CF_LABEL" <<'PY'
import json, os, shutil, sys, time, subprocess
import urllib.error
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
now = time.time()
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

def in_dev_sleep_window(now_ts):
    # Nightly 23:45–03:00 America/Los_Angeles (D-0026 / launchd sleep+wake).
    try:
        from datetime import datetime
        from zoneinfo import ZoneInfo
        local = datetime.fromtimestamp(now_ts, ZoneInfo("America/Los_Angeles"))
    except Exception:
        return False
    mins = local.hour * 60 + local.minute
    return mins >= (23 * 60 + 45) or mins < (3 * 60)

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
        add("stack-down",
            "ForteL2 stack is down",
            "Sepolia stack is not running outside the 23:45-03:00 PT sleep "
            "window: %s." % ", ".join(missing))

# --- cloudflared system daemon (plist present = this host runs the tunnel) ---
# Absence is not an alert. Unparseable print with plist present fails toward
# alerting. No sleep-grace: KeepAlive 24/7, not a calendar agent.
def parse_cf_print(stdout):
    """Defensive parse of `launchctl print` (format varies across macOS).

    Returns (state, exit_code) where state is 'running', 'not running',
    or None (unparseable) and exit_code is an int or None.
    """
    state = None
    exit_code = None
    if not stdout:
        return None, None
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
    return state, exit_code

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
    cf_state, cf_exit = parse_cf_print(cf_stdout)
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

# --- public replica liveness (Render; no Mac-sleep grace) ---
# Head-timestamp age and its trend only. Do not compare to the sequencer.
# One eth_getBlockByNumber(latest). Never QuickNode, Access, or loopback.
REPLICA_RPC_URL = "https://fortel2-replica-rpc.onrender.com"
REPLICA_RPC_TIMEOUT = 15

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
    _env_int("REPLICA_TREND_NOISE_SECS", 120),
)

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
    try:
        with urllib.request.urlopen(req, timeout=REPLICA_RPC_TIMEOUT) as resp:
            raw = resp.read()
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        return None
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
    if prev_obs is not None and prev_ts is not None:
        prev_age = prev_obs - prev_ts
        delta = age - prev_age
        # Exclusive: jitter of exactly the floor is not losing ground.
        if delta > replica_noise_secs:
            add("replica-losing-ground",
                "ForteL2 public replica losing ground",
                "public replica head age grew by %.0f s across consecutive "
                "successful probes (noise floor %d s, exclusive). "
                "current age %.0f s (head %s); previous age %.0f s. "
                "gateway %s. Render does not sleep."
                % (delta, replica_noise_secs, age, number, prev_age,
                   REPLICA_RPC_URL))
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
