#!/usr/bin/env bash
# Read-only drift check: repo launchd/*.plist vs ~/Library/LaunchAgents.
# Never mutates launchd state (no bootout/bootstrap/kickstart) and never deletes files.
#
# Compares checked-in plists to installed plist *files* only. It does NOT inspect
# what launchd has actually loaded (launchctl print) for user agents — a third
# state where the loaded job differs from both repo and installed file has
# occurred twice (D-0026). After re-copying a plist, bootout + bootstrap is
# required; file equality is necessary but not sufficient.
#
# Repo agents are enumerated from launchd/com.steve.fortel2-*.plist (not a
# hardcoded label list). Script path is the last non-flag ProgramArguments
# entry that looks like a path, so a trailing --execute is not the script.
#
# A separate read-only section reports the *system* Cloudflare tunnel daemon
# (com.cloudflare.cloudflared / D-0034 / D-0107 Finding 5): plist present or
# not, launchctl print system/… state and last exit code. Plist absent is
# informational, not a FAIL. No gui/$UID, no sudo, never attempts a fix.
# Test-only overrides (names never appear in env files):
#   CHECK_LAUNCHD_CLOUDFLARED_PLIST  CHECK_LAUNCHD_LAUNCHCTL
#     (absolute shim path — lib.sh prepends homebrew onto PATH)
#   CHECK_LAUNCHD_AGENTS_DIR         fake ~/Library/LaunchAgents for fixtures
#   CHECK_LAUNCHD_PINNED_TREE        fake /Users/steveforte/fortel2-agents
#   CHECK_LAUNCHD_DEV_DIR            fake ~/ForteL2 (env-symlink and data/ targets)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin python3
# plutil is only needed for user-agent plist compares (plist_xml). The system
# cloudflared section is launchctl-print-only and must run on Linux CI without it.

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCHD_DIR="$REPO_ROOT/launchd"
AGENTS_DIR="${CHECK_LAUNCHD_AGENTS_DIR:-${HOME}/Library/LaunchAgents}"
# Pinned clone the agents must execute from (D-0113 Finding 2). Not a worktree
# of the mutable ~/ForteL2 checkout — a sibling `git clone` of main.
PINNED_TREE="${CHECK_LAUNCHD_PINNED_TREE:-/Users/steveforte/fortel2-agents}"
PINNED_PREFIX="/Users/steveforte/fortel2-agents"
OLD_DEV_PREFIX="/Users/steveforte/ForteL2"
DEV_DIR="${CHECK_LAUNCHD_DEV_DIR:-/Users/steveforte/ForteL2}"
# Verbs for operator-facing hints only (kept out of source as adjacent tokens — see checks).
_LC_VERB_OUT=bootout
_LC_VERB_STRAP=bootstrap
_RM_VERB=rm

FAILS=0
WARNS=0

# Sleep/wake schedules are a published commitment (rail-interface availability, README,
# SOS retry behaviour) — minutes there are a contract. Other agent schedules are internal.
is_contract_schedule() {
  case "$1" in
    fortel2-sleep|fortel2-wake) return 0 ;;
    *) return 1 ;;
  esac
}

# Normalize plist to xml1 on stdout. $1 = path.
plist_xml() {
  require_bin plutil
  plutil -convert xml1 -o - "$1"
}

# Print "Hour:Minute" for StartCalendarInterval (dict or single-element array).
# Empty string if missing/unparseable; "MULTI" if array length != 1.
# A missing Hour is a wildcard ("*:0" = every hour at minute 0).
plist_calendar() {
  plist_xml "$1" | python3 -c '
import sys, plistlib
data = plistlib.loads(sys.stdin.buffer.read())
sci = data.get("StartCalendarInterval")
if sci is None:
    print("")
    raise SystemExit(0)
if isinstance(sci, list):
    if len(sci) != 1 or not isinstance(sci[0], dict):
        print("MULTI")
        raise SystemExit(0)
    sci = sci[0]
if not isinstance(sci, dict):
    print("")
    raise SystemExit(0)
hour = sci.get("Hour")
minute = sci.get("Minute", 0)
print("%s:%s" % ("*" if hour is None else hour, minute))
'
}

