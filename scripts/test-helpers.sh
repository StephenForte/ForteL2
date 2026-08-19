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
SHORT_PATH_REDACTED="$(redact_rpc_url "https://rpc.example/secret")"
if [[ "$SHORT_PATH_REDACTED" == "https://rpc.example/…" ]]; then
  echo "PASS redact_rpc_url redacts short path tokens"
else
  echo "FAIL redact_rpc_url exposed short path: $SHORT_PATH_REDACTED" >&2
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

# env -u: the fixture has no .env.sepolia — an inherited FORTEL2_ENV (e.g. from
# demo-checklist --sepolia) must not leak into the fixture run.
if env -u FORTEL2_ENV FORTEL2_ROOT="$FIXTURE" "$SCRIPT_DIR/gen-viewer-config.sh" >/dev/null; then
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
  && grep -q 'SEPOLIA_BATCHER_TXMGR_RECEIPT_QUERY_INTERVAL:-36s' "$SCRIPT_DIR/05-start-batcher-sepolia.sh" \
  && grep -q 'SEPOLIA_BATCHER_TXMGR_REBROADCAST_INTERVAL:-36s' "$SCRIPT_DIR/05-start-batcher-sepolia.sh" \
  && grep -q 'SEPOLIA_PROPOSER_POLL_INTERVAL:-12s' "$SCRIPT_DIR/06-start-proposer-sepolia.sh" \
  && grep -q 'SEPOLIA_PROPOSER_INTERVAL:-5m' "$SCRIPT_DIR/06-start-proposer-sepolia.sh" \
  && grep -q 'SEPOLIA_PROPOSER_TXMGR_RECEIPT_QUERY_INTERVAL:-36s' "$SCRIPT_DIR/06-start-proposer-sepolia.sh" \
  && grep -q 'SEPOLIA_PROPOSER_TXMGR_REBROADCAST_INTERVAL:-36s' "$SCRIPT_DIR/06-start-proposer-sepolia.sh" \
  && grep -q 'SEPOLIA_L1_HTTP_POLL_INTERVAL:-12s' "$SCRIPT_DIR/04-start-sequencer-sepolia.sh" \
  && grep -q 'SEPOLIA_L1_RPC_RATE_LIMIT:-20' "$SCRIPT_DIR/04-start-sequencer-sepolia.sh"; then
  echo "PASS Sepolia start scripts use credit-budget poll/channel defaults"
else
  echo "FAIL Sepolia start scripts must keep credit-budget env defaults" >&2
  fail=1
fi
# Phase 4: custom batcher is opt-in; stock path remains default; Sepolia needs confirm gate.
# Stop existing op-batcher pid before custom start; Sepolia passes L1 confirmations + receipt-timeout.
if grep -q 'USE_CUSTOM_BATCHER' "$SCRIPT_DIR/05-start-batcher.sh" \
  && grep -q 'fortel2-batcher' "$SCRIPT_DIR/05-start-batcher.sh" \
  && grep -q 'stop_bg op-batcher' "$SCRIPT_DIR/05-start-batcher.sh" \
  && grep -q 'CONFIRM_CUSTOM_BATCHER_SEPOLIA' "$SCRIPT_DIR/05-start-batcher-sepolia.sh" \
  && grep -q 'USE_CUSTOM_BATCHER' "$SCRIPT_DIR/05-start-batcher-sepolia.sh" \
  && grep -q 'stop_bg op-batcher' "$SCRIPT_DIR/05-start-batcher-sepolia.sh" \
  && grep -q -- '-confirmations' "$SCRIPT_DIR/05-start-batcher-sepolia.sh" \
  && grep -q -- '-receipt-timeout' "$SCRIPT_DIR/05-start-batcher-sepolia.sh"; then
  echo "PASS Phase 4 USE_CUSTOM_BATCHER switch (local + Sepolia confirm gate)"
else
  echo "FAIL 05-start-batcher*.sh must support USE_CUSTOM_BATCHER with Sepolia confirm gate" >&2
  fail=1
fi
# Local deploy must override preimageOracleChallengePeriod so short fault-game clocks can create().
if grep -q 'preimageOracleChallengePeriod' "$SCRIPT_DIR/02-deploy-contracts.sh" \
  && grep -q 'PREIMAGE_ORACLE_CHALLENGE_PERIOD' "$SCRIPT_DIR/02-deploy-contracts.sh"; then
  echo "PASS local deploy sets preimageOracleChallengePeriod for short fault-game clocks"
else
  echo "FAIL 02-deploy-contracts.sh must set preimageOracleChallengePeriod (InvalidClockExtension otherwise)" >&2
  fail=1
fi
# Sepolia deploy must write + validate the sixth immutable (D-0046). Stock
# preimageOracleChallengePeriod=86400 makes Phase 7's 600/7200 illegal.
if grep -q 'preimageOracleChallengePeriod' "$SCRIPT_DIR/02-deploy-contracts-sepolia.sh" \
  && grep -q 'PREIMAGE_ORACLE_CHALLENGE_PERIOD:-86400' "$SCRIPT_DIR/02-deploy-contracts-sepolia.sh" \
  && grep -q 'clockExtension+preimageOracleChallengePeriod' "$SCRIPT_DIR/02-deploy-contracts-sepolia.sh" \
  && grep -q '_min_oracle' "$SCRIPT_DIR/02-deploy-contracts-sepolia.sh" \
  && grep -q 'PREIMAGE_ORACLE_CHALLENGE_PERIOD' "$SCRIPT_DIR/../.env.sepolia.example"; then
  echo "PASS Sepolia deploy sets and validates preimageOracleChallengePeriod (D-0046)"
else
  echo "FAIL 02-deploy-contracts-sepolia.sh must override + validate preimageOracleChallengePeriod before apply" >&2
  fail=1
fi
# Phase 7 proposed clocks are legal with proposed preimage=3600 and illegal with stock 86400.
_p7_ext=600; _p7_max=7200; _p7_pre=3600
_p7_min=$(( _p7_ext * 2 )); _p7_or=$(( _p7_ext + _p7_pre ))
if (( _p7_or > _p7_min )); then _p7_min=$_p7_or; fi
if (( _p7_max >= _p7_min )); then
  echo "PASS Phase 7 proposed 600/7200/3600 satisfies initialize constraint (min=$_p7_min)"
else
  echo "FAIL Phase 7 proposed 3600 preimage must fit under maxClockDuration=7200" >&2
  fail=1
fi
_p7_stock=$(( _p7_ext + 86400 ))
if (( _p7_max < _p7_stock )); then
  echo "PASS stock preimageOracleChallengePeriod=86400 is rejected under Phase 7 600/7200"
else
  echo "FAIL 7200 must be < 600+86400 so the Sepolia deploy gate has something to catch" >&2
  fail=1
