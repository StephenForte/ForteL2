#!/usr/bin/env bash
# Lightweight regression checks for scripts/lib.sh helpers (no chain required).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

fail=0
assert_true() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS $name"
  else
    echo "FAIL $name" >&2
    fail=1
  fi
}

assert_false() {
  local name="$1"
  shift
  if "$@"; then
    echo "FAIL $name (expected false)" >&2
    fail=1
  else
    echo "PASS $name"
  fi
}

# Wei-safe unsigned compare (deposit poll must require increase, not inequality).
assert_true "uint_gt larger" uint_gt "1000000000000000001" "1000000000000000000"
assert_false "uint_gt equal" uint_gt "42" "42"
assert_false "uint_gt smaller" uint_gt "1" "2"

assert_true "valid checksum-ish address" is_eth_address "0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc"
assert_true "valid lowercase address" is_eth_address "0x9965507d1a55bcc2695c58ba16fb37d819b0a4dc"
assert_false "reject short address" is_eth_address "0x9965507D1a55bcC2695C58ba16FB37d819"
assert_false "reject missing 0x" is_eth_address "9965507D1a55bcC2695C58ba16FB37d819B0A4dc"
assert_false "reject empty" is_eth_address ""

# assert_loopback_url exits on failure — probe in subshells
if (assert_loopback_url "http://127.0.0.1:9545" "t" >/dev/null); then
  echo "PASS loopback 127.0.0.1"
else
  echo "FAIL loopback 127.0.0.1" >&2
  fail=1
fi
if (assert_loopback_url "http://localhost:8080" "t" >/dev/null); then
  echo "PASS loopback localhost"
else
  echo "FAIL loopback localhost" >&2
  fail=1
fi
if (assert_loopback_url "http://192.168.1.2:8545" "t" >/dev/null 2>&1); then
  echo "FAIL should reject non-loopback" >&2
  fail=1
else
  echo "PASS reject non-loopback"
fi

# Block-time coupling
L1_BLOCK_TIME=2 L2_BLOCK_TIME=2
if (assert_block_times >/dev/null); then
  echo "PASS block times equal"
else
  echo "FAIL block times equal" >&2
  fail=1
fi
L1_BLOCK_TIME=1 L2_BLOCK_TIME=2
if (assert_block_times >/dev/null 2>&1); then
  echo "FAIL should reject L1 < L2 block time" >&2
  fail=1
else
  echo "PASS reject L1 < L2 block time"
fi

# Foundry default key detection + Phase 2 tripwire
DEMO_KEY="0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba"
assert_true "detect Foundry default key" is_foundry_default_private_key "$DEMO_KEY"
assert_false "reject random key as Foundry default" is_foundry_default_private_key \
  "0x1111111111111111111111111111111111111111111111111111111111111111"

L2_CHAIN_ID=901
if (refuse_foundry_defaults_unless_local_l2 "$DEMO_KEY" "DEMO" >/dev/null); then
  echo "PASS Foundry default allowed on chain 901"
else
  echo "FAIL Foundry default should be allowed on 901" >&2
  fail=1
fi
L2_CHAIN_ID=11155111
if (refuse_foundry_defaults_unless_local_l2 "$DEMO_KEY" "DEMO" >/dev/null 2>&1); then
  echo "FAIL should refuse Foundry default on Sepolia chain id" >&2
  fail=1
else
  echo "PASS refuse Foundry default when L2_CHAIN_ID != 901"
fi
L2_CHAIN_ID=852
if (refuse_foundry_defaults_unless_local_l2 "$DEMO_KEY" "DEMO" >/dev/null 2>&1); then
  echo "FAIL should refuse Foundry default on L2 chain 852" >&2
  fail=1
else
  echo "PASS refuse Foundry default on L2_CHAIN_ID=852"
fi

# Phase 2d: redact QuickNode-style tokens from log display (not from cast --rpc-url).
SECRET_URL="https://user:pass@bold-abc.quiknode.pro/SECRET_TOKEN_abc123xyz/?api_key=leakme#frag"
REDACTED="$(redact_rpc_url "$SECRET_URL")"
if [[ "$REDACTED" == "https://bold-abc.quiknode.pro/…" ]] \
  && [[ "$REDACTED" != *SECRET* ]] \
  && [[ "$REDACTED" != *api_key* ]] \
  && [[ "$REDACTED" != *user:pass* ]]; then
  echo "PASS redact_rpc_url drops userinfo/query/path token"
