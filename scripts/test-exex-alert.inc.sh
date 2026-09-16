# sourced by test-helpers.sh — do not run standalone
# alert-watch ExEx panic attribution. register_cleanup / register_tmp — never trap EXIT.

EXEX_AW="$SCRIPT_DIR/alert-watch.sh"
EXEX_FIX="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-exex-alert.XXXXXX")"
register_tmp "$EXEX_FIX"
cleanup_exex() {
  if [ -n "${EXEX_UNREAD:-}" ] && [ -e "$EXEX_UNREAD" ]; then
    chmod u+rw "$EXEX_UNREAD" 2>/dev/null || true
  fi
  rm -rf "$EXEX_FIX"
}
register_cleanup cleanup_exex

mkdir -p "$EXEX_FIX/shim" "$EXEX_FIX/mock" "$EXEX_FIX/data" "$EXEX_FIX/bin" \
  "$EXEX_FIX/deploy" "$EXEX_FIX/pids" "$EXEX_FIX/logs"
cat > "$EXEX_FIX/env" <<EOF
FORTEL2_ROOT=$EXEX_FIX
DATA_DIR=$EXEX_FIX/data
BIN_DIR=$EXEX_FIX/bin
DEPLOY_DIR=$EXEX_FIX/deploy
L2_CHAIN_ID=852
FORTEL2_EL=reth
EOF
cat > "$EXEX_FIX/shim/curl" <<'EOS'
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
cat > "$EXEX_FIX/shim/osascript" <<'EOS'
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
cat > "$EXEX_FIX/shim/launchctl" <<'EOS'
#!/bin/sh
printf 'gui/501/com.steve.fortel2-resolve-games = {\n\tstate = not running\n\tlast exit code = 0\n}\n'
exit 0
EOS
chmod +x "$EXEX_FIX/shim/curl" "$EXEX_FIX/shim/osascript" "$EXEX_FIX/shim/launchctl"

EXEX_START='reth 2.3.0-dev (9384bc5) starting'
EXEX_PANIC_DIV='thread '"'"'tokio-rt'"'"' panicked at crates/node/builder/src/launch/exex.rs:130:41:
ExEx proofs-history crashed: Parent hash mismatch at block 1045407:
  expected 0x21da8faeed91a224ba3a0d8de8fbef7da75aff744448c0e6b2b2caa988928740,
  got      0x4635c0367baffc1b608698108c294b56c0213724c5e2fd3bd06ebaa8e1493e46
ERROR Critical task `exex` panicked
ERROR shutting down due to error'
EXEX_PANIC_INIT='2026-08-31T15:46:28Z ERROR Critical task `exex` panicked:
  `ExEx proofs-history crashed: Proofs storage not initialized`'
EXEX_PANIC_OTHER='thread '"'"'tokio-rt'"'"' panicked at crates/node/builder/src/launch/exex.rs:130:41:
ExEx proofs-history crashed: I/O error opening proofs store
ERROR Critical task `exex` panicked
ERROR shutting down due to error'