fi
# Phase 5: custom proposer is opt-in; stock path remains default; Sepolia needs confirm gate.
if grep -q 'USE_CUSTOM_PROPOSER' "$SCRIPT_DIR/06-start-proposer.sh" \
  && grep -q 'fortel2-proposer' "$SCRIPT_DIR/06-start-proposer.sh" \
  && grep -q 'stop_bg op-proposer' "$SCRIPT_DIR/06-start-proposer.sh" \
  && grep -q 'CONFIRM_CUSTOM_PROPOSER_SEPOLIA' "$SCRIPT_DIR/06-start-proposer-sepolia.sh" \
  && grep -q 'USE_CUSTOM_PROPOSER' "$SCRIPT_DIR/06-start-proposer-sepolia.sh" \
  && grep -q 'stop_bg op-proposer' "$SCRIPT_DIR/06-start-proposer-sepolia.sh" \
  && grep -q -- '-confirmations' "$SCRIPT_DIR/06-start-proposer-sepolia.sh" \
  && grep -q -- '-receipt-timeout' "$SCRIPT_DIR/06-start-proposer-sepolia.sh"; then
  echo "PASS Phase 5 USE_CUSTOM_PROPOSER switch (local + Sepolia confirm gate)"
else
  echo "FAIL 06-start-proposer*.sh must support USE_CUSTOM_PROPOSER with Sepolia confirm gate" >&2
  fail=1
fi
# Overnight sleep/wake helper for metered Sepolia / QuickNode.
if [[ -x "$SCRIPT_DIR/dev-sleep.sh" ]] \
  && grep -q 'cmd_sleep' "$SCRIPT_DIR/dev-sleep.sh" \
  && grep -q 'stop-all-sepolia' "$SCRIPT_DIR/dev-sleep.sh" \
  && grep -q 'start-all-sepolia' "$SCRIPT_DIR/dev-sleep.sh"; then
  echo "PASS dev-sleep.sh sleep/wake wraps Sepolia start/stop"
else
  echo "FAIL missing scripts/dev-sleep.sh sleep/wake helper" >&2
  fail=1
fi
# Checked-in LaunchAgents for overnight sleep / morning wake (Mac mini).
LAUNCHD_DIR="$(cd "$SCRIPT_DIR/../launchd" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -x "$ROOT_DIR/run_dev_sleep.sh" ]] \
  && [[ -x "$ROOT_DIR/run_dev_wake.sh" ]] \
  && grep -q 'dev-sleep.sh sleep' "$ROOT_DIR/run_dev_sleep.sh" \
  && grep -q 'dev-sleep.sh wake' "$ROOT_DIR/run_dev_wake.sh" \
  && grep -q 'com.steve.fortel2-sleep' "$LAUNCHD_DIR/com.steve.fortel2-sleep.plist" \
  && grep -q 'run_dev_sleep.sh' "$LAUNCHD_DIR/com.steve.fortel2-sleep.plist" \
  && grep -q 'Library/Logs/fortel2-sleep' "$LAUNCHD_DIR/com.steve.fortel2-sleep.plist" \
  && grep -q 'com.steve.fortel2-wake' "$LAUNCHD_DIR/com.steve.fortel2-wake.plist" \
  && grep -q 'run_dev_wake.sh' "$LAUNCHD_DIR/com.steve.fortel2-wake.plist" \
  && grep -q 'Library/Logs/fortel2-wake' "$LAUNCHD_DIR/com.steve.fortel2-wake.plist" \
  && ! grep -q 'data/.*\.log' "$LAUNCHD_DIR/com.steve.fortel2-sleep.plist" \
  && ! grep -q 'data/.*\.log' "$LAUNCHD_DIR/com.steve.fortel2-wake.plist"; then
  echo "PASS launchd sleep/wake plists + run_dev_{sleep,wake}.sh wrappers"
else
  echo "FAIL launchd sleep/wake agents must wrap run_dev_*.sh and log under ~/Library/Logs" >&2
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

# Gas floors must be checked before the sequencer, and wake must stop leftovers
# first — otherwise launchd wake fails on underfunded BATCHER then on :9545.
if awk '
    /04-start-sequencer-sepolia/ { exit (batcher && proposer) ? 0 : 1 }
    /require_min_balance_eth.*BATCHER/ { batcher = 1 }
    /require_min_balance_eth.*PROPOSER/ { proposer = 1 }
  ' "$SCRIPT_DIR/start-all-sepolia.sh" \
  && grep -q 'stop-all-sepolia' "$SCRIPT_DIR/start-all-sepolia.sh" \
  && awk '
    /start-all-sepolia/ { exit stopped ? 0 : 1 }
    /cmd_wake/ { in_wake = 1 }
    in_wake && /stop-all-sepolia/ { stopped = 1 }
  ' "$SCRIPT_DIR/dev-sleep.sh"; then
  echo "PASS Sepolia wake/start preflight funds + orphan cleanup"
else
  echo "FAIL start-all-sepolia must preflight BATCHER/PROPOSER; wake must stop leftovers first" >&2
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

# sepolia-fund-check.sh exits non-zero only for BATCHER/PROPOSER NEED (Phase 2c).
# ADMIN/HARVEST floors are advisory so post-2b ADMIN < 0.70 does not fail --auto.
if grep -q 'fund_needs=0' "$SCRIPT_DIR/sepolia-fund-check.sh" \
  && grep -q 'fund_needs=1' "$SCRIPT_DIR/sepolia-fund-check.sh" \
  && grep -q 'exit 1' "$SCRIPT_DIR/sepolia-fund-check.sh" \
  && grep -q 'local blocking=' "$SCRIPT_DIR/sepolia-fund-check.sh" \
  && grep -q 'print_row "BATCHER".* 1$' "$SCRIPT_DIR/sepolia-fund-check.sh" \
  && grep -q 'print_row "PROPOSER".* 1$' "$SCRIPT_DIR/sepolia-fund-check.sh" \
  && grep -q 'print_row "ADMIN".* 0$' "$SCRIPT_DIR/sepolia-fund-check.sh" \
  && grep -q 'print_row "HARVEST".* 0$' "$SCRIPT_DIR/sepolia-fund-check.sh"; then
  echo "PASS sepolia-fund-check blocks only BATCHER/PROPOSER NEED"
else
  echo "FAIL sepolia-fund-check must exit 1 only for BATCHER/PROPOSER NEED" >&2
  fail=1
fi

# Behavioral twin: blocking under min → exit 1; advisory under min → exit 0.
fund_need_twin_ok=1
# Under-funded BATCHER (blocking) must fail.
if (
  set -euo pipefail
  fund_needs=0
  row() {
    local bal="$1" min="$2" blocking="${3:-0}"
    if python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) + 1e-18 >= float(sys.argv[2]) else 1)' "$bal" "$min"; then
      :
    elif (( blocking )); then
      fund_needs=1
    fi
  }
  row "0.10" "0.15" 1
  row "0.01" "0.70" 0
  if (( fund_needs )); then
    exit 1
  fi
  exit 0
); then
  fund_need_twin_ok=0
fi
# Only ADMIN under floor (advisory) must pass.
if ! (
  set -euo pipefail
  fund_needs=0
  row() {
    local bal="$1" min="$2" blocking="${3:-0}"
    if python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) + 1e-18 >= float(sys.argv[2]) else 1)' "$bal" "$min"; then
      :
    elif (( blocking )); then
      fund_needs=1
    fi
  }
  row "0.20" "0.15" 1
  row "0.01" "0.70" 0
  row "0.01" "0.05" 0
  if (( fund_needs )); then
    exit 1
  fi
  exit 0
); then
  fund_need_twin_ok=0
