# sourced by test-helpers.sh — do not run standalone
# alert-watch proposer-overdue (D-0142). register_cleanup / register_tmp —
# never trap EXIT. Offline fixtures only — never a live L1 RPC or QuickNode.

PO_AW="$SCRIPT_DIR/alert-watch.sh"
# Deliberately NOT "...proposer-overdue..." — that substring would leak into
# the FORTEL2_ROOT-mismatch WARN line (which embeds this path) and false-match
# every `*proposer-overdue*` assertion below.
PO_FIX="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-aw-proposer.XXXXXX")"
register_tmp "$PO_FIX"
cleanup_po() { rm -rf "$PO_FIX"; }
register_cleanup cleanup_po

mkdir -p "$PO_FIX/shim" "$PO_FIX/mock" "$PO_FIX/data" "$PO_FIX/bin" "$PO_FIX/deploy"
cat > "$PO_FIX/env" <<EOF
FORTEL2_ROOT=$PO_FIX
DATA_DIR=$PO_FIX/data
BIN_DIR=$PO_FIX/bin
DEPLOY_DIR=$PO_FIX/deploy
EOF
cat > "$PO_FIX/shim/curl" <<'EOS'
#!/bin/sh
dir="${ALERT_WATCH_MOCK_DIR:-}"
[ -n "$dir" ] || exit 99
n=0
[ -f "$dir/curl.calls" ] && n=$(cat "$dir/curl.calls")
n=$((n + 1))
printf '%s\n' "$n" > "$dir/curl.calls"
printf 'ARG:%s\n' "$@" >> "$dir/curl.argv"
cat > "$dir/curl.stdin"
out=""
writeout=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ] || [ "$prev" = "--output" ]; then out="$a"; fi
  if [ "$prev" = "-w" ] || [ "$prev" = "--write-out" ]; then writeout="$a"; fi
  prev="$a"
done
[ -n "$out" ] && printf '%s\n' '{"id":"mock-resend"}' > "$out"
[ -n "$writeout" ] && printf '%s' "${ALERT_WATCH_CURL_HTTP:-200}"
exit 0
EOS
cat > "$PO_FIX/shim/osascript" <<'EOS'
#!/bin/sh
dir="${ALERT_WATCH_MOCK_DIR:-}"
[ -n "$dir" ] || exit 99
n=0
[ -f "$dir/osascript.calls" ] && n=$(cat "$dir/osascript.calls")
n=$((n + 1))
printf '%s\n' "$n" > "$dir/osascript.calls"
printf 'ARG:%s\n' "$@" >> "$dir/osascript.argv"
exit 0
EOS
cat > "$PO_FIX/shim/launchctl" <<'EOS'
#!/bin/sh
printf 'gui/501/com.steve.fortel2-resolve-games = {\n\tstate = not running\n\tlast exit code = 0\n}\n'
exit 0
EOS
chmod +x "$PO_FIX/shim/curl" "$PO_FIX/shim/osascript" "$PO_FIX/shim/launchctl"

# 20:00 PT default (a pin, not a weakening — same reasoning as rp_run's
# RP_DAYTIME_NOW). Deliberately NOT noon: a 10h-old proposal at noon would
# reach back to ~02:00, inside the 23:45-03:00 PT window, which is exactly
# the trap this task closes — the boundary-exact cases below need an anchor
# whose lookback of up to ~10h never touches the window.
PO_DAYTIME_NOW="$(rp_pt_now 20 0)"

