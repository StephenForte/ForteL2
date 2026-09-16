# sourced by test-helpers.sh — do not run standalone
# log-hygiene-and-resolver-temp. register_cleanup / register_tmp — never trap EXIT.

LOGHYG_FIX="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-loghyg.XXXXXX")"
register_tmp "$LOGHYG_FIX"
cleanup_loghyg() {
  if [[ -n "${LOGHYG_WRITER_PID:-}" ]]; then
    kill "$LOGHYG_WRITER_PID" 2>/dev/null || true
    wait "$LOGHYG_WRITER_PID" 2>/dev/null || true
    LOGHYG_WRITER_PID=""
  fi
  rm -rf "$LOGHYG_FIX"
}
register_cleanup cleanup_loghyg
# shellcheck disable=SC1091
source "$SCRIPT_DIR/rotate-logs.sh"

LOGHYG_UNDER="$LOGHYG_FIX/under.log"
dd if=/dev/zero of="$LOGHYG_UNDER" bs=100 count=1 2>/dev/null
FORTEL2_LOG_ROTATE_BYTES=1000 FORTEL2_LOG_ROTATE_KEEP=5 rotate_log_file "$LOGHYG_UNDER"
if [[ -f "$LOGHYG_UNDER" && ! -f "${LOGHYG_UNDER}.1" ]] \
  && [[ "$(wc -c < "$LOGHYG_UNDER" | tr -d '[:space:]')" -eq 100 ]]; then
  echo "PASS log rotation under threshold leaves the file alone"
else
  echo "FAIL under-threshold log must not rotate" >&2
  fail=1
fi

LOGHYG_OVER="$LOGHYG_FIX/over.log"
dd if=/dev/zero of="$LOGHYG_OVER" bs=200 count=1 2>/dev/null
printf 'keep-me\n' >> "$LOGHYG_OVER"
FORTEL2_LOG_ROTATE_BYTES=150 FORTEL2_LOG_ROTATE_KEEP=5 rotate_log_file "$LOGHYG_OVER"
if [[ -f "${LOGHYG_OVER}.1" ]] \
  && grep -q 'keep-me' "${LOGHYG_OVER}.1" \
  && [[ "$(wc -c < "$LOGHYG_OVER" | tr -d '[:space:]')" -eq 0 ]]; then
  echo "PASS log rotation at threshold copies then truncates"
else
  echo "FAIL at-threshold log must copy then truncate in place" >&2
  fail=1
fi

LOGHYG_KEEP="$LOGHYG_FIX/keep.log"
LOGHYG_I=0
while [[ "$LOGHYG_I" -lt 3 ]]; do
  dd if=/dev/zero of="$LOGHYG_KEEP" bs=200 count=1 2>/dev/null
  printf 'gen-%s\n' "$LOGHYG_I" >> "$LOGHYG_KEEP"
  FORTEL2_LOG_ROTATE_BYTES=50 FORTEL2_LOG_ROTATE_KEEP=2 rotate_log_file "$LOGHYG_KEEP"
  LOGHYG_I=$((LOGHYG_I + 1))
done
if [[ -f "${LOGHYG_KEEP}.1" && -f "${LOGHYG_KEEP}.2" && ! -f "${LOGHYG_KEEP}.3" ]] \
  && grep -q 'gen-2' "${LOGHYG_KEEP}.1" \
  && grep -q 'gen-1' "${LOGHYG_KEEP}.2"; then
  echo "PASS log rotation honouring keep=2 drops the oldest copy"
else
  echo "FAIL retention keep=2 must leave .1 and .2 only" >&2
  ls -l "$LOGHYG_FIX"/keep.log* >&2 || true
  fail=1
fi

loghyg_live_reclaim() {
  local rotator="$1"
  local dir f marker before_ino after_ino before_blocks after_blocks wpid ok
  dir="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-loghyg-live.XXXXXX")"
  f="$dir/op-reth.log"
  python3 -c 'import sys; open(sys.argv[1],"wb").write(b"x"*20000)' "$f"
  marker="LIVE-MARKER-$$"
  python3 - "$f" "$marker" <<'LIVEPY' &
