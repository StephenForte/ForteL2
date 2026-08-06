#!/usr/bin/env bash
# Offline drift guard for deployments/rail-interface.json (SOS consumer contract).
# File/JSON/env-example only — no network clients; safe on CI without Sepolia or .env.sepolia.
#
# Env overrides (for test-helpers fixtures):
#   RAIL_INTERFACE_JSON   default: $REPO_ROOT/deployments/rail-interface.json
#   SEPOLIA_DEPLOYMENTS   default: $REPO_ROOT/deployments/sepolia/deployments.json
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin python3

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RAIL_JSON="${RAIL_INTERFACE_JSON:-$REPO_ROOT/deployments/rail-interface.json}"
DEPLOY_JSON="${SEPOLIA_DEPLOYMENTS:-$REPO_ROOT/deployments/sepolia/deployments.json}"
ENV_SEPOLIA_EXAMPLE="$REPO_ROOT/.env.sepolia.example"
ENV_LOCAL_EXAMPLE="$REPO_ROOT/.env.example"

FAILS=0

lc() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

pass() {
  echo "PASS $1"
}

fail() {
  echo "FAIL $1"
  FAILS=$((FAILS + 1))
}

# Dig a dotted path from a JSON file; prints the value (strings/numbers/null).
json_get() {
  local file="$1" path="$2"
  python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
cur = data
for part in sys.argv[2].split("."):
    if not isinstance(cur, dict) or part not in cur:
        sys.stderr.write("missing key path: %s\n" % sys.argv[2])
        raise SystemExit(2)
    cur = cur[part]
if cur is None:
    print("null")
elif isinstance(cur, bool):
    print("true" if cur else "false")
else:
    print(cur)
' "$file" "$path"
}

env_example_var() {
  local file="$1" key="$2"
  local line
  line="$(grep -E "^${key}=" "$file" | head -n1 || true)"
  if [[ -z "$line" ]]; then
    echo ""
    return
  fi
  printf '%s' "${line#*=}"
}

# --- JSON parses ---
if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$RAIL_JSON" 2>/dev/null; then
  pass "rail-interface.json parses"
else
  fail "rail-interface.json parses"
fi

if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$DEPLOY_JSON" 2>/dev/null; then
  pass "sepolia deployments.json parses"
else
  fail "sepolia deployments.json parses"
fi

# --- Bridge proxies (case-insensitive; rail camelCase vs deployments CapitalCase) ---
# rail key | deployments.json key
PROXY_PAIRS="
optimismPortalProxy:OptimismPortalProxy
l1StandardBridgeProxy:L1StandardBridgeProxy
l1CrossDomainMessengerProxy:L1CrossDomainMessengerProxy
systemConfigProxy:SystemConfigProxy
disputeGameFactoryProxy:DisputeGameFactoryProxy
"

while IFS= read -r pair; do
  [[ -z "$pair" ]] && continue
  rail_key="${pair%%:*}"
  deploy_key="${pair#*:}"
  rail_addr="$(json_get "$RAIL_JSON" "networks.fortel2-sepolia.bridge.${rail_key}" 2>/dev/null || echo "")"
  deploy_addr="$(json_get "$DEPLOY_JSON" "$deploy_key" 2>/dev/null || echo "")"
  rail_lc="$(lc "$rail_addr")"
  deploy_lc="$(lc "$deploy_addr")"
  if [[ -n "$rail_addr" && -n "$deploy_addr" && "$rail_lc" == "$deploy_lc" ]]; then
    pass "bridge.${rail_key} matches deployments.json ${deploy_key}"
  else
    fail "bridge.${rail_key} drift (rail=${rail_addr:-<missing>} deploy=${deploy_addr:-<missing>})"
  fi
done <<EOF
$PROXY_PAIRS
EOF

# --- Chain IDs: fortel2-sepolia ---
SEP_L2="$(json_get "$RAIL_JSON" "networks.fortel2-sepolia.l2ChainId" 2>/dev/null || echo "")"
SEP_L1="$(json_get "$RAIL_JSON" "networks.fortel2-sepolia.l1ChainId" 2>/dev/null || echo "")"
ENV_SEP_L2="$(env_example_var "$ENV_SEPOLIA_EXAMPLE" "L2_CHAIN_ID")"
ENV_SEP_L1="$(env_example_var "$ENV_SEPOLIA_EXAMPLE" "L1_CHAIN_ID")"

if [[ "$SEP_L2" == "852" ]]; then
  pass "fortel2-sepolia.l2ChainId == 852"
else
  fail "fortel2-sepolia.l2ChainId == 852 (got ${SEP_L2:-<missing>})"