po_reset() {
  rm -f "$PO_FIX/mock"/curl.argv "$PO_FIX/mock"/curl.calls \
    "$PO_FIX/mock"/osascript.argv "$PO_FIX/mock"/osascript.calls \
    "$PO_FIX/state.json"
  : > "$PO_FIX/resolve.out.log"
  : > "$PO_FIX/resolve.err.log"
  printf '%s\n' '{"verdict":"OK","reason":"balance at or above the funding policy minimum"}' \
    > "$PO_FIX/funding-health.json"
}
po_stamp_now() {
  python3 - "${1:?}" "$PO_FIX/resolve.out.log" "$PO_FIX/resolve.err.log" "$PO_FIX/funding-health.json" <<'PY'
import os, sys
now = float(sys.argv[1])
for p in sys.argv[2:]:
    if os.path.exists(p):
        os.utime(p, (now, now))
PY
}
po_run() {
  _po_now="$PO_DAYTIME_NOW"
  for _po_arg in "$@"; do
    case "$_po_arg" in
      ALERT_WATCH_NOW=*) _po_now="${_po_arg#ALERT_WATCH_NOW=}"; break ;;
    esac
  done
  po_stamp_now "$_po_now"
  env -u RESEND_API_TOKEN \
    PATH="$PO_FIX/shim:$PATH" \
    FORTEL2_ENV="$PO_FIX/env" \
    ALERT_WATCH_MOCK_DIR="$PO_FIX/mock" \
    ALERT_WATCH_FUNDING_JSON="$PO_FIX/funding-health.json" \
    ALERT_WATCH_STATE="$PO_FIX/state.json" \
    ALERT_WATCH_RESOLVE_OUT="$PO_FIX/resolve.out.log" \
    ALERT_WATCH_RESOLVE_ERR="$PO_FIX/resolve.err.log" \
    ALERT_WATCH_CURL="$PO_FIX/shim/curl" \
    ALERT_WATCH_OSASCRIPT="$PO_FIX/shim/osascript" \
    ALERT_WATCH_LAUNCHCTL="$PO_FIX/shim/launchctl" \
    ALERT_WATCH_NOW="$_po_now" \
    ALERT_WATCH_PROPOSER_LATEST_AGE="${ALERT_WATCH_PROPOSER_LATEST_AGE:-0}" \
    ALERT_WATCH_CLOUDFLARED_METRICS='cloudflared_tunnel_ha_connections 4' \
    ALERT_WATCH_CLOUDFLARED_RUNS=1 \
    ALERT_EMAIL_TO='fortel2-alert-watch@example.invalid' \
    "$@"
  unset _po_now _po_arg
}

# Source-level: condition id, env var, --help documents it, header documents
# the metered dependency, legacy PROPOSER_INTERVAL never read for this condition.
PO_BLK="$(awk '/# --- proposer overdue/,/# --- cooldown/' "$PO_AW")"
if grep -q 'proposer-overdue' "$PO_AW" \
  && grep -q 'SEPOLIA_PROPOSER_INTERVAL' "$PO_AW" \
  && grep -q 'ALERT_WATCH_PROPOSER_LATEST_AGE' "$PO_AW" \
  && grep -q 'ALERT_WATCH_PROPOSER_UNREACHABLE' "$PO_AW" \
  && grep -q 'ALERT_WATCH_PROPOSER_THROW' "$PO_AW" \
  && echo "$PO_BLK" | grep -q 'in_dev_sleep_window' \
  && echo "$PO_BLK" | grep -qF 'PROPOSER_OVERDUE_GRACE_SECS = 2 * 3600' \
  && ! echo "$PO_BLK" | grep -qiE 'quicknode\.com|quiknode' \
  && ! grep -q 'os.environ.get("PROPOSER_INTERVAL")' "$PO_AW"; then
  echo "PASS alert-watch proposer-overdue reuses in_dev_sleep_window, reads SEPOLIA_PROPOSER_INTERVAL, never legacy PROPOSER_INTERVAL"
else
  echo "FAIL proposer-overdue must reuse in_dev_sleep_window and never read legacy PROPOSER_INTERVAL" >&2
  fail=1
fi

_po_help_rc=0
_po_help_out="$(FORTEL2_ENV="$PO_FIX/env" "$PO_AW" --help 2>&1)" || _po_help_rc=$?
if [[ "$_po_help_rc" == "0" ]] \
  && printf '%s' "$_po_help_out" | grep -q 'proposer-overdue' \
  && printf '%s' "$_po_help_out" | grep -q 'ALERT_WATCH_PROPOSER_LATEST_AGE' \
  && printf '%s' "$_po_help_out" | grep -q 'metered'; then
  echo "PASS alert-watch.sh --help documents proposer-overdue and its metered dependency"
else
  echo "FAIL --help must document proposer-overdue and disclose the metered L1 dependency (ec=$_po_help_rc)" >&2
  printf '%s\n' "$_po_help_out" >&2
  fail=1
fi
unset _po_help_out _po_help_rc

# Measured real cadence (8h02m) against the default 8h interval is quiet.
po_reset
PO_OUT="$(po_run ALERT_WATCH_PROPOSER_LATEST_AGE=$((8 * 3600 + 2 * 60)) \
  SEPOLIA_PROPOSER_INTERVAL=8h \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$PO_AW" 2>&1)" && PO_EC=0 || PO_EC=$?
if [[ "$PO_EC" -eq 0 ]] \
  && [[ ! -f "$PO_FIX/mock/osascript.calls" ]] \
  && [[ "$PO_OUT" == *"no alert"* ]]; then
  echo "PASS alert-watch proposer-overdue is quiet on the measured 8h02m cadence"