import os, sys, time
path, marker = sys.argv[1], sys.argv[2]
fd = os.open(path, os.O_WRONLY | os.O_APPEND)
while True:
    os.write(fd, (marker + "\n").encode())
    time.sleep(0.05)
LIVEPY
  wpid=$!
  sleep 0.2
  before_ino="$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$f")"
  before_blocks="$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_blocks)' "$f")"
  echo "loghyg df-before $(df -k "$dir" | tail -1)"
  echo "loghyg live-before ino=$before_ino blocks=$before_blocks size=$(wc -c < "$f" | tr -d '[:space:]')"
  FORTEL2_LOG_ROTATE_BYTES=1000 FORTEL2_LOG_ROTATE_KEEP=5 "$rotator" "$f"
  after_ino="$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$f")"
  after_blocks="$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_blocks)' "$f")"
  echo "loghyg df-after $(df -k "$dir" | tail -1)"
  echo "loghyg live-after ino=$after_ino blocks=$after_blocks size=$(wc -c < "$f" | tr -d '[:space:]')"
  sleep 0.25
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  ok=0
  if [[ "$before_ino" == "$after_ino" ]] \
    && [[ "$after_blocks" -lt "$before_blocks" ]] \
    && [[ -f "${f}.1" ]] \
    && grep -q "$marker" "$f"; then
    ok=1
  fi
  rm -rf "$dir"
  [[ "$ok" -eq 1 ]]
}

if loghyg_live_reclaim "$SCRIPT_DIR/rotate-logs.sh"; then
  echo "PASS log rotation reclaims blocks from a live O_APPEND writer"
else
  echo "FAIL live-writer rotation must keep the inode, drop blocks, and keep appending on the live path" >&2
  fail=1
fi

LOGHYG_STARTS=(
  01-start-l1.sh
  04-start-sequencer.sh
  04-start-sequencer-sepolia.sh
  05-start-batcher.sh
  05-start-batcher-sepolia.sh
  06-start-proposer.sh
  06-start-proposer-sepolia.sh
  07-start-rpc-filter-sepolia.sh
  09-start-challenger-sepolia.sh
  start-l1-batch-proxy-sepolia.sh
  start-op-reth-verifier.sh
  start-all.sh
  start-all-sepolia.sh
)
LOGHYG_START_OK=1
for LOGHYG_S in "${LOGHYG_STARTS[@]}"; do
  if ! grep -q 'rotate-logs.sh" --dir "$LOG_DIR"' "$SCRIPT_DIR/$LOGHYG_S"; then
    echo "FAIL $LOGHYG_S must call rotate-logs.sh --dir \"\$LOG_DIR\"" >&2
    LOGHYG_START_OK=0
  fi
done
if awk 'BEGIN{p=0} /--print-plan/{p=1} p && /rotate-logs.sh/{found=1} /exit 0/{if(p){exit}} END{exit found?0:1}' "$SCRIPT_DIR/04-start-sequencer-sepolia.sh"; then
  echo "FAIL 04-start-sequencer-sepolia.sh --print-plan must not rotate logs" >&2
  LOGHYG_START_OK=0
fi
if [[ "$LOGHYG_START_OK" -eq 1 ]]; then
  echo "PASS start scripts rotate \$LOG_DIR before start_bg"
else
  fail=1
fi

