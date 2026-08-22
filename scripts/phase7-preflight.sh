#!/usr/bin/env bash
# Phase 7 / US-071: go/no-go gate to run immediately before sequence step 2.
# Read-only and offline. Never prints a key or any env-file line contents.
# Two checks execute the deploy script's real guards (F7-10, F7-11) against the
# resolved env file rather than restating them. A check that CANNOT RUN is a
# FAILURE, not a pass (D-0067 Finding 6). Extraction anchors on content, never
# on line numbers -- the script grows and line ranges silently go stale.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${FORTEL2_ROOT:-$SCRIPT_DIR/..}" || exit 1
S=scripts/02-deploy-contracts-sepolia.sh; E=.env.sepolia; fail=0
p(){ printf '  %-50s %s\n' "$1" "$2"; }
bad(){ p "$1" "$2"; fail=1; }
[ "$(stat -f '%Sp' "$E")" = "-rw-------" ] && p "env file mode 600" "PASS" || bad "env file mode 600" "FAIL"
d=$(grep -nE '^[A-Za-z_][A-Za-z_0-9]*=' "$E" | sed 's/=.*//' | awk -F: '{print $2}' | sort | uniq -d | wc -l | tr -d ' ')
[ "$d" = 0 ] && p "no duplicated assignments in env" "PASS" || bad "no duplicated assignments in env" "FAIL ($d dup)"
eval "$(grep -E '^(FAULT_GAME_CLOCK_EXTENSION|FAULT_GAME_MAX_CLOCK_DURATION|PREIMAGE_ORACLE_CHALLENGE_PERIOD|PROOF_MATURITY_DELAY_SECONDS|DISPUTE_GAME_FINALITY_DELAY_SECONDS|FAULT_GAME_WITHDRAWAL_DELAY)=' "$E")"
got="$FAULT_GAME_CLOCK_EXTENSION $FAULT_GAME_MAX_CLOCK_DURATION $PREIMAGE_ORACLE_CHALLENGE_PERIOD $PROOF_MATURITY_DELAY_SECONDS $DISPUTE_GAME_FINALITY_DELAY_SECONDS $FAULT_GAME_WITHDRAWAL_DELAY"
[ "$got" = "600 7200 3600 1800 1800 3600" ] && p "six immutables match D-0049" "PASS  $got" || bad "six immutables match D-0049" "FAIL  $got"
a=$(grep -n '^FAULT_GAME_CLOCK_EXTENSION="\${FAULT_GAME_CLOCK_EXTENSION' "$S" | cut -d: -f1)
z=$(grep -n 'Choose all six Phase 7 knobs' "$S" | cut -d: -f1)
cc=$(mktemp "${TMPDIR:-/tmp}/cc.XXXXXX"); [ -n "$a" ] && [ -n "$z" ] && sed -n "${a},$((z+2))p" "$S" > "$cc"
if [ "$(grep -c '_min_needed' "$cc" 2>/dev/null)" -ge 3 ] && [ "$(tail -1 "$cc" 2>/dev/null)" = "fi" ]; then
  if env FAULT_GAME_CLOCK_EXTENSION="$FAULT_GAME_CLOCK_EXTENSION" FAULT_GAME_MAX_CLOCK_DURATION="$FAULT_GAME_MAX_CLOCK_DURATION" PREIMAGE_ORACLE_CHALLENGE_PERIOD="$PREIMAGE_ORACLE_CHALLENGE_PERIOD" FAULT_GAME_WITHDRAWAL_DELAY="$FAULT_GAME_WITHDRAWAL_DELAY" bash -c "set -euo pipefail; source $cc" >/dev/null 2>&1
  then p "clock gate (script's own check)" "PASS"; else bad "clock gate (script's own check)" "FAIL"; fi
else bad "clock gate" "COULD NOT RUN - treat as failure"; fi
rm -f "$cc"
g=$(mktemp "${TMPDIR:-/tmp}/g.XXXXXX"); { awk '/^_f711_is_phase7_immutable\(\)/,/^}/' "$S"; awk '/^_f711_scan_immutable_assignments\(\)/,/^}/' "$S"; awk '/^refuse_duplicate_phase7_immutables\(\)/,/^}/' "$S"; awk '/^refuse_absent_phase7_immutables\(\)/,/^}/' "$S"; } > "$g"
if [ "$(grep -c '^refuse_.*phase7_immutables()' "$g")" -eq 2 ]; then
  if env FORTEL2_ENV_FILE="$PWD/$E" FORCE_SEPOLIA_REDEPLOY=1 bash -c "set -uo pipefail; source $g; refuse_duplicate_phase7_immutables; refuse_absent_phase7_immutables" >/dev/null 2>&1
  then p "F7-11 duplicate + absence guards (wipe path)" "PASS"; else bad "F7-11 duplicate + absence guards (wipe path)" "FAIL"; fi
else bad "F7-11 guards" "COULD NOT RUN - treat as failure"; fi
rm -f "$g"
k=$(mktemp "${TMPDIR:-/tmp}/k.XXXXXX"); awk '/^require_admin_key_matches_address\(\)/,/^}/' "$S" > "$k"
if grep -q 'cast wallet address' "$k"; then
  if env $(grep -E '^ADMIN_(PRIVATE_KEY|ADDRESS)=' "$E" | tr '\n' ' ') bash -c "set -uo pipefail; source $k; require_admin_key_matches_address" >/dev/null 2>&1
  then p "F7-10 ADMIN key derives ADMIN_ADDRESS" "PASS"; else bad "F7-10 ADMIN key derives ADMIN_ADDRESS" "FAIL"; fi
else bad "F7-10 guard" "COULD NOT RUN - treat as failure"; fi
rm -f "$k"
echo; [ "$fail" = 0 ] && echo "  ALL CHECKS PASSED - clear to run step 2" || echo "  *** NOT CLEAR TO PROCEED ***"

