#!/bin/zsh
# LaunchAgent entrypoint: morning Sepolia wake (start Mac stack, credit-budget defaults).
# Resume Render in the dashboard separately if you suspended it overnight.
# Every line launchd captures must be datable without launchctl (D-0138).
# Launchd invokes this with /bin/zsh; keep the body valid bash too so CI
# (no zsh) can syntax-check and exercise the timestamp prefixer.
cd "$(dirname "$0")" || exit 1
export FORTEL2_ENV="${FORTEL2_ENV:-.env.sepolia}"
timestamp_lines() {
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$line"
  done
}
{
  echo "fortel2-wake begin"
  ./scripts/dev-sleep.sh wake
  rc=$?
  echo "fortel2-wake end rc=$rc"
  exit $rc
} 2>&1 | timestamp_lines
# FIRST statement after the pipe: assignment RHS expands pipestatus before any
# command clobbers it. bash PIPESTATUS is 0-indexed; zsh pipestatus is 1-indexed.
# Do not insert a command (including `[`) between the pipe and this line.
_wrap_rc="${PIPESTATUS[0]-${pipestatus[1]-0}}"
exit "${_wrap_rc}"