LOGHYG_TS_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4} '
LOGHYG_WRAP="$LOGHYG_FIX/wrap"
mkdir -p "$LOGHYG_WRAP/scripts"
cp "$SCRIPT_DIR/../run_dev_wake.sh" "$SCRIPT_DIR/../run_dev_sleep.sh" "$SCRIPT_DIR/../refresh_health.sh" "$LOGHYG_WRAP/"
cat > "$LOGHYG_WRAP/scripts/dev-sleep.sh" <<'STUBSLEEP'
#!/bin/zsh
echo "child $1 stdout"
echo "child $1 stderr" >&2
exit 0
STUBSLEEP
chmod +x "$LOGHYG_WRAP/scripts/dev-sleep.sh"
printf '%s\n' 'print("snapshot-ok")' 'open("data/pipeline-health.json.tmp","w").write("{}\n")' > "$LOGHYG_WRAP/scripts/pipeline-snapshot.py"
cat > "$LOGHYG_WRAP/scripts/gas-runway.sh" <<'STUBGAS'
#!/bin/zsh
echo gas-ok
exit 0
STUBGAS
cat > "$LOGHYG_WRAP/scripts/funding-watch.sh" <<'STUBFUND'
#!/bin/zsh
echo funding-ok
exit 0
STUBFUND
chmod +x "$LOGHYG_WRAP/scripts/gas-runway.sh" "$LOGHYG_WRAP/scripts/funding-watch.sh"
LOGHYG_ZSH_OK=1
for LOGHYG_W in run_dev_wake.sh run_dev_sleep.sh refresh_health.sh; do
  if ! zsh -n "$SCRIPT_DIR/../$LOGHYG_W"; then
    echo "FAIL zsh -n $LOGHYG_W" >&2
    LOGHYG_ZSH_OK=0
  fi
done
if [[ "$LOGHYG_ZSH_OK" -eq 1 ]]; then
  echo "PASS zsh -n on wake/sleep/health wrappers"
else
  fail=1
fi

loghyg_all_lines_stamped() {
  local out="$1"
  local line
  [[ -n "$out" ]] || return 1
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ $LOGHYG_TS_RE ]] || return 1
  done <<< "$out"
  return 0
}

LOGHYG_WAKE_OUT="$("$LOGHYG_WRAP/run_dev_wake.sh" 2>&1)" && LOGHYG_WAKE_EC=0 || LOGHYG_WAKE_EC=$?
LOGHYG_SLEEP_OUT="$("$LOGHYG_WRAP/run_dev_sleep.sh" 2>&1)" && LOGHYG_SLEEP_EC=0 || LOGHYG_SLEEP_EC=$?
mkdir -p "$LOGHYG_WRAP/data"
LOGHYG_HEALTH_OUT="$(cd "$LOGHYG_WRAP" && ./refresh_health.sh 2>&1)" && LOGHYG_HEALTH_EC=0 || LOGHYG_HEALTH_EC=$?
echo "loghyg sample wake: $(printf '%s\n' "$LOGHYG_WAKE_OUT" | head -1)"
echo "loghyg sample sleep: $(printf '%s\n' "$LOGHYG_SLEEP_OUT" | head -1)"
echo "loghyg sample health: $(printf '%s\n' "$LOGHYG_HEALTH_OUT" | head -1)"
if [[ "$LOGHYG_WAKE_EC" -eq 0 && "$LOGHYG_SLEEP_EC" -eq 0 && "$LOGHYG_HEALTH_EC" -eq 0 ]] \
  && loghyg_all_lines_stamped "$LOGHYG_WAKE_OUT" \
  && loghyg_all_lines_stamped "$LOGHYG_SLEEP_OUT" \
  && loghyg_all_lines_stamped "$LOGHYG_HEALTH_OUT" \
  && printf '%s\n' "$LOGHYG_WAKE_OUT" | grep -q 'child wake stdout' \
  && printf '%s\n' "$LOGHYG_WAKE_OUT" | grep -q 'child wake stderr'; then
  echo "PASS launchd wrappers stamp every line with local ISO-8601"
else
  echo "FAIL wrappers must timestamp stdout and stderr (wake_ec=$LOGHYG_WAKE_EC sleep_ec=$LOGHYG_SLEEP_EC health_ec=$LOGHYG_HEALTH_EC)" >&2
  printf '%s\n' "$LOGHYG_WAKE_OUT" "$LOGHYG_SLEEP_OUT" "$LOGHYG_HEALTH_OUT" >&2
  fail=1
fi

LOGHYG_RG="$SCRIPT_DIR/resolve-games-sepolia.sh"
LOGHYG_RG_PY_DIR="$(dirname "$(command -v python3)")"
LOGHYG_RG_PATH="$LOGHYG_RG_PY_DIR:/usr/bin:/bin"
LOGHYG_RG_FIX="$LOGHYG_FIX/rg"
mkdir -p "$LOGHYG_RG_FIX"