fi
if [[ -n "$ENV_SEP_L2" && "$SEP_L2" == "$ENV_SEP_L2" ]]; then
  pass "fortel2-sepolia.l2ChainId matches .env.sepolia.example L2_CHAIN_ID"
else
  fail "fortel2-sepolia.l2ChainId vs .env.sepolia.example (rail=${SEP_L2:-<missing>} env=${ENV_SEP_L2:-<missing>})"
fi
if [[ "$SEP_L1" == "11155111" ]]; then
  pass "fortel2-sepolia.l1ChainId == 11155111"
else
  fail "fortel2-sepolia.l1ChainId == 11155111 (got ${SEP_L1:-<missing>})"
fi
if [[ -n "$ENV_SEP_L1" && "$SEP_L1" == "$ENV_SEP_L1" ]]; then
  pass "fortel2-sepolia.l1ChainId matches .env.sepolia.example L1_CHAIN_ID"
else
  fail "fortel2-sepolia.l1ChainId vs .env.sepolia.example (rail=${SEP_L1:-<missing>} env=${ENV_SEP_L1:-<missing>})"
fi

# --- Chain IDs: fortel2-local ---
LOC_L2="$(json_get "$RAIL_JSON" "networks.fortel2-local.l2ChainId" 2>/dev/null || echo "")"
LOC_L1="$(json_get "$RAIL_JSON" "networks.fortel2-local.l1ChainId" 2>/dev/null || echo "")"
ENV_LOC_L2="$(env_example_var "$ENV_LOCAL_EXAMPLE" "L2_CHAIN_ID")"
ENV_LOC_L1="$(env_example_var "$ENV_LOCAL_EXAMPLE" "L1_CHAIN_ID")"

if [[ "$LOC_L2" == "901" ]]; then
  pass "fortel2-local.l2ChainId == 901"
else
  fail "fortel2-local.l2ChainId == 901 (got ${LOC_L2:-<missing>})"
fi
if [[ -n "$ENV_LOC_L2" && "$LOC_L2" == "$ENV_LOC_L2" ]]; then
  pass "fortel2-local.l2ChainId matches .env.example L2_CHAIN_ID"
else
  fail "fortel2-local.l2ChainId vs .env.example (rail=${LOC_L2:-<missing>} env=${ENV_LOC_L2:-<missing>})"
fi
if [[ "$LOC_L1" == "900" ]]; then
  pass "fortel2-local.l1ChainId == 900"
else
  fail "fortel2-local.l1ChainId == 900 (got ${LOC_L1:-<missing>})"
fi
if [[ -n "$ENV_LOC_L1" && "$LOC_L1" == "$ENV_LOC_L1" ]]; then
  pass "fortel2-local.l1ChainId matches .env.example L1_CHAIN_ID"
else
  fail "fortel2-local.l1ChainId vs .env.example (rail=${LOC_L1:-<missing>} env=${ENV_LOC_L1:-<missing>})"
fi

# --- docs: repo-relative paths (no ://) must exist ---
# Scoped to docs only: l2Metadata.rollupConfig points at gitignored
# deployments/sepolia/.deployer/rollup.json (not present on CI checkouts).
while IFS= read -r doc_line; do
  [[ -z "$doc_line" ]] && continue
  doc_key="${doc_line%%|*}"
  doc_val="${doc_line#*|}"
  if [[ "$doc_val" == *"://"* ]]; then
    pass "docs.${doc_key} is absolute URL (existence not asserted)"
    continue
  fi
  if [[ -e "$REPO_ROOT/$doc_val" ]]; then
    pass "docs.${doc_key} path exists (${doc_val})"
  else
    fail "docs.${doc_key} path missing (${doc_val})"
  fi
done <<EOF
$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
for k, v in (data.get("docs") or {}).items():
    if isinstance(v, str):
        print("%s|%s" % (k, v))
' "$RAIL_JSON")
EOF

# --- updated parses as %Y-%m-%d ---
UPDATED="$(json_get "$RAIL_JSON" "updated" 2>/dev/null || echo "")"
if python3 -c '
from datetime import datetime
import sys
s = sys.argv[1]
datetime.strptime(s, "%Y-%m-%d")
' "$UPDATED" 2>/dev/null; then
  pass "updated parses as %Y-%m-%d (${UPDATED})"
else
  fail "updated parses as %Y-%m-%d (got ${UPDATED:-<missing>})"
fi

if [[ "$FAILS" -gt 0 ]]; then
  echo "rail-interface-check: ${FAILS} FAIL(s)" >&2
  exit 1
fi
echo "rail-interface-check: all checks passed"
exit 0