fi
if (( fund_need_twin_ok )); then
  echo "PASS sepolia-fund-check NEED twin (blocking vs advisory)"
else
  echo "FAIL sepolia-fund-check NEED twin" >&2
  fail=1
fi

# demo-checklist must FAIL (not PASS/SKIP) when sepolia-fund-check exits non-zero.
# Match the auto-check if-block only (checklist prose also mentions the script).
fund_check_block="$(
  grep -A4 'if "$SCRIPT_DIR/sepolia-fund-check.sh"' "$SCRIPT_DIR/demo-checklist.sh" || true
)"
if echo "$fund_check_block" | grep -q 'fail_item "sepolia-fund-check: BATCHER/PROPOSER NEED' \
  && echo "$fund_check_block" | grep -q 'pass "sepolia-fund-check: BATCHER/PROPOSER'; then
  echo "PASS demo-checklist fails auto check on BATCHER/PROPOSER NEED"
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

# derivation-check.sh: CLI-mode guards (D-0013 / R2 debugging arc).
DERIV_CHECK="$SCRIPT_DIR/derivation-check.sh"
if grep -q '"$SEPOLIA" -eq 1 && "$MAKE_ANCHOR" -eq 0' "$DERIV_CHECK" \
  && grep -q 'skip it in --make-anchor mode' "$DERIV_CHECK" \
  && grep -q 'never continue into verification' "$DERIV_CHECK" \
  && grep -q 'run derivation-check without --make-anchor' "$DERIV_CHECK" \
  && awk '/"\$MAKE_ANCHOR" -eq 1/ { in_block=1 } in_block && /exit 0/ { found=1 } END { exit !found }' "$DERIV_CHECK"; then
  echo "PASS derivation-check --make-anchor skips live-RPC window setup and exits"
else
  echo "FAIL derivation-check --make-anchor must guard Sepolia window setup and exit before verify" >&2
  fail=1
fi
if grep -q 'VERIFY_ARGS+=(-json)' "$DERIV_CHECK" \
  && awk '/"\$JSON_OUT"/ { in_json=1 } in_json && /VERIFY_ARGS\+=\(-json\)/ { found=1 } END { exit !found }' "$DERIV_CHECK"; then
  echo "PASS derivation-check --json-out adds -json to verifier"
else
  echo "FAIL derivation-check --json-out must pass -json to cmd/verify" >&2
  fail=1
fi
if grep -q 'start-l2=\$START_L2 requires anchor datadir' "$DERIV_CHECK" \
  && awk '/"\$START_L2" -gt 1/ { mid=1 } mid && /requires anchor datadir/ { found=1 } END { exit !found }' "$DERIV_CHECK"; then
  echo "PASS derivation-check mid-chain start requires anchor datadir"
else
  echo "FAIL derivation-check must error when start-l2>1 without anchor datadir" >&2
  fail=1
fi
if grep -q 'FORTEL2_ENV=.env.sepolia \$0 --sepolia --make-anchor' "$DERIV_CHECK"; then
  echo "PASS derivation-check usage documents --sepolia --make-anchor"
else
  echo "FAIL derivation-check usage must mention --sepolia --make-anchor" >&2
  fail=1
fi

# gas-runway.sh: analyze-only fixtures (no RPC / cast / Sepolia env).
GAS_RUNWAY="$SCRIPT_DIR/gas-runway.sh"
GAS_FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-gas-runway.XXXXXX")"
cleanup_gas_fixtures() { rm -rf "$GAS_FIXTURE_DIR"; }
trap cleanup_gas_fixtures EXIT

# Two samples 1 h apart, 0.01 ETH consumed → ~0.24 ETH/day; ~3.5 days to 0.15 floor.
cat >"$GAS_FIXTURE_DIR/burn.jsonl" <<'EOF'
{"ts":1000000000,"batcher_wei":"1000000000000000000","proposer_wei":"1000000000000000000","l2_block":100}
{"ts":1000003600,"batcher_wei":"990000000000000000","proposer_wei":"990000000000000000","l2_block":200}
EOF
GAS_BURN_OUT="$(
  GAS_RUNWAY_SAMPLES_FILE="$GAS_FIXTURE_DIR/burn.jsonl" \
    "$GAS_RUNWAY" --analyze-only 2>&1
)" && GAS_BURN_EC=0 || GAS_BURN_EC=$?
if [[ "$GAS_BURN_EC" -eq 0 ]] \
  && echo "$GAS_BURN_OUT" | grep -q 'burn_eth_per_day=0.240000' \
  && echo "$GAS_BURN_OUT" | grep -q 'role=BATCHER' \
  && echo "$GAS_BURN_OUT" | grep -q 'days_to_floor=3.500'; then
  echo "PASS gas-runway burn/day ~0.24 ETH and days-to-floor"
else
  echo "FAIL gas-runway burn fixture (ec=$GAS_BURN_EC)" >&2
  echo "$GAS_BURN_OUT" >&2
  fail=1
fi

# Top-up: balance rises → no negative burn rate.
cat >"$GAS_FIXTURE_DIR/topup.jsonl" <<'EOF'
{"ts":1000000000,"batcher_wei":"100000000000000000","proposer_wei":"100000000000000000","l2_block":100}
{"ts":1000003600,"batcher_wei":"200000000000000000","proposer_wei":"200000000000000000","l2_block":200}
EOF
GAS_TOPUP_OUT="$(
  GAS_RUNWAY_SAMPLES_FILE="$GAS_FIXTURE_DIR/topup.jsonl" \
    "$GAS_RUNWAY" --analyze-only 2>&1
)" && GAS_TOPUP_EC=0 || GAS_TOPUP_EC=$?
if [[ "$GAS_TOPUP_EC" -eq 0 ]] \
  && echo "$GAS_TOPUP_OUT" | grep -q 'burn_eth_per_day=0.000000' \
  && ! echo "$GAS_TOPUP_OUT" | grep -qE 'burn_eth_per_day=-'; then
  echo "PASS gas-runway top-up skips negative burn"
else
  echo "FAIL gas-runway top-up fixture (ec=$GAS_TOPUP_EC)" >&2
  echo "$GAS_TOPUP_OUT" >&2
  fail=1
fi

# Single sample → INSUFFICIENT SAMPLES, exit 0.
cat >"$GAS_FIXTURE_DIR/one.jsonl" <<'EOF'
{"ts":1000000000,"batcher_wei":"1000000000000000000","proposer_wei":"1000000000000000000","l2_block":100}
EOF
GAS_ONE_OUT="$(
  GAS_RUNWAY_SAMPLES_FILE="$GAS_FIXTURE_DIR/one.jsonl" \
    "$GAS_RUNWAY" --analyze-only 2>&1
)" && GAS_ONE_EC=0 || GAS_ONE_EC=$?
if [[ "$GAS_ONE_EC" -eq 0 ]] && echo "$GAS_ONE_OUT" | grep -q 'INSUFFICIENT SAMPLES'; then
  echo "PASS gas-runway single sample → INSUFFICIENT SAMPLES"
else
  echo "FAIL gas-runway single-sample fixture (ec=$GAS_ONE_EC)" >&2
  echo "$GAS_ONE_OUT" >&2
  fail=1
fi