python3 - "$LOGHYG_RG_FIX" <<'RGSNP'
import json, os, sys
root = sys.argv[1]

def game(idx, status=0, credit=0, resolved_sub=False, resolved_at=0, created_at=990000):
    return {
        "index": idx,
        "game_type": 8,
        "address": "0x00000000000000000000000000000000000000%02x" % idx,
        "created_at": created_at,
        "max_clock_duration": 7200,
        "status": status,
        "resolved_at": resolved_at,
        "credit_wei": str(credit),
        "claim_data_len": 1,
        "resolved_subgame": resolved_sub,
        "weth_amount_wei": "0",
        "weth_unlock_ts": 0,
    }

def snap(path, games):
    doc = {
        "now": 1000000,
        "mode": "execute",
        "finality_delay": 1800,
        "weth_delay": 3600,
        "init_bond_wei": "0",
        "respected_game_type": 8,
        "games": games,
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f)
        f.write("\n")

success = os.path.join(root, "success")
os.makedirs(os.path.join(success, "fetch"), exist_ok=True)
open(os.path.join(success, "now"), "w").write("1000000\n")
snap(os.path.join(success, "snapshot.json"), [game(1)])
states = [
    game(1, status=0, resolved_sub=False),
    game(1, status=0, resolved_sub=True),
    game(1, status=0, resolved_sub=True),
    game(1, status=2, resolved_sub=True, resolved_at=990000),
    game(1, status=2, resolved_sub=True, resolved_at=990000),
]
for n, g in enumerate(states, 1):
    with open(os.path.join(success, "fetch", "1.%d.json" % n), "w") as f:
        json.dump(g, f)

fail = os.path.join(root, "fail")
os.makedirs(os.path.join(fail, "fetch"), exist_ok=True)
open(os.path.join(fail, "now"), "w").write("0\n")
snap(os.path.join(fail, "snapshot.json"), [game(1)])

intr = os.path.join(root, "intr")
os.makedirs(os.path.join(intr, "fetch"), exist_ok=True)
open(os.path.join(intr, "now"), "w").write("1000000\n")
snap(os.path.join(intr, "snapshot.json"), [game(1)])
open(os.path.join(intr, "fetch", "1.1.json"), "w").write("{}\n")
os.remove(os.path.join(intr, "now"))
os.mkfifo(os.path.join(intr, "now"))
RGSNP

loghyg_rg_run() {
  local mock_dir="$1"
  local tmp="$2"
  env -u FORTEL2_ENV PATH="$LOGHYG_RG_PATH" \
    TMPDIR="$tmp" \
    RESOLVE_GAMES_SNAPSHOT="$mock_dir/snapshot.json" \
    RESOLVE_GAMES_MOCK_DIR="$mock_dir" \
    RESOLVE_GAMES_MAX_TXS_PER_RUN=10 \
    "$LOGHYG_RG" 2>&1
}

loghyg_owned_left() {
  local tmp="$1"
  local other="$2"
  python3 - "$tmp" "$other" <<'OWNEDPY'
import os, sys
tmp, other = sys.argv[1], os.path.realpath(sys.argv[2])
left = []
for name in os.listdir(tmp):
    if not name.startswith("fortel2-resolve-one."):
        continue
    path = os.path.realpath(os.path.join(tmp, name))
    if path != other:
        left.append(path)
print(len(left))
OWNEDPY
}

LOGHYG_STMP="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-loghyg-stmp.XXXXXX")"
register_tmp "$LOGHYG_STMP"
LOGHYG_OTHER="$(mktemp "${LOGHYG_STMP}/fortel2-resolve-one.XXXXXX")"
echo planted-other > "$LOGHYG_OTHER"
LOGHYG_SOUT="$(loghyg_rg_run "$LOGHYG_RG_FIX/success" "${LOGHYG_STMP}/")" && LOGHYG_SEC=0 || LOGHYG_SEC=$?
LOGHYG_SLEFT="$(loghyg_owned_left "$LOGHYG_STMP" "$LOGHYG_OTHER")"
if [[ "$LOGHYG_SEC" -eq 0 && "$LOGHYG_SLEFT" -eq 0 && -f "$LOGHYG_OTHER" ]]; then
  echo "PASS resolver removes its temp on success; other invocation's file survives"