else
  echo "FAIL an 8h02m-old proposal against an 8h interval must stay quiet (ec=$PO_EC)" >&2
  echo "$PO_OUT" >&2
  fail=1
fi

# Exclusive threshold: exactly interval+2h is quiet, one second past fires.
po_reset
PO_OUT="$(po_run ALERT_WATCH_PROPOSER_LATEST_AGE=$((10 * 3600)) \
  SEPOLIA_PROPOSER_INTERVAL=8h \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$PO_AW" 2>&1)" && PO_EC=0 || PO_EC=$?
if [[ "$PO_EC" -eq 0 ]] \
  && [[ ! -f "$PO_FIX/mock/osascript.calls" ]] \
  && [[ "$PO_OUT" == *"no alert"* ]]; then
  echo "PASS alert-watch proposer-overdue is quiet exactly at the 10h threshold"
else
  echo "FAIL age == interval+2h (10h) must stay quiet (exclusive) (ec=$PO_EC)" >&2
  echo "$PO_OUT" >&2
  fail=1
fi
po_reset
PO_OUT="$(po_run ALERT_WATCH_PROPOSER_LATEST_AGE=$((10 * 3600 + 1)) \
  SEPOLIA_PROPOSER_INTERVAL=8h \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$PO_AW" 2>&1)" && PO_EC=0 || PO_EC=$?
if [[ "$PO_EC" -eq 0 ]] \
  && [[ "$(cat "$PO_FIX/mock/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
  && [[ "$PO_OUT" == *"proposer-overdue"* ]] \
  && grep -qi 'proposer overdue' "$PO_FIX/mock/osascript.argv"; then
  echo "PASS alert-watch proposer-overdue fires one second past the threshold"
else
  echo "FAIL age == interval+2h+1s must fire proposer-overdue (ec=$PO_EC)" >&2
  echo "$PO_OUT" >&2
  fail=1
fi

# Verdict is judged against the CONFIGURED interval: same age, different
# interval, different outcome.
po_reset
PO_OUT="$(po_run ALERT_WATCH_PROPOSER_LATEST_AGE=$((5 * 3600)) \
  SEPOLIA_PROPOSER_INTERVAL=8h \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$PO_AW" 2>&1)" && PO_EC=0 || PO_EC=$?
if [[ "$PO_EC" -ne 0 ]] || [[ "$PO_OUT" == *"proposer-overdue"* ]]; then
  echo "FAIL a 5h-old proposal against an 8h interval must stay quiet (ec=$PO_EC)" >&2
  echo "$PO_OUT" >&2
  fail=1
fi
po_reset
PO_OUT2="$(po_run ALERT_WATCH_PROPOSER_LATEST_AGE=$((5 * 3600)) \
  SEPOLIA_PROPOSER_INTERVAL=1h \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$PO_AW" 2>&1)" && PO_EC2=0 || PO_EC2=$?
if [[ "$PO_EC2" -eq 0 ]] \
  && [[ "$PO_OUT2" == *"proposer-overdue"* ]]; then
  echo "PASS alert-watch proposer-overdue is judged against the configured interval, not a hardcoded 8h"
else
  echo "FAIL the same 5h-old proposal against a 1h interval must fire proposer-overdue (ec=$PO_EC2)" >&2
  echo "$PO_OUT2" >&2
  fail=1
fi

# §7 trap: a proposal whose raw age spans one full sleep window, but whose
# AWAKE age is under the threshold, must stay quiet — the case a naive
# `age >` check gets wrong. 8h interval => 10h threshold. Anchor "now" at
# 05:00 PT so the window ends just before it; last proposal at 16:45 the
# prior day (raw age 12h15m, awake age exactly 9h — under 10h).
po_reset
PO_WAKE_NOW="$(rp_pt_now 5 0 19)"
PO_OUT="$(po_run ALERT_WATCH_NOW="$PO_WAKE_NOW" \
  ALERT_WATCH_PROPOSER_LATEST_AGE=$((12 * 3600 + 15 * 60)) \
  SEPOLIA_PROPOSER_INTERVAL=8h \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$PO_AW" 2>&1)" && PO_EC=0 || PO_EC=$?
if [[ "$PO_EC" -eq 0 ]] \
  && [[ ! -f "$PO_FIX/mock/osascript.calls" ]] \
  && [[ "$PO_OUT" == *"no alert"* ]]; then
  echo "PASS alert-watch proposer-overdue stays quiet when awake age is under threshold despite raw age spanning one sleep window"