# Below min days → exit 2 (0.20→0.19 ETH in 1 h ≈ 0.17 days to 0.15 floor).
cat >"$GAS_FIXTURE_DIR/short.jsonl" <<'EOF'
{"ts":1000000000,"batcher_wei":"200000000000000000","proposer_wei":"200000000000000000","l2_block":100}
{"ts":1000003600,"batcher_wei":"190000000000000000","proposer_wei":"190000000000000000","l2_block":200}
EOF
GAS_SHORT_OUT="$(
  GAS_RUNWAY_SAMPLES_FILE="$GAS_FIXTURE_DIR/short.jsonl" \
    "$GAS_RUNWAY" --analyze-only 2>&1
)" && GAS_SHORT_EC=0 || GAS_SHORT_EC=$?
if [[ "$GAS_SHORT_EC" -eq 2 ]]; then
  echo "PASS gas-runway below-min-days exits 2"
else
  echo "FAIL gas-runway below-min-days expected exit 2 (ec=$GAS_SHORT_EC)" >&2
  echo "$GAS_SHORT_OUT" >&2
  fail=1
fi

# Capture fixture-run output for redaction check (burn case is representative).
GAS_LEAK_COUNT="$(
  printf '%s' "$GAS_BURN_OUT$GAS_TOPUP_OUT$GAS_ONE_OUT$GAS_SHORT_OUT" \
    | grep -icE 'private|quiknode' || true
)"
if [[ "$GAS_LEAK_COUNT" -eq 0 ]]; then
  echo "PASS gas-runway fixture output has no private/quiknode"
else
  echo "FAIL gas-runway fixture output leaked private/quiknode" >&2
  fail=1
fi

cleanup_gas_fixtures
trap - EXIT

# rail-interface-check.sh: corrupted proxy address fails; clean repo file passes.
RAIL_CHECK="$SCRIPT_DIR/rail-interface-check.sh"
RAIL_FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-rail-iface.XXXXXX")"
cleanup_rail_fixtures() { rm -rf "$RAIL_FIXTURE_DIR"; }
trap cleanup_rail_fixtures EXIT

cp "$SCRIPT_DIR/../deployments/rail-interface.json" "$RAIL_FIXTURE_DIR/rail-interface.json"
# Flip one hex digit in optimismPortalProxy (…c624 → …c625).
python3 -c '
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
bridge = data["networks"]["fortel2-sepolia"]["bridge"]
addr = bridge["optimismPortalProxy"]
bridge["optimismPortalProxy"] = addr[:-1] + ("5" if addr[-1].lower() != "5" else "4")
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
' "$RAIL_FIXTURE_DIR/rail-interface.json"

RAIL_BAD_OUT="$(
  RAIL_INTERFACE_JSON="$RAIL_FIXTURE_DIR/rail-interface.json" \
    "$RAIL_CHECK" 2>&1
)" && RAIL_BAD_EC=0 || RAIL_BAD_EC=$?
if [[ "$RAIL_BAD_EC" -ne 0 ]] && echo "$RAIL_BAD_OUT" | grep -q 'optimismPortalProxy'; then
  echo "PASS rail-interface-check rejects corrupted optimismPortalProxy"
else
  echo "FAIL rail-interface-check should exit non-zero naming optimismPortalProxy (ec=$RAIL_BAD_EC)" >&2
  echo "$RAIL_BAD_OUT" >&2
  fail=1
fi

RAIL_OK_OUT="$("$RAIL_CHECK" 2>&1)" && RAIL_OK_EC=0 || RAIL_OK_EC=$?
if [[ "$RAIL_OK_EC" -eq 0 ]]; then
  echo "PASS rail-interface-check exits 0 on unmodified repo file"
else
  echo "FAIL rail-interface-check should exit 0 on repo file (ec=$RAIL_OK_EC)" >&2
  echo "$RAIL_OK_OUT" >&2
  fail=1
fi

cleanup_rail_fixtures
trap - EXIT

# --- funding-watch.sh: external funder (chainbank-wallet-reconciler) liveness ---------
FW_CHECK="$SCRIPT_DIR/funding-watch.sh"
FW_FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-funding-watch.XXXXXX")"
cleanup_fw_fixtures() { rm -rf "$FW_FIXTURE_DIR"; }
trap cleanup_fw_fixtures EXIT
FW_NOW="$(date +%s)"

# Below the 0.6 policy for a full day with no top-up => funder presumed dead.
printf '{"ts":%d,"batcher_wei":"500000000000000000","proposer_wei":"500000000000000000","l2_block":1}\n{"ts":%d,"batcher_wei":"400000000000000000","proposer_wei":"500000000000000000","l2_block":2}\n' \
  "$((FW_NOW - 86400))" "$FW_NOW" > "$FW_FIXTURE_DIR/stale.jsonl"
FW_STALE_OUT="$(GAS_RUNWAY_SAMPLES_FILE="$FW_FIXTURE_DIR/stale.jsonl" "$FW_CHECK" 2>&1)" && FW_STALE_EC=0 || FW_STALE_EC=$?
if [[ "$FW_STALE_EC" -ne 0 && "$FW_STALE_OUT" == *"FAIL"* && "$FW_STALE_OUT" == *"chainbank-wallet-reconciler"* ]]; then
  echo "PASS funding-watch flags a stalled external funder and names it"
else
  echo "FAIL funding-watch should exit non-zero naming the funder (ec=$FW_STALE_EC)" >&2
  echo "$FW_STALE_OUT" >&2
  fail=1
fi

# Below policy but a top-up landed inside the tolerance window => funder alive, WARN only.
printf '{"ts":%d,"batcher_wei":"400000000000000000","proposer_wei":"500000000000000000","l2_block":1}\n{"ts":%d,"batcher_wei":"450000000000000000","proposer_wei":"500000000000000000","l2_block":2}\n' \
  "$((FW_NOW - 90000))" "$((FW_NOW - 3600))" > "$FW_FIXTURE_DIR/recent.jsonl"
FW_WARN_OUT="$(GAS_RUNWAY_SAMPLES_FILE="$FW_FIXTURE_DIR/recent.jsonl" "$FW_CHECK" 2>&1)" && FW_WARN_EC=0 || FW_WARN_EC=$?
if [[ "$FW_WARN_EC" -eq 0 && "$FW_WARN_OUT" == *"WARN"* ]]; then
  echo "PASS funding-watch stays non-fatal when a top-up is inside the tolerance window"
else
  echo "FAIL funding-watch should WARN + exit 0 after a recent top-up (ec=$FW_WARN_EC)" >&2
  echo "$FW_WARN_OUT" >&2
  fail=1
fi

# Above policy => OK, and --json writes a parseable verdict document.
printf '{"ts":%d,"batcher_wei":"700000000000000000","proposer_wei":"500000000000000000","l2_block":1}\n' \
  "$FW_NOW" > "$FW_FIXTURE_DIR/ok.jsonl"
FW_OK_OUT="$(GAS_RUNWAY_SAMPLES_FILE="$FW_FIXTURE_DIR/ok.jsonl" "$FW_CHECK" --json "$FW_FIXTURE_DIR/out.json" 2>&1)" && FW_OK_EC=0 || FW_OK_EC=$?
if [[ "$FW_OK_EC" -eq 0 && "$FW_OK_OUT" == *"OK"* ]] \
   && python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d['verdict']=='OK' else 1)" "$FW_FIXTURE_DIR/out.json"; then
  echo "PASS funding-watch reports OK above policy and writes valid --json"