else
  echo "FAIL resolver success must unlink its own temp only (ec=$LOGHYG_SEC left=$LOGHYG_SLEFT other=$([[ -f $LOGHYG_OTHER ]] && echo yes || echo no))" >&2
  printf '%s\n' "$LOGHYG_SOUT" >&2
  fail=1
fi

LOGHYG_FTMP="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-loghyg-ftmp.XXXXXX")"
register_tmp "$LOGHYG_FTMP"
LOGHYG_FOTHER="$(mktemp "${LOGHYG_FTMP}/fortel2-resolve-one.XXXXXX")"
echo planted-fail > "$LOGHYG_FOTHER"
LOGHYG_FOUT="$(loghyg_rg_run "$LOGHYG_RG_FIX/fail" "${LOGHYG_FTMP}/")" && LOGHYG_FEC=0 || LOGHYG_FEC=$?
LOGHYG_FLEFT="$(loghyg_owned_left "$LOGHYG_FTMP" "$LOGHYG_FOTHER")"
if [[ "$LOGHYG_FEC" -ne 0 && "$LOGHYG_FLEFT" -eq 0 && -f "$LOGHYG_FOTHER" ]]; then
  echo "PASS resolver removes its temp on failure; other invocation's file survives"
else
  echo "FAIL resolver failure must unlink its own temp only (ec=$LOGHYG_FEC left=$LOGHYG_FLEFT)" >&2
  printf '%s\n' "$LOGHYG_FOUT" >&2
  fail=1
fi

LOGHYG_ITMP="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-loghyg-itmp.XXXXXX")"
register_tmp "$LOGHYG_ITMP"
LOGHYG_IOTHER="$(mktemp "${LOGHYG_ITMP}/fortel2-resolve-one.XXXXXX")"
echo planted-intr > "$LOGHYG_IOTHER"
LOGHYG_IJSON="$(python3 - "$LOGHYG_RG" "$LOGHYG_RG_FIX/intr" "$LOGHYG_ITMP" "$LOGHYG_IOTHER" "$LOGHYG_RG_PATH" <<'INTRPY'
import os, signal, subprocess, sys, time
script, mock, tmp, other, path = sys.argv[1:]
env = os.environ.copy()
env.pop("FORTEL2_ENV", None)
env["PATH"] = path
env["TMPDIR"] = tmp if tmp.endswith(os.sep) else tmp + os.sep
env["RESOLVE_GAMES_SNAPSHOT"] = os.path.join(mock, "snapshot.json")
env["RESOLVE_GAMES_MOCK_DIR"] = mock
env["RESOLVE_GAMES_MAX_TXS_PER_RUN"] = "10"
p = subprocess.Popen([script], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
deadline = time.time() + 8
owned = []
while time.time() < deadline:
    owned = [
        os.path.join(tmp, n)
        for n in os.listdir(tmp)
        if n.startswith("fortel2-resolve-one.")
        and os.path.realpath(os.path.join(tmp, n)) != os.path.realpath(other)
    ]
    if owned:
        break
    if p.poll() is not None:
        break
    time.sleep(0.05)
if owned:
    os.killpg(p.pid, signal.SIGINT)
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.wait(timeout=2)
else:
    try:
        out = p.communicate(timeout=2)[0]
    except subprocess.TimeoutExpired:
        p.kill()
        out = p.communicate()[0]
    sys.stderr.write((out or b"").decode("utf-8", "replace"))
    sys.exit(1)
left = [
    os.path.join(tmp, n)
    for n in os.listdir(tmp)
    if n.startswith("fortel2-resolve-one.")
    and os.path.realpath(os.path.join(tmp, n)) != os.path.realpath(other)
]
print("owned_before=%d left=%d other=%d ec=%s" % (
    len(owned), len(left), int(os.path.isfile(other)), p.returncode))
sys.exit(0 if owned and len(left) == 0 and os.path.isfile(other) else 1)
INTRPY
)" && LOGHYG_IEC=0 || LOGHYG_IEC=$?
if [[ "$LOGHYG_IEC" -eq 0 ]]; then
  echo "PASS resolver removes its temp on interrupt; other invocation's file survives ($LOGHYG_IJSON)"
