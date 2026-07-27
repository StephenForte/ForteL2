#!/bin/zsh
# LaunchAgent entrypoint: morning Sepolia wake (start Mac stack, credit-budget defaults).
# Resume Render in the dashboard separately if you suspended it overnight.
cd "$(dirname "$0")" || exit 1
export FORTEL2_ENV="${FORTEL2_ENV:-.env.sepolia}"
exec ./scripts/dev-sleep.sh wake