else
  echo "FAIL redact_rpc_url got: $REDACTED" >&2
  fail=1
fi
if [[ "$(rpc_origin "https://example.quiknode.pro/secrettoken123/")" == "https://example.quiknode.pro" ]]; then
  echo "PASS rpc_origin strips path token"
else
  echo "FAIL rpc_origin should return scheme://host only" >&2
  fail=1
fi
if [[ "$(rpc_origin "http://127.0.0.1:8545")" == "http://127.0.0.1:8545" ]]; then
  echo "PASS rpc_origin keeps loopback host:port"
else
  echo "FAIL rpc_origin should keep loopback URL" >&2
  fail=1
fi
# wait_for_rpc must log the redacted form even on timeout (Phase 2d).
WAIT_OUT="$(wait_for_rpc "$SECRET_URL" "L1" 1 2>&1 || true)"
if [[ "$WAIT_OUT" == *"Waiting for L1 at https://bold-abc.quiknode.pro/…"* ]] \
  && [[ "$WAIT_OUT" == *"timed out waiting for L1 at https://bold-abc.quiknode.pro/…"* ]] \
  && [[ "$WAIT_OUT" != *SECRET_TOKEN* ]] \
  && [[ "$WAIT_OUT" != *api_key=leakme* ]] \
  && [[ "$WAIT_OUT" != *user:pass* ]]; then
  echo "PASS wait_for_rpc logs redacted URL only"
else
  echo "FAIL wait_for_rpc leaked or missing redacted URL: $WAIT_OUT" >&2
  fail=1
fi

# Phase 2 RPC asserts: remote L1 OK; L2 loopback; chain 852
L1_RPC_URL="https://ethereum-sepolia-rpc.publicnode.com"
L2_RPC_URL="http://127.0.0.1:9545"
L2_NODE_RPC_URL="http://127.0.0.1:9547"
L2_CHAIN_ID=852
if (assert_sepolia_rpc_urls >/dev/null); then
  echo "PASS assert_sepolia_rpc_urls remote L1 + loopback L2"
else
  echo "FAIL assert_sepolia_rpc_urls remote L1 + loopback L2" >&2
  fail=1
fi
L2_RPC_URL="http://192.168.1.2:9545"
if (assert_sepolia_rpc_urls >/dev/null 2>&1); then
  echo "FAIL assert_sepolia_rpc_urls should reject non-loopback L2" >&2
  fail=1
else
  echo "PASS assert_sepolia_rpc_urls reject non-loopback L2"
fi
L2_RPC_URL="http://127.0.0.1:9545"
L2_CHAIN_ID=901
if (assert_sepolia_rpc_urls >/dev/null 2>&1); then
  echo "FAIL assert_sepolia_rpc_urls should reject L2_CHAIN_ID=901" >&2
  fail=1
else
  echo "PASS assert_sepolia_rpc_urls reject chain 901"
fi
L2_CHAIN_ID=852
if (assert_remote_l1_rpc_url "https://rpc.sepolia.org" "t" >/dev/null); then
  echo "PASS assert_remote_l1_rpc_url https"
else
  echo "FAIL assert_remote_l1_rpc_url https" >&2
  fail=1
fi
if (assert_remote_l1_rpc_url "" "t" >/dev/null 2>&1); then
  echo "FAIL assert_remote_l1_rpc_url should reject empty" >&2
  fail=1
else
  echo "PASS assert_remote_l1_rpc_url reject empty"
fi

# HTTP port validation (serve_static_loopback)
if (require_http_port "8081" "t" >/dev/null); then
  echo "PASS require_http_port valid"
else
  echo "FAIL require_http_port valid" >&2
  fail=1
fi
if (require_http_port "0" "t" >/dev/null 2>&1); then
  echo "FAIL should reject port 0" >&2
  fail=1
else
  echo "PASS reject port 0"
fi
if (require_http_port "65536" "t" >/dev/null 2>&1); then
  echo "FAIL should reject port 65536" >&2
  fail=1
else
  echo "PASS reject port 65536"
fi

# serve_static_loopback: missing dir (does not start a server)
if (serve_static_loopback "/no/such/dir-$$" "8081" "t" >/dev/null 2>&1); then
  echo "FAIL serve_static_loopback should reject missing dir" >&2
  fail=1
else
  echo "PASS serve_static_loopback reject missing dir"
fi
if (serve_static_loopback "$SCRIPT_DIR" "notaport" "t" >/dev/null 2>&1); then
  echo "FAIL serve_static_loopback should reject bad port" >&2
  fail=1
else
  echo "PASS serve_static_loopback reject bad port"
fi

# gen-viewer-config.sh against a fixture tree (no live chain)
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-viewer-XXXXXX")"
SEPOLIA_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-sepolia-env-XXXXXX")"
cleanup_fixtures() {
  rm -rf "$FIXTURE" "$SEPOLIA_FIXTURE"
}
trap cleanup_fixtures EXIT
mkdir -p "$FIXTURE/deployments/.deployer" "$FIXTURE/viewer" "$FIXTURE/data"
cat > "$FIXTURE/.env" <<EOF
FORTEL2_ROOT=$FIXTURE
DATA_DIR=$FIXTURE/data
DEPLOY_DIR=$FIXTURE/deployments/.deployer
L1_CHAIN_ID=900
L2_CHAIN_ID=901
L1_RPC_URL=http://127.0.0.1:8545
L2_RPC_URL=http://127.0.0.1:9545
L2_NODE_RPC_URL=http://127.0.0.1:9547
BATCHER_ADDRESS=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
PROPOSER_ADDRESS=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
EOF
echo '{"DisputeGameFactoryProxy":"0xb3cc73ce8efac81f5c1ee1943b9f1ffeed98c4d2"}' \
  > "$FIXTURE/deployments/deployments.json"
echo '{"batch_inbox_address":"0x00289c189bee4e70334629f04cd5ed602b6600eb"}' \
  > "$FIXTURE/deployments/.deployer/rollup.json"

if FORTEL2_ROOT="$FIXTURE" "$SCRIPT_DIR/gen-viewer-config.sh" >/dev/null; then
  if grep -q 'BATCH_INBOX_ADDRESS = "0x00289c189bee4e70334629f04cd5ed602b6600eb"' "$FIXTURE/viewer/config.js" \
    && grep -q 'DISPUTE_GAME_FACTORY = "0xb3cc73ce8efac81f5c1ee1943b9f1ffeed98c4d2"' "$FIXTURE/viewer/config.js" \
    && grep -q 'L2_NODE_RPC_URL = "http://127.0.0.1:9547"' "$FIXTURE/viewer/config.js"; then
    echo "PASS gen-viewer-config fixture"
  else
    echo "FAIL gen-viewer-config missing expected exports" >&2
    fail=1
  fi
else
  echo "FAIL gen-viewer-config fixture run" >&2
  fail=1
fi

# Sepolia: remote L1 allowed; CSP header must include L1 origin (no path token)
mkdir -p "$SEPOLIA_FIXTURE/viewer" "$SEPOLIA_FIXTURE/deployments/sepolia/.deployer" "$SEPOLIA_FIXTURE/data"
cat > "$SEPOLIA_FIXTURE/.env.sepolia" <<EOF
FORTEL2_ROOT=$SEPOLIA_FIXTURE
DATA_DIR=$SEPOLIA_FIXTURE/data
DEPLOY_DIR=$SEPOLIA_FIXTURE/deployments/sepolia/.deployer
L1_CHAIN_ID=11155111
L2_CHAIN_ID=852
L1_BLOCK_TIME=12
L2_BLOCK_TIME=2
L1_RPC_URL=https://example.ethereum-sepolia.quiknode.pro/secrettoken1234567890/
L2_RPC_URL=http://127.0.0.1:9545
L2_NODE_RPC_URL=http://127.0.0.1:9547
BATCHER_ADDRESS=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
PROPOSER_ADDRESS=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
HARVEST_ADDRESS=0x5128889F20Ec13e0Be38b2BeBC568594159B652d
EOF
echo '{"DisputeGameFactoryProxy":"0xb3cc73ce8efac81f5c1ee1943b9f1ffeed98c4d2"}' \
  > "$SEPOLIA_FIXTURE/deployments/sepolia/deployments.json"
echo '{"batch_inbox_address":"0x00289c189bee4e70334629f04cd5ed602b6600eb"}' \
  > "$SEPOLIA_FIXTURE/deployments/sepolia/.deployer/rollup.json"
if FORTEL2_ROOT="$SEPOLIA_FIXTURE" FORTEL2_ENV=.env.sepolia \
  "$SCRIPT_DIR/gen-viewer-config.sh" >/dev/null; then
  if grep -q 'L2_CHAIN_ID = 852' "$SEPOLIA_FIXTURE/viewer/config.js" \
    && grep -q 'REFRESH_MS = 15000' "$SEPOLIA_FIXTURE/viewer/config.js" \
    && grep -q 'https://example.ethereum-sepolia.quiknode.pro' "$SEPOLIA_FIXTURE/viewer/.csp-header" \
    && ! grep -q 'secrettoken' "$SEPOLIA_FIXTURE/viewer/.csp-header"; then
    echo "PASS gen-viewer-config Sepolia remote L1 + CSP origin"
  else
    echo "FAIL gen-viewer-config Sepolia CSP / chain exports" >&2
    fail=1
  fi
else
  echo "FAIL gen-viewer-config Sepolia run" >&2
  fail=1
fi

# Bad batcher address must fail closed
sed -i.bak 's/BATCHER_ADDRESS=.*/BATCHER_ADDRESS=not-an-address/' "$FIXTURE/.env"
if FORTEL2_ROOT="$FIXTURE" "$SCRIPT_DIR/gen-viewer-config.sh" >/dev/null 2>&1; then
  echo "FAIL gen-viewer-config should reject bad BATCHER_ADDRESS" >&2
  fail=1
else
  echo "PASS gen-viewer-config reject bad address"
fi

# FORTEL2_ENV loader (subprocess — does not clobber this shell's env)
mkdir -p "$SEPOLIA_FIXTURE/deployments/sepolia/.deployer" "$SEPOLIA_FIXTURE/data"
cat > "$SEPOLIA_FIXTURE/.env.sepolia" <<EOF
FORTEL2_ROOT=$SEPOLIA_FIXTURE
DATA_DIR=$SEPOLIA_FIXTURE/data
DEPLOY_DIR=$SEPOLIA_FIXTURE/deployments/sepolia/.deployer
L1_CHAIN_ID=11155111
L2_CHAIN_ID=852
L1_BLOCK_TIME=12
L2_BLOCK_TIME=2
L1_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
L2_RPC_URL=http://127.0.0.1:9545
L2_NODE_RPC_URL=http://127.0.0.1:9547
HARVEST_ADDRESS=0x5128889F20Ec13e0Be38b2BeBC568594159B652d
EOF
if (
  FORTEL2_ROOT="$SEPOLIA_FIXTURE" FORTEL2_ENV=.env.sepolia \
    bash -c 'source "'"$SCRIPT_DIR"'/lib.sh" && [[ "$L2_CHAIN_ID" == "852" ]] && assert_sepolia_rpc_urls'
) >/dev/null; then
  echo "PASS FORTEL2_ENV=.env.sepolia loads chain 852"
else
  echo "FAIL FORTEL2_ENV=.env.sepolia load / assert" >&2
  fail=1
fi
if (
  FORTEL2_ROOT="$SEPOLIA_FIXTURE" FORTEL2_ENV=.env.missing \
    bash -c 'source "'"$SCRIPT_DIR"'/lib.sh"'
) >/dev/null 2>&1; then
  echo "FAIL FORTEL2_ENV missing file should error" >&2
  fail=1
else
  echo "PASS FORTEL2_ENV missing file errors"
fi

# assert_l2_ports_free must cover shared batcher/proposer admin ports (Phase 1 + 2c).
if awk '/^assert_l2_ports_free\(\)/,/^}/' "$SCRIPT_DIR/lib.sh" | grep -q 'BATCHER_RPC_PORT' \
  && awk '/^assert_l2_ports_free\(\)/,/^}/' "$SCRIPT_DIR/lib.sh" | grep -q 'PROPOSER_RPC_PORT'; then
  echo "PASS assert_l2_ports_free probes batcher/proposer ports"
else
  echo "FAIL assert_l2_ports_free must probe BATCHER_RPC_PORT and PROPOSER_RPC_PORT" >&2
  fail=1
fi
# Fail closed when lsof is missing (no silent skip).
if awk '/^assert_l2_ports_free\(\)/,/^}/' "$SCRIPT_DIR/lib.sh" | grep -q 'lsof is required'; then
  echo "PASS assert_l2_ports_free requires lsof"
else
  echo "FAIL assert_l2_ports_free must fail closed without lsof" >&2
  fail=1
fi
# Proposer admin RPC must bind loopback (op-service defaults ListenAddr to 0.0.0.0).
if grep -q -- '--rpc.addr=127.0.0.1' "$SCRIPT_DIR/06-start-proposer.sh" \
  && grep -q -- '--rpc.addr=127.0.0.1' "$SCRIPT_DIR/06-start-proposer-sepolia.sh" \
  && grep -q -- '--rpc.addr=127.0.0.1' "$SCRIPT_DIR/05-start-batcher.sh" \
  && grep -q -- '--rpc.addr=127.0.0.1' "$SCRIPT_DIR/05-start-batcher-sepolia.sh"; then
  echo "PASS batcher/proposer admin RPC bind loopback"
else
  echo "FAIL batcher/proposer start scripts must set --rpc.addr=127.0.0.1" >&2
  fail=1
fi
# Sepolia credit-budget defaults (metered QuickNode L1).
if grep -q 'SEPOLIA_BATCHER_POLL_INTERVAL:-12s' "$SCRIPT_DIR/05-start-batcher-sepolia.sh" \
  && grep -q 'SEPOLIA_BATCHER_MAX_CHANNEL_DURATION:-30' "$SCRIPT_DIR/05-start-batcher-sepolia.sh" \
  && grep -q 'SEPOLIA_BATCHER_TXMGR_RECEIPT_QUERY_INTERVAL:-24s' "$SCRIPT_DIR/05-start-batcher-sepolia.sh" \
  && grep -q 'SEPOLIA_PROPOSER_POLL_INTERVAL:-12s' "$SCRIPT_DIR/06-start-proposer-sepolia.sh" \
  && grep -q 'SEPOLIA_PROPOSER_INTERVAL:-5m' "$SCRIPT_DIR/06-start-proposer-sepolia.sh" \
  && grep -q 'SEPOLIA_L1_HTTP_POLL_INTERVAL:-12s' "$SCRIPT_DIR/04-start-sequencer-sepolia.sh" \
  && grep -q 'SEPOLIA_L1_RPC_RATE_LIMIT:-20' "$SCRIPT_DIR/04-start-sequencer-sepolia.sh"; then
  echo "PASS Sepolia start scripts use credit-budget poll/channel defaults"
else
  echo "FAIL Sepolia start scripts must keep credit-budget env defaults" >&2
  fail=1
fi
# smoke-transfer must assert balance movement, not only receipt success.
if grep -q 'uint_gt "\$AFTER_B" "\$BEFORE_B"' "$SCRIPT_DIR/smoke-transfer.sh" \
  && grep -q 'uint_gt "\$BEFORE_A" "\$AFTER_A"' "$SCRIPT_DIR/smoke-transfer.sh"; then
  echo "PASS smoke-transfer asserts A decrease and B increase"
else
  echo "FAIL smoke-transfer must uint_gt-assert balances after transfer" >&2
  fail=1
fi
# Behavioral: if default batcher admin port is free, bind it and expect assert_l2_ports_free to fail.
if ! command -v lsof >/dev/null 2>&1; then
  echo "FAIL assert_l2_ports_free behavioral probe needs lsof" >&2
  fail=1
elif ! lsof -nP -iTCP:"${BATCHER_RPC_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  python3 - <<PY &
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int("${BATCHER_RPC_PORT}")))
s.listen(1)
time.sleep(30)
PY
  listener_pid=$!
  for _ in 1 2 3 4 5; do
    lsof -nP -iTCP:"${BATCHER_RPC_PORT}" -sTCP:LISTEN >/dev/null 2>&1 && break
    sleep 0.1
  done
  # Keep EL/op-node ports on unused values so only the batcher admin conflict trips.
  if (
    L2_EL_HTTP_PORT=19545
    L2_EL_WS_PORT=19546
    L2_EL_AUTH_PORT=19551
    L2_NODE_RPC_PORT=19547
    assert_l2_ports_free >/dev/null 2>&1
  ); then
    echo "FAIL assert_l2_ports_free should fail when ${BATCHER_RPC_PORT} is in use" >&2
    fail=1
  else
    echo "PASS assert_l2_ports_free rejects occupied batcher port ${BATCHER_RPC_PORT}"
  fi
  kill "$listener_pid" >/dev/null 2>&1 || true
  wait "$listener_pid" 2>/dev/null || true
else
  echo "PASS assert_l2_ports_free batcher-port probe skipped (${BATCHER_RPC_PORT} busy)"
fi

# deployments_json_path selects Phase 1 vs Sepolia tree from L2_CHAIN_ID.
if (
  L2_CHAIN_ID=901
  [[ "$(deployments_json_path)" == "$FORTEL2_ROOT/deployments/deployments.json" ]]
) && (
  L2_CHAIN_ID=852
  [[ "$(deployments_json_path)" == "$FORTEL2_ROOT/deployments/sepolia/deployments.json" ]]
); then
  echo "PASS deployments_json_path phase selection"
else
  echo "FAIL deployments_json_path phase selection" >&2
  fail=1
fi

# assert_local_rpc_urls: both L1 and L2 must be loopback.
L1_RPC_URL="http://127.0.0.1:8545"
L2_RPC_URL="http://127.0.0.1:9545"
L2_NODE_RPC_URL="http://127.0.0.1:9547"
if (assert_local_rpc_urls >/dev/null); then
  echo "PASS assert_local_rpc_urls loopback L1+L2"
else
  echo "FAIL assert_local_rpc_urls loopback L1+L2" >&2
  fail=1
fi
L1_RPC_URL="https://ethereum-sepolia-rpc.publicnode.com"
if (assert_local_rpc_urls >/dev/null 2>&1); then
  echo "FAIL assert_local_rpc_urls should reject remote L1" >&2
  fail=1
else
  echo "PASS assert_local_rpc_urls rejects remote L1"
fi
L1_RPC_URL="http://127.0.0.1:8545"

# require_sepolia_env: chain ids + sepolia deploy tree.
if (
  L1_RPC_URL="https://ethereum-sepolia-rpc.publicnode.com"
  L2_RPC_URL="http://127.0.0.1:9545"
  L2_NODE_RPC_URL="http://127.0.0.1:9547"
  L1_CHAIN_ID=11155111
  L2_CHAIN_ID=852
  DEPLOY_DIR="$FORTEL2_ROOT/deployments/sepolia/.deployer"
  require_sepolia_env >/dev/null
); then
  echo "PASS require_sepolia_env happy path"
else
  echo "FAIL require_sepolia_env happy path" >&2
  fail=1
fi
if (
  L1_RPC_URL="https://ethereum-sepolia-rpc.publicnode.com"
  L2_RPC_URL="http://127.0.0.1:9545"
  L2_NODE_RPC_URL="http://127.0.0.1:9547"
  L1_CHAIN_ID=11155111
  L2_CHAIN_ID=852
  DEPLOY_DIR="$FORTEL2_ROOT/deployments/.deployer"
  require_sepolia_env >/dev/null 2>&1
); then
  echo "FAIL require_sepolia_env should reject Phase 1 DEPLOY_DIR" >&2
  fail=1
else
  echo "PASS require_sepolia_env rejects Phase 1 DEPLOY_DIR"
fi

# Phase 2c start scripts must share sepolia-fund-check.sh min-balance defaults.
if grep -q 'SEPOLIA_BATCHER_MIN_ETH:-0\.15' "$SCRIPT_DIR/05-start-batcher-sepolia.sh" \
  && grep -q 'SEPOLIA_PROPOSER_MIN_ETH:-0\.15' "$SCRIPT_DIR/06-start-proposer-sepolia.sh" \
  && grep -q 'SEPOLIA_BATCHER_MIN_ETH:-0\.15' "$SCRIPT_DIR/sepolia-fund-check.sh" \
  && grep -q 'SEPOLIA_PROPOSER_MIN_ETH:-0\.15' "$SCRIPT_DIR/sepolia-fund-check.sh"; then
  echo "PASS Sepolia batcher/proposer min ETH defaults aligned at 0.15"
else
  echo "FAIL Sepolia batcher/proposer min ETH defaults must be 0.15 across fund-check + start scripts" >&2
  fail=1
fi

# start-all-sepolia.sh must require deployments.json before the sequencer so a
# partial deploy tree cannot leave op-geth/op-node running after batcher fails.
if grep -q 'deployments_json_path' "$SCRIPT_DIR/start-all-sepolia.sh" \
  && awk '
    /04-start-sequencer-sepolia/ { exit found ? 0 : 1 }
    /deployments_json_path/ { found = 1 }
  ' "$SCRIPT_DIR/start-all-sepolia.sh"; then
  echo "PASS start-all-sepolia.sh checks deployments.json before sequencer"
else
  echo "FAIL start-all-sepolia.sh must require deployments.json before 04-start-sequencer-sepolia.sh" >&2
  fail=1
fi

# demo-checklist.sh: cast chain-id after a successful block-number must not abort
# under set -e (bare assignment exits before fail_item / checklist aggregation).
if grep -E '^\s+(l1|l2)_chain=\$\(cast chain-id' "$SCRIPT_DIR/demo-checklist.sh" \
  | grep -qv '||'; then
  echo "FAIL demo-checklist chain-id missing || guard under set -e" >&2
  fail=1
else
  echo "PASS demo-checklist chain-id guarded against set -e"
fi

# Behavioral twin of the L1/L2 RPC chain-id path in demo-checklist.sh.
chain_id_guard_ok=0
if (
  set -euo pipefail
  fail=0
  fail_item() { fail=1; }
  L1_CHAIN_ID=900
  if l1_block=$(echo 42); then
    l1_chain=$(false 2>/dev/null || echo "")
    if [[ -n "$l1_chain" && "$l1_chain" == "${L1_CHAIN_ID}" ]]; then
      exit 2
    elif [[ -n "$l1_chain" ]]; then
      fail_item "wrong"
    else
      fail_item "unread"
    fi
  else
    exit 3
  fi
  # Must reach aggregation with fail set (not abort on the failing assignment).
  (( fail )) || exit 4
); then
  chain_id_guard_ok=1
fi
if (( chain_id_guard_ok )); then
  echo "PASS demo-checklist chain-id fail records FAIL under set -e"
else
  echo "FAIL demo-checklist chain-id path should record FAIL without aborting" >&2
  fail=1
fi

# demo-checklist Sepolia path: --print with fixture env mentions Sepolia (not Anvil five-proc list)
SEPOLIA_DEMO_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-demo-sepolia-XXXXXX")"
mkdir -p "$SEPOLIA_DEMO_FIXTURE/deployments/sepolia/.deployer" "$SEPOLIA_DEMO_FIXTURE/data"
cat > "$SEPOLIA_DEMO_FIXTURE/.env.sepolia" <<EOF
FORTEL2_ROOT=$SEPOLIA_DEMO_FIXTURE
DATA_DIR=$SEPOLIA_DEMO_FIXTURE/data
DEPLOY_DIR=$SEPOLIA_DEMO_FIXTURE/deployments/sepolia/.deployer
L1_CHAIN_ID=11155111
L2_CHAIN_ID=852
L1_BLOCK_TIME=12
L2_BLOCK_TIME=2
L1_RPC_URL=https://example.ethereum-sepolia.quiknode.pro/token/
L2_RPC_URL=http://127.0.0.1:9545
L2_NODE_RPC_URL=http://127.0.0.1:9547
BATCHER_ADDRESS=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
PROPOSER_ADDRESS=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
HARVEST_ADDRESS=0x5128889F20Ec13e0Be38b2BeBC568594159B652d
ADMIN_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
SEQUENCER_ADDRESS=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
CHALLENGER_ADDRESS=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
EOF
SEPOLIA_PRINT="$(
  FORTEL2_ROOT="$SEPOLIA_DEMO_FIXTURE" FORTEL2_ENV=.env.sepolia \
    "$SCRIPT_DIR/demo-checklist.sh" --print 2>/dev/null || true
)"
rm -rf "$SEPOLIA_DEMO_FIXTURE"
if echo "$SEPOLIA_PRINT" | grep -q 'Sepolia (L2 852' \
  && echo "$SEPOLIA_PRINT" | grep -q 'no Anvil' \
  && echo "$SEPOLIA_PRINT" | grep -q 'demo-live.sh --sepolia'; then
  echo "PASS demo-checklist --print Sepolia mode"
else
  echo "FAIL demo-checklist Sepolia --print content" >&2
  fail=1
fi

if grep -q 'assert_sepolia_rpc_urls' "$SCRIPT_DIR/demo-checklist.sh" \
  && grep -q 'IS_SEPOLIA' "$SCRIPT_DIR/demo-checklist.sh"; then
  echo "PASS demo-checklist has Sepolia assert path"
else
  echo "FAIL demo-checklist missing Sepolia assert wiring" >&2
  fail=1
fi

# sepolia-fund-check.sh must exit non-zero when a required role prints NEED so
# demo-checklist --auto cannot PASS on under-funded BATCHER/PROPOSER.
if grep -q 'fund_needs=0' "$SCRIPT_DIR/sepolia-fund-check.sh" \
  && grep -q 'fund_needs=1' "$SCRIPT_DIR/sepolia-fund-check.sh" \
  && grep -q 'exit 1' "$SCRIPT_DIR/sepolia-fund-check.sh"; then
  echo "PASS sepolia-fund-check tracks NEED and exits non-zero"
else
  echo "FAIL sepolia-fund-check must set fund_needs and exit 1 on NEED" >&2
  fail=1
fi

# Behavioral twin: balance < min → NEED → exit 1; balance ≥ min → exit 0.
fund_need_twin_ok=1
if (
  set -euo pipefail
  fund_needs=0
  row() {
    local bal="$1" min="$2"
    if python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) + 1e-18 >= float(sys.argv[2]) else 1)' "$bal" "$min"; then
      :
    else
      if python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) > 0 else 1)' "$min"; then
        fund_needs=1
      fi
    fi
  }
  row "0.10" "0.15"
  row "1.00" "0.00"
  if (( fund_needs )); then
    exit 1
  fi
  exit 0
); then
  fund_need_twin_ok=0