else
  echo "FAIL resolver interrupt must unlink its own temp only ($LOGHYG_IJSON)" >&2
  fail=1
fi

# Mutations: broken copies must fail the named property.
LOGHYG_MUT="$LOGHYG_FIX/mut-rotate.sh"
cp "$SCRIPT_DIR/rotate-logs.sh" "$LOGHYG_MUT"
python3 - "$LOGHYG_MUT" <<'MUT1'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
old = '  cp -p "$f" "$dest"\n  : > "$f"\n'
new = '  mv -f "$f" "$dest"\n  : > "$f"\n'
if old not in t:
    raise SystemExit("rotate mutation needle missing")
p.write_text(t.replace(old, new, 1))
MUT1
chmod +x "$LOGHYG_MUT"
if loghyg_live_reclaim "$LOGHYG_MUT"; then
  echo "FAIL mutation mv-live-log must make live-writer reclaim go red" >&2
  fail=1
else
  echo "PASS mutation mv-live-log goes red on live-writer reclaim"
fi

LOGHYG_MUT_RG="$LOGHYG_FIX/mut-resolve.sh"
LOGHYG_MUT_GLOB="$LOGHYG_FIX/mut-glob.sh"
LOGHYG_MTMP="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-loghyg-mtmp.XXXXXX")"
register_tmp "$LOGHYG_MTMP"
LOGHYG_GTMP="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-loghyg-gtmp.XXXXXX")"
register_tmp "$LOGHYG_GTMP"
LOGHYG_MUTDRV_OUT="$(
python3 - "$LOGHYG_RG" "$LOGHYG_MUT_RG" "$LOGHYG_MUT_GLOB" \
  "$LOGHYG_RG_FIX/fail" "$LOGHYG_RG_FIX/success" \
  "$LOGHYG_MTMP" "$LOGHYG_GTMP" "$LOGHYG_RG_PATH" <<'MUTDRV'
import os, subprocess, sys
from pathlib import Path

src, mut_rm, mut_glob, fail_mock, ok_mock, mtmp, gtmp, path = sys.argv[1:]
src_path = Path(src)
src_text = src_path.read_text()
scripts_dir = str(src_path.parent)
needle = 'rm -f -- "$RESOLVE_GAMES_GAME_FILE"'
if needle not in src_text:
    raise SystemExit("resolver unlink needle missing")

def pin_script_dir(text):
    old = 'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"'
    repl = 'SCRIPT_DIR="%s"' % scripts_dir
    if old not in text:
        raise SystemExit("SCRIPT_DIR assignment missing")
    return text.replace(old, repl, 1)

def owned(dirpath, other):
    other = Path(other).resolve()
    left = []
    for p in Path(dirpath).iterdir():
        if p.name.startswith("fortel2-resolve-one.") and p.resolve() != other:
            left.append(p)
    return left