else
  echo "FAIL funding-watch OK/--json path broken (ec=$FW_OK_EC)" >&2
  echo "$FW_OK_OUT" >&2
  fail=1
fi

# Missing samples file must never be fatal (fresh clone, first run).
FW_NONE_OUT="$(GAS_RUNWAY_SAMPLES_FILE="$FW_FIXTURE_DIR/absent.jsonl" "$FW_CHECK" 2>&1)" && FW_NONE_EC=0 || FW_NONE_EC=$?
if [[ "$FW_NONE_EC" -eq 0 && "$FW_NONE_OUT" == *"INSUFFICIENT"* ]]; then
  echo "PASS funding-watch is non-fatal with no samples file"
else
  echo "FAIL funding-watch should exit 0 INSUFFICIENT with no samples (ec=$FW_NONE_EC)" >&2
  echo "$FW_NONE_OUT" >&2
  fail=1
fi

# A funder that declares itself broken outranks a healthy-looking local balance:
# the wallet sits above policy for hours after the job dies.
printf '{"ts":%d,"batcher_wei":"700000000000000000","proposer_wei":"500000000000000000","l2_block":1}\n' \
  "$FW_NOW" > "$FW_FIXTURE_DIR/rich.jsonl"
echo '{"status":"failing","lastRun":{"finishedAt":"2026-08-01T00:00:00Z"}}' > "$FW_FIXTURE_DIR/ep-failing.json"
FW_EP_OUT="$(GAS_RUNWAY_SAMPLES_FILE="$FW_FIXTURE_DIR/rich.jsonl" FUNDING_HEALTH_JSON="$FW_FIXTURE_DIR/ep-failing.json" "$FW_CHECK" 2>&1)" && FW_EP_EC=0 || FW_EP_EC=$?
if [[ "$FW_EP_EC" -ne 0 && "$FW_EP_OUT" == *"status=failing"* ]]; then
  echo "PASS funding-watch fails on funder endpoint status=failing despite healthy balance"
else
  echo "FAIL funding-watch should fail when the endpoint reports failing (ec=$FW_EP_EC)" >&2
  echo "$FW_EP_OUT" >&2
  fail=1
fi

# An unreachable/erroring endpoint must degrade to local inference, never invent a failure.
echo 'this is not json' > "$FW_FIXTURE_DIR/ep-garbage.json"
FW_EPBAD_OUT="$(GAS_RUNWAY_SAMPLES_FILE="$FW_FIXTURE_DIR/rich.jsonl" FUNDING_HEALTH_JSON="$FW_FIXTURE_DIR/ep-garbage.json" "$FW_CHECK" 2>&1)" && FW_EPBAD_EC=0 || FW_EPBAD_EC=$?
if [[ "$FW_EPBAD_EC" -eq 0 && "$FW_EPBAD_OUT" == *"UNPARSEABLE"* && "$FW_EPBAD_OUT" == *"OK"* ]]; then
  echo "PASS funding-watch falls back to local samples when the endpoint is unusable"
else
  echo "FAIL funding-watch should fall back on an unusable endpoint (ec=$FW_EPBAD_EC)" >&2
  echo "$FW_EPBAD_OUT" >&2
  fail=1
fi

# The funder's rollup labels are known to under-report severity (ChainBank confirmed two
# Bugbot findings: blocked/failed reported as below_policy; a new wallet reading degraded
# instead of failing). These two cases pin that we derive from facts, not labels.
FW_ADDR="0x3D54FD6353cd66D143fb94D178c9eEB1aE98a31d"
FW_OLD_RUN="$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=30)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
FW_NEW_RUN="$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"

printf '{"status":"ok","lastRun":{"finishedAt":"%s"},"wallets":[{"address":"%s","status":"ok"}]}\n' \
  "$FW_OLD_RUN" "$FW_ADDR" > "$FW_FIXTURE_DIR/ep-stalerun.json"
FW_SR_OUT="$(FUNDING_WATCH_ADDRESS="$FW_ADDR" GAS_RUNWAY_SAMPLES_FILE="$FW_FIXTURE_DIR/rich.jsonl" FUNDING_HEALTH_JSON="$FW_FIXTURE_DIR/ep-stalerun.json" "$FW_CHECK" 2>&1)" && FW_SR_EC=0 || FW_SR_EC=$?
if [[ "$FW_SR_EC" -ne 0 && "$FW_SR_OUT" == *"last finished run"* ]]; then
  echo "PASS funding-watch fails on a stale last-run timestamp even when the label says ok"
else
  echo "FAIL funding-watch must not trust an ok label over a stale run (ec=$FW_SR_EC)" >&2
  echo "$FW_SR_OUT" >&2
  fail=1
fi

printf '{"status":"degraded","lastRun":{"finishedAt":"%s"},"wallets":[{"address":"%s","status":"blocked"}]}\n' \
  "$FW_NEW_RUN" "$FW_ADDR" > "$FW_FIXTURE_DIR/ep-blocked.json"
FW_BL_OUT="$(FUNDING_WATCH_ADDRESS="$FW_ADDR" GAS_RUNWAY_SAMPLES_FILE="$FW_FIXTURE_DIR/rich.jsonl" FUNDING_HEALTH_JSON="$FW_FIXTURE_DIR/ep-blocked.json" "$FW_CHECK" 2>&1)" && FW_BL_EC=0 || FW_BL_EC=$?
if [[ "$FW_BL_EC" -ne 0 && "$FW_BL_OUT" == *"blocked"* ]]; then
  echo "PASS funding-watch fails when our own wallet entry is blocked, whatever the rollup says"
else
  echo "FAIL funding-watch must escalate a blocked wallet entry (ec=$FW_BL_EC)" >&2
  echo "$FW_BL_OUT" >&2
  fail=1
fi

printf '{"status":"ok","lastRun":{"finishedAt":"%s"},"wallets":[{"address":"0xdead","status":"ok"}]}\n' \
  "$FW_NEW_RUN" > "$FW_FIXTURE_DIR/ep-absent.json"
FW_AB_OUT="$(FUNDING_WATCH_ADDRESS="$FW_ADDR" GAS_RUNWAY_SAMPLES_FILE="$FW_FIXTURE_DIR/rich.jsonl" FUNDING_HEALTH_JSON="$FW_FIXTURE_DIR/ep-absent.json" "$FW_CHECK" 2>&1)" && FW_AB_EC=0 || FW_AB_EC=$?
if [[ "$FW_AB_EC" -eq 0 && "$FW_AB_OUT" == *"absent from the funder"* ]]; then
  echo "PASS funding-watch warns (without inventing failure) when our address is not listed"
else
  echo "FAIL funding-watch should warn but not fail on an absent address (ec=$FW_AB_EC)" >&2
  echo "$FW_AB_OUT" >&2
  fail=1
fi

# `not_reconciled` (CB-03) means a policy-holding wallet is excluded from the reconciler.
# Harmless for ChainBank's own wallets; for ours it means auto-funding is switched off.
printf '{"ts":%d,"batcher_wei":"400000000000000000","proposer_wei":"500000000000000000","l2_block":1}\n' \
  "$FW_NOW" > "$FW_FIXTURE_DIR/poor.jsonl"