fi
if ! (
  set -euo pipefail
  fund_needs=0
  row() {
    local bal="$1" min="$2"
    if python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) + 1e-18 >= float(sys.argv[2]) else 1)' "$bal" "$min"; then
      :
    else
      if python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) > 0 else 1)' "$min"; then
        fund_needs=1
      fi
    fi
  }
  row "0.20" "0.15"
  row "0.00" "0.00"
  if (( fund_needs )); then
    exit 1
  fi
  exit 0
); then
  fund_need_twin_ok=0
fi
if (( fund_need_twin_ok )); then
  echo "PASS sepolia-fund-check NEED twin (under min → fail, ok → pass)"
else
  echo "FAIL sepolia-fund-check NEED twin" >&2
  fail=1
fi

# demo-checklist must FAIL (not PASS/SKIP) when sepolia-fund-check exits non-zero.
# Match the auto-check if-block only (checklist prose also mentions the script).
fund_check_block="$(
  grep -A4 'if "$SCRIPT_DIR/sepolia-fund-check.sh"' "$SCRIPT_DIR/demo-checklist.sh" || true
)"
if echo "$fund_check_block" | grep -q 'fail_item "sepolia-fund-check reported NEED' \
  && echo "$fund_check_block" | grep -q 'pass "sepolia-fund-check: required roles'; then
  echo "PASS demo-checklist fails auto check on sepolia-fund-check NEED"
else
  echo "FAIL demo-checklist must fail_item when sepolia-fund-check exits non-zero" >&2
  fail=1
fi

if "$SCRIPT_DIR/demo-live.sh" --help >/dev/null 2>&1; then
  echo "PASS demo-live.sh --help"
else
  echo "FAIL demo-live.sh --help" >&2
  fail=1
fi

if (( fail )); then
  echo "script helper tests FAILED" >&2
  exit 1
fi
echo "All script helper tests passed."