def run(script, mock, tmp):
    env = os.environ.copy()
    env.pop("FORTEL2_ENV", None)
    env["PATH"] = path
    env["TMPDIR"] = tmp if tmp.endswith(os.sep) else tmp + os.sep
    env["RESOLVE_GAMES_SNAPSHOT"] = os.path.join(mock, "snapshot.json")
    env["RESOLVE_GAMES_MOCK_DIR"] = mock
    env["RESOLVE_GAMES_MAX_TXS_PER_RUN"] = "10"
    return subprocess.run([script], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

# 1. drop unlink
t = pin_script_dir(src_text.replace(needle, ": # mutated no unlink", 1))
Path(mut_rm).write_text(t)
os.chmod(mut_rm, 0o755)
mother = Path(mtmp) / "fortel2-resolve-one.planted"
mother.write_text("planted-mut\n")
run(mut_rm, fail_mock, mtmp)
left = owned(mtmp, mother)
print("MUT_DROP_UNLINK left=%d other=%d files=%s" % (
    len(left), int(mother.is_file()), sorted(p.name for p in Path(mtmp).iterdir())))
if left:
    print("PASS mutation dropping resolver cleanup goes red (left=%d)" % len(left))
else:
    print("FAIL mutation dropping resolver cleanup must leave an owned temp")

# 2. glob unlink
t = pin_script_dir(src_text.replace(needle, 'rm -f -- "${TMPDIR:-/tmp}"/fortel2-resolve-one.*', 1))
Path(mut_glob).write_text(t)
os.chmod(mut_glob, 0o755)
gother = Path(gtmp) / "fortel2-resolve-one.planted"
gother.write_text("planted-glob\n")
run(mut_glob, ok_mock, gtmp)
print("MUT_GLOB other=%d files=%s" % (
    int(gother.is_file()), sorted(p.name for p in Path(gtmp).iterdir())))
if not gother.is_file():
    print("PASS mutation glob-rm goes red (other invocation's file did not survive)")
else:
    print("FAIL mutation glob-rm must destroy the other invocation's file")
MUTDRV
)"
printf '%s\n' "$LOGHYG_MUTDRV_OUT"
if printf '%s\n' "$LOGHYG_MUTDRV_OUT" | grep -q '^FAIL '; then
  fail=1
fi
LOGHYG_MUT_WRAP="$LOGHYG_WRAP/run_dev_wake.mut.sh"
cat > "$LOGHYG_MUT_WRAP" <<'MUT4'
#!/bin/zsh
cd "$(dirname "$0")" || exit 1
export FORTEL2_ENV="${FORTEL2_ENV:-.env.sepolia}"
exec ./scripts/dev-sleep.sh wake
MUT4
chmod +x "$LOGHYG_MUT_WRAP"
LOGHYG_MW_OUT="$("$LOGHYG_MUT_WRAP" 2>&1)" || true
if loghyg_all_lines_stamped "$LOGHYG_MW_OUT"; then
  echo "FAIL mutation stripping wrapper timestamps must go red" >&2
  printf '%s\n' "$LOGHYG_MW_OUT" >&2
  fail=1
else
  echo "PASS mutation stripping wrapper timestamps goes red"
fi

cleanup_loghyg
unset LOGHYG_FIX LOGHYG_UNDER LOGHYG_OVER LOGHYG_KEEP LOGHYG_I LOGHYG_STARTS LOGHYG_S LOGHYG_START_OK
unset LOGHYG_TS_RE LOGHYG_WRAP LOGHYG_ZSH_OK LOGHYG_W LOGHYG_WAKE_OUT LOGHYG_SLEEP_OUT LOGHYG_HEALTH_OUT
unset LOGHYG_WAKE_EC LOGHYG_SLEEP_EC LOGHYG_HEALTH_EC
unset LOGHYG_RG LOGHYG_RG_PY_DIR LOGHYG_RG_PATH LOGHYG_RG_FIX
unset LOGHYG_STMP LOGHYG_OTHER LOGHYG_SOUT LOGHYG_SEC LOGHYG_SLEFT
unset LOGHYG_FTMP LOGHYG_FOTHER LOGHYG_FOUT LOGHYG_FEC LOGHYG_FLEFT
unset LOGHYG_ITMP LOGHYG_IOTHER LOGHYG_IJSON LOGHYG_IEC
unset LOGHYG_MUT LOGHYG_MUT_RG LOGHYG_MTMP LOGHYG_MOTHER LOGHYG_MLEFT
unset LOGHYG_MUT_GLOB LOGHYG_GTMP LOGHYG_GOTHER LOGHYG_MUT_WRAP LOGHYG_MW_OUT
unset -f cleanup_loghyg loghyg_live_reclaim loghyg_all_lines_stamped loghyg_rg_run loghyg_owned_left 2>/dev/null || true
