# sourced by test-helpers.sh — do not run standalone
# alert-watch sequencer-stalled / sequencer-unreachable (D-0148).
# register_cleanup / register_tmp — never trap EXIT. Offline fixtures only.
# The op-node probe must not open a socket in fixture mode.

SQ_AW="$SCRIPT_DIR/alert-watch.sh"
# Deliberately NOT "...sequencer-stalled..." — that substring would leak into
# the FORTEL2_ROOT-mismatch WARN line (which embeds this path) and false-match
# every `*sequencer-stalled*` assertion below.
SQ_FIX="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-aw-seqhead.XXXXXX")"
register_tmp "$SQ_FIX"
cleanup_sq() {
  if [ -n "${SQ_SOCKET_PID:-}" ]; then
    kill "$SQ_SOCKET_PID" 2>/dev/null || true
    wait "$SQ_SOCKET_PID" 2>/dev/null || true
    SQ_SOCKET_PID=""
  fi
  rm -rf "$SQ_FIX"
}
register_cleanup cleanup_sq

mkdir -p "$SQ_FIX/shim" "$SQ_FIX/mock" "$SQ_FIX/data" "$SQ_FIX/bin" "$SQ_FIX/deploy" "$SQ_FIX/pids"
aw_write_sleep_plists "$SQ_FIX/agents"
cat > "$SQ_FIX/env" <<EOF
FORTEL2_ROOT=$SQ_FIX
DATA_DIR=$SQ_FIX/data
BIN_DIR=$SQ_FIX/bin
DEPLOY_DIR=$SQ_FIX/deploy
EOF
cat > "$SQ_FIX/shim/curl" <<'EOS'
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
cat > "$SQ_FIX/shim/osascript" <<'EOS'
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
cat > "$SQ_FIX/shim/launchctl" <<'EOS'
#!/bin/sh
printf 'gui/501/com.steve.fortel2-resolve-games = {\n\tstate = not running\n\tlast exit code = 0\n}\n'
exit 0
EOS
chmod +x "$SQ_FIX/shim/curl" "$SQ_FIX/shim/osascript" "$SQ_FIX/shim/launchctl"

# 20:00 PT is outside 23:45–00:15 and well after the 00:15 wake grace.
SQ_DAYTIME_NOW="$(rp_pt_now 20 0)"
SQ_CORE="op-geth op-node op-batcher op-proposer l2-rpc-filter"

