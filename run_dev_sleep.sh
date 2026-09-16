#!/bin/zsh
# LaunchAgent entrypoint: overnight Sepolia sleep (stop Mac stack + HTTP).
# Does not suspend Render or pause QuickNode — do those in the dashboard if needed.
# Every line launchd captures must be datable without launchctl (D-0138).
cd "$(dirname "$0")" || exit 1
export FORTEL2_ENV="${FORTEL2_ENV:-.env.sepolia}"
timestamp_lines() {
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$line"
  done
}
{
  echo "fortel2-sleep begin"
  ./scripts/dev-sleep.sh sleep
  rc=$?
  echo "fortel2-sleep end rc=$rc"
  exit $rc
} 2>&1 | timestamp_lines
exit "${pipestatus[1]}"