else
  echo "FAIL a 12h15m raw age spanning exactly one sleep window (awake age 9h, threshold 10h) must stay quiet (ec=$PO_EC)" >&2
  echo "$PO_OUT" >&2
  fail=1
fi

# A proposal well past the threshold on awake time IS overdue and DOES alert.
po_reset
PO_OUT="$(po_run ALERT_WATCH_PROPOSER_LATEST_AGE=$((30 * 3600)) \
  SEPOLIA_PROPOSER_INTERVAL=8h \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$PO_AW" 2>&1)" && PO_EC=0 || PO_EC=$?
if [[ "$PO_EC" -eq 0 ]] \
  && [[ "$(cat "$PO_FIX/mock/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
  && [[ "$PO_OUT" == *"proposer-overdue"* ]]; then
  echo "PASS alert-watch proposer-overdue fires on a 30h-old proposal (well past threshold on awake time)"
else
  echo "FAIL a 30h-old proposal must fire proposer-overdue (ec=$PO_EC)" >&2
  echo "$PO_OUT" >&2
  fail=1
fi

# game_count 0 / no games ever proposed: quiet once, "cannot verify" fires on
# the second consecutive read, never "healthy" and never "overdue" claimed.
po_reset
PO_OUT="$(po_run ALERT_WATCH_PROPOSER_GAME_COUNT=0 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$PO_AW" 2>&1)" && PO_EC=0 || PO_EC=$?
if [[ "$PO_EC" -ne 0 ]] || [[ -f "$PO_FIX/mock/osascript.calls" ]]; then
  echo "FAIL game_count 0 on the first read must stay quiet (ec=$PO_EC)" >&2
  echo "$PO_OUT" >&2
  fail=1
fi
PO_OUT2="$(po_run ALERT_WATCH_PROPOSER_GAME_COUNT=0 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$PO_AW" 2>&1)" && PO_EC2=0 || PO_EC2=$?
if [[ "$PO_EC2" -eq 0 ]] \
  && [[ "$(cat "$PO_FIX/mock/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
  && [[ "$PO_OUT2" == *"proposer-overdue"* ]] \
  && grep -qi 'unverifiable\|cannot be evaluated' "$PO_FIX/mock/osascript.argv"; then
  echo "PASS alert-watch proposer-overdue reports 'cannot verify' (never healthy or overdue) on two consecutive zero-game reads"
else
  echo "FAIL two consecutive game_count=0 reads must fire proposer-overdue as unverifiable, not silently healthy (ec=$PO_EC2)" >&2
  echo "$PO_OUT2" >&2
  fail=1
fi

# One failed L1 read is quiet; two consecutive fire; a later success resets
# the streak (replica_unreachable_streak precedent).
po_reset
PO_OUT="$(po_run ALERT_WATCH_PROPOSER_UNREACHABLE=1 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$PO_AW" 2>&1)" && PO_EC=0 || PO_EC=$?
if [[ "$PO_EC" -eq 0 ]] \
  && [[ ! -f "$PO_FIX/mock/osascript.calls" ]] \
  && [[ "$PO_OUT" == *"no alert"* ]]; then
  echo "PASS alert-watch proposer-overdue is quiet on one failed L1 read"
else
  echo "FAIL one failed proposer L1 read must be quiet (ec=$PO_EC)" >&2
  echo "$PO_OUT" >&2
  fail=1
fi
po_reset
po_run ALERT_WATCH_PROPOSER_UNREACHABLE=1 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$PO_AW" >/dev/null 2>&1 || true
PO_OUT2="$(po_run ALERT_WATCH_PROPOSER_UNREACHABLE=1 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$PO_AW" 2>&1)" && PO_EC2=0 || PO_EC2=$?
if [[ "$PO_EC2" -eq 0 ]] \
  && [[ "$(cat "$PO_FIX/mock/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
  && [[ "$PO_OUT2" == *"proposer-overdue"* ]]; then
  echo "PASS alert-watch proposer-overdue fires on two consecutive failed L1 reads"
else
  echo "FAIL two consecutive failed proposer L1 reads must fire proposer-overdue (ec=$PO_EC2)" >&2
  echo "$PO_OUT2" >&2
  fail=1
fi
po_reset
po_run ALERT_WATCH_PROPOSER_UNREACHABLE=1 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$PO_AW" >/dev/null 2>&1 || true
po_run ALERT_WATCH_PROPOSER_LATEST_AGE=0 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$PO_AW" >/dev/null 2>&1 || true
rm -f "$PO_FIX/mock"/osascript.calls "$PO_FIX/mock"/osascript.argv \
  "$PO_FIX/mock"/curl.calls "$PO_FIX/mock"/curl.argv
PO_OUT3="$(po_run ALERT_WATCH_PROPOSER_UNREACHABLE=1 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$PO_AW" 2>&1)" && PO_EC3=0 || PO_EC3=$?
if [[ "$PO_EC3" -eq 0 ]] \
  && [[ ! -f "$PO_FIX/mock/osascript.calls" ]] \
  && [[ "$PO_OUT3" == *"no alert"* ]]; then
  echo "PASS alert-watch proposer-overdue unreachable streak resets after a success"
else
  echo "FAIL a successful read must reset the proposer unreachable streak (ec=$PO_EC3)" >&2
  echo "$PO_OUT3" >&2
  fail=1
fi

# Unparseable interval routes through the same "cannot determine" path as a
# failed read — never a default that silently disagrees with config.
po_reset
po_run ALERT_WATCH_PROPOSER_LATEST_AGE=0 SEPOLIA_PROPOSER_INTERVAL='not-a-duration' \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$PO_AW" >/dev/null 2>&1 || true
PO_OUT2="$(po_run ALERT_WATCH_PROPOSER_LATEST_AGE=0 SEPOLIA_PROPOSER_INTERVAL='not-a-duration' \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$PO_AW" 2>&1)" && PO_EC2=0 || PO_EC2=$?
if [[ "$PO_EC2" -eq 0 ]] \
  && [[ "$(cat "$PO_FIX/mock/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
  && [[ "$PO_OUT2" == *"proposer-overdue"* ]] \
  && grep -qi 'unparseable' "$PO_FIX/mock/osascript.argv"; then
  echo "PASS alert-watch proposer-overdue treats an unparseable SEPOLIA_PROPOSER_INTERVAL as unverifiable, not healthy"
else
  echo "FAIL an unparseable interval must fire proposer-overdue as unverifiable after two reads (ec=$PO_EC2)" >&2
  echo "$PO_OUT2" >&2
  fail=1
fi

# Probe throw must not prevent funding-fail (or the evaluator) from running.
po_reset
printf '%s\n' '{"verdict":"FAIL","reason":"batcher below policy for 24.0 h with no top-up"}' \
  > "$PO_FIX/funding-health.json"
PO_OUT="$(po_run ALERT_WATCH_PROPOSER_THROW=1 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$PO_AW" 2>&1)" && PO_EC=0 || PO_EC=$?
if [[ "$PO_EC" -eq 0 ]] \
  && [[ "$PO_OUT" == *"condition funding-fail"* ]] \
  && [[ "$(cat "$PO_FIX/mock/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
  && ! printf '%s' "$PO_OUT" | grep -qi 'traceback'; then
  echo "PASS alert-watch proposer probe throw still evaluates funding-fail"
else
  echo "FAIL a proposer probe throw must not prevent funding-fail from alerting (ec=$PO_EC)" >&2
  echo "$PO_OUT" >&2
  fail=1
fi

# Cooldown: two consecutive overdue evaluations send once inside ALERT_REALERT_HOURS.
po_reset
po_run ALERT_WATCH_PROPOSER_LATEST_AGE=$((30 * 3600)) \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$PO_AW" >/dev/null 2>&1 || true
PO_C1="$(cat "$PO_FIX/mock/curl.calls" 2>/dev/null || echo 0)"
po_run ALERT_WATCH_PROPOSER_LATEST_AGE=$((31 * 3600)) \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$PO_AW" >/dev/null 2>&1 || true
PO_C2="$(cat "$PO_FIX/mock/curl.calls" 2>/dev/null || echo 0)"
if [[ "$PO_C1" -eq 1 && "$PO_C2" -eq 1 ]]; then
  echo "PASS alert-watch proposer-overdue cooldown suppresses a second send"
else
  echo "FAIL proposer-overdue must send once inside ALERT_REALERT_HOURS (c1=$PO_C1 c2=$PO_C2)" >&2
  fail=1
fi

cleanup_po
unset PO_AW PO_FIX PO_DAYTIME_NOW PO_BLK PO_OUT PO_OUT2 PO_OUT3 PO_EC PO_EC2 PO_EC3 \
  PO_C1 PO_C2 PO_WAKE_NOW
unset -f po_reset po_stamp_now po_run cleanup_po 2>/dev/null || true
