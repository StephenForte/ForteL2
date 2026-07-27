#!/bin/zsh
# LaunchAgent entrypoint: overnight Sepolia sleep (stop Mac stack + HTTP).
# Does not suspend Render or pause QuickNode — do those in the dashboard if needed.
cd "$(dirname "$0")" || exit 1
export FORTEL2_ENV="${FORTEL2_ENV:-.env.sepolia}"
exec ./scripts/dev-sleep.sh sleep
