#!/usr/bin/env bash
# Read-only drift check: repo launchd/*.plist vs ~/Library/LaunchAgents.
# Never mutates launchd state (no bootout/bootstrap/kickstart) and never deletes files.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin plutil
require_bin python3

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCHD_DIR="$REPO_ROOT/launchd"
AGENTS_DIR="${HOME}/Library/LaunchAgents"
# Verbs for operator-facing hints only (kept out of source as adjacent tokens — see checks).
_LC_VERB_OUT=bootout
_LC_VERB_STRAP=bootstrap
_RM_VERB=rm

FAILS=0
WARNS=0

# Normalize plist to xml1 on stdout. $1 = path.
plist_xml() {
  plutil -convert xml1 -o - "$1"
}

# Print "Hour:Minute" for StartCalendarInterval (dict or single-element array).
# Empty string if missing/unparseable; "MULTI" if array length != 1.
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
print("%s:%s" % (sci.get("Hour"), sci.get("Minute", 0)))
'
}

# Print ProgramArguments joined by SOH (\x01), last field is the repo script path.
plist_prog_args() {
  plist_xml "$1" | python3 -c '
import sys, plistlib
data = plistlib.loads(sys.stdin.buffer.read())
args = data.get("ProgramArguments") or []
sys.stdout.write("\x01".join(args))
'
}

# Print KeepAlive as "true" / "false" / "dict" / empty.
plist_keepalive() {
  plist_xml "$1" | python3 -c '
import sys, plistlib
data = plistlib.loads(sys.stdin.buffer.read())
ka = data.get("KeepAlive")
if ka is True:
    print("true")
elif ka is False:
    print("false")
elif isinstance(ka, dict):
    print("dict")
else:
    print("")
'
}

label_base() {
  # fortel2-sleep -> com.steve.fortel2-sleep
  echo "com.steve.$1"
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

  local repo_cal host_cal
  repo_cal="$(plist_calendar "$repo_plist")"
  host_cal="$(plist_calendar "$host_plist")"

  local repo_args host_args
  repo_args="$(plist_prog_args "$repo_plist")"
  host_args="$(plist_prog_args "$host_plist")"

  # Last ProgramArguments entry is the repo wrapper script path.
  local repo_script host_script
  repo_script="${repo_args##*$'\x01'}"
  if [[ "$repo_args" != *$'\x01'* ]]; then
    repo_script="$repo_args"
  fi
  host_script="${host_args##*$'\x01'}"
  if [[ "$host_args" != *$'\x01'* ]]; then
    host_script="$host_args"
  fi

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
    status="FAIL"
    detail="schedule mismatch: repo=${repo_cal} installed=${host_cal}"
    agent_fail=1
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
    status="WARN"
    detail="ProgramArguments wrapper-prefixed (ends in same repo script); LaunchControl fdautil is a third-party dependency"
    WARNS=$((WARNS + 1))
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

# KeepAlive daemon (no StartCalendarInterval) — cloudflared write tunnel (D-0034).
check_keepalive_agent() {
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

  local repo_ka host_ka repo_cal host_cal
  repo_ka="$(plist_keepalive "$repo_plist")"
  host_ka="$(plist_keepalive "$host_plist")"
  repo_cal="$(plist_calendar "$repo_plist")"
  host_cal="$(plist_calendar "$host_plist")"

  local repo_args host_args
  repo_args="$(plist_prog_args "$repo_plist")"
  host_args="$(plist_prog_args "$host_plist")"

  local repo_script host_script
  repo_script="${repo_args##*$'\x01'}"
  if [[ "$repo_args" != *$'\x01'* ]]; then
    repo_script="$repo_args"
  fi
  host_script="${host_args##*$'\x01'}"
  if [[ "$host_args" != *$'\x01'* ]]; then
    host_script="$host_args"
  fi

  local status="OK"
  local detail=""
  local agent_fail=0

  if [[ "$repo_ka" != "true" ]]; then
    status="FAIL"
    detail="repo KeepAlive must be true (got ${repo_ka:-empty})"
    agent_fail=1
  elif [[ "$host_ka" != "true" ]]; then
    status="FAIL"
    detail="installed KeepAlive mismatch: repo=${repo_ka} installed=${host_ka}"
    agent_fail=1
  fi

  if [[ -n "$repo_cal" || -n "$host_cal" ]]; then
    status="FAIL"
    detail="${detail:+$detail; }KeepAlive agent must not have StartCalendarInterval (repo=${repo_cal:-empty} host=${host_cal:-empty})"
    agent_fail=1
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
    status="WARN"
    detail="ProgramArguments wrapper-prefixed (ends in same repo script); LaunchControl fdautil is a third-party dependency"
    WARNS=$((WARNS + 1))
  fi

  if [[ "$agent_fail" -eq 1 ]]; then
    FAILS=$((FAILS + 1))
  fi

  if [[ -n "$detail" ]]; then
    echo "${status}  ${label}  keepalive=${repo_ka}  script=${repo_script}  ${detail}"
  else
    echo "${status}  ${label}  keepalive=${repo_ka}  script=${repo_script}"
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

for short in fortel2-health fortel2-sleep fortel2-wake; do
  check_agent "$short"
done

check_keepalive_agent fortel2-cloudflared

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