printf '{"status":"ok","lastRun":{"finishedAt":"%s"},"wallets":[{"address":"%s","status":"not_reconciled"}]}\n' \
  "$FW_NEW_RUN" "$FW_ADDR" > "$FW_FIXTURE_DIR/ep-notrec.json"

FW_NR1_OUT="$(FUNDING_WATCH_ADDRESS="$FW_ADDR" GAS_RUNWAY_SAMPLES_FILE="$FW_FIXTURE_DIR/rich.jsonl" FUNDING_HEALTH_JSON="$FW_FIXTURE_DIR/ep-notrec.json" "$FW_CHECK" 2>&1)" && FW_NR1_EC=0 || FW_NR1_EC=$?
if [[ "$FW_NR1_EC" -eq 0 && "$FW_NR1_OUT" == *"not_reconciled"* && "$FW_NR1_OUT" == *"WARNING"* ]]; then
  echo "PASS funding-watch warns when our own wallet is excluded from the reconciler"
else
  echo "FAIL funding-watch should warn on our wallet not_reconciled (ec=$FW_NR1_EC)" >&2
  echo "$FW_NR1_OUT" >&2
  fail=1
fi

FW_NR2_OUT="$(FUNDING_WATCH_ADDRESS="$FW_ADDR" GAS_RUNWAY_SAMPLES_FILE="$FW_FIXTURE_DIR/poor.jsonl" FUNDING_HEALTH_JSON="$FW_FIXTURE_DIR/ep-notrec.json" "$FW_CHECK" 2>&1)" && FW_NR2_EC=0 || FW_NR2_EC=$?
if [[ "$FW_NR2_EC" -ne 0 && "$FW_NR2_OUT" == *"draining with no automation"* ]]; then
  echo "PASS funding-watch fails when our wallet is excluded AND below policy"
else
  echo "FAIL funding-watch should fail on not_reconciled + below policy (ec=$FW_NR2_EC)" >&2
  echo "$FW_NR2_OUT" >&2
  fail=1
fi

printf '{"status":"ok","lastRun":{"finishedAt":"%s"},"wallets":[{"address":"0xFfa06ef7c43a66BC1203C5f154371Ac21B8f969f","status":"not_reconciled"},{"address":"%s","status":"ok"}]}\n' \
  "$FW_NEW_RUN" "$FW_ADDR" > "$FW_FIXTURE_DIR/ep-othernr.json"
FW_NR3_OUT="$(FUNDING_WATCH_ADDRESS="$FW_ADDR" GAS_RUNWAY_SAMPLES_FILE="$FW_FIXTURE_DIR/rich.jsonl" FUNDING_HEALTH_JSON="$FW_FIXTURE_DIR/ep-othernr.json" "$FW_CHECK" 2>&1)" && FW_NR3_EC=0 || FW_NR3_EC=$?
if [[ "$FW_NR3_EC" -eq 0 && "$FW_NR3_OUT" != *"WARNING"* ]]; then
  echo "PASS funding-watch ignores not_reconciled on wallets that are not ours"
else
  echo "FAIL another wallet's not_reconciled must not affect us (ec=$FW_NR3_EC)" >&2
  echo "$FW_NR3_OUT" >&2
  fail=1
fi

cleanup_fw_fixtures
trap - EXIT

# --- T5-D1: write-facing JSON-RPC method filter (eth/net/web3 allowlist) ---
FILTER_PY="$SCRIPT_DIR/rpc-method-filter.py"
FILTER_START="$SCRIPT_DIR/07-start-rpc-filter-sepolia.sh"

# Wiring: start/stop/status + env example mention the filter port; lib.sh untouched.
if [[ -f "$FILTER_PY" && -x "$FILTER_START" ]] \
  && grep -q '07-start-rpc-filter-sepolia' "$SCRIPT_DIR/start-all-sepolia.sh" \
  && grep -q 'l2-rpc-filter' "$SCRIPT_DIR/stop-all-sepolia.sh" \
  && grep -q 'l2-rpc-filter' "$SCRIPT_DIR/status.sh" \
  && grep -q 'L2_WRITE_RPC_PORT' "$FORTEL2_ROOT/.env.sepolia.example" \
  && ! grep -q 'L2_WRITE_RPC_PORT' "$SCRIPT_DIR/lib.sh"; then
  echo "PASS T5-D1 filter wired (start/stop/status/env; lib.sh untouched)"
else
  echo "FAIL T5-D1 filter must be wired without editing lib.sh" >&2
  fail=1
fi

# Filter must hard-require loopback listen + upstream (fail closed off-box).
if grep -q 'require_loopback_listen' "$FILTER_PY" \
  && grep -q 'require_loopback_upstream' "$FILTER_PY" \
  && grep -q 'ALLOWED_METHODS' "$FILTER_PY"; then
  echo "PASS T5-D1 filter requires loopback listen/upstream + explicit allowlist"
else
  echo "FAIL T5-D1 filter must bind/upstream loopback and use ALLOWED_METHODS" >&2
  fail=1
fi

# Property tests (prefix trap, batch, chunked, empty-batch, mixed-batch 503, loopback).
FILTER_PROP_OUT="$(python3 "$FILTER_PY" --self-test 2>&1)" && FILTER_PROP_EC=0 || FILTER_PROP_EC=$?
if [[ "$FILTER_PROP_EC" -eq 0 && "$FILTER_PROP_OUT" == *"self-test ok"* ]]; then
  echo "PASS T5-D1 allowlist properties (prefix/batch/chunked/empty/503/loopback)"
else
  echo "FAIL T5-D1 allowlist property tests (ec=$FILTER_PROP_EC)" >&2
  echo "$FILTER_PROP_OUT" >&2
  fail=1
fi

# Start script must force 127.0.0.1 listen (not remodel op-geth --http.api).
if grep -q 'L2_RPC_FILTER_LISTEN="127.0.0.1:' "$FILTER_START" \
  && ! grep -q '\-\-http.api=eth,net,web3$' "$SCRIPT_DIR/04-start-sequencer-sepolia.sh" \
  && grep -q 'eth,net,web3,debug,txpool,admin,miner' "$SCRIPT_DIR/04-start-sequencer-sepolia.sh"; then
  echo "PASS T5-D1 keeps full op-geth :9545; filter listens on 127.0.0.1"
else
  echo "FAIL T5-D1 must not narrow op-geth --http.api; filter must bind 127.0.0.1" >&2
  fail=1
fi

# start-all must preflight L2_WRITE_RPC_PORT (free + distinct) before the ERR trap
# and before starting the sequencer — lib.sh assert_l2_ports_free does not cover it.
if awk '
    /trap sepolia_start_cleanup ERR/ { exit (write_check && collide_check) ? 0 : 1 }
    /lsof.*WRITE_PORT|lsof.*L2_WRITE_RPC_PORT/ { write_check = 1 }
    /L2_WRITE_RPC_PORT.*collides|collides with an L2 stack port/ { collide_check = 1 }
  ' "$SCRIPT_DIR/start-all-sepolia.sh" \
  && awk '
    /04-start-sequencer-sepolia/ { exit write_check ? 0 : 1 }
    /lsof.*WRITE_PORT|lsof.*L2_WRITE_RPC_PORT/ { write_check = 1 }
  ' "$SCRIPT_DIR/start-all-sepolia.sh"; then
  echo "PASS T5-D1 start-all preflights WRITE_PORT before trap/sequencer"