exex_reset() {
  rm -f "$EXEX_FIX/mock"/curl.argv "$EXEX_FIX/mock"/curl.calls \
    "$EXEX_FIX/mock"/osascript.argv "$EXEX_FIX/mock"/osascript.calls \
    "$EXEX_FIX/state.json"
  : > "$EXEX_FIX/resolve.out.log"
  : > "$EXEX_FIX/resolve.err.log"
  printf '%s\n' '{"verdict":"OK","reason":"balance at or above the funding policy minimum"}' \
    > "$EXEX_FIX/funding-health.json"
}
exex_mark() {
  local n
  rm -f "$EXEX_FIX/pids"/*.pid
  for n in "$@"; do
    printf '%s\n' "$$" > "$EXEX_FIX/pids/$n.pid"
  done
}
exex_write_log() {
  printf '%s\n' "$1" > "$EXEX_FIX/logs/op-reth.log"
}
# Prefix enough noise that first-240 of the 1500-byte look-back is padding,
# and suffix enough that last-240 of idx+500 lookahead is shutdown fill.
# The quote is taken around the marker, so the panic must still appear.
exex_write_noisy_log() {
  python3 - "$EXEX_FIX/logs/op-reth.log" "$EXEX_START" "$1" <<'PY'
import sys
path, start, panic = sys.argv[1], sys.argv[2], sys.argv[3]
before = (
    "INFO Block added to canonical chain number=999 hash=0xabc "
    "gas_used=54.62Kgas\n"
) * 40
after = ("ERROR shutting down due to error peer=0xdeadbeef\n") * 20
with open(path, "w") as fh:
    fh.write(start + "\n" + before + panic + "\n" + after)
PY
}
exex_matched_quote() {
  python3 -c '
import re, sys
text = sys.stdin.read()
m = re.search(r"Matched: (.*?)(?:\. Remedy:|\. Do not guess)", text, re.S)
sys.stdout.write(m.group(1) if m else "")
'
}
exex_run() {
  env -u RESEND_API_TOKEN -u CHALLENGER_L1_RPC_URL \
    PATH="$EXEX_FIX/shim:$PATH" \
    FORTEL2_ENV="$EXEX_FIX/env" \
    L2_CHAIN_ID=852 \
    FORTEL2_EL=reth \
    ALERT_WATCH_MOCK_DIR="$EXEX_FIX/mock" \
    ALERT_WATCH_FUNDING_JSON="$EXEX_FIX/funding-health.json" \
    ALERT_WATCH_STATE="$EXEX_FIX/state.json" \
    ALERT_WATCH_RESOLVE_OUT="$EXEX_FIX/resolve.out.log" \
    ALERT_WATCH_RESOLVE_ERR="$EXEX_FIX/resolve.err.log" \
    ALERT_WATCH_PID_DIR="$EXEX_FIX/pids" \
    ALERT_WATCH_OP_RETH_LOG="$EXEX_FIX/logs/op-reth.log" \
    ALERT_WATCH_CURL="$EXEX_FIX/shim/curl" \
    ALERT_WATCH_OSASCRIPT="$EXEX_FIX/shim/osascript" \
    ALERT_WATCH_LAUNCHCTL="$EXEX_FIX/shim/launchctl" \
    ALERT_WATCH_REPLICA_HEAD_NUMBER=1 \
    ALERT_WATCH_REPLICA_HEAD_AGE=0 \
    ALERT_WATCH_CLOUDFLARED_METRICS='cloudflared_tunnel_ha_connections 4' \
    ALERT_WATCH_CLOUDFLARED_RUNS=1 \
    ALERT_EMAIL_TO='fortel2-alert-watch@example.invalid' \
    "$@"
}

EXEX_CORE="op-node op-batcher op-proposer l2-rpc-filter op-challenger"

# Source-level: enrichment, not a new condition; hooks documented; 64 KiB tail;
# evaluation fixtures skip the host log; argv still carries LOG_DIR for production.
EXEX_SRC_OK=1
grep -q 'ALERT_WATCH_OP_RETH_LOG' "$EXEX_AW" \
  && grep -q 'ALERT_WATCH_EXEX_THROW' "$EXEX_AW" \
  && grep -q 'ALERT_WATCH_EXEX_TAIL_BYTES' "$EXEX_AW" \
  && grep -q 'EXEX_TAIL_DEFAULT = 65536' "$EXEX_AW" \
  && grep -q 'ALERT_WATCH_OP_RETH_LOG:-$LOG_DIR/op-reth.log' "$EXEX_AW" \
  && grep -q 'cf_token_hint' "$EXEX_AW" \
  && ! grep -q 'add("exex' "$EXEX_AW" \
  && grep -q 'ALERT_WATCH_CURL' "$EXEX_AW" || EXEX_SRC_OK=0
# Offline skip lives in _exex_log_path (CURL/LAUNCHCTL → None).
python3 - "$EXEX_AW" <<'PY' || EXEX_SRC_OK=0
import sys
src = open(sys.argv[1]).read()
start = src.find("def _exex_log_path")
end = src.find("def _exex_last_start")
blk = src[start:end]
ok = (
    "ALERT_WATCH_OP_RETH_LOG" in blk
    and "ALERT_WATCH_CURL" in blk
    and "ALERT_WATCH_LAUNCHCTL" in blk
    and "return None" in blk
)
sys.exit(0 if ok else 1)
PY
# Recency uses last start banner + pid down, never mtime of op-reth.log.
python3 - "$EXEX_AW" <<'PY' || EXEX_SRC_OK=0
import sys
src = open(sys.argv[1]).read()
start = src.find("def exex_hint")
end = src.find("# Isolated so a missing")
blk = src[start:end]
ok = "getmtime" not in blk and "_exex_last_start" in blk
sys.exit(0 if ok else 1)
PY
if [[ "$EXEX_SRC_OK" -eq 1 ]]; then
  echo "PASS alert-watch ExEx scan is enrichment with 64 KiB tail, test hooks, and no host-log default"
else
  echo "FAIL alert-watch ExEx scan must enrich stack-* via a bounded tail and skip the host log under CURL" >&2
  fail=1
fi

if ! grep -E 'ALERT_WATCH_(OP_RETH_LOG|EXEX_THROW|EXEX_TAIL_BYTES)' \
     "$FORTEL2_ROOT/.env.example" "$FORTEL2_ROOT/.env.sepolia.example" \
     >/dev/null 2>&1; then
  echo "PASS ALERT_WATCH_OP_RETH_LOG / EXEX_* do not appear in env example files"
else
  echo "FAIL ALERT_WATCH_* ExEx hooks must never appear in env files (lib.sh set -a)" >&2
  fail=1
fi

_exex_help_out="$( "$EXEX_AW" --help )" && _exex_help_rc=0 || _exex_help_rc=$?
if [[ "$_exex_help_rc" -eq 0 ]] \
  && printf '%s' "$_exex_help_out" | grep -q 'ALERT_WATCH_OP_RETH_LOG' \
  && printf '%s' "$_exex_help_out" | grep -q 'ALERT_WATCH_EXEX_THROW' \
  && printf '%s' "$_exex_help_out" | grep -q 'stack-missing' \
  && ! printf '%s' "$_exex_help_out" | grep -q 'set -euo pipefail'; then
  echo "PASS alert-watch.sh --help prints ExEx test hooks from the header"
else
  echo "FAIL --help must include ALERT_WATCH_OP_RETH_LOG / ALERT_WATCH_EXEX_THROW (ec=$_exex_help_rc)" >&2
  fail=1
fi

# Fresh panic, op-reth down, others up → stack-missing names the divergent store.
exex_reset
exex_mark $EXEX_CORE
exex_write_log "${EXEX_START}
${EXEX_PANIC_DIV}"
EXEX_OUT="$(exex_run ALERT_WATCH_EXPECT_STACK=1 RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' \
  "$EXEX_AW" 2>&1)" && EXEX_EC=0 || EXEX_EC=$?
EXEX_BODY="$(cat "$EXEX_FIX/mock/osascript.argv" 2>/dev/null || true)"
if [[ "$EXEX_EC" -eq 0 ]] \
  && [[ "$EXEX_OUT" == *"condition stack-missing"* ]] \
  && [[ "$EXEX_OUT" != *"condition exex"* ]] \
  && printf '%s' "$EXEX_BODY" | grep -q 'Parent hash mismatch' \
  && printf '%s' "$EXEX_BODY" | grep -q 'divergent' \
  && printf '%s' "$EXEX_BODY" | grep -q 'historical-proofs' \
  && printf '%s' "$EXEX_BODY" | grep -q 'Do not run op-reth proofs init'; then
  echo "PASS alert-watch ExEx parent-hash mismatch is not the init remedy"
else
  echo "FAIL a fresh Parent hash mismatch with op-reth down must enrich stack-missing as delete-store (ec=$EXEX_EC)" >&2
  echo "$EXEX_OUT" >&2
  echo "$EXEX_BODY" >&2
  fail=1
fi

# Fresh init-class panic, everything down → stack-down names the missing store.
exex_reset
rm -f "$EXEX_FIX/pids"/*.pid
exex_write_log "${EXEX_START}
${EXEX_PANIC_INIT}"
EXEX_OUT="$(exex_run ALERT_WATCH_EXPECT_STACK=1 RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' \
  "$EXEX_AW" 2>&1)" && EXEX_EC=0 || EXEX_EC=$?
EXEX_BODY="$(cat "$EXEX_FIX/mock/osascript.argv" 2>/dev/null || true)"
if [[ "$EXEX_EC" -eq 0 ]] \
  && [[ "$EXEX_OUT" == *"condition stack-down"* ]] \
  && printf '%s' "$EXEX_BODY" | grep -q 'not initialized' \
  && printf '%s' "$EXEX_BODY" | grep -q 'proofs init' \
  && printf '%s' "$EXEX_BODY" | grep -q 'Do not delete' \
  && ! printf '%s' "$EXEX_BODY" | grep -q 'Parent hash mismatch' \
  && ! printf '%s' "$EXEX_BODY" | grep -q 'divergent'; then
  echo "PASS alert-watch ExEx uninitialized is not the delete-store remedy"
else
  echo "FAIL a fresh Proofs storage not initialized with op-reth down must enrich stack-down as init (ec=$EXEX_EC)" >&2
  echo "$EXEX_OUT" >&2
  echo "$EXEX_BODY" >&2
  fail=1
fi

# Quote must contain the panic, not the 1500-byte look-back padding.
# Dedicated noisy fixtures: first-240 truncation of ctx is noise.
exex_reset
exex_mark $EXEX_CORE
exex_write_noisy_log "$EXEX_PANIC_DIV"
EXEX_OUT="$(exex_run ALERT_WATCH_EXPECT_STACK=1 RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' \
  "$EXEX_AW" 2>&1)" && EXEX_EC=0 || EXEX_EC=$?
EXEX_BODY="$(cat "$EXEX_FIX/mock/osascript.argv" 2>/dev/null || true)"
EXEX_QUOTE="$(printf '%s' "$EXEX_BODY" | exex_matched_quote)"
if [[ "$EXEX_EC" -eq 0 ]] \
  && printf '%s' "$EXEX_QUOTE" | grep -q 'expected 0x21da8fae' \
  && printf '%s' "$EXEX_QUOTE" | grep -q 'Critical task `exex` panicked'; then
  echo "PASS alert-watch ExEx matched quote contains the parent-hash panic"
  echo "QUOTE parent-hash: $EXEX_QUOTE"
else
  echo "FAIL parent-hash Matched quote must contain the panic text, not look-back padding (ec=$EXEX_EC)" >&2
  echo "QUOTE=$EXEX_QUOTE" >&2
  echo "$EXEX_BODY" >&2
  fail=1
fi

exex_reset
rm -f "$EXEX_FIX/pids"/*.pid
exex_write_noisy_log "$EXEX_PANIC_INIT"
EXEX_OUT="$(exex_run ALERT_WATCH_EXPECT_STACK=1 RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' \
  "$EXEX_AW" 2>&1)" && EXEX_EC=0 || EXEX_EC=$?
EXEX_BODY="$(cat "$EXEX_FIX/mock/osascript.argv" 2>/dev/null || true)"
EXEX_QUOTE="$(printf '%s' "$EXEX_BODY" | exex_matched_quote)"
if [[ "$EXEX_EC" -eq 0 ]] \
  && printf '%s' "$EXEX_QUOTE" | grep -q 'Proofs storage not initialized' \
  && printf '%s' "$EXEX_QUOTE" | grep -q 'Critical task `exex` panicked'; then
  echo "PASS alert-watch ExEx matched quote contains the uninitialized panic"
  echo "QUOTE uninitialized: $EXEX_QUOTE"
else
  echo "FAIL uninitialized Matched quote must contain the panic text, not look-back padding (ec=$EXEX_EC)" >&2
  echo "QUOTE=$EXEX_QUOTE" >&2
  echo "$EXEX_BODY" >&2
  fail=1
fi

# The remedy must name a path the operator can paste. $DATADIR is script-local to
# 04-start-sequencer-sepolia.sh and unset in an operator shell, so printing it makes
# `rm -rf $DATADIR/historical-proofs` a silent no-op during an outage (Codex P1 on #240).
exex_reset
rm -f "$EXEX_FIX/pids"/*.pid
exex_write_noisy_log "$EXEX_PANIC_DIV"
EXEX_OUT="$(exex_run ALERT_WATCH_EXPECT_STACK=1 RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' \
  "$EXEX_AW" 2>&1)" && EXEX_EC=0 || EXEX_EC=$?
EXEX_BODY="$(cat "$EXEX_FIX/mock/osascript.argv" 2>/dev/null || true)"
if [[ "$EXEX_EC" -eq 0 ]] \
  && ! printf '%s' "$EXEX_BODY" | grep -q 'DATADIR' \
  && printf '%s' "$EXEX_BODY" | grep -q "delete $EXEX_FIX/data/l2/op-reth/historical-proofs"; then
  echo "PASS alert-watch ExEx remedy names a resolved absolute proofs-store path"
else
  echo "FAIL ExEx remedy must print the resolved store path, never the script-local \$DATADIR (ec=$EXEX_EC)" >&2
  echo "$EXEX_BODY" >&2
  fail=1
fi

exex_reset
rm -f "$EXEX_FIX/pids"/*.pid
exex_write_noisy_log "$EXEX_PANIC_OTHER"
EXEX_OUT="$(exex_run ALERT_WATCH_EXPECT_STACK=1 RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' \
  "$EXEX_AW" 2>&1)" && EXEX_EC=0 || EXEX_EC=$?
EXEX_BODY="$(cat "$EXEX_FIX/mock/osascript.argv" 2>/dev/null || true)"
EXEX_QUOTE="$(printf '%s' "$EXEX_BODY" | exex_matched_quote)"
if [[ "$EXEX_EC" -eq 0 ]] \
  && [[ "$EXEX_OUT" == *"condition stack-down"* ]] \
  && printf '%s' "$EXEX_BODY" | grep -q 'unclassified' \
  && printf '%s' "$EXEX_QUOTE" | grep -q 'I/O error opening proofs store' \
  && printf '%s' "$EXEX_QUOTE" | grep -q 'Critical task `exex` panicked' \
  && ! printf '%s' "$EXEX_BODY" | grep -q 'divergent' \
  && ! printf '%s' "$EXEX_BODY" | grep -q 'not initialized'; then
  echo "PASS alert-watch ExEx matched quote contains the unclassified panic"
  echo "QUOTE unclassified: $EXEX_QUOTE"
else
  echo "FAIL unclassified Matched quote must contain the panic text, not look-back padding (ec=$EXEX_EC)" >&2
  echo "QUOTE=$EXEX_QUOTE" >&2
  echo "$EXEX_BODY" >&2
  fail=1
fi

# Headline: stale panic in the log, op-reth pid alive → silent.
exex_reset
exex_mark op-reth $EXEX_CORE
exex_write_log "${EXEX_START}
${EXEX_PANIC_INIT}
healthy status latest_block=1045408"
EXEX_OUT="$(exex_run ALERT_WATCH_EXPECT_STACK=1 RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' \
  "$EXEX_AW" 2>&1)" && EXEX_EC=0 || EXEX_EC=$?
if [[ "$EXEX_EC" -eq 0 ]] \
  && [[ ! -f "$EXEX_FIX/mock/osascript.calls" ]] \
  && [[ "$EXEX_OUT" == *"no alert"* ]] \
  && [[ "$EXEX_OUT" != *"ExEx cause"* ]]; then
  echo "PASS alert-watch ExEx scan is silent on a stale panic while op-reth is healthy"
else
  echo "FAIL a historical ExEx panic must not page while op-reth is up (ec=$EXEX_EC)" >&2
  echo "$EXEX_OUT" >&2
  fail=1
fi

# Recency: op-reth down, panic BEFORE the last start banner, no panic after.
exex_reset
rm -f "$EXEX_FIX/pids"/*.pid
exex_write_log "${EXEX_PANIC_DIV}

${EXEX_START}
Status latest_block=1045561"
EXEX_OUT="$(exex_run ALERT_WATCH_EXPECT_STACK=1 RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' \
  "$EXEX_AW" 2>&1)" && EXEX_EC=0 || EXEX_EC=$?
EXEX_BODY="$(cat "$EXEX_FIX/mock/osascript.argv" 2>/dev/null || true)"
if [[ "$EXEX_EC" -eq 0 ]] \
  && [[ "$EXEX_OUT" == *"condition stack-down"* ]] \
  && [[ "$(cat "$EXEX_FIX/mock/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
  && ! printf '%s' "$EXEX_BODY" | grep -q 'ExEx cause' \
  && ! printf '%s' "$EXEX_BODY" | grep -q 'Parent hash mismatch'; then
  echo "PASS alert-watch ExEx scan ignores a panic before the last start banner"
else
  echo "FAIL stack-down must still fire, but a panic before the last start must not be attributed (ec=$EXEX_EC)" >&2
  echo "$EXEX_OUT" >&2
  echo "$EXEX_BODY" >&2
  fail=1
fi

# Challenger missing, op-reth alive, panic in log → stack-missing without ExEx.
exex_reset
exex_mark op-reth op-node op-batcher op-proposer l2-rpc-filter
exex_write_log "${EXEX_START}
${EXEX_PANIC_DIV}"
EXEX_OUT="$(exex_run ALERT_WATCH_EXPECT_STACK=1 RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' \
  "$EXEX_AW" 2>&1)" && EXEX_EC=0 || EXEX_EC=$?
EXEX_BODY="$(cat "$EXEX_FIX/mock/osascript.argv" 2>/dev/null || true)"
if [[ "$EXEX_EC" -eq 0 ]] \
  && [[ "$EXEX_OUT" == *"condition stack-missing"* ]] \
  && printf '%s' "$EXEX_BODY" | grep -q 'op-challenger' \
  && ! printf '%s' "$EXEX_BODY" | grep -q 'ExEx cause'; then
  echo "PASS alert-watch ExEx scan does not attribute a panic when op-reth is still up"
else
  echo "FAIL missing challenger must not inherit ExEx text while op-reth is alive (ec=$EXEX_EC)" >&2
  echo "$EXEX_OUT" >&2
  echo "$EXEX_BODY" >&2
  fail=1
fi

# Log missing: stack-down still fires, no ExEx text.
exex_reset
rm -f "$EXEX_FIX/pids"/*.pid "$EXEX_FIX/logs/op-reth.log"
EXEX_OUT="$(exex_run ALERT_WATCH_EXPECT_STACK=1 RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' \
  "$EXEX_AW" 2>&1)" && EXEX_EC=0 || EXEX_EC=$?
EXEX_BODY="$(cat "$EXEX_FIX/mock/osascript.argv" 2>/dev/null || true)"
if [[ "$EXEX_EC" -eq 0 ]] \
  && [[ "$EXEX_OUT" == *"condition stack-down"* ]] \
  && ! printf '%s' "$EXEX_BODY" | grep -q 'ExEx cause'; then
  echo "PASS alert-watch ExEx scan stays quiet when the log is missing"
else
  echo "FAIL a missing op-reth.log must not prevent stack-down or invent an ExEx cause (ec=$EXEX_EC)" >&2
  echo "$EXEX_OUT" >&2
  fail=1
fi

# Log unreadable: same.
exex_reset
rm -f "$EXEX_FIX/pids"/*.pid
exex_write_log "${EXEX_START}
${EXEX_PANIC_DIV}"
EXEX_UNREAD="$EXEX_FIX/logs/op-reth.log"
chmod 000 "$EXEX_UNREAD"
EXEX_OUT="$(exex_run ALERT_WATCH_EXPECT_STACK=1 RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' \
  "$EXEX_AW" 2>&1)" && EXEX_EC=0 || EXEX_EC=$?
chmod u+rw "$EXEX_UNREAD" 2>/dev/null || true
EXEX_BODY="$(cat "$EXEX_FIX/mock/osascript.argv" 2>/dev/null || true)"
if [[ "$EXEX_EC" -eq 0 ]] \
  && [[ "$EXEX_OUT" == *"condition stack-down"* ]] \
  && ! printf '%s' "$EXEX_BODY" | grep -q 'ExEx cause'; then
  echo "PASS alert-watch ExEx scan stays quiet when the log is unreadable"
else
  echo "FAIL an unreadable op-reth.log must not prevent stack-down (ec=$EXEX_EC)" >&2
  echo "$EXEX_OUT" >&2
  fail=1
fi

# Log present, no panic.
exex_reset
rm -f "$EXEX_FIX/pids"/*.pid
exex_write_log "${EXEX_START}
Status latest_block=1045561"
EXEX_OUT="$(exex_run ALERT_WATCH_EXPECT_STACK=1 RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' \
  "$EXEX_AW" 2>&1)" && EXEX_EC=0 || EXEX_EC=$?
EXEX_BODY="$(cat "$EXEX_FIX/mock/osascript.argv" 2>/dev/null || true)"
if [[ "$EXEX_EC" -eq 0 ]] \
  && [[ "$EXEX_OUT" == *"condition stack-down"* ]] \
  && ! printf '%s' "$EXEX_BODY" | grep -q 'ExEx cause'; then
  echo "PASS alert-watch ExEx scan stays quiet when the log has no panic"
else
  echo "FAIL a healthy-looking log must not attribute ExEx while still firing stack-down (ec=$EXEX_EC)" >&2
  echo "$EXEX_OUT" >&2
  fail=1
fi

# Isolation: throw inside the scan, funding-fail still evaluates (and stack-down).
exex_reset
rm -f "$EXEX_FIX/pids"/*.pid
exex_write_log "${EXEX_START}
${EXEX_PANIC_DIV}"
printf '%s\n' '{"verdict":"FAIL","reason":"batcher below policy for 24.0 h with no top-up"}' \
  > "$EXEX_FIX/funding-health.json"
EXEX_OUT="$(exex_run ALERT_WATCH_EXEX_THROW=1 ALERT_WATCH_EXPECT_STACK=1 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$EXEX_AW" 2>&1)" && EXEX_EC=0 || EXEX_EC=$?
if [[ "$EXEX_EC" -eq 0 ]] \
  && [[ "$EXEX_OUT" == *"condition funding-fail"* ]] \
  && [[ "$EXEX_OUT" == *"condition stack-down"* ]] \
  && [[ "$(cat "$EXEX_FIX/mock/osascript.calls" 2>/dev/null || echo 0)" -ge 1 ]] \
  && ! printf '%s' "$EXEX_OUT" | grep -qi 'traceback'; then
  echo "PASS alert-watch ExEx scan throw still evaluates funding-fail"
else
  echo "FAIL an ExEx scan throw must not prevent funding-fail or stack-down (ec=$EXEX_EC)" >&2
  echo "$EXEX_OUT" >&2
  fail=1
fi

# Cooldown: two runs of the same enriched stack-down send once.
exex_reset
rm -f "$EXEX_FIX/pids"/*.pid
exex_write_log "${EXEX_START}
${EXEX_PANIC_DIV}"
exex_run ALERT_WATCH_EXPECT_STACK=1 RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' \
  "$EXEX_AW" >/dev/null 2>&1 || true
EXEX_C1="$(cat "$EXEX_FIX/mock/curl.calls" 2>/dev/null || echo 0)"
exex_run ALERT_WATCH_EXPECT_STACK=1 RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' \
  "$EXEX_AW" >/dev/null 2>&1 || true
EXEX_C2="$(cat "$EXEX_FIX/mock/curl.calls" 2>/dev/null || echo 0)"
if [[ "$EXEX_C1" -eq 1 && "$EXEX_C2" -eq 1 ]]; then
  echo "PASS alert-watch ExEx-enriched stack-down cooldown suppresses a second send"
else
  echo "FAIL enriched stack-down must send once inside ALERT_REALERT_HOURS (c1=$EXEX_C1 c2=$EXEX_C2)" >&2
  fail=1
fi

# Tail bound: panic only in the prefix of a file larger than 64 KiB.
# No later start banner — recency must not paper over a whole-file read.
exex_reset
rm -f "$EXEX_FIX/pids"/*.pid
python3 - "$EXEX_FIX/logs/op-reth.log" "$EXEX_PANIC_DIV" <<'PY'
import sys
path, panic = sys.argv[1], sys.argv[2]
prefix = (panic + "\n").encode("utf-8")
pad = b"x" * (90 * 1024 - len(prefix))
with open(path, "wb") as fh:
    fh.write(prefix + pad)
PY
EXEX_OUT="$(exex_run ALERT_WATCH_EXPECT_STACK=1 RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' \
  "$EXEX_AW" 2>&1)" && EXEX_EC=0 || EXEX_EC=$?
EXEX_BODY="$(cat "$EXEX_FIX/mock/osascript.argv" 2>/dev/null || true)"
if [[ "$EXEX_EC" -eq 0 ]] \
  && [[ "$EXEX_OUT" == *"condition stack-down"* ]] \
  && ! printf '%s' "$EXEX_BODY" | grep -q 'ExEx cause' \
  && ! printf '%s' "$EXEX_BODY" | grep -q 'Parent hash mismatch'; then
  echo "PASS alert-watch ExEx scan does not read a panic outside the tail window"
else
  echo "FAIL a panic past the 64 KiB tail must not be attributed (ec=$EXEX_EC)" >&2
  echo "$EXEX_OUT" >&2
  echo "$EXEX_BODY" >&2
  fail=1
fi

# Tail bound positive: panic in the last 64 KiB of a larger file is attributed.
exex_reset
rm -f "$EXEX_FIX/pids"/*.pid
python3 - "$EXEX_FIX/logs/op-reth.log" "$EXEX_PANIC_DIV" "$EXEX_START" <<'PY'
import sys
path, panic, start = sys.argv[1], sys.argv[2], sys.argv[3]
pad = b"y" * (90 * 1024)
tail = ("\n" + start + "\n" + panic + "\n").encode("utf-8")
with open(path, "wb") as fh:
    fh.write(pad + tail)
PY
EXEX_OUT="$(exex_run ALERT_WATCH_EXPECT_STACK=1 RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' \
  "$EXEX_AW" 2>&1)" && EXEX_EC=0 || EXEX_EC=$?
EXEX_BODY="$(cat "$EXEX_FIX/mock/osascript.argv" 2>/dev/null || true)"
if [[ "$EXEX_EC" -eq 0 ]] \
  && printf '%s' "$EXEX_BODY" | grep -q 'Parent hash mismatch' \
  && printf '%s' "$EXEX_BODY" | grep -q 'divergent'; then
  echo "PASS alert-watch ExEx scan attributes a panic inside the tail window of a large file"
else
  echo "FAIL a panic in the last 64 KiB of a large file must be attributed (ec=$EXEX_EC)" >&2
  echo "$EXEX_OUT" >&2
  echo "$EXEX_BODY" >&2
  fail=1
fi

# Both classes in one tail: LAST panic after last start wins (divergent, not init).
exex_reset
exex_mark $EXEX_CORE
exex_write_log "${EXEX_PANIC_INIT}

${EXEX_START}
${EXEX_PANIC_DIV}"
EXEX_OUT="$(exex_run ALERT_WATCH_EXPECT_STACK=1 RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' \
  "$EXEX_AW" 2>&1)" && EXEX_EC=0 || EXEX_EC=$?
EXEX_BODY="$(cat "$EXEX_FIX/mock/osascript.argv" 2>/dev/null || true)"
if [[ "$EXEX_EC" -eq 0 ]] \
  && printf '%s' "$EXEX_BODY" | grep -q 'divergent' \
  && printf '%s' "$EXEX_BODY" | grep -q 'Do not run op-reth proofs init' \
  && ! printf '%s' "$EXEX_BODY" | grep -q 'proofs store not initialized'; then
  echo "PASS alert-watch ExEx scan classifies the last panic after the last start"
else
  echo "FAIL last panic after last start must win when both classes are in the tail (ec=$EXEX_EC)" >&2
  echo "$EXEX_OUT" >&2
  echo "$EXEX_BODY" >&2
  fail=1
fi

cleanup_exex
unset EXEX_AW EXEX_FIX EXEX_START EXEX_PANIC_DIV EXEX_PANIC_INIT EXEX_PANIC_OTHER EXEX_CORE
unset EXEX_OUT EXEX_EC EXEX_BODY EXEX_QUOTE EXEX_C1 EXEX_C2 EXEX_SRC_OK EXEX_UNREAD
unset _exex_help_out _exex_help_rc
unset -f cleanup_exex exex_reset exex_mark exex_write_log exex_write_noisy_log \
  exex_matched_quote exex_run 2>/dev/null || true