# Print ProgramArguments joined by SOH (\x01).
plist_prog_args() {
  plist_xml "$1" | python3 -c '
import sys, plistlib
data = plistlib.loads(sys.stdin.buffer.read())
args = data.get("ProgramArguments") or []
sys.stdout.write("\x01".join(args))
'
}

# Script path: last non-flag ProgramArguments entry that looks like a path.
# Trailing flags (--execute) must not be treated as the script (R-15).
plist_script() {
  plist_xml "$1" | python3 -c '
import sys, plistlib
data = plistlib.loads(sys.stdin.buffer.read())
args = data.get("ProgramArguments") or []
script = ""
for a in reversed(args):
    if not a or a.startswith("-"):
        continue
    if "/" in a:
        script = a
        break
if not script:
    for a in reversed(args):
        if a and not a.startswith("-"):
            script = a
            break
sys.stdout.write(script)
'
}

label_base() {
  # fortel2-sleep -> com.steve.fortel2-sleep
  echo "com.steve.$1"
}

# True if $1 is the mutable checkout path (exact or a child). fortel2-agents
# does not match: it does not equal OLD_DEV_PREFIX and does not start with
# OLD_DEV_PREFIX + "/".
is_old_dev_path() {
  local p="$1"
  [[ "$p" == "$OLD_DEV_PREFIX" || "$p" == "$OLD_DEV_PREFIX"/* ]]
}

# Print ProgramArguments, WorkingDirectory, and PATH entries from a plist.
# python3 plistlib reads XML and binary; no plutil (Linux CI fixtures).
plist_exec_paths() {
  python3 -c '
import sys, plistlib
data = plistlib.loads(open(sys.argv[1], "rb").read())
for a in data.get("ProgramArguments") or []:
    print(a)
wd = data.get("WorkingDirectory")
if wd:
    print(wd)
env = data.get("EnvironmentVariables") or {}
for p in (env.get("PATH") or "").split(":"):
    if p:
        print(p)
' "$1"
}

# Nonzero if any exec path still points at the mutable ~/ForteL2 checkout.
plist_points_at_old_dev() {
  local line
  while IFS= read -r line; do
    if is_old_dev_path "$line"; then
      return 0
    fi
  done < <(plist_exec_paths "$1")
  return 1
}

# Print the ProgramArguments script path (last non-flag entry containing /).
# Independent of plutil so repo-template audits run on Linux CI.
plist_script_python() {
  python3 -c '
import sys, plistlib
data = plistlib.loads(open(sys.argv[1], "rb").read())
args = data.get("ProgramArguments") or []
script = ""
for a in reversed(args):
    if not a or a.startswith("-"):
        continue
    if "/" in a:
        script = a
        break
sys.stdout.write(script)
' "$1"
}

normalize_git_url() {
  local u="$1"
  u="${u%.git}"
  u="${u%/}"
  u="${u#git@}"
  u="${u#https://}"
  u="${u#http://}"
  u="${u/://}"
  printf '%s' "$u"
}

# Repo template: ProgramArguments (and WorkingDirectory / PATH) must target the
# pinned tree, never the mutable ~/ForteL2 checkout. python3-only — no plutil.
check_repo_plist_pinned() {
  local repo_plist="$1"
  local label script
  label="$(basename "$repo_plist" .plist)"
  if plist_points_at_old_dev "$repo_plist"; then
    echo "FAIL  ${label}  repo template still points at ${OLD_DEV_PREFIX}"
    FAILS=$((FAILS + 1))
    return
  fi
  script="$(plist_script_python "$repo_plist")"
  if [[ -z "$script" ]]; then
    echo "FAIL  ${label}  repo ProgramArguments empty"
    FAILS=$((FAILS + 1))
    return
  fi
  if [[ "$script" != "$PINNED_PREFIX" && "$script" != "$PINNED_PREFIX"/* ]]; then
    echo "FAIL  ${label}  repo script not under pinned tree: ${script}"
    FAILS=$((FAILS + 1))
    return
  fi
  echo "PASS  ${label}  repo script=${script}"
}

check_pinned_tree() {
  echo
  echo "=== pinned agent execution tree (${PINNED_TREE}) ==="

  if ! git -C "$PINNED_TREE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "FAIL  pinned tree missing or not a git checkout (${PINNED_TREE})"
    FAILS=$((FAILS + 1))
    return
  fi

  local pinned_url repo_url
  pinned_url="$(git -C "$PINNED_TREE" remote get-url origin 2>/dev/null || true)"
  repo_url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  if [[ -z "$pinned_url" || -z "$repo_url" ]]; then
    echo "FAIL  pinned tree origin missing or this checkout has no origin"
    FAILS=$((FAILS + 1))
    return
  fi
  if [[ "$(normalize_git_url "$pinned_url")" != "$(normalize_git_url "$repo_url")" ]]; then
    echo "FAIL  pinned tree origin is not this repo (pinned=${pinned_url} repo=${repo_url})"
    FAILS=$((FAILS + 1))
    return
  fi

  local branch
  branch="$(git -C "$PINNED_TREE" rev-parse --abbrev-ref HEAD)"
  if [[ "$branch" != "main" ]]; then
    echo "FAIL  pinned tree is not on branch main (on ${branch})"
    FAILS=$((FAILS + 1))
    return
  fi

  local leftover
  leftover="$(git -C "$PINNED_TREE" status --porcelain | grep -v -E '^\?\? (\.env|\.env\.sepolia|data|deployments/sepolia/\.deployer)$' || true)"
  if [[ -n "$leftover" ]]; then
    echo "FAIL  pinned tree is dirty"
    FAILS=$((FAILS + 1))
    return
  fi

  # .env.sepolia / .deployer are gitignored — porcelain cannot see a missing
  # link. lib.sh pins FORTEL2_ROOT to this tree; data/ and .deployer must
  # still be dest-checkout symlinks. Tracked sepolia/ files stay copies.
  local name expected link target
  for name in .env.sepolia data deployments/sepolia/.deployer; do
    expected="$DEV_DIR/$name"
    link="$PINNED_TREE/$name"
    if [[ ! -L "$link" ]]; then
      echo "FAIL  pinned tree $name is missing or not a symlink"
      FAILS=$((FAILS + 1))
      return
    fi
    target="$(readlink "$link")"
    if [[ "$target" != "$expected" ]]; then
      echo "FAIL  pinned tree $name symlink points at ${target} (expected ${expected})"
      FAILS=$((FAILS + 1))
      return
    fi
    if [[ ! -e "$link" ]]; then
      echo "FAIL  pinned tree $name symlink is dangling"
      FAILS=$((FAILS + 1))
      return
    fi
  done

  local env_link="$PINNED_TREE/.env.sepolia"
  if grep -E '^[[:space:]]*(export[[:space:]]+)?FORTEL2_ROOT=' "$env_link" >/dev/null 2>&1; then
    echo "INFO  pinned tree env still sets FORTEL2_ROOT (lib.sh ignores it with a warning; you may delete the line)"
  else
    echo "INFO  pinned tree env does not set FORTEL2_ROOT"
  fi

  echo "PASS  pinned tree  branch=main  clean  $(git -C "$PINNED_TREE" log -1 --format='%h %s')"
}

check_agent() {
  local short="$1"
  local label
  label="$(label_base "$short")"
  local repo_plist="$LAUNCHD_DIR/${label}.plist"
  local host_plist="$AGENTS_DIR/${label}.plist"

  if [[ ! -f "$repo_plist" ]]; then
    echo "FAIL  ${label}  repo plist missing: ${repo_plist}"
    FAILS=$((FAILS + 1))
    return
  fi

  if [[ ! -d "$AGENTS_DIR" ]]; then
    echo "FAIL  ${label}  not installed (${AGENTS_DIR} missing — CI/VM or fresh account?)"
    FAILS=$((FAILS + 1))
    return
  fi

  if [[ ! -f "$host_plist" ]]; then
    echo "FAIL  ${label}  not installed (expected ${host_plist})"
    FAILS=$((FAILS + 1))
    return
  fi

  # Half-migrated host: installed plist still points at ~/ForteL2. Fail before
  # plutil compares so Linux CI fixtures (no plutil) can still go red.
  if plist_points_at_old_dev "$host_plist"; then
    echo "FAIL  ${label}  installed plist still points at ${OLD_DEV_PREFIX} (pinned tree is ${PINNED_PREFIX})"
    FAILS=$((FAILS + 1))
    return
  fi

  local repo_cal host_cal
  repo_cal="$(plist_calendar "$repo_plist")"
  host_cal="$(plist_calendar "$host_plist")"

  local repo_args host_args
  repo_args="$(plist_prog_args "$repo_plist")"
  host_args="$(plist_prog_args "$host_plist")"

  local repo_script host_script
  repo_script="$(plist_script "$repo_plist")"
  host_script="$(plist_script "$host_plist")"

  local status="OK"
  local detail=""
  local agent_fail=0

  if [[ -z "$repo_cal" || -z "$host_cal" ]]; then
    status="FAIL"
    detail="StartCalendarInterval missing or unparseable (repo=${repo_cal:-empty} host=${host_cal:-empty})"
    agent_fail=1
  elif [[ "$repo_cal" == "MULTI" || "$host_cal" == "MULTI" ]]; then
    status="FAIL"
    detail="StartCalendarInterval multi-element array not supported for compare (repo=${repo_cal} host=${host_cal})"
    agent_fail=1
  elif [[ "$repo_cal" != "$host_cal" ]]; then
    if is_contract_schedule "$short"; then
      status="FAIL"
      detail="schedule mismatch: repo=${repo_cal} installed=${host_cal}"
      agent_fail=1
    else
      status="WARN"
      detail="schedule mismatch: repo=${repo_cal} installed=${host_cal}"
      WARNS=$((WARNS + 1))
    fi
  fi

  if [[ -z "$repo_script" ]]; then
    status="FAIL"
    detail="${detail:+$detail; }repo ProgramArguments empty"
    agent_fail=1
  elif [[ "$host_script" != "$repo_script" ]]; then
    status="FAIL"
    detail="${detail:+$detail; }script path mismatch: repo=${repo_script} installed=${host_script}"
    agent_fail=1
  elif [[ "$agent_fail" -eq 0 && "$host_args" != "$repo_args" ]]; then
    # Same trailing script, but ProgramArguments prefixed (e.g. LaunchControl fdautil).
    # May combine with a non-contract schedule WARN (e.g. fortel2-health).
    local wrapper_detail="ProgramArguments wrapper-prefixed (ends in same repo script); LaunchControl fdautil is a third-party dependency"
    if [[ "$status" == "OK" ]]; then
      status="WARN"
      detail="$wrapper_detail"
      WARNS=$((WARNS + 1))
    elif [[ "$status" == "WARN" ]]; then
      detail="${detail}; ${wrapper_detail}"
    fi
  fi

  if [[ "$agent_fail" -eq 1 ]]; then
    FAILS=$((FAILS + 1))
  fi

  if [[ -n "$detail" ]]; then
    echo "${status}  ${label}  schedule=${repo_cal}  script=${repo_script}  ${detail}"
  else
    echo "${status}  ${label}  schedule=${repo_cal}  script=${repo_script}"
  fi
}

echo "=== ForteL2 launchd drift check (repo vs ~/Library/LaunchAgents) ==="
echo "repo: $LAUNCHD_DIR"
echo

if [[ ! -d "$AGENTS_DIR" ]]; then
  echo "FAIL  ${AGENTS_DIR} does not exist — treating every repo agent as not installed."
  echo "      This is expected on CI/VMs; install on the Mac mini per launchd/README.md."
  FAILS=$((FAILS + 1))
fi

shopt -s nullglob
_repo_plists=("$LAUNCHD_DIR"/com.steve.fortel2-*.plist)
shopt -u nullglob
if [[ ${#_repo_plists[@]} -eq 0 ]]; then
  echo "FAIL  no com.steve.fortel2-*.plist under $LAUNCHD_DIR"
  FAILS=$((FAILS + 1))
else
  for _repo_plist in "${_repo_plists[@]}"; do
    _base="$(basename "$_repo_plist" .plist)"
    check_agent "${_base#com.steve.}"
  done

  echo
  echo "=== repo plist ProgramArguments (must target ${PINNED_PREFIX}) ==="
  for _repo_plist in "${_repo_plists[@]}"; do
    check_repo_plist_pinned "$_repo_plist"
  done
fi

echo
echo "--- STALE host plists (no counterpart under launchd/) ---"
stale_found=0
if [[ -d "$AGENTS_DIR" ]]; then
  # bash 3.2: nullglob so empty dir does not leave the literal pattern.
  shopt -s nullglob
  for host_plist in "$AGENTS_DIR"/com.steve.fortel2-*.plist; do
    base="$(basename "$host_plist")"
    if [[ ! -f "$LAUNCHD_DIR/$base" ]]; then
      stale_found=1
      FAILS=$((FAILS + 1))
      echo "STALE  ${host_plist}"
      uid_gui="$(id -u)"
      printf '  launchctl %s "gui/%s" "%s"\n' "$_LC_VERB_OUT" "$uid_gui" "$host_plist"
      printf '  %s "%s"\n' "$_RM_VERB" "$host_plist"
    fi
  done
  shopt -u nullglob
fi
if [[ "$stale_found" -eq 0 ]]; then
  echo "(none)"
fi

check_pinned_tree

# --- system Cloudflare tunnel daemon (not a user LaunchAgent) ---
# Read-only. Detection only — remediation is a human run-block (needs root).
check_cloudflared_daemon() {
  local plist="${CHECK_LAUNCHD_CLOUDFLARED_PLIST:-/Library/LaunchDaemons/com.cloudflare.cloudflared.plist}"
  local lc="${CHECK_LAUNCHD_LAUNCHCTL:-launchctl}"
  local label="com.cloudflare.cloudflared"
  local out rc=0
  local state_raw="" exit_raw="" state_disp="unparseable" exit_disp="unparseable"
  local unhealthy=0 detail=""

  echo
  echo "=== system LaunchDaemon (Cloudflare tunnel; not a user agent) ==="

  if [[ ! -f "$plist" ]]; then
    echo "INFO  ${label}  system domain  plist absent (${plist}) — tunnel not installed on this host (not a FAIL)"
    return
  fi

  if ! command -v "$lc" >/dev/null 2>&1; then
    echo "FAIL  ${label}  system domain  launchctl not found — cannot determine daemon state"
    FAILS=$((FAILS + 1))
    return
  fi

  rc=0
  out="$("$lc" print "system/${label}" 2>/dev/null)" || rc=$?

  if [[ "$rc" -ne 0 ]]; then
    echo "FAIL  ${label}  system domain  launchctl print missing/failed (exit ${rc})  plist=${plist}"
    FAILS=$((FAILS + 1))
    return
  fi

  # Defensive parse: macOS launchctl print format varies. Trim around '='.
  # BSD awk (no IGNORECASE); launchctl prints "state =" / "last exit code =".
  state_raw="$(printf '%s\n' "$out" | awk -F= '
    $1 ~ /^[[:space:]]*state[[:space:]]*$/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      print $2
      exit
    }')"
  exit_raw="$(printf '%s\n' "$out" | awk -F= '
    $1 ~ /last exit code/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      print $2
      exit
    }')"

  if [[ "$state_raw" == *"not running"* ]]; then
    state_disp="not running"
  elif [[ "$state_raw" == *"running"* ]]; then
    state_disp="running"
  elif [[ -n "$state_raw" ]]; then
    state_disp="$state_raw"
  fi

  if [[ -n "$exit_raw" ]]; then
    exit_disp="$exit_raw"
  fi

  if [[ "$state_disp" == "unparseable" ]]; then
    unhealthy=1
    detail="launchctl print unparseable"
  elif [[ "$state_disp" == "not running" ]]; then
    unhealthy=1
    detail="not running (KeepAlive does not restart a clean exit)"
  elif [[ "$state_disp" != "running" ]]; then
    unhealthy=1
    detail="unknown state"
  fi

  if [[ "$unhealthy" -eq 1 ]]; then
    echo "FAIL  ${label}  system domain  state=${state_disp}  last exit code=${exit_disp}  ${detail}"
    FAILS=$((FAILS + 1))
  else
    echo "PASS  ${label}  system domain  state=${state_disp}  last exit code=${exit_disp}"
  fi
}
check_cloudflared_daemon

echo
if [[ "$FAILS" -eq 0 ]]; then
  if [[ "$WARNS" -gt 0 ]]; then
    echo "Result: OK with ${WARNS} warning(s)."
  else
    echo "Result: OK — repo and installed agents match."
  fi
  exit 0
fi

echo "Result: FAIL (${FAILS} issue(s), ${WARNS} warning(s))." >&2
echo "Repo plists are source of truth; after editing, re-copy then launchctl ${_LC_VERB_OUT} + ${_LC_VERB_STRAP} (see launchd/README.md / H4-004)." >&2
exit 1