else
  echo "FAIL T5-D1 start-all must preflight WRITE_PORT before ERR trap and sequencer" >&2
  fail=1
fi

# --- T5 step 3 / D-0034: cloudflared dials the write filter (:9555) only ---
CF_HELPER="$SCRIPT_DIR/08-run-cloudflared-write.sh"
CF_TEMPLATE="$FORTEL2_ROOT/config/cloudflared-write.yml.example"
CF_CHECK="$SCRIPT_DIR/check-launchd.sh"

# Template origin is the write filter; helper exists; start-all does not own the tunnel.
if [[ -x "$CF_HELPER" && -f "$CF_TEMPLATE" ]] \
  && grep -q 'service: http://127.0.0.1:9555' "$CF_TEMPLATE" \
  && ! grep -E '^[[:space:]]*(-[[:space:]]+)?service:.*:(9545|9546|9547|9551)' "$CF_TEMPLATE" \
  && ! grep -q '08-run-cloudflared-write' "$SCRIPT_DIR/start-all-sepolia.sh" \
  && ! grep -q '08-run-cloudflared-write' "$SCRIPT_DIR/stop-all-sepolia.sh" \
  && grep -q 'config/cloudflared-write.yml' "$FORTEL2_ROOT/.gitignore"; then
  echo "PASS D-0034 cloudflared template/helper independent of start-all; origin :9555"
else
  echo "FAIL D-0034 must commit :9555 template + helper; not wired into start/stop-all" >&2
  fail=1
fi

# --check-config accepts the committed template origin.
if CF_OK="$("$CF_HELPER" --check-config "$CF_TEMPLATE" 2>&1)" && [[ "$CF_OK" == *"OK origin http://127.0.0.1:9555"* ]]; then
  echo "PASS D-0034 --check-config accepts template origin :9555"
else
  echo "FAIL D-0034 --check-config must accept config/cloudflared-write.yml.example" >&2
  echo "${CF_OK:-}" >&2
  fail=1
fi

# --check-config accepts a dashed-only write-filter origin (list-item form).
CF_DASH="$(mktemp "${TMPDIR:-/tmp}/cf-write-dash.XXXXXX.yml")"
printf 'ingress:\n  - service: http://127.0.0.1:9555\n  - service: http_status:404\n' > "$CF_DASH"
if CF_DASH_OK="$("$CF_HELPER" --check-config "$CF_DASH" 2>&1)" && [[ "$CF_DASH_OK" == *"OK origin http://127.0.0.1:9555"* ]]; then
  echo "PASS D-0034 --check-config accepts dashed service origin :9555"
else
  echo "FAIL D-0034 --check-config must accept list-item - service: :9555" >&2
  echo "${CF_DASH_OK:-}" >&2
  fail=1
fi
rm -f "$CF_DASH"

# --check-config refuses the full EL port (the trap).
CF_BAD="$(mktemp "${TMPDIR:-/tmp}/cf-write-bad.XXXXXX.yml")"
printf 'ingress:\n  - service: http://127.0.0.1:9545\n  - service: http_status:404\n' > "$CF_BAD"
if "$CF_HELPER" --check-config "$CF_BAD" >/dev/null 2>&1; then
  echo "FAIL D-0034 --check-config must reject origin :9545" >&2
  fail=1
else
  echo "PASS D-0034 --check-config rejects origin :9545"
fi
rm -f "$CF_BAD"

# Hostname :9555 plus a dashed catch-all to the full EL must fail closed.
CF_MIXED="$(mktemp "${TMPDIR:-/tmp}/cf-write-mixed.XXXXXX.yml")"
printf 'ingress:\n  - hostname: example.example.com\n    service: http://127.0.0.1:9555\n  - service: http://127.0.0.1:9545\n' > "$CF_MIXED"
if "$CF_HELPER" --check-config "$CF_MIXED" >/dev/null 2>&1; then
  echo "FAIL D-0034 --check-config must reject dashed catch-all origin :9545" >&2
  fail=1
else
  echo "PASS D-0034 --check-config rejects dashed catch-all origin :9545"
fi
rm -f "$CF_MIXED"

# --check-config refuses op-node admin RPC.
CF_NODE="$(mktemp "${TMPDIR:-/tmp}/cf-write-node.XXXXXX.yml")"
printf 'ingress:\n  - service: http://127.0.0.1:9547\n  - service: http_status:404\n' > "$CF_NODE"
if "$CF_HELPER" --check-config "$CF_NODE" >/dev/null 2>&1; then
  echo "FAIL D-0034 --check-config must reject origin :9547" >&2
  fail=1
else
  echo "PASS D-0034 --check-config rejects origin :9547"
fi
rm -f "$CF_NODE"

# L2_WRITE_RPC_PORT=9545 is refused even if the yaml matches that port.
CF_FAKE="$(mktemp "${TMPDIR:-/tmp}/cf-write-fake.XXXXXX.yml")"
printf 'ingress:\n  - service: http://127.0.0.1:9545\n  - service: http_status:404\n' > "$CF_FAKE"
if L2_WRITE_RPC_PORT=9545 "$CF_HELPER" --check-config "$CF_FAKE" >/dev/null 2>&1; then
  echo "FAIL D-0034 must refuse L2_WRITE_RPC_PORT=9545" >&2
  fail=1
else
  echo "PASS D-0034 refuses L2_WRITE_RPC_PORT=9545"
fi
rm -f "$CF_FAKE"

# --- LD-01: launchd drift check tiered severity + cloudflared plist removed ---
LD_CHECK="$SCRIPT_DIR/check-launchd.sh"
if [[ ! -f "$LAUNCHD_DIR/com.steve.fortel2-cloudflared.plist" ]] \
  && grep -q '<integer>0</integer>' "$LAUNCHD_DIR/com.steve.fortel2-health.plist" \
  && grep -q 'is_contract_schedule' "$LD_CHECK" \
  && grep -q 'fortel2-sleep|fortel2-wake' "$LD_CHECK" \
  && ! grep -q 'check_keepalive_agent' "$LD_CHECK" \
  && grep -q 'launchctl print' "$LD_CHECK"; then
  echo "PASS LD-01 check-launchd tiered severity; no cloudflared LaunchAgent plist"
else
  echo "FAIL LD-01 check-launchd must tier sleep/wake FAIL vs other WARN; drop cloudflared plist" >&2
  fail=1
fi