sq_reset() {
  rm -f "$SQ_FIX/mock"/curl.argv "$SQ_FIX/mock"/curl.calls \
    "$SQ_FIX/mock"/osascript.argv "$SQ_FIX/mock"/osascript.calls \
    "$SQ_FIX/state.json"
  : > "$SQ_FIX/resolve.out.log"
  : > "$SQ_FIX/resolve.err.log"
  printf '%s\n' '{"verdict":"OK","reason":"balance at or above the funding policy minimum"}' \
    > "$SQ_FIX/funding-health.json"
}
sq_stamp_now() {
  python3 - "${1:?}" "$SQ_FIX/resolve.out.log" "$SQ_FIX/resolve.err.log" "$SQ_FIX/funding-health.json" <<'PY'
import os, sys
now = float(sys.argv[1])
for p in sys.argv[2:]:
    if os.path.exists(p):
        os.utime(p, (now, now))
PY
}
sq_mark() {
  local n
  rm -f "$SQ_FIX/pids"/*.pid
  for n in "$@"; do
    printf '%s\n' "$$" > "$SQ_FIX/pids/$n.pid"
  done
}
sq_run() {
  _sq_now="$SQ_DAYTIME_NOW"
  for _sq_arg in "$@"; do
    case "$_sq_arg" in
      ALERT_WATCH_NOW=*) _sq_now="${_sq_arg#ALERT_WATCH_NOW=}"; break ;;
    esac
  done
  sq_stamp_now "$_sq_now"
  env -u RESEND_API_TOKEN -u CHALLENGER_L1_RPC_URL \
    -u SEQUENCER_STALL_SECS \
    -u ALERT_WATCH_PID_DIR -u ALERT_WATCH_EXPECT_STACK \
    -u ALERT_WATCH_SEQUENCER_UNSAFE_AGE \
    -u ALERT_WATCH_SEQUENCER_UNSAFE_NUMBER \
    -u ALERT_WATCH_SEQUENCER_CURRENT_L1 \
    -u ALERT_WATCH_SEQUENCER_HEAD_L1 \
    -u ALERT_WATCH_SEQUENCER_SYNC_JSON \
    -u ALERT_WATCH_SEQUENCER_UNREACHABLE \
    -u ALERT_WATCH_SEQUENCER_THROW \
    -u ALERT_WATCH_SEQUENCER_TIMEOUT \
    PATH="$SQ_FIX/shim:$PATH" \
    FORTEL2_ENV="$SQ_FIX/env" \
    L2_CHAIN_ID=852 \
    ALERT_WATCH_MOCK_DIR="$SQ_FIX/mock" \
    ALERT_WATCH_FUNDING_JSON="$SQ_FIX/funding-health.json" \
    ALERT_WATCH_STATE="$SQ_FIX/state.json" \
    ALERT_WATCH_RESOLVE_OUT="$SQ_FIX/resolve.out.log" \
    ALERT_WATCH_RESOLVE_ERR="$SQ_FIX/resolve.err.log" \
    ALERT_WATCH_CURL="$SQ_FIX/shim/curl" \
    ALERT_WATCH_OSASCRIPT="$SQ_FIX/shim/osascript" \
    ALERT_WATCH_LAUNCHCTL="$SQ_FIX/shim/launchctl" \
    ALERT_WATCH_NOW="$_sq_now" \
    ALERT_WATCH_REPLICA_HEAD_NUMBER=982723 \
    ALERT_WATCH_REPLICA_HEAD_AGE=0 \
    ALERT_WATCH_PROPOSER_LATEST_AGE=0 \
    ALERT_WATCH_CLOUDFLARED_METRICS='cloudflared_tunnel_ha_connections 4' \
    ALERT_WATCH_CLOUDFLARED_RUNS=1 \
    FORTEL2_DEV_SLEEP_AGENTS_DIR="$SQ_FIX/agents" \
    ALERT_EMAIL_TO='fortel2-alert-watch@example.invalid' \
    "$@"
  unset _sq_now _sq_arg
}
# Pid up, challenger deliberately off, so stack-missing stays quiet.
sq_run_up() {
  sq_mark $SQ_CORE
  sq_run \
    ALERT_WATCH_PID_DIR="$SQ_FIX/pids" \
    ALERT_WATCH_EXPECT_STACK=1 \
    FORTEL2_EL=geth \
    SEPOLIA_START_CHALLENGER=0 \
    "$@"
}

SQ_BLK="$(awk '/# --- sequencer stall/,/# --- cooldown/' "$SQ_AW")"
if echo "$SQ_BLK" | grep -q 'optimism_syncStatus' \
  && echo "$SQ_BLK" | grep -q 'L2_NODE_RPC_URL' \
  && echo "$SQ_BLK" | grep -q 'age > SEQUENCER_STALL_SECS' \
  && echo "$SQ_BLK" | grep -q 'l2_chain == "852"' \
  && echo "$SQ_BLK" | grep -q 'op-node' \
  && ! echo "$SQ_BLK" | grep -q 'pipeline-snapshot' \
  && ! echo "$SQ_BLK" | grep -q 'status.sh'; then
  echo "PASS alert-watch sequencer probe reads op-node optimism_syncStatus, gated on chain 852"
else
  echo "FAIL sequencer probe must read optimism_syncStatus on chain 852 and not another script" >&2
  fail=1
fi

_sq_help_rc=0
_sq_help_out="$(FORTEL2_ENV="$SQ_FIX/env" "$SQ_AW" --help 2>&1)" || _sq_help_rc=$?
if [[ "$_sq_help_rc" == "0" ]] \
  && printf '%s' "$_sq_help_out" | grep -q 'sequencer-stalled' \
  && printf '%s' "$_sq_help_out" | grep -q 'sequencer-unreachable' \
  && printf '%s' "$_sq_help_out" | grep -q 'SEQUENCER_STALL_SECS' \
  && printf '%s' "$_sq_help_out" | grep -q 'ALERT_WATCH_SEQUENCER_UNSAFE_AGE' \
  && printf '%s' "$_sq_help_out" | grep -q 'ALERT_WATCH_SEQUENCER_SYNC_JSON'; then
  echo "PASS alert-watch.sh --help documents sequencer-stalled, sequencer-unreachable, and their fixtures"
else
  echo "FAIL --help must document sequencer stall conditions and fixtures (ec=$_sq_help_rc)" >&2
  printf '%s\n' "$_sq_help_out" >&2
  fail=1
fi
unset _sq_help_out _sq_help_rc

# Fires at 601 with the default 600 s threshold. Body carries the diagnostic.
sq_reset
SQ_OUT="$(sq_run ALERT_WATCH_SEQUENCER_UNSAFE_AGE=601 \
  ALERT_WATCH_SEQUENCER_UNSAFE_NUMBER=1930794 \
  ALERT_WATCH_SEQUENCER_CURRENT_L1=11856336 \
  ALERT_WATCH_SEQUENCER_HEAD_L1=11856340 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$SQ_AW" 2>&1)" && SQ_EC=0 || SQ_EC=$?
if [[ "$SQ_EC" -eq 0 ]] \
  && [[ "$(cat "$SQ_FIX/mock/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
  && [[ "$SQ_OUT" == *"condition sequencer-stalled"* ]] \
  && [[ "$SQ_OUT" != *"condition sequencer-unreachable"* ]] \
  && grep -q '1930794' "$SQ_FIX/mock/osascript.argv" \
  && grep -q '601' "$SQ_FIX/mock/osascript.argv" \
  && grep -q '11856336' "$SQ_FIX/mock/osascript.argv" \
  && grep -q '11856340' "$SQ_FIX/mock/osascript.argv" \
  && grep -q 'gap 4' "$SQ_FIX/mock/osascript.argv" \
  && grep -q 'threshold 600' "$SQ_FIX/mock/osascript.argv"; then
  echo "PASS alert-watch sequencer-stalled fires at age 601 and names unsafe head, age, and L1 gap"
else
  echo "FAIL age 601 must fire sequencer-stalled with unsafe number, age, current_l1, head_l1, and gap (ec=$SQ_EC)" >&2
  echo "$SQ_OUT" >&2
  fail=1
fi

# Exclusive: exactly 600 is quiet.
sq_reset
SQ_OUT="$(sq_run ALERT_WATCH_SEQUENCER_UNSAFE_AGE=600 \
  ALERT_WATCH_SEQUENCER_UNSAFE_NUMBER=1930794 \
  ALERT_WATCH_SEQUENCER_CURRENT_L1=11856336 \
  ALERT_WATCH_SEQUENCER_HEAD_L1=11856340 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$SQ_AW" 2>&1)" && SQ_EC=0 || SQ_EC=$?
if [[ "$SQ_EC" -eq 0 ]] \
  && [[ ! -f "$SQ_FIX/mock/osascript.calls" ]] \
  && [[ "$SQ_OUT" == *"no alert"* ]] \
  && [[ "$SQ_OUT" != *"sequencer-stalled"* ]]; then
  echo "PASS alert-watch sequencer-stalled is quiet at the exact 600 s threshold"
else
  echo "FAIL age == 600 must stay quiet (exclusive) (ec=$SQ_EC)" >&2
  echo "$SQ_OUT" >&2
  fail=1
fi

# Override: SEQUENCER_STALL_SECS=100. Exactly 100 quiet, 101 fires.
sq_reset
SQ_OUT="$(sq_run ALERT_WATCH_SEQUENCER_UNSAFE_AGE=100 \
  SEQUENCER_STALL_SECS=100 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$SQ_AW" 2>&1)" && SQ_EC=0 || SQ_EC=$?
if [[ "$SQ_EC" -eq 0 ]] \
  && [[ ! -f "$SQ_FIX/mock/osascript.calls" ]] \
  && [[ "$SQ_OUT" == *"no alert"* ]]; then
  echo "PASS alert-watch sequencer-stalled honours SEQUENCER_STALL_SECS and stays quiet at the override"
else
  echo "FAIL age == SEQUENCER_STALL_SECS override must stay quiet (ec=$SQ_EC)" >&2
  echo "$SQ_OUT" >&2
  fail=1
fi
sq_reset
SQ_OUT="$(sq_run ALERT_WATCH_SEQUENCER_UNSAFE_AGE=101 \
  SEQUENCER_STALL_SECS=100 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$SQ_AW" 2>&1)" && SQ_EC=0 || SQ_EC=$?
if [[ "$SQ_EC" -eq 0 ]] \
  && [[ "$(cat "$SQ_FIX/mock/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
  && [[ "$SQ_OUT" == *"condition sequencer-stalled"* ]] \
  && grep -q 'threshold 100' "$SQ_FIX/mock/osascript.argv"; then
  echo "PASS alert-watch sequencer-stalled fires one second past SEQUENCER_STALL_SECS"
else
  echo "FAIL age == SEQUENCER_STALL_SECS+1 must fire sequencer-stalled (ec=$SQ_EC)" >&2
  echo "$SQ_OUT" >&2
  fail=1
fi

# Inside the dev-sleep window (23:50 PT). Age 601 must not page.
sq_reset
SQ_SLEEP_NOW="$(rp_pt_now 23 50)"
SQ_OUT="$(sq_run ALERT_WATCH_NOW="$SQ_SLEEP_NOW" \
  ALERT_WATCH_SEQUENCER_UNSAFE_AGE=601 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$SQ_AW" 2>&1)" && SQ_EC=0 || SQ_EC=$?
if [[ "$SQ_EC" -eq 0 ]] \
  && [[ ! -f "$SQ_FIX/mock/osascript.calls" ]] \
  && [[ "$SQ_OUT" == *"no alert"* ]] \
  && [[ "$SQ_OUT" != *"sequencer-stalled"* ]]; then
  echo "PASS alert-watch sequencer-stalled is suppressed inside the dev-sleep window"
else
  echo "FAIL age 601 inside the dev-sleep window must not fire sequencer-stalled (ec=$SQ_EC)" >&2
  echo "$SQ_OUT" >&2
  fail=1
fi

# 00:30 is outside the window (ends 00:15) and inside the one-cycle grace.
sq_reset
SQ_GRACE_NOW="$(rp_pt_now 0 30 19)"
SQ_OUT="$(sq_run ALERT_WATCH_NOW="$SQ_GRACE_NOW" \
  ALERT_WATCH_SEQUENCER_UNSAFE_AGE=601 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$SQ_AW" 2>&1)" && SQ_EC=0 || SQ_EC=$?
if [[ "$SQ_EC" -eq 0 ]] \
  && [[ ! -f "$SQ_FIX/mock/osascript.calls" ]] \
  && [[ "$SQ_OUT" == *"no alert"* ]] \
  && [[ "$SQ_OUT" != *"sequencer-stalled"* ]]; then
  echo "PASS alert-watch sequencer-stalled is suppressed inside post-wake grace"
else
  echo "FAIL age 601 at 00:30 PT must stay inside post-wake grace (ec=$SQ_EC)" >&2
  echo "$SQ_OUT" >&2
  fail=1
fi

# 01:15 is exactly 3600 s after the 00:15 wake. Grace is exclusive there.
sq_reset
SQ_AFTER_NOW="$(rp_pt_now 1 15 19)"
SQ_OUT="$(sq_run ALERT_WATCH_NOW="$SQ_AFTER_NOW" \
  ALERT_WATCH_SEQUENCER_UNSAFE_AGE=601 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$SQ_AW" 2>&1)" && SQ_EC=0 || SQ_EC=$?
if [[ "$SQ_EC" -eq 0 ]] \
  && [[ "$(cat "$SQ_FIX/mock/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
  && [[ "$SQ_OUT" == *"condition sequencer-stalled"* ]]; then
  echo "PASS alert-watch sequencer-stalled fires just after post-wake grace"
else
  echo "FAIL age 601 at 01:15 PT must fire sequencer-stalled (ec=$SQ_EC)" >&2
  echo "$SQ_OUT" >&2
  fail=1
fi

# One failed probe is quiet; two consecutive fire sequencer-unreachable.
sq_reset
SQ_OUT="$(sq_run_up ALERT_WATCH_SEQUENCER_UNREACHABLE=1 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$SQ_AW" 2>&1)" && SQ_EC=0 || SQ_EC=$?
if [[ "$SQ_EC" -eq 0 ]] \
  && [[ ! -f "$SQ_FIX/mock/osascript.calls" ]] \
  && [[ "$SQ_OUT" == *"no alert"* ]] \
  && [[ "$SQ_OUT" != *"sequencer-unreachable"* ]]; then
  echo "PASS alert-watch sequencer-unreachable is quiet on one failed probe"
else
  echo "FAIL one failed sequencer probe must stay quiet (ec=$SQ_EC)" >&2
  echo "$SQ_OUT" >&2
  fail=1
fi
SQ_OUT2="$(sq_run_up ALERT_WATCH_SEQUENCER_UNREACHABLE=1 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$SQ_AW" 2>&1)" && SQ_EC2=0 || SQ_EC2=$?
if [[ "$SQ_EC2" -eq 0 ]] \
  && [[ "$(cat "$SQ_FIX/mock/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
  && [[ "$SQ_OUT2" == *"condition sequencer-unreachable"* ]] \
  && [[ "$SQ_OUT2" != *"condition sequencer-stalled"* ]]; then
  echo "PASS alert-watch sequencer-unreachable fires on two consecutive failures"
else
  echo "FAIL two consecutive failed sequencer probes must fire sequencer-unreachable (ec=$SQ_EC2)" >&2
  echo "$SQ_OUT2" >&2
  fail=1
fi

# Failure then success resets, so one later failure stays quiet.
sq_reset
sq_run_up ALERT_WATCH_SEQUENCER_UNREACHABLE=1 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$SQ_AW" >/dev/null 2>&1 || true
sq_run_up ALERT_WATCH_SEQUENCER_UNSAFE_AGE=0 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$SQ_AW" >/dev/null 2>&1 || true
rm -f "$SQ_FIX/mock"/osascript.calls "$SQ_FIX/mock"/curl.calls \
  "$SQ_FIX/mock"/osascript.argv "$SQ_FIX/mock"/curl.argv
SQ_OUT="$(sq_run_up ALERT_WATCH_SEQUENCER_UNREACHABLE=1 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$SQ_AW" 2>&1)" && SQ_EC=0 || SQ_EC=$?
if [[ "$SQ_EC" -eq 0 ]] \
  && [[ ! -f "$SQ_FIX/mock/osascript.calls" ]] \
  && [[ "$SQ_OUT" == *"no alert"* ]] \
  && [[ "$SQ_OUT" != *"sequencer-unreachable"* ]]; then
  echo "PASS alert-watch sequencer-unreachable streak resets after a success"
else
  echo "FAIL a success must reset the sequencer unreachable streak (ec=$SQ_EC)" >&2
  echo "$SQ_OUT" >&2
  fail=1
fi

# Missing / null unsafe timestamp and malformed JSON are not a fresh head.
sq_cannot_verify() {
  local label="$1"
  shift
  sq_reset
  SQ_OUT="$(sq_run_up "$@" RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$SQ_AW" 2>&1)" && SQ_EC=0 || SQ_EC=$?
  SQ_OUT2="$(sq_run_up "$@" RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$SQ_AW" 2>&1)" && SQ_EC2=0 || SQ_EC2=$?
  if [[ "$SQ_EC" -eq 0 && "$SQ_EC2" -eq 0 ]] \
    && [[ "$SQ_OUT" == *"no alert"* ]] \
    && [[ "$SQ_OUT" != *"sequencer-stalled"* ]] \
    && [[ "$SQ_OUT2" == *"condition sequencer-unreachable"* ]] \
    && [[ "$SQ_OUT2" != *"condition sequencer-stalled"* ]]; then
    echo "PASS alert-watch sequencer $label is not a fresh head"
  else
    echo "FAIL sequencer $label must reach sequencer-unreachable, not a fresh head (ec=$SQ_EC/$SQ_EC2)" >&2
    echo "$SQ_OUT" >&2
    echo "$SQ_OUT2" >&2
    fail=1
  fi
}
sq_cannot_verify "missing unsafe timestamp" \
  ALERT_WATCH_SEQUENCER_SYNC_JSON='{"jsonrpc":"2.0","id":1,"result":{"unsafe_l2":{"number":1930794},"current_l1":{"number":1},"head_l1":{"number":2}}}'
sq_cannot_verify "null unsafe timestamp" \
  ALERT_WATCH_SEQUENCER_SYNC_JSON='{"jsonrpc":"2.0","id":1,"result":{"unsafe_l2":{"number":1930794,"timestamp":null}}}'
sq_cannot_verify "malformed syncStatus JSON" \
  ALERT_WATCH_SEQUENCER_SYNC_JSON='{'
sq_cannot_verify "UNSAFE_AGE=none" \
  ALERT_WATCH_SEQUENCER_UNSAFE_AGE=none

# THROW must not skip a canned funding-fail in the same run.
sq_reset
sq_mark $SQ_CORE
printf '%s\n' '{"verdict":"FAIL","reason":"batcher below policy for 24.0 h with no top-up"}' \
  > "$SQ_FIX/funding-health.json"
SQ_OUT="$(sq_run_up ALERT_WATCH_SEQUENCER_THROW=1 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$SQ_AW" 2>&1)" && SQ_EC=0 || SQ_EC=$?
if [[ "$SQ_EC" -eq 0 ]] \
  && [[ "$SQ_OUT" == *"condition funding-fail"* ]] \
  && [[ "$SQ_OUT" != *"condition sequencer-unreachable"* ]] \
  && [[ "$(cat "$SQ_FIX/mock/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
  && ! printf '%s' "$SQ_OUT" | grep -qi 'traceback'; then
  echo "PASS alert-watch sequencer probe throw still evaluates funding-fail"
else
  echo "FAIL a sequencer probe throw must not prevent funding-fail from alerting (ec=$SQ_EC)" >&2
  echo "$SQ_OUT" >&2
  fail=1
fi

# Chain 901 never evaluates either condition.
sq_reset
SQ_OUT="$(sq_run L2_CHAIN_ID=901 \
  ALERT_WATCH_SEQUENCER_UNSAFE_AGE=601 \
  ALERT_WATCH_SEQUENCER_UNSAFE_NUMBER=1930794 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$SQ_AW" 2>&1)" && SQ_EC=0 || SQ_EC=$?
if [[ "$SQ_EC" -eq 0 ]] \
  && [[ ! -f "$SQ_FIX/mock/osascript.calls" ]] \
  && [[ "$SQ_OUT" == *"no alert"* ]] \
  && [[ "$SQ_OUT" != *"sequencer-stalled"* ]]; then
  echo "PASS alert-watch sequencer conditions do not evaluate when L2_CHAIN_ID=901"
else
  echo "FAIL L2_CHAIN_ID=901 must not fire sequencer-stalled (ec=$SQ_EC)" >&2
  echo "$SQ_OUT" >&2
  fail=1
fi
sq_reset
sq_run_up L2_CHAIN_ID=901 ALERT_WATCH_SEQUENCER_UNREACHABLE=1 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$SQ_AW" >/dev/null 2>&1 || true
rm -f "$SQ_FIX/mock"/osascript.calls "$SQ_FIX/mock"/curl.calls
SQ_OUT="$(sq_run_up L2_CHAIN_ID=901 ALERT_WATCH_SEQUENCER_UNREACHABLE=1 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$SQ_AW" 2>&1)" && SQ_EC=0 || SQ_EC=$?
if [[ "$SQ_EC" -eq 0 ]] \
  && [[ ! -f "$SQ_FIX/mock/osascript.calls" ]] \
  && [[ "$SQ_OUT" == *"no alert"* ]] \
  && [[ "$SQ_OUT" != *"sequencer-unreachable"* ]]; then
  echo "PASS alert-watch sequencer-unreachable does not evaluate when L2_CHAIN_ID=901"
else
  echo "FAIL L2_CHAIN_ID=901 must not fire sequencer-unreachable (ec=$SQ_EC)" >&2
  echo "$SQ_OUT" >&2
  fail=1
fi

# Op-node pid absent: two failures stay quiet (stack-missing owns that).
sq_reset
sq_mark
SQ_OUT="$(sq_run ALERT_WATCH_PID_DIR="$SQ_FIX/pids" \
  ALERT_WATCH_EXPECT_STACK=0 \
  FORTEL2_EL=geth \
  SEPOLIA_START_CHALLENGER=0 \
  ALERT_WATCH_SEQUENCER_UNREACHABLE=1 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$SQ_AW" 2>&1)" && SQ_EC=0 || SQ_EC=$?
SQ_OUT2="$(sq_run ALERT_WATCH_PID_DIR="$SQ_FIX/pids" \
  ALERT_WATCH_EXPECT_STACK=0 \
  FORTEL2_EL=geth \
  SEPOLIA_START_CHALLENGER=0 \
  ALERT_WATCH_SEQUENCER_UNREACHABLE=1 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$SQ_AW" 2>&1)" && SQ_EC2=0 || SQ_EC2=$?
if [[ "$SQ_EC" -eq 0 && "$SQ_EC2" -eq 0 ]] \
  && [[ ! -f "$SQ_FIX/mock/osascript.calls" ]] \
  && [[ "$SQ_OUT" == *"no alert"* ]] \
  && [[ "$SQ_OUT2" == *"no alert"* ]] \
  && [[ "$SQ_OUT2" != *"sequencer-unreachable"* ]]; then
  echo "PASS alert-watch sequencer-unreachable stays quiet when the op-node pid is absent"
else
  echo "FAIL a missing op-node pid must not fire sequencer-unreachable (ec=$SQ_EC/$SQ_EC2)" >&2
  echo "$SQ_OUT" >&2
  echo "$SQ_OUT2" >&2
  fail=1
fi

# Distinct cooldown: replica-head-stale already sent, sequencer-stalled still sends.
sq_reset
python3 - "$SQ_FIX/state.json" "$SQ_DAYTIME_NOW" <<'PY'
import json, sys
path, now = sys.argv[1], float(sys.argv[2])
with open(path, "w") as fh:
    json.dump({
        "cooldown": {
            "replica-head-stale": {"banner": now, "email": now},
        }
    }, fh)
    fh.write("\n")
PY
SQ_OUT="$(sq_run ALERT_WATCH_REPLICA_HEAD_AGE=10801 \
  ALERT_WATCH_SEQUENCER_UNSAFE_AGE=601 \
  ALERT_WATCH_SEQUENCER_UNSAFE_NUMBER=1930794 \
  ALERT_WATCH_SEQUENCER_CURRENT_L1=11856336 \
  ALERT_WATCH_SEQUENCER_HEAD_L1=11856340 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$SQ_AW" 2>&1)" && SQ_EC=0 || SQ_EC=$?
SQ_C="$(cat "$SQ_FIX/mock/curl.calls" 2>/dev/null || echo 0)"
if [[ "$SQ_EC" -eq 0 ]] \
  && [[ "$SQ_C" -eq 1 ]] \
  && [[ "$(cat "$SQ_FIX/mock/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
  && [[ "$SQ_OUT" == *"condition sequencer-stalled"* ]] \
  && [[ "$SQ_OUT" != *"condition replica-head-stale"* ]]; then
  echo "PASS alert-watch sequencer-stalled still sends while replica-head-stale is in cooldown"
else
  echo "FAIL a cooled replica-head-stale must not suppress sequencer-stalled (ec=$SQ_EC curl=$SQ_C)" >&2
  echo "$SQ_OUT" >&2
  fail=1
fi

# Fixture mode must not open a socket even if L2_NODE_RPC_URL is a live listener.
: > "$SQ_FIX/socket-hits"
python3 - "$SQ_FIX/socket-hits" "$SQ_FIX/socket-port" <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
hits, portfile = sys.argv[1], sys.argv[2]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        with open(hits, "a") as fh:
            fh.write("hit\n")
        body = b'{"jsonrpc":"2.0","id":1,"result":{}}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, fmt, *args):
        return
httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(portfile, "w") as fh:
    fh.write(str(httpd.server_address[1]))
httpd.serve_forever()
PY
SQ_SOCKET_PID=$!
SQ_PORT=""
for _sq_i in 1 2 3 4 5 6 7 8 9 10; do
  if [[ -s "$SQ_FIX/socket-port" ]]; then
    SQ_PORT="$(cat "$SQ_FIX/socket-port")"
    break
  fi
  sleep 0.05
done
sq_reset
SQ_OUT="$(sq_run ALERT_WATCH_SEQUENCER_UNSAFE_AGE=601 \
  L2_NODE_RPC_URL="http://127.0.0.1:${SQ_PORT}" \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$SQ_AW" 2>&1)" && SQ_EC=0 || SQ_EC=$?
SQ_HITS="$(wc -l < "$SQ_FIX/socket-hits" | tr -d ' ')"
if [[ -n "$SQ_PORT" && "$SQ_EC" -eq 0 && "$SQ_HITS" -eq 0 ]] \
  && [[ "$SQ_OUT" == *"condition sequencer-stalled"* ]]; then
  echo "PASS alert-watch sequencer fixture mode does not open a socket"
else
  echo "FAIL a sequencer fixture must not connect to L2_NODE_RPC_URL (port=${SQ_PORT:-missing} hits=$SQ_HITS ec=$SQ_EC)" >&2
  echo "$SQ_OUT" >&2
  fail=1
fi
kill "$SQ_SOCKET_PID" 2>/dev/null || true
wait "$SQ_SOCKET_PID" 2>/dev/null || true
SQ_SOCKET_PID=""

cleanup_sq
unset SQ_AW SQ_FIX SQ_DAYTIME_NOW SQ_CORE SQ_BLK SQ_OUT SQ_OUT2 SQ_EC SQ_EC2 \
  SQ_SLEEP_NOW SQ_GRACE_NOW SQ_AFTER_NOW SQ_C SQ_PORT SQ_HITS SQ_SOCKET_PID
unset -f sq_reset sq_stamp_now sq_mark sq_run sq_run_up sq_cannot_verify cleanup_sq 2>/dev/null || true