# rail-interface: public *read* URLs are published (D-0045); write hostname stays unpublished
# (D-0034 / D-0035). Checks URL-carrying *fields* plus a raw-file ban on the Access write
# host. Resolve from SCRIPT_DIR, not FORTEL2_ROOT: earlier cases reassign FORTEL2_ROOT to
# mktemp fixture dirs (lines ~233, ~268) and bare assignments persist, so by here it no
# longer points at the repo. Neighbouring late tests (LD_CHECK, CF_HELPER) use SCRIPT_DIR
# for the same reason.
RAIL_JSON="$SCRIPT_DIR/../deployments/rail-interface.json"
if python3 - "$RAIL_JSON" <<'PY'
import json, sys
path = sys.argv[1]
d = json.load(open(path))
bad = []
replica_pub = "https://fortel2-replica-rpc.onrender.com"
seq_pub = "https://fortel2-sequencer-rpc.onrender.com"
for nid, n in (d.get("networks") or {}).items():
    if n.get("l2ChainId") == 852 and n.get("l2RpcUrl") != "http://127.0.0.1:9545":
        bad.append("%s.l2RpcUrl not loopback: %r" % (nid, n.get("l2RpcUrl")))
    if n.get("writeRpcUrl"):
        bad.append("%s.writeRpcUrl is published: %r" % (nid, n["writeRpcUrl"]))
    if n.get("l2ChainId") != 852:
        continue
    rep = n.get("replica") or {}
    if rep.get("readRpcUrl") != replica_pub:
        bad.append("%s.replica.readRpcUrl want %r got %r" % (nid, replica_pub, rep.get("readRpcUrl")))
    if rep.get("writeRpcUrl"):
        bad.append("%s.replica.writeRpcUrl is published: %r" % (nid, rep["writeRpcUrl"]))
    sr = n.get("sequencerReads") or {}
    if sr.get("readRpcUrl") != seq_pub:
        bad.append("%s.sequencerReads.readRpcUrl want %r got %r" % (nid, seq_pub, sr.get("readRpcUrl")))
    if sr.get("writeRpcUrl"):
        bad.append("%s.sequencerReads.writeRpcUrl is published: %r" % (nid, sr["writeRpcUrl"]))
    if replica_pub == seq_pub:
        bad.append("replica and sequencer-tip public URLs must differ")
raw = open(path).read()
for host in ("ente.ltd", "trycloudflare.com"):
    if host in raw:
        bad.append("write hostname %r appears in the file" % host)
if bad:
    print("; ".join(bad))
    sys.exit(1)
PY
then
  echo "PASS D-0045 rail-interface public reads published; write hostname unpublished"
else
  echo "FAIL D-0045 must publish replica+sequencer-tip reads and keep the write hostname out" >&2
  fail=1
fi

# P7-0-A: Sepolia stock batcher defaults to span (--batch-type 1). Flag is a
# UintFlag on the pinned op-batcher (0=singular, 1=span); the script maps
# span/singular as well. Revert is BATCHER_BATCH_TYPE=singular. Do not change
# channel duration / compression / DA type here.
# Stock else-branch must stop_bg before start_bg — start_bg no-ops when the
# pid is alive, so a batch-type switch would otherwise report success on the
# old process. The custom branch already stops; this asserts the stock path too.
if grep -q 'BATCHER_BATCH_TYPE:-span' "$SCRIPT_DIR/05-start-batcher-sepolia.sh" \
  && grep -q -- '--batch-type="${BATCHER_BATCH_TYPE_FLAG}"' "$SCRIPT_DIR/05-start-batcher-sepolia.sh" \
  && grep -q 'BATCHER_BATCH_TYPE=span' "$FORTEL2_ROOT/.env.sepolia.example" \
  && grep -q 'BATCHER_BATCH_TYPE=singular' "$SCRIPT_DIR/05-start-batcher-sepolia.sh" \
  && grep -q 'SEPOLIA_BATCHER_MAX_CHANNEL_DURATION:-30' "$SCRIPT_DIR/05-start-batcher-sepolia.sh" \
  && grep -q -- '--sub-safety-margin=2' "$SCRIPT_DIR/05-start-batcher-sepolia.sh" \
  && grep -q 'BATCHER_DA_TYPE:-calldata' "$SCRIPT_DIR/05-start-batcher-sepolia.sh" \
  && awk '
       /^else$/ { in_else=1 }
       in_else && /stop_bg op-batcher/ { if (!found_start) stopped=1 }
       in_else && /start_bg op-batcher/ { found_start=1 }
       END { exit !(in_else && stopped && found_start) }
     ' "$SCRIPT_DIR/05-start-batcher-sepolia.sh"; then
  echo "PASS Sepolia stock batcher defaults BATCHER_BATCH_TYPE=span (--batch-type 1)"
else
  echo "FAIL 05-start-batcher-sepolia.sh must default span batches without touching cadence/DA" >&2
  fail=1
fi

# F7-2c / D-0054: cannon / cannon-kona fail closed without a pre-image server.
# start_bg returns 0 whether the daemon survives, so CheckRequired flags must
# be refused before wait_for_rpc. Assert properties, not error phrasing.
# Resolve the example env from SCRIPT_DIR: FORTEL2_ROOT is reassigned to
# fixture dirs earlier in this file (same reason as the D-0045 rail check).
CHALLENGER_START="$SCRIPT_DIR/09-start-challenger-sepolia.sh"
CHALLENGER_ENV="$SCRIPT_DIR/../.env.sepolia.example"
if [[ -f "$CHALLENGER_START" ]] \
  && awk '
       /CHALLENGER_CANNON_SERVER/ { if (!cannon_var) cannon_var = NR }
       /CHALLENGER_KONA_SERVER/ { if (!kona_var) kona_var = NR }
       /--cannon-server/ && !/--cannon-server=/ { if (!cannon_flag) cannon_flag = NR }
       /--cannon-kona-server/ && !/--cannon-kona-server=/ { if (!kona_flag) kona_flag = NR }
       /wait_for_rpc/ { if (!first_wait) first_wait = NR }
       END {
         exit !(cannon_var && kona_var && cannon_flag && kona_flag && first_wait \
           && cannon_var < first_wait && kona_var < first_wait \
           && cannon_flag < first_wait && kona_flag < first_wait)
       }
     ' "$CHALLENGER_START" \
  && awk '
       /challenger_args=\(/ { building = 1 }
       building && /needs_cannon_server/ { cguard = 1 }
       building && cguard && /--cannon-server=/ { carg = 1 }
       building && /needs_kona_server/ { kguard = 1 }
       building && kguard && /--cannon-kona-server=/ { karg = 1 }
       END { exit !(carg && karg) }
     ' "$CHALLENGER_START" \
  && awk '
       /-x/ && /CANNON_SERVER/ { cannon_x = 1 }
       /-x/ && /KONA_SERVER/ { kona_x = 1 }
       END { exit !(cannon_x && kona_x) }
     ' "$CHALLENGER_START" \
  && grep -qE '^# CHALLENGER_CANNON_SERVER=$' "$CHALLENGER_ENV" \
  && grep -qE '^# CHALLENGER_KONA_SERVER=$' "$CHALLENGER_ENV" \
  && ! grep -qE '^CHALLENGER_CANNON_SERVER=' "$CHALLENGER_ENV" \
  && ! grep -qE '^CHALLENGER_KONA_SERVER=' "$CHALLENGER_ENV"; then
  echo "PASS F7-2c cannon/cannon-kona fail closed without pre-image server (D-0054)"
else
  echo "FAIL 09-start-challenger-sepolia.sh must refuse cannon/cannon-kona without an executable server, before wait_for_rpc" >&2
  fail=1
fi

if (( fail )); then
  echo "script helper tests FAILED" >&2
  exit 1
fi
echo "All script helper tests passed."
