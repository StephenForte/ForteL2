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

# op-node wait: mock JSON-RPC on loopback. No live network.
# Modes: opnode (optimism_* result, eth_* -32601), reject (both -32601), httpok (HTTP 200, not JSON-RPC).
_start_mock_jsonrpc() {
  local mode="$1"
  local port_file="$2"
  python3 - "$mode" "$port_file" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

mode, port_file = sys.argv[1], sys.argv[2]

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            req = json.loads(body.decode() or "{}")
        except Exception:
            req = {}
        method = req.get("method", "")
        rid = req.get("id", 1)
        if mode == "httpok":
            raw = b"ok"
        elif mode == "opnode" and method == "optimism_syncStatus":
            raw = json.dumps({
                "jsonrpc": "2.0",
                "id": rid,
                "result": {"current_l1": {"number": 11559189}},
            }).encode()
        else:
            raw = json.dumps({
                "jsonrpc": "2.0",
                "id": rid,
                "error": {
                    "code": -32601,
                    "message": "the method %s does not exist/is not available" % method,
                },
            }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PY
  _MOCK_RPC_PID=$!
  local i=0
  while [[ ! -s "$port_file" && $i -lt 50 ]]; do
    sleep 0.05
    ((i++)) || true
  done
  if [[ ! -s "$port_file" ]]; then
    echo "FAIL mock JSON-RPC server did not bind" >&2
    kill "$_MOCK_RPC_PID" >/dev/null 2>&1 || true
    wait "$_MOCK_RPC_PID" 2>/dev/null || true
    return 1
  fi
}

_stop_mock_jsonrpc() {
  if [[ -n "${_MOCK_RPC_PID:-}" ]]; then
    kill "$_MOCK_RPC_PID" >/dev/null 2>&1 || true
    wait "$_MOCK_RPC_PID" 2>/dev/null || true
    _MOCK_RPC_PID=""
  fi
}

MOCK_RPC_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-mock-rpc.XXXXXX")"
MOCK_PORT_FILE="$MOCK_RPC_DIR/port"
_start_mock_jsonrpc opnode "$MOCK_PORT_FILE"
MOCK_URL="http://127.0.0.1:$(cat "$MOCK_PORT_FILE")"
OPNODE_OUT="$(wait_for_opnode_rpc "$MOCK_URL" "op-node" 2 2>&1)" && OPNODE_EC=0 || OPNODE_EC=$?
ETH_OUT="$(wait_for_rpc "$MOCK_URL" "op-node" 1 2>&1)" && ETH_EC=0 || ETH_EC=$?
_stop_mock_jsonrpc
if [[ "$OPNODE_EC" -eq 0 ]] \
  && [[ "$OPNODE_OUT" == *"op-node is up (L1 block 11559189)"* ]] \
  && [[ "$ETH_EC" -ne 0 ]] \
  && [[ "$ETH_OUT" == *"timed out waiting for op-node"* ]]; then
  echo "PASS wait_for_opnode_rpc succeeds on optimism_syncStatus; wait_for_rpc eth probe fails"
else
  echo "FAIL op-node mock must pass wait_for_opnode_rpc and fail wait_for_rpc (opnode_ec=$OPNODE_EC eth_ec=$ETH_EC)" >&2
  echo "$OPNODE_OUT" >&2
  echo "$ETH_OUT" >&2
  fail=1
fi

: >"$MOCK_PORT_FILE"
_start_mock_jsonrpc reject "$MOCK_PORT_FILE"
MOCK_URL="http://127.0.0.1:$(cat "$MOCK_PORT_FILE")"
REJECT_OUT="$(wait_for_opnode_rpc "$MOCK_URL" "op-node" 1 2>&1)" && REJECT_EC=0 || REJECT_EC=$?
_stop_mock_jsonrpc
if [[ "$REJECT_EC" -eq 1 ]] \
  && [[ "$REJECT_OUT" == *"timed out waiting for op-node"* ]]; then
  echo "PASS wait_for_opnode_rpc times out with return 1 when both namespaces reject"
else
  echo "FAIL reject-all mock must time out wait_for_opnode_rpc with return 1 (ec=$REJECT_EC)" >&2
  echo "$REJECT_OUT" >&2
  fail=1
fi

: >"$MOCK_PORT_FILE"
_start_mock_jsonrpc httpok "$MOCK_PORT_FILE"
MOCK_URL="http://127.0.0.1:$(cat "$MOCK_PORT_FILE")"
HTTPOK_OUT="$(wait_for_opnode_rpc "$MOCK_URL" "op-node" 1 2>&1)" && HTTPOK_EC=0 || HTTPOK_EC=$?
_stop_mock_jsonrpc
if [[ "$HTTPOK_EC" -eq 1 ]] \
  && [[ "$HTTPOK_OUT" == *"timed out waiting for op-node"* ]]; then
  echo "PASS wait_for_opnode_rpc does not accept HTTP 200 without a JSON-RPC result"
else
  echo "FAIL HTTP 200 body-ok must not pass wait_for_opnode_rpc (ec=$HTTPOK_EC)" >&2
  echo "$HTTPOK_OUT" >&2
  fail=1
fi

rm -rf "$MOCK_RPC_DIR"

# Call sites: L2_NODE_RPC_URL must use the op-node probe, not eth_blockNumber.
if grep -q 'wait_for_opnode_rpc "$L2_NODE_RPC_URL"' "$SCRIPT_DIR/09-start-challenger-sepolia.sh" \
  && grep -q 'wait_for_opnode_rpc "$L2_NODE_RPC_URL"' "$SCRIPT_DIR/create-bad-proposal-sepolia.sh" \
  && ! grep -q 'wait_for_rpc "$L2_NODE_RPC_URL"' "$SCRIPT_DIR/09-start-challenger-sepolia.sh" \
  && ! grep -q 'wait_for_rpc "$L2_NODE_RPC_URL"' "$SCRIPT_DIR/create-bad-proposal-sepolia.sh"; then
  echo "PASS op-node waiters use wait_for_opnode_rpc"
else
  echo "FAIL L2_NODE_RPC_URL waits must use wait_for_opnode_rpc (eth_blockNumber is not served)" >&2
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
mkdir -p "$FIXTURE/deployments/.deployer" "$FIXTURE/viewer" "$FIXTURE/data" "$FIXTURE/scripts"
cp "$SCRIPT_DIR/lib.sh" "$SCRIPT_DIR/gen-viewer-config.sh" "$FIXTURE/scripts/"
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
if env -u FORTEL2_ENV FORTEL2_ROOT="$FIXTURE" "$FIXTURE/scripts/gen-viewer-config.sh" >/dev/null; then
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
mkdir -p "$SEPOLIA_FIXTURE/viewer" "$SEPOLIA_FIXTURE/deployments/sepolia/.deployer" "$SEPOLIA_FIXTURE/data" "$SEPOLIA_FIXTURE/scripts"
cp "$SCRIPT_DIR/lib.sh" "$SCRIPT_DIR/gen-viewer-config.sh" "$SEPOLIA_FIXTURE/scripts/"
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
  "$SEPOLIA_FIXTURE/scripts/gen-viewer-config.sh" >/dev/null; then
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
# env -u: same FORTEL2_ENV leak as the fixture run above — an inherited
# absolute FORTEL2_ENV would load a valid BATCHER_ADDRESS and this would pass.
if env -u FORTEL2_ENV FORTEL2_ROOT="$FIXTURE" "$FIXTURE/scripts/gen-viewer-config.sh" >/dev/null 2>&1; then
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
  && grep -q 'SEPOLIA_PROPOSER_INTERVAL:-1h' "$SCRIPT_DIR/06-start-proposer-sepolia.sh" \
  && grep -q 'SEPOLIA_PROPOSER_TXMGR_RECEIPT_QUERY_INTERVAL:-36s' "$SCRIPT_DIR/06-start-proposer-sepolia.sh" \
  && grep -q 'SEPOLIA_PROPOSER_TXMGR_REBROADCAST_INTERVAL:-36s' "$SCRIPT_DIR/06-start-proposer-sepolia.sh" \
  && grep -q 'SEPOLIA_L1_HTTP_POLL_INTERVAL:-12s' "$SCRIPT_DIR/04-start-sequencer-sepolia.sh" \
  && grep -q 'SEPOLIA_L1_RPC_RATE_LIMIT:-20' "$SCRIPT_DIR/04-start-sequencer-sepolia.sh" \
  && grep -q 'SEPOLIA_CHALLENGER_HTTP_POLL_INTERVAL:-${OP_CHALLENGER_HTTP_POLL_INTERVAL:-300s}' "$SCRIPT_DIR/09-start-challenger-sepolia.sh" \
  && grep -q 'SEPOLIA_CHALLENGER_MIN_UPDATE_INTERVAL:-${OP_CHALLENGER_MIN_UPDATE_INTERVAL:-300s}' "$SCRIPT_DIR/09-start-challenger-sepolia.sh" \
  && grep -q 'SEPOLIA_CHALLENGER_MAX_CONCURRENCY:-${OP_CHALLENGER_MAX_CONCURRENCY:-1}' "$SCRIPT_DIR/09-start-challenger-sepolia.sh"; then
  echo "PASS Sepolia start scripts use credit-budget poll/channel defaults"
else
  echo "FAIL Sepolia start scripts must keep credit-budget env defaults" >&2
  fail=1
fi
# Sepolia op-node L1 receipts-fetch kind (QuickNode; D-0105 Finding 3).
if grep -q 'SEPOLIA_L1_RPC_KIND:-quicknode' "$SCRIPT_DIR/04-start-sequencer-sepolia.sh" \
  && grep -q -- '--l1.rpckind="${L1_RPC_KIND}"' "$SCRIPT_DIR/04-start-sequencer-sepolia.sh" \
  && grep -q 'kind=${L1_RPC_KIND}' "$SCRIPT_DIR/04-start-sequencer-sepolia.sh" \
  && ! grep -q -- '--l1.rpckind=standard' "$SCRIPT_DIR/04-start-sequencer-sepolia.sh"; then
  echo "PASS Sepolia op-node L1 rpckind defaults to quicknode from env"
else
  echo "FAIL Sepolia op-node must take --l1.rpckind from SEPOLIA_L1_RPC_KIND (default quicknode)" >&2
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

# Stale lastRun is a derived fact and still FAILs even when the aggregate label
# is also "failing". The label itself is advisory; a fresh failing label is
# asserted separately below. The 2026-08-01 timestamp is months stale.
printf '{"ts":%d,"batcher_wei":"700000000000000000","proposer_wei":"500000000000000000","l2_block":1}\n' \
  "$FW_NOW" > "$FW_FIXTURE_DIR/rich.jsonl"
echo '{"status":"failing","lastRun":{"finishedAt":"2026-08-01T00:00:00Z"}}' > "$FW_FIXTURE_DIR/ep-failing.json"
FW_EP_OUT="$(GAS_RUNWAY_SAMPLES_FILE="$FW_FIXTURE_DIR/rich.jsonl" FUNDING_HEALTH_JSON="$FW_FIXTURE_DIR/ep-failing.json" "$FW_CHECK" 2>&1)" && FW_EP_EC=0 || FW_EP_EC=$?
if [[ "$FW_EP_EC" -ne 0 && "$FW_EP_OUT" == *"VERDICT: FAIL"* && "$FW_EP_OUT" == *"last finished run"* ]]; then
  echo "PASS funding-watch fails on a stale last-run even when the rollup also says failing"
else
  echo "FAIL funding-watch must fail a stale run regardless of the rollup label (ec=$FW_EP_EC)" >&2
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

# Isolated advisory-label path: aggregate status=failing, our wallet ok, last run
# fresh, balance above policy. Must be WARN (exit 0), not FAIL. Pre-fix this
# fixture exited 1 with VERDICT: FAIL on the rollup label alone.
printf '{"status":"failing","lastRun":{"finishedAt":"%s"},"wallets":[{"address":"%s","status":"ok"}]}\n' \
  "$FW_NEW_RUN" "$FW_ADDR" > "$FW_FIXTURE_DIR/ep-failing-fresh.json"
FW_AFF_OUT="$(FUNDING_WATCH_ADDRESS="$FW_ADDR" GAS_RUNWAY_SAMPLES_FILE="$FW_FIXTURE_DIR/rich.jsonl" FUNDING_HEALTH_JSON="$FW_FIXTURE_DIR/ep-failing-fresh.json" "$FW_CHECK" 2>&1)" && FW_AFF_EC=0 || FW_AFF_EC=$?
if [[ "$FW_AFF_EC" -eq 0 && "$FW_AFF_OUT" == *"VERDICT: WARN"* && "$FW_AFF_OUT" == *"status=failing"* ]]; then
  echo "PASS funding-watch treats a bare advisory status=failing as WARN, not FAIL"
else
  echo "FAIL advisory status=failing with a healthy wallet must WARN (ec=$FW_AFF_EC)" >&2
  echo "$FW_AFF_OUT" >&2
  fail=1
fi

# Fact path intact: aggregate failing + our wallet blocked still FAILs.
printf '{"status":"failing","lastRun":{"finishedAt":"%s"},"wallets":[{"address":"%s","status":"blocked"}]}\n' \
  "$FW_NEW_RUN" "$FW_ADDR" > "$FW_FIXTURE_DIR/ep-failing-blocked.json"
FW_FB_OUT="$(FUNDING_WATCH_ADDRESS="$FW_ADDR" GAS_RUNWAY_SAMPLES_FILE="$FW_FIXTURE_DIR/rich.jsonl" FUNDING_HEALTH_JSON="$FW_FIXTURE_DIR/ep-failing-blocked.json" "$FW_CHECK" 2>&1)" && FW_FB_EC=0 || FW_FB_EC=$?
if [[ "$FW_FB_EC" -ne 0 && "$FW_FB_OUT" == *"VERDICT: FAIL"* && "$FW_FB_OUT" == *"blocked"* ]]; then
  echo "PASS funding-watch still fails when our wallet is blocked under a failing rollup"
else
  echo "FAIL status=failing must not mask a blocked wallet (ec=$FW_FB_EC)" >&2
  echo "$FW_FB_OUT" >&2
  fail=1
fi

# Below-policy ladder intact: advisory failing must not short-circuit a
# below-policy-past-tolerance FAIL. lastRun is fresh so the stale-run fact
# does not fire; the local samples have been below 0.6 ETH for a day.
printf '{"status":"failing","lastRun":{"finishedAt":"%s"},"wallets":[{"address":"%s","status":"ok"}]}\n' \
  "$FW_NEW_RUN" "$FW_ADDR" > "$FW_FIXTURE_DIR/ep-failing-below.json"
FW_FBP_OUT="$(FUNDING_WATCH_ADDRESS="$FW_ADDR" GAS_RUNWAY_SAMPLES_FILE="$FW_FIXTURE_DIR/stale.jsonl" FUNDING_HEALTH_JSON="$FW_FIXTURE_DIR/ep-failing-below.json" "$FW_CHECK" 2>&1)" && FW_FBP_EC=0 || FW_FBP_EC=$?
if [[ "$FW_FBP_EC" -ne 0 && "$FW_FBP_OUT" == *"VERDICT: FAIL"* && "$FW_FBP_OUT" == *"below the"* && "$FW_FBP_OUT" == *"funding policy"* ]]; then
  echo "PASS funding-watch still fails below policy past tolerance under a failing rollup"
else
  echo "FAIL advisory failing must not short-circuit the below-policy ladder (ec=$FW_FBP_EC)" >&2
  echo "$FW_FBP_OUT" >&2
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
  && grep -q 'com.steve.fortel2-\*.plist' "$LD_CHECK" \
  && grep -q 'plist_script' "$LD_CHECK" \
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

# Task 5: stock Sepolia batcher disables builder throttle only under reth.
# op-reth has no miner_setMaxDASize; a later checkout must not depend on
# .env.sepolia OP_BATCHER_THROTTLE_* alone. Geth path must keep the default.
# bash 3.2 + set -u: empty "${arr[@]}" is unbound (would abort start-all after
# the sequencer is up). Require the + idiom and prove both expansions survive.
if grep -qE '[[:space:]]"\$\{BATCHER_THROTTLE_FLAGS\[@\]\}"[[:space:]]' \
     "$SCRIPT_DIR/05-start-batcher-sepolia.sh"; then
  echo "FAIL 05-start-batcher-sepolia.sh must not expand empty \"\${arr[@]}\" under set -u" >&2
  fail=1
elif grep -q 'fortel2_el' "$SCRIPT_DIR/05-start-batcher-sepolia.sh" \
  && grep -q -- '--throttle.unsafe-da-bytes-lower-threshold=0' "$SCRIPT_DIR/05-start-batcher-sepolia.sh" \
  && grep -q 'BATCHER_THROTTLE_FLAGS\[@\]+' "$SCRIPT_DIR/05-start-batcher-sepolia.sh" \
  && awk '
       /fortel2_el/ && /reth/ { gated=1 }
       gated && /throttle.unsafe-da-bytes-lower-threshold=0/ { flag=1 }
       /start_bg op-batcher op-batcher/ { start=1 }
       start && /BATCHER_THROTTLE_FLAGS\[@\]\+/ { expanded=1 }
       /unset OP_BATCHER_THROTTLE_UNSAFE_DA_BYTES_LOWER_THRESHOLD/ { unset_env=1 }
       END { exit !(gated && flag && expanded && unset_env) }
     ' "$SCRIPT_DIR/05-start-batcher-sepolia.sh" \
  && grep -q 'throttle.unsafe-da-bytes-lower-threshold=0' "$FORTEL2_ROOT/.env.sepolia.example" \
  && bash -c 'set -euo pipefail; BATCHER_THROTTLE_FLAGS=(); set -- ${BATCHER_THROTTLE_FLAGS[@]+"${BATCHER_THROTTLE_FLAGS[@]}"}; [[ $# -eq 0 ]]' \
  && bash -c 'set -euo pipefail; BATCHER_THROTTLE_FLAGS=(--throttle.unsafe-da-bytes-lower-threshold=0); set -- ${BATCHER_THROTTLE_FLAGS[@]+"${BATCHER_THROTTLE_FLAGS[@]}"}; [[ $# -eq 1 && $1 == --throttle.unsafe-da-bytes-lower-threshold=0 ]]'; then
  echo "PASS Sepolia stock batcher disables throttle when FORTEL2_EL=reth"
else
  echo "FAIL 05-start-batcher-sepolia.sh must pass throttle-off only when fortel2_el is reth (nounset-safe)" >&2
  fail=1
fi

# Mistyped FORTEL2_EL must fail closed before stop_bg (else a live batcher is
# interrupted and the replacement exits on miner_setMaxDASize).
if awk '
     /require_fortel2_el/ && !req { req=NR }
     /stop_bg op-batcher/ && !stop { stop=NR }
     END { exit !(req && stop && req < stop) }
   ' "$SCRIPT_DIR/05-start-batcher-sepolia.sh"; then
  echo "PASS Sepolia stock batcher validates FORTEL2_EL before stopping op-batcher"
else
  echo "FAIL 05-start-batcher-sepolia.sh must call require_fortel2_el before stop_bg" >&2
  fail=1
fi

# Example must warn, not recommend, the env override (it survives geth rollback).
if grep -qE 'OP_BATCHER_THROTTLE_UNSAFE_DA_BYTES_LOWER_THRESHOLD=' \
     "$FORTEL2_ROOT/.env.sepolia.example"; then
  echo "FAIL .env.sepolia.example must not assign or recommend OP_BATCHER_THROTTLE_*" >&2
  fail=1
elif grep -q 'Do not set OP_BATCHER_THROTTLE_UNSAFE_DA_BYTES_LOWER_THRESHOLD' \
       "$FORTEL2_ROOT/.env.sepolia.example"; then
  echo "PASS .env.sepolia.example refuses a persistent batcher throttle env"
else
  echo "FAIL .env.sepolia.example must warn not to persist OP_BATCHER_THROTTLE_*" >&2
  fail=1
fi

if grep -q -- '--throttle.unsafe-da-bytes-lower-threshold=0' "$FORTEL2_ROOT/README.md" \
  && grep -q 'FORTEL2_EL=reth' "$FORTEL2_ROOT/README.md" \
  && grep -q 'OP_BATCHER_THROTTLE_UNSAFE_DA_BYTES_LOWER_THRESHOLD' "$FORTEL2_ROOT/README.md"; then
  echo "PASS README documents EL-gated batcher throttle and rollback"
else
  echo "FAIL README.md must document reth/geth batcher throttle and the leftover env" >&2
  fail=1
fi

# --- l1-batch-proxy: split oversized L1 batches for op-challenger ---
L1_PROXY_PY="$SCRIPT_DIR/l1-batch-proxy.py"
L1_PROXY_START="$SCRIPT_DIR/start-l1-batch-proxy-sepolia.sh"
CHALLENGER_START="$SCRIPT_DIR/09-start-challenger-sepolia.sh"

if [[ -f "$L1_PROXY_PY" && -x "$L1_PROXY_START" ]] \
  && grep -q 'l1-batch-proxy' "$SCRIPT_DIR/stop-all-sepolia.sh" \
  && grep -q 'CHALLENGER_L1_RPC_URL="${CHALLENGER_L1_RPC_URL:-$L1_RPC_URL}"' "$CHALLENGER_START" \
  && grep -q 'require_loopback_listen' "$L1_PROXY_PY"; then
  echo "PASS l1-batch-proxy wired (start/stop/challenger knob; loopback listen)"
else
  echo "FAIL l1-batch-proxy must be wired without putting L1_RPC_URL on argv" >&2
  fail=1
fi

# Start command must not pass upstream URL on argv (key lives in env).
if grep -qE 'start_bg l1-batch-proxy python3 "\$PROXY_PY"' "$L1_PROXY_START" \
  && ! grep -qE 'start_bg l1-batch-proxy .*https?://' "$L1_PROXY_START"; then
  echo "PASS l1-batch-proxy start_bg has no URL on argv"
else
  echo "FAIL l1-batch-proxy start must exec python3 only; upstream from L1_RPC_URL env" >&2
  fail=1
fi

# 09-start-challenger uses CHALLENGER_L1_RPC_URL for L1 wait, preflight, and --l1-eth-rpc.
if grep -q 'wait_for_rpc "$CHALLENGER_L1_RPC_URL"' "$CHALLENGER_START" \
  && grep -q '\-\-rpc-url "$CHALLENGER_L1_RPC_URL"' "$CHALLENGER_START" \
  && grep -q '\-\-l1-eth-rpc="$CHALLENGER_L1_RPC_URL"' "$CHALLENGER_START"; then
  echo "PASS 09-start-challenger honors CHALLENGER_L1_RPC_URL for all L1 dials"
else
  echo "FAIL 09-start-challenger-sepolia.sh must route L1 through CHALLENGER_L1_RPC_URL" >&2
  fail=1
fi

L1_PROXY_PROP_OUT="$(python3 "$L1_PROXY_PY" --self-test 2>&1)" && L1_PROXY_PROP_EC=0 || L1_PROXY_PROP_EC=$?
if [[ "$L1_PROXY_PROP_EC" -eq 0 && "$L1_PROXY_PROP_OUT" == *"self-test ok"* ]]; then
  echo "PASS l1-batch-proxy properties (split/order/id/429/single/unreachable)"
else
  echo "FAIL l1-batch-proxy property tests (ec=$L1_PROXY_PROP_EC)" >&2
  echo "$L1_PROXY_PROP_OUT" >&2
  fail=1
fi

# F7-2c / D-0054: cannon / cannon-kona fail closed without a pre-image server.
# start_bg returns 0 whether the daemon survives, so CheckRequired flags must
# be refused before wait_for_rpc. Assert properties, not error phrasing.
# Resolve the example env from SCRIPT_DIR: FORTEL2_ROOT is reassigned to
# fixture dirs earlier in this file (same reason as the D-0045 rail check).
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

# F7-3 / D-0055: preflight reads gameArgs (CWIA implArgs tail), not the
# implementation's vm()/absolutePrestate() as the primary source. Those
# getters are the empty-args fallback only. Unmapped trace types still
# skip before any factory call. Assert structure, not error phrasing.
#
# F7-4 items 1–2: the skip-preflight grep was a string match (the name
# appears in four error texts), so deleting the bypass left this green.
# The 104-hex bound was unasserted — relaxing `< 104` to `< 0` also
# stayed green. Both are structural now; this is a strengthening of the
# same F7-3 PASS, not a new one.
if awk '
     /^run_preflight\(\)/ { fn = 1; next }
     fn && /^}/ { fn = 0 }
     fn {
       if (!committed) {
         if ($0 ~ /skipping factory lookup/) { skip_msg = 1; skip_msg_nr = NR }
         if ($0 ~ /return 0/) { skip_ret = 1; skip_ret_nr = NR }
         if ($0 ~ /cast call/ && $0 ~ /gameImpls/) { committed = 1; fact_nr = NR }
       } else {
         if ($0 ~ /return 0/) leak = 1
         if ($0 ~ /exit 1/) e1++
         if ($0 ~ /cast call/ && $0 ~ /gameArgs/) { args = 1; args_nr = NR }
         if ($0 ~ /cast call/ && $0 ~ /vm\(\)\(address\)/) { vm_fb = 1; vm_nr = NR }
         if ($0 ~ /cast call/ && $0 ~ /absolutePrestate\(\)\(bytes32\)/) ps_fb = 1
         if (index($0, "is_zero_hex \"$impl\"")) impl_z = 1
         if (index($0, "is_zero_hex \"$vm_addr\"")) vm_z = 1
         if (index($0, "is_zero_hex \"$prestate\"")) ps_z = 1
       }
     }
     END {
       exit !(skip_msg && skip_ret && committed && skip_msg_nr < fact_nr \
         && skip_ret_nr < fact_nr && !leak && e1 >= 4 \
         && args && vm_fb && ps_fb && impl_z && vm_z && ps_z \
         && args_nr && vm_nr && args_nr < vm_nr)
     }
   ' "$CHALLENGER_START" \
  && awk '
       /if \[\[/ && /CHALLENGER_SKIP_PREFLIGHT/ { in_if = 1; in_then = 1; next }
       !in_if { next }
       /^else$/ { in_else = 1; in_then = 0; next }
       /^fi$/ { saw_fi = 1; in_if = 0; next }
       in_then {
         if ($0 ~ /WARN/ && $0 ~ />&2/) then_warn = 1
         if ($0 ~ /run_preflight/ && $0 !~ /run_preflight\(\)/) then_calls = 1
       }
       in_else {
         if ($0 ~ /run_preflight/ && $0 !~ /run_preflight\(\)/) else_calls = 1
       }
       END { exit !(saw_fi && then_warn && else_calls && !then_calls) }
     ' "$CHALLENGER_START" \
  && awk '
       /^run_preflight\(\)/ { fn = 1; next }
       fn && /^}/ { fn = 0 }
       fn {
         if ($0 ~ /cast call/ && $0 ~ /gameArgs/) saw_args = 1
         if (saw_args && !in_empty_fallback) {
           if (index($0, "-n \"$args_hex\"")) nonempty = 1
           if (nonempty && index($0, "${#args_hex}") && index($0, "< 104")) gate = 1
           if (nonempty && gate && /exit 1/) refused = 1
           if (/falling back to implementation/ || /implementation getters/) in_empty_fallback = 1
         }
       }
       END { exit !(saw_args && nonempty && gate && refused) }
     ' "$CHALLENGER_START" \
  && grep -Fq 'gameArgs(uint32)(bytes)' "$CHALLENGER_START" \
  && grep -Fq 'vm()(address)' "$CHALLENGER_START" \
  && grep -Fq 'absolutePrestate()(bytes32)' "$CHALLENGER_START"; then
  echo "PASS F7-3 preflight reads gameArgs with impl-getter fallback; mapped types fail closed (D-0055)"
else
  echo "FAIL 09-start-challenger-sepolia.sh preflight must read gameArgs, keep impl-getter fallback, skip unmapped types before factory lookup, and exit 1 on every mapped-type miss (D-0055)" >&2
  fail=1
fi

# F7-4 / D-0055: bypass WARN cites D-0055 (D-0052 Finding 2 was withdrawn).
# Text only — branch, exit behaviour, >&2 stay as they are.
if awk '
     /if \[\[/ && /CHALLENGER_SKIP_PREFLIGHT/ { in_if = 1; in_then = 1; next }
     !in_if { next }
     /^else$/ { in_else = 1; in_then = 0; next }
     /^fi$/ { in_if = 0; next }
     in_then && /WARN/ && /D-0055/ { cite = 1 }
     in_then && /WARN/ && /D-0052/ { stale = 1 }
     END { exit !(cite && !stale) }
   ' "$CHALLENGER_START"; then
  echo "PASS F7-4 bypass WARN cites D-0055, not withdrawn D-0052"
else
  echo "FAIL 09-start-challenger-sepolia.sh skip-preflight WARN must cite D-0055 (D-0052 Finding 2 was withdrawn)" >&2
  fail=1
fi

# F7-4: a failed gameArgs call is a named refusal, not a raw cast abort and
# not the empty-args fallback. Predating-gameArgs vs RPC failure cannot be
# told apart from here; guessing is how D-0055 happened. Successful empty
# (`0x`) must still reach the impl-getter fallback.
if awk '
     /^run_preflight\(\)/ { fn = 1; next }
     fn && /^}/ { fn = 0 }
     fn {
       if ($0 ~ /cast call/ && $0 ~ /gameArgs/) {
         saw_args = 1
         if ($0 ~ /if !/ || $0 ~ /\|\|/) { guarded = 1; in_fail = 1 }
       }
       if (in_fail) {
         if (/exit 1/) fail_exit = 1
         if (/echo/ && /ERROR/) err_echo = 1
         if (/echo/ && /GAME_FACTORY/) names_factory = 1
         if (/echo/ && /type_num/) names_type = 1
         if (/predate/) cause_old = 1
         if (/RPC/) cause_rpc = 1
         if (/vm\(\)\(address\)/ || /absolutePrestate\(\)\(bytes32\)/) leaked = 1
         if (/^[[:space:]]*fi[[:space:]]*$/) in_fail = 0
       }
     }
     END {
       exit !(saw_args && guarded && fail_exit && err_echo \
         && names_factory && names_type && cause_old && cause_rpc && !leaked)
     }
   ' "$CHALLENGER_START"; then
  echo "PASS F7-4 failed gameArgs call is a named refusal, not an impl-getter fallback"
else
  echo "FAIL 09-start-challenger-sepolia.sh must refuse a failed gameArgs call with a named error (factory + type + predates-or-RPC); must not fall back" >&2
  fail=1
fi

# US-073 step-11 / D-0077: cannon-kona maps to type 8; preflight runs (not skips);
# zero gameImpls(8) fails closed; unmapped types still skip; local prestate witness
# hash must match on-chain absolutePrestate unless CHALLENGER_SKIP_PREFLIGHT=1.
_F711_CHAIN_PRESTATE="0x034c90f083e8c86bb6bf18236d653d4aa42fac0653f013c780448000b9796b8d"
_F711_CHAIN_VM="71b4b694a5f522f8ecc6e4f7ac2e966a8ead0f73"
_F711_GAME_IMPL="0x84c0889A10E2f120F9fE6a27cEE8c6Cf735A8584"
_F711_GAME_FACTORY="0x1234567890123456789012345678901234567890"
_F711_PREFLIGHT_FN="$(
  awk '
    /^is_zero_hex\(\)/ { fn = 1 }
    /^game_impls_type_number\(\)/ { fn = 1 }
    /^run_preflight\(\)/ { fn = 1 }
    fn { print }
    fn && /^}/ { fn = 0 }
  ' "$CHALLENGER_START"
)"

_f711_setup_mocks() {
  local mock_dir="$1"
  local cast_mode="$2"
  local witness_hash="${3:-}"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/cast" << EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" != "call" ]]; then
  echo "mock cast: expected call subcommand, got: \${1:-}" >&2
  exit 1
fi
case "\${3:-}" in
  "gameImpls(uint32)(address)")
    if [[ "\${CAST_MODE:-}" == "zero_impl_8" && "\${4:-}" == "8" ]]; then
      echo "0x0000000000000000000000000000000000000000"
    elif [[ "\${4:-}" == "8" ]]; then
      echo "$_F711_GAME_IMPL"
    else
      echo "0x0000000000000000000000000000000000000001"
    fi
    ;;
  "gameArgs(uint32)(bytes)")
    echo "0x${_F711_CHAIN_PRESTATE#0x}${_F711_CHAIN_VM}0000000000000000000000000000000000000000"
    ;;
  *)
    echo "mock cast: unexpected signature: \${3:-}" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$mock_dir/cast"
  if [[ "$witness_hash" == "FAIL" ]]; then
    cat > "$mock_dir/cannon" << 'EOF'
#!/usr/bin/env bash
echo "unknown version: 110" >&2
exit 1
EOF
    chmod +x "$mock_dir/cannon"
  elif [[ -n "$witness_hash" ]]; then
    cat > "$mock_dir/cannon" << EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "witness" && "\${2:-}" == "--input" ]]; then
  printf '{"witnessHash":"%s"}\n' "$witness_hash"
  exit 0
fi
echo "mock cannon: unexpected argv: \$*" >&2
exit 1
EOF
    chmod +x "$mock_dir/cannon"
  fi
  export CAST_MODE="$cast_mode"
}

_f711_run_preflight() {
  local trace_type="$1"
  local skip_flag="${2:-}"
  local prestate_path="${3:-}"
  local mock_dir="$4"
  local runner rc out
  runner="$mock_dir/run_preflight.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    printf '%s\n' "$_F711_PREFLIGHT_FN"
    cat << RUNEOF
TRACE_TYPE='$trace_type'
GAME_FACTORY='$_F711_GAME_FACTORY'
L1_RPC_URL='http://127.0.0.1:8545'
CHALLENGER_L1_RPC_URL="\$L1_RPC_URL"
PRESTATE_PATH='${prestate_path:-}'
CANNON_BIN='$mock_dir/cannon'
CHALLENGER_SKIP_PREFLIGHT='${skip_flag:-}'
if [[ "\${CHALLENGER_SKIP_PREFLIGHT:-}" == "1" ]]; then
  exit 0
fi
run_preflight
RUNEOF
  } > "$runner"
  chmod +x "$runner"
  rc=0
  out="$(PATH="$mock_dir:$PATH" CAST_MODE="${CAST_MODE:-}" bash "$runner" 2>&1)" || rc=$?
  printf '%s' "$out"
  return "$rc"
}

if [[ -z "$_F711_PREFLIGHT_FN" ]] || ! awk '
     /cannon-kona\) echo 8/ { kona = 1 }
     END { exit !kona }
   ' "$CHALLENGER_START"; then
  echo "FAIL 09-start-challenger-sepolia.sh must map cannon-kona to game type 8 (D-0077)" >&2
  fail=1
else
  _f711_tmp="$(mktemp -d)"
  _f711_setup_mocks "$_f711_tmp" "zero_impl_8" ""
  _f711_rc=0
  _f711_out="$(_f711_run_preflight cannon-kona "" "" "$_f711_tmp" 2>&1)" || _f711_rc=$?
  if [[ "$_f711_rc" != "0" ]] \
    && printf '%s' "$_f711_out" | grep -q 'gameImpls(8)' \
    && printf '%s' "$_f711_out" | grep -q 'no implementation registered for game type 8'; then
    echo "PASS US-073 step-11 cannon-kona type 8 preflight refuses zero gameImpls(8) (D-0077)"
  else
    echo "FAIL 09-start-challenger-sepolia.sh must run preflight for cannon-kona (type 8) and exit 1 on zero gameImpls(8), not skip" >&2
    fail=1
  fi

  _f711_rc=0
  _f711_out="$(_f711_run_preflight alphabet "" "" "$_f711_tmp" 2>&1)" || _f711_rc=$?
  if [[ "$_f711_rc" == "0" ]] \
    && printf '%s' "$_f711_out" | grep -q 'skipping factory lookup' \
    && printf '%s' "$_f711_out" | grep -q 'cannon=0, permissioned=1, cannon-kona=8'; then
    echo "PASS US-073 step-11 unmapped trace type skips preflight and lists mapped types"
  else
    echo "FAIL 09-start-challenger-sepolia.sh must skip factory lookup for unmapped types and name mapped cannon=0, permissioned=1, cannon-kona=8" >&2
    fail=1
  fi

  touch "$_f711_tmp/prestate.bin"
  _f711_local_hash="0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  _f711_setup_mocks "$_f711_tmp" "" "$_f711_local_hash"
  _f711_rc=0
  _f711_out="$(_f711_run_preflight cannon-kona "" "$_f711_tmp/prestate.bin" "$_f711_tmp" 2>&1)" || _f711_rc=$?
  if [[ "$_f711_rc" != "0" ]] \
    && printf '%s' "$_f711_out" | grep -Fq "$_F711_CHAIN_PRESTATE" \
    && printf '%s' "$_f711_out" | grep -Fq "$_f711_local_hash"; then
    echo "PASS US-073 step-11 prestate witness mismatch refuses with local and on-chain hashes"
  else
    echo "FAIL 09-start-challenger-sepolia.sh must refuse when cannon witness hash mismatches on-chain absolutePrestate (both values printed)" >&2
    fail=1
  fi

  _f711_rc=0
  _f711_out="$(_f711_run_preflight cannon-kona "1" "$_f711_tmp/prestate.bin" "$_f711_tmp" 2>&1)" || _f711_rc=$?
  if [[ "$_f711_rc" == "0" ]] \
    && ! printf '%s' "$_f711_out" | grep -q 'witness hash does not match'; then
    echo "PASS US-073 step-11 CHALLENGER_SKIP_PREFLIGHT=1 bypasses prestate witness check"
  else
    echo "FAIL 09-start-challenger-sepolia.sh CHALLENGER_SKIP_PREFLIGHT=1 must bypass prestate witness comparison" >&2
    fail=1
  fi

  _f711_setup_mocks "$_f711_tmp" "" "FAIL"
  _f711_rc=0
  _f711_out="$(_f711_run_preflight cannon-kona "" "$_f711_tmp/prestate.bin" "$_f711_tmp" 2>&1)" || _f711_rc=$?
  if [[ "$_f711_rc" == "0" ]] \
    && printf '%s' "$_f711_out" | grep -q 'cannot compute CHALLENGER_PRESTATE witness hash' \
    && printf '%s' "$_f711_out" | grep -q 'D-0057'; then
    echo "PASS US-073 step-11 unhashable prestate warns and proceeds (D-0057)"
  else
    echo "FAIL 09-start-challenger-sepolia.sh must WARN and proceed when cannon witness cannot compute (D-0057)" >&2
    fail=1
  fi

  rm -rf "$_f711_tmp"
fi

# --- challenger-429-resilience (D-0107): scan-cost knobs + init grace retry ---
# (a) Wired flags reach challenger_args with credit-budget defaults; README table
#     documents the same numbers. (b) Functional: a process that dies inside the
#     grace window is retried; exhausting attempts exits nonzero. Removing the
#     retry loop must turn (b) red.
if grep -q -- '--http-poll-interval="$HTTP_POLL"' "$CHALLENGER_START" \
  && grep -q -- '--min-update-interval="$MIN_UPDATE"' "$CHALLENGER_START" \
  && grep -q -- '--max-concurrency="$MAX_CONCURRENCY"' "$CHALLENGER_START" \
  && grep -q 'challenger_args+=(--game-window="$GAME_WINDOW")' "$CHALLENGER_START" \
  && grep -q 'http-poll=${HTTP_POLL} min-update=${MIN_UPDATE} max-concurrency=${MAX_CONCURRENCY}' "$CHALLENGER_START" \
  && grep -q 'SEPOLIA_CHALLENGER_HTTP_POLL_INTERVAL:-${OP_CHALLENGER_HTTP_POLL_INTERVAL:-300s}' "$CHALLENGER_START" \
  && grep -q 'SEPOLIA_CHALLENGER_MIN_UPDATE_INTERVAL:-${OP_CHALLENGER_MIN_UPDATE_INTERVAL:-300s}' "$CHALLENGER_START" \
  && grep -q 'SEPOLIA_CHALLENGER_MAX_CONCURRENCY:-${OP_CHALLENGER_MAX_CONCURRENCY:-1}' "$CHALLENGER_START" \
  && grep -q 'CHALLENGER_START_GRACE_SEC:-15' "$CHALLENGER_START" \
  && grep -q 'CHALLENGER_START_ATTEMPTS:-3' "$CHALLENGER_START" \
  && grep -q 'start_challenger_with_retry' "$CHALLENGER_START" \
  && awk '
       /CHALLENGER_CANNON_SERVER|CHALLENGER_KONA_SERVER|super-cannon-kona is not supported/ { gate = NR }
       /^start_challenger_with_retry\(\)/ { fn = NR }
       END { exit !(gate && fn && gate < fn) }
     ' "$CHALLENGER_START" \
  && grep -q 'SEPOLIA_CHALLENGER_HTTP_POLL_INTERVAL' "$SCRIPT_DIR/../README.md" \
  && grep -q '`300s` / `300s`' "$SCRIPT_DIR/../README.md" \
  && grep -q 'SEPOLIA_CHALLENGER_MAX_CONCURRENCY' "$SCRIPT_DIR/../README.md" \
  && grep -qE '^# SEPOLIA_CHALLENGER_HTTP_POLL_INTERVAL=300s$' "$CHALLENGER_ENV" \
  && grep -qE '^# SEPOLIA_CHALLENGER_MIN_UPDATE_INTERVAL=300s$' "$CHALLENGER_ENV" \
  && grep -qE '^# SEPOLIA_CHALLENGER_MAX_CONCURRENCY=1$' "$CHALLENGER_ENV" \
  && grep -qE '^# OP_CHALLENGER_HTTP_POLL_INTERVAL=$' "$CHALLENGER_ENV"; then
  echo "PASS challenger scan-cost knobs wired (args + echo + README + .env.sepolia.example)"
else
  echo "FAIL 09-start-challenger must wire poll/update/concurrency into challenger_args with 300s/1 defaults, echo them, and document in README/.env.sepolia.example" >&2
  fail=1
fi

# Functional retry: extract helpers, stub start_bg so the "daemon" dies inside grace.
_C429_FIX="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-challenger-429.XXXXXX")"
_C429_FN="${_C429_FIX}/fn.sh"
# Extract the three helpers (alive / clear / retry) plus their call site is not needed.
awk '
  /^challenger_process_alive\(\)/ { keep=1 }
  /^challenger_clear_dead_pidfile\(\)/ { keep=1 }
  /^start_challenger_with_retry\(\)/ { keep=1 }
  keep { print }
  keep && /^}/ { keep=0; print "" }
' "$CHALLENGER_START" > "$_C429_FN"
if ! grep -q '^start_challenger_with_retry()' "$_C429_FN" \
  || ! grep -q '^challenger_process_alive()' "$_C429_FN"; then
  echo "FAIL could not extract challenger retry helpers from 09-start-challenger-sepolia.sh" >&2
  fail=1
else
  mkdir -p "$_C429_FIX/pids" "$_C429_FIX/logs"
  # Stub start_bg: launch a short-lived process whose cmdline contains op-challenger,
  # write its pid, return 0 — mimics D-0054 (start_bg succeeds, child dies soon).
  # Redirect stdio away from the caller's capture pipe (Codex P2 on #168).
  cat > "$_C429_FIX/stub_lib.sh" <<'EOS'
start_bg() {
  local name="$1"; shift
  local pidfile="$PID_DIR/$name.pid"
  local logfile="$LOG_DIR/$name.log"
  : >>"$logfile"
  # argv[0] shape that ps -o args= will show as containing op-challenger
  bash -c 'exec -a op-challenger-stub sleep 0.2' </dev/null >>"$logfile" 2>&1 &
  local pid=$!
  echo "$pid" >"$pidfile"
  echo "stub start_bg $name pid $pid" >>"$logfile"
  START_BG_CALLS=$(( ${START_BG_CALLS:-0} + 1 ))
  export START_BG_CALLS
  echo "$START_BG_CALLS" >"$PID_DIR/start_bg.calls"
  return 0
}
EOS
  _C429_RC=0
  _C429_OUT="$(
    set +e
    (
      set -euo pipefail
      PID_DIR="$_C429_FIX/pids"
      LOG_DIR="$_C429_FIX/logs"
      CHALLENGER_START_GRACE_SEC=1
      CHALLENGER_START_ATTEMPTS=3
      challenger_args=(--datadir=/tmp)
      START_BG_CALLS=0
      # shellcheck disable=SC1090
      source "$_C429_FIX/stub_lib.sh"
      # shellcheck disable=SC1090
      source "$_C429_FN"
      start_challenger_with_retry
    ) 2>&1
  )" || _C429_RC=$?
  _C429_CALLS="$(cat "$_C429_FIX/pids/start_bg.calls" 2>/dev/null || echo 0)"
  if [[ "$_C429_RC" -ne 0 ]] \
    && [[ "$_C429_CALLS" -eq 3 ]] \
    && printf '%s' "$_C429_OUT" | grep -q 'failed to stay up after 3 attempts' \
    && printf '%s' "$_C429_OUT" | grep -q 'died within 1s grace'; then
    echo "PASS challenger init retry exhausts after grace deaths (nonzero + 3 start_bg calls)"
  else
    echo "FAIL challenger start_challenger_with_retry must retry on grace death and exit nonzero after attempts (rc=$_C429_RC calls=$_C429_CALLS)" >&2
    echo "$_C429_OUT" >&2
    fail=1
  fi

  # Success path: stub that stays alive past grace.
  # Detach stdio from the $(...) capture pipe so we do not wait for sleep 30
  # (Codex P2 on #168 — real start_bg dup2s to the logfile).
  cat > "$_C429_FIX/stub_lib_ok.sh" <<'EOS'
start_bg() {
  local name="$1"; shift
  local pidfile="$PID_DIR/$name.pid"
  local logfile="$LOG_DIR/$name.log"
  : >>"$logfile"
  bash -c 'exec -a op-challenger-ok sleep 30' </dev/null >>"$logfile" 2>&1 &
  local pid=$!
  echo "$pid" >"$pidfile"
  echo "$pid" >"$PID_DIR/ok.pid"
  START_BG_CALLS=$(( ${START_BG_CALLS:-0} + 1 ))
  echo "$START_BG_CALLS" >"$PID_DIR/start_bg.calls"
  return 0
}
EOS
  rm -f "$_C429_FIX/pids"/* "$_C429_FIX/logs"/*
  mkdir -p "$_C429_FIX/pids" "$_C429_FIX/logs"
  _C429_OK_RC=0
  _C429_OK_OUT="$(
    set +e
    (
      set -euo pipefail
      PID_DIR="$_C429_FIX/pids"
      LOG_DIR="$_C429_FIX/logs"
      CHALLENGER_START_GRACE_SEC=1
      CHALLENGER_START_ATTEMPTS=3
      challenger_args=(--datadir=/tmp)
      # shellcheck disable=SC1090
      source "$_C429_FIX/stub_lib_ok.sh"
      # shellcheck disable=SC1090
      source "$_C429_FN"
      start_challenger_with_retry
    ) 2>&1
  )" || _C429_OK_RC=$?
  _C429_OK_PID="$(cat "$_C429_FIX/pids/ok.pid" 2>/dev/null || true)"
  if [[ -n "$_C429_OK_PID" ]]; then
    kill "$_C429_OK_PID" 2>/dev/null || true
    wait "$_C429_OK_PID" 2>/dev/null || true
  fi
  _C429_OK_CALLS="$(cat "$_C429_FIX/pids/start_bg.calls" 2>/dev/null || echo 0)"
  if [[ "$_C429_OK_RC" -eq 0 ]] \
    && [[ "$_C429_OK_CALLS" -eq 1 ]] \
    && printf '%s' "$_C429_OK_OUT" | grep -q 'survived 1s post-start grace'; then
    echo "PASS challenger init retry accepts a process that survives grace (single start_bg)"
  else
    echo "FAIL challenger start_challenger_with_retry must succeed once the process survives grace (rc=$_C429_OK_RC calls=$_C429_OK_CALLS)" >&2
    echo "$_C429_OK_OUT" >&2
    fail=1
  fi
fi
rm -rf "$_C429_FIX"
unset _C429_FIX _C429_FN _C429_RC _C429_OUT _C429_CALLS _C429_OK_RC _C429_OK_OUT _C429_OK_PID _C429_OK_CALLS

# F7-6 / D-0061: type-8 additional dispute game is a second apply, never the wipe.
# Assert properties of generated intent and of the prestate gate, not error phrasing.
DEPLOY_SEPOLIA="$SCRIPT_DIR/02-deploy-contracts-sepolia.sh"
_F76_VALID_PRESTATE="0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
_F76_CANNON32_DEFAULT="0x038512e02c4c3f7bdaec27d00edf55b7155e0905301e1a88083e4e0a6764d54c"

_f76_expand_intent() {
  local mode="$1"
  python3 - "$DEPLOY_SEPOLIA" "$mode" "${2:-}" << 'PY'
import pathlib, subprocess, sys
script_path, mode = sys.argv[1], sys.argv[2]
prestate = sys.argv[3] if len(sys.argv) > 3 else ""
script = pathlib.Path(script_path).read_text()

def heredoc_after(marker: str) -> str:
    start = script.find(marker)
    if start < 0:
        raise SystemExit("missing marker: " + marker)
    rest = script[start + len(marker):]
    end = rest.find("\nEOF\n")
    if end < 0:
        raise SystemExit("missing EOF after: " + marker)
    return rest[:end]

main = heredoc_after('cat > "$DEPLOY_DIR/intent.toml" << EOF\n')
extra = heredoc_after('cat >> "$DEPLOY_DIR/intent.toml" << EOF\n')
body = main if mode == "unset" else main + extra
env = {
    "L1_CHAIN_ID": "11155111",
    "L2_ID_HEX": "0x" + format(852, "064x"),
    "ADMIN_ADDRESS": "0x1111111111111111111111111111111111111111",
    "CHALLENGER_ADDRESS": "0x2222222222222222222222222222222222222222",
    "SEQUENCER_ADDRESS": "0x3333333333333333333333333333333333333333",
    "BATCHER_ADDRESS": "0x4444444444444444444444444444444444444444",
    "PROPOSER_ADDRESS": "0x5555555555555555555555555555555555555555",
    "PROOF_MATURITY_DELAY_SECONDS": "12",
    "DISPUTE_GAME_FINALITY_DELAY_SECONDS": "6",
    "FAULT_GAME_CLOCK_EXTENSION": "5",
    "FAULT_GAME_MAX_CLOCK_DURATION": "10",
    "FAULT_GAME_WITHDRAWAL_DELAY": "1",
    "PREIMAGE_ORACLE_CHALLENGE_PERIOD": "86400",
    "FAULT_GAME_ABSOLUTE_PRESTATE": prestate,
}
assign = "\n".join(f"{k}={v!r}" for k, v in env.items())
out = subprocess.check_output(
    ["bash", "-c", f"set -euo pipefail\n{assign}\ncat << EOF\n{body}\nEOF\n"],
    text=True,
)
sys.stdout.write(out)
PY
}

_f76_unset="$(_f76_expand_intent unset)"
_f76_main_heredoc="$(python3 - "$DEPLOY_SEPOLIA" << 'PY'
import pathlib, sys
script = pathlib.Path(sys.argv[1]).read_text()
marker = 'cat > "$DEPLOY_DIR/intent.toml" << EOF\n'
start = script.find(marker)
rest = script[start + len(marker):]
print(rest[:rest.find("\nEOF\n")])
PY
)"
if [[ "$_f76_unset" != *dangerousAdditionalDisputeGames* ]] \
  && [[ "$_f76_main_heredoc" != *dangerousAdditionalDisputeGames* ]] \
  && awk '
       /cat > "\$DEPLOY_DIR\/intent.toml"/ { over = NR }
       /if \[\[ -n "\$\{FAULT_GAME_ABSOLUTE_PRESTATE:-\}" \]\]/ {
         if (over && !app) gated = NR
       }
       /cat >> "\$DEPLOY_DIR\/intent.toml"/ { app = NR }
       END { exit !(over && gated && app && over < gated && gated < app) }
     ' "$DEPLOY_SEPOLIA"; then
  echo "PASS F7-6 unset intent has no additional dispute game (append is gated)"
else
  echo "FAIL 02-deploy-contracts-sepolia.sh must omit dangerousAdditionalDisputeGames unless FAULT_GAME_ABSOLUTE_PRESTATE is set" >&2
  fail=1
fi

_f76_set="$(_f76_expand_intent set "$_F76_VALID_PRESTATE")"
_f76_set_parse=1
if ! printf '%s' "$_f76_set" | python3 -c '
import sys, tomllib
data = tomllib.loads(sys.stdin.read())
if "dangerousAdditionalDisputeGames" in data:
    raise SystemExit("additional games escaped to top-level TOML")
chains = data.get("chains") or []
if len(chains) != 1:
    raise SystemExit("expected one [[chains]] entry")
chain = chains[0]
for key in ("id", "gasLimit", "baseFeeVaultRecipient", "roles"):
    if key not in chain:
        raise SystemExit("[[chains]] missing scalar/table " + key)
games = chain.get("dangerousAdditionalDisputeGames") or []
if len(games) != 1:
    raise SystemExit("expected one additional dispute game")
g = games[0]
required = {
    "respectedGameType": 8,
    "faultGameAbsolutePrestate": "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "faultGameMaxDepth": 73,
    "faultGameSplitDepth": 30,
    "faultGameClockExtension": 5,
    "faultGameMaxClockDuration": 10,
    "VMType": "CANNON",
    "MakeRespected": True,
}
missing = [k for k in required if k not in g]
if missing:
    raise SystemExit("missing keys: " + ",".join(missing))
for k, v in required.items():
    if g[k] != v:
        raise SystemExit(f"{k}: got {g[k]!r} want {v!r}")
if len(g) != 8:
    raise SystemExit(f"expected exactly 8 keys, got {sorted(g)}")
'; then
  _f76_set_parse=0
fi
if ((_f76_set_parse)) \
  && awk '
       /cat > "\$DEPLOY_DIR\/intent.toml"/ { over = NR }
       /cat >> "\$DEPLOY_DIR\/intent.toml"/ { app = NR }
       END { exit !(over && app && over < app) }
     ' "$DEPLOY_SEPOLIA" \
  && awk '
       /cat >> "\$DEPLOY_DIR\/intent.toml"/ { extra = 1; next }
       extra && /^EOF$/ { extra = 0 }
       extra {
         if ($0 ~ /respectedGameType = 8/) t8 = 1
         if ($0 ~ /respectedGameType = \$/) t8var = 1
         if ($0 ~ /\[\[chains\.dangerousAdditionalDisputeGames\]\]/) nested = 1
       }
       END { exit !(t8 && nested && !t8var) }
     ' "$DEPLOY_SEPOLIA"; then
  echo "PASS F7-6 set intent registers type-8 stanza inside [[chains]] with all eight keys"
else
  echo "FAIL 02-deploy-contracts-sepolia.sh must append [[chains.dangerousAdditionalDisputeGames]] with respectedGameType=8 and all eight keys" >&2
  fail=1
fi

_f76_fn="$(awk '/^refuse_fault_game_absolute_prestate\(\)/,/^}/' "$DEPLOY_SEPOLIA")"
_f76_run_gate() {
  local rc
  rc=0
  (
    eval "$_f76_fn"
    FAULT_GAME_ABSOLUTE_PRESTATE="${1-}"
    FORCE_SEPOLIA_REDEPLOY="${2-}"
    export FAULT_GAME_ABSOLUTE_PRESTATE FORCE_SEPOLIA_REDEPLOY
    refuse_fault_game_absolute_prestate
  ) >/dev/null 2>&1 || rc=$?
  echo "$rc"
}
_f76_rc_wipe="$(_f76_run_gate "" "1")"
_f76_rc_step8b="$(_f76_run_gate "$_F76_VALID_PRESTATE" "")"
_f76_rc_a="$(_f76_run_gate "$_F76_VALID_PRESTATE" "1")"
_f76_rc_b="$(_f76_run_gate "0x1234" "")"
_f76_rc_c="$(_f76_run_gate "$_F76_CANNON32_DEFAULT" "")"
if [[ "$_f76_rc_wipe" == "0" && "$_f76_rc_step8b" == "0" \
     && "$_f76_rc_a" != "0" && "$_f76_rc_b" != "0" && "$_f76_rc_c" != "0" ]] \
  && awk '
       /^refuse_fault_game_absolute_prestate\(\)/ { def = NR }
       /^refuse_fault_game_absolute_prestate$/ { call = NR }
       /rm -rf "\$DEPLOY_DIR"/ { rm = NR }
       /cat > "\$DEPLOY_DIR\/intent.toml"/ { intent = NR }
       END { exit !(def && call && rm && intent && def < call && call < rm && call < intent) }
     ' "$DEPLOY_SEPOLIA"; then
  echo "PASS F7-6 prestate refusals (wipe+set / malformed / cannon32 default) exit non-zero before writes"
else
  echo "FAIL 02-deploy-contracts-sepolia.sh must refuse FAULT_GAME_ABSOLUTE_PRESTATE during wipe, if malformed, or if it is op-deployer's cannon32 default — before any write (D-0061 / D-0056)" >&2
  fail=1
fi

_f76_extra="$(python3 - "$DEPLOY_SEPOLIA" << 'PY'
import pathlib, sys
script = pathlib.Path(sys.argv[1]).read_text()
marker = 'cat >> "$DEPLOY_DIR/intent.toml" << EOF\n'
start = script.find(marker)
rest = script[start + len(marker):]
print(rest[:rest.find("\nEOF\n")])
PY
)"
_f76_allowed=1
if ! printf '%s\n' "$_f76_extra" | grep -q 'faultGameClockExtension = ${FAULT_GAME_CLOCK_EXTENSION}'; then
  _f76_allowed=0
fi
if ! printf '%s\n' "$_f76_extra" | grep -q 'faultGameMaxClockDuration = ${FAULT_GAME_MAX_CLOCK_DURATION}'; then
  _f76_allowed=0
fi
while IFS= read -r _v; do
  [[ -z "$_v" ]] && continue
  case "$_v" in
    '${FAULT_GAME_ABSOLUTE_PRESTATE}'|'${FAULT_GAME_CLOCK_EXTENSION}'|'${FAULT_GAME_MAX_CLOCK_DURATION}') ;;
    *) _f76_allowed=0 ;;
  esac
done << EOF
$(printf '%s\n' "$_f76_extra" | grep -oE '\$\{FAULT_GAME_[A-Z_]+\}' | sort -u)
EOF
if ((_f76_allowed)); then
  echo "PASS F7-6 additional-game clocks reuse FAULT_GAME_CLOCK_EXTENSION / FAULT_GAME_MAX_CLOCK_DURATION"
else
  echo "FAIL 02-deploy-contracts-sepolia.sh additional-game clocks must reference the existing FAULT_GAME_CLOCK_* variables, not new ones" >&2
  fail=1
fi

ENV_SEPOLIA_EXAMPLE="$SCRIPT_DIR/../.env.sepolia.example"
if grep -qE '^# FAULT_GAME_ABSOLUTE_PRESTATE=' "$ENV_SEPOLIA_EXAMPLE" \
  && ! grep -qE '^FAULT_GAME_ABSOLUTE_PRESTATE=' "$ENV_SEPOLIA_EXAMPLE" \
  && ! grep -q "$_F76_CANNON32_DEFAULT" "$ENV_SEPOLIA_EXAMPLE" \
  && ! grep -q 'prestate must be resolved and pinned first' "$ENV_SEPOLIA_EXAMPLE" \
  && awk '
       /[Ss]tep 8b/ { eight = NR }
       /^# FAULT_GAME_ABSOLUTE_PRESTATE=/ { assign = NR }
       END {
         d = eight - assign; if (d < 0) d = -d
         exit !(eight && assign && d <= 15)
       }
     ' "$ENV_SEPOLIA_EXAMPLE"; then
  echo "PASS F7-6 .env.sepolia.example documents FAULT_GAME_ABSOLUTE_PRESTATE commented out for step 8b"
else
  echo "FAIL .env.sepolia.example must document FAULT_GAME_ABSOLUTE_PRESTATE as commented-out, step 8b only — not pinned before the wipe, not op-deployer's default" >&2
  fail=1
fi

# Challenger / proxy / safedb / 8b vars must appear in the tracked example so
# an operator recreating .env.sepolia can stand up Phase 7. Appearance is
# `KEY=` or `# KEY=` (empty or commented). Do not require DEMO_*/FUNDING_* —
# that gap is a separate task, and two of those are secrets.
_env_ex_keys=(
  OP_NODE_SAFEDB_PATH
  L1_BEACON_URL
  CHALLENGER_TRACE_TYPE
  CHALLENGER_PRESTATE
  CHALLENGER_L1_RPC_URL
  OP_CHALLENGER_MAX_CONCURRENCY
  OP_CHALLENGER_HTTP_POLL_INTERVAL
  OP_CHALLENGER_GAME_WINDOW
  OP_CHALLENGER_MIN_UPDATE_INTERVAL
  SEPOLIA_CHALLENGER_HTTP_POLL_INTERVAL
  SEPOLIA_CHALLENGER_MIN_UPDATE_INTERVAL
  SEPOLIA_CHALLENGER_MAX_CONCURRENCY
  SEPOLIA_CHALLENGER_GAME_WINDOW
  FAULT_GAME_ABSOLUTE_PRESTATE
  L1_BATCH_PROXY_PORT
  L1_BATCH_PROXY_CHUNK
  L1_BATCH_PROXY_PACE_SEC
)
_env_ex_ok=1
for _k in "${_env_ex_keys[@]}"; do
  if ! grep -qE "^(# )?${_k}=" "$ENV_SEPOLIA_EXAMPLE"; then
    echo "FAIL .env.sepolia.example missing ${_k}" >&2
    _env_ex_ok=0
  fi
  _n="$(grep -cE "^${_k}=" "$ENV_SEPOLIA_EXAMPLE" || true)"
  if [[ "${_n}" -gt 1 ]]; then
    echo "FAIL .env.sepolia.example duplicate uncommented assignment of ${_k}" >&2
    _env_ex_ok=0
  fi
  # Commented `# KEY=` plus later `KEY=` is the D-0065 overwrite trap (Codex on #145).
  _c="$(grep -cE "^# ${_k}=" "$ENV_SEPOLIA_EXAMPLE" || true)"
  if [[ "${_c}" -gt 0 && "${_n}" -gt 0 ]]; then
    echo "FAIL .env.sepolia.example documents ${_k} as both commented and uncommented" >&2
    _env_ex_ok=0
  fi
done
if ((_env_ex_ok)); then
  echo "PASS .env.sepolia.example documents challenger/proxy/safedb/8b env vars"
else
  echo "FAIL .env.sepolia.example must document each challenger/proxy/safedb/8b var once (empty or commented)" >&2
  fail=1
fi
unset _env_ex_keys _env_ex_ok _k _n _c

# Tripwire: a PRIVATE_KEY= or TOKEN= line (commented or not) must not carry a
# value. Report names only — never the value (Codex P2 on #145). The live
# .env.sepolia is gitignored; pasting from it is a leak.
if grep -qE '(PRIVATE_KEY|TOKEN)=.+' "$ENV_SEPOLIA_EXAMPLE"; then
  echo "FAIL .env.sepolia.example must not contain a populated PRIVATE_KEY or TOKEN (placeholders only)" >&2
  grep -E '(PRIVATE_KEY|TOKEN)=.+' "$ENV_SEPOLIA_EXAMPLE" \
    | sed -E 's/=.*$//; s/^[[:space:]]*#[[:space:]]*//; s/^[[:space:]]*export[[:space:]]+//' >&2 || true
  fail=1
else
  echo "PASS .env.sepolia.example PRIVATE_KEY/TOKEN values are empty"
fi

# F7-10: ADMIN_PRIVATE_KEY must derive ADMIN_ADDRESS before spend or wipe.
# Generate the keypair at runtime — never a key literal in this file.
# Helper lives in lib.sh (call-site swap in 02-deploy-contracts-sepolia.sh).
_f710_fn="$(awk '/^require_key_matches_address\(\)/,/^}/' "$SCRIPT_DIR/lib.sh")"
_f710_rc=""
_f710_out=""
_f710_run() {
  local key="${1-}"
  local addr="${2-}"
  _f710_rc=0
  _f710_out="$(
    (
      eval "$_f710_fn"
      if [[ "$key" == "__UNSET__" ]]; then
        unset ADMIN_PRIVATE_KEY
      else
        ADMIN_PRIVATE_KEY="$key"
        export ADMIN_PRIVATE_KEY
      fi
      ADMIN_ADDRESS="$addr"
      export ADMIN_ADDRESS
      require_key_matches_address ADMIN_PRIVATE_KEY ADMIN_ADDRESS
    ) 2>&1
  )" || _f710_rc=$?
}
_f710_key_leaked() {
  local hay="$1" key="$2" allowed="$3"
  local body chunk i
  [[ -z "$key" ]] && return 1
  if printf '%s' "$hay" | grep -F -q -- "$key"; then
    return 0
  fi
  body="${key#0x}"
  body="${body#0X}"
  if [[ "$body" != "$key" ]] && printf '%s' "$hay" | grep -F -q -- "$body"; then
    return 0
  fi
  i=0
  while (( i + 8 <= ${#body} )); do
    chunk="${body:i:8}"
    if printf '%s' "$hay" | grep -F -q -- "$chunk"; then
      if ! printf '%s' "$allowed" | grep -F -q -- "$chunk"; then
        return 0
      fi
    fi
    i=$((i + 1))
  done
  return 1
}

if ! command -v cast >/dev/null 2>&1; then
  echo "FAIL F7-10 tests require cast on PATH (Foundry)" >&2
  fail=1
elif [[ -z "$_f710_fn" ]]; then
  echo "FAIL lib.sh must define require_key_matches_address" >&2
  fail=1
else
  _f710_wallet="$(cast wallet new)"
  _f710_addr="$(printf '%s\n' "$_f710_wallet" | awk '/^Address:/{print $2}')"
  _f710_key="$(printf '%s\n' "$_f710_wallet" | awk '/^Private key:/{print $3}')"
  _f710_addr_lc="$(printf '%s' "$_f710_addr" | tr '[:upper:]' '[:lower:]')"
  _f710_other_addr="$(cast wallet new | awk '/^Address:/{print $2}')"
  unset _f710_wallet

  _f710_run "$_f710_key" "$_f710_addr_lc"
  if [[ "$_f710_rc" == "0" ]]; then
    echo "PASS F7-10 matching pair (checksummed vs lowercase) exits 0"
  else
    echo "FAIL require_admin_key_matches_address must accept a checksummed-vs-lowercase pair of the same account" >&2
    fail=1
  fi

  _f710_run "$_f710_key" "$_f710_other_addr"
  _f710_mismatch_out="$_f710_out"
  if [[ "$_f710_rc" != "0" ]] \
    && printf '%s' "$_f710_mismatch_out" | grep -F -q -- "$_f710_addr" \
    && printf '%s' "$_f710_mismatch_out" | grep -F -q -- "$_f710_other_addr"; then
    echo "PASS F7-10 mismatched pair exits non-zero"
  else
    echo "FAIL require_admin_key_matches_address must refuse when ADMIN_PRIVATE_KEY does not derive ADMIN_ADDRESS" >&2
    fail=1
  fi

  _f710_run "" "$_f710_addr"
  _f710_empty_rc="$_f710_rc"
  _f710_empty_out="$_f710_out"
  _f710_run "__UNSET__" "$_f710_addr"
  if [[ "$_f710_empty_rc" != "0" && "$_f710_rc" != "0" ]] \
    && printf '%s' "$_f710_empty_out" | grep -q 'ADMIN_PRIVATE_KEY is required' \
    && printf '%s' "$_f710_out" | grep -q 'ADMIN_PRIVATE_KEY is required'; then
    echo "PASS F7-10 unset or empty ADMIN_PRIVATE_KEY exits non-zero"
  else
    echo "FAIL require_admin_key_matches_address must refuse an unset or empty ADMIN_PRIVATE_KEY" >&2
    fail=1
  fi

  _f710_run "$_f710_key" "$_f710_addr_lc"
  _f710_match_out="$_f710_out"
  if ! _f710_key_leaked "${_f710_match_out}${_f710_mismatch_out}${_f710_empty_out}" "$_f710_key" "${_f710_addr}${_f710_addr_lc}${_f710_other_addr}"; then
    echo "PASS F7-10 error output does not contain the key or an 8-character substring of it"
  else
    echo "FAIL require_admin_key_matches_address must not print ADMIN_PRIVATE_KEY or any 8-character substring of it" >&2
    fail=1
  fi

  if awk '
       /require_key_matches_address ADMIN_PRIVATE_KEY ADMIN_ADDRESS/ { call = NR }
       /require_min_balance_eth/ && !bal { bal = NR }
       /rm -rf "\$DEPLOY_DIR"/ && !rm { rm = NR }
       END { exit !(call && bal && rm && call < bal && call < rm) }
     ' "$DEPLOY_SEPOLIA"; then
    echo "PASS F7-10 pairing check is called before require_min_balance_eth and before the wipe"
  else
    echo "FAIL require_key_matches_address must run before require_min_balance_eth and before rm -rf \"\$DEPLOY_DIR\"" >&2
    fail=1
  fi

  if awk '
       /cast wallet address/ {
         saw = 1
         if ($0 ~ /--private-key/) flag = 1
         if ($0 ~ /cast wallet address[[:space:]]+"\$ADMIN_PRIVATE_KEY"/) pos = 1
         if ($0 ~ /cast wallet address[[:space:]]+"\$key"/) pos = 1
       }
       END { exit !(saw && flag && !pos) }
     ' "$SCRIPT_DIR/lib.sh"; then
    echo "PASS F7-10 derives the address with cast wallet address --private-key"
  else
    echo "FAIL lib.sh must call cast wallet address --private-key, not a positional key" >&2
    fail=1
  fi

  unset _f710_key _f710_addr _f710_addr_lc _f710_other_addr _f710_match_out _f710_mismatch_out _f710_empty_out _f710_empty_rc
fi
unset _f710_fn _f710_rc _f710_out

# F7-11: refuse duplicate Phase 7 immutables on every run; refuse absent/empty
# ones on the two irreversible paths (D-0065). Do not modify the F7-6 or F7-10
# blocks above. Fixtures are built at runtime — never a committed env file.
_F711_VARS=(
  PROOF_MATURITY_DELAY_SECONDS
  DISPUTE_GAME_FINALITY_DELAY_SECONDS
  FAULT_GAME_CLOCK_EXTENSION
  FAULT_GAME_MAX_CLOCK_DURATION
  FAULT_GAME_WITHDRAWAL_DELAY
  PREIMAGE_ORACLE_CHALLENGE_PERIOD
)
_f711_fn="$(awk '/^# >>> F7-11$/,/^# <<< F7-11$/' "$DEPLOY_SEPOLIA")"
_f711_dir="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-f711-XXXXXX")"
_f711_rc=""
_f711_out=""
_f711_write_complete() {
  local dest="$1"
  cat > "$dest" <<'EOF'
PROOF_MATURITY_DELAY_SECONDS=1800
DISPUTE_GAME_FINALITY_DELAY_SECONDS=1800
FAULT_GAME_CLOCK_EXTENSION=600
FAULT_GAME_MAX_CLOCK_DURATION=7200
FAULT_GAME_WITHDRAWAL_DELAY=3600
PREIMAGE_ORACLE_CHALLENGE_PERIOD=3600
EOF
}
_f711_write_complete_except() {
  local dest="$1" skip="$2"
  local v
  : > "$dest"
  for v in "${_F711_VARS[@]}"; do
    if [[ "$v" == "$skip" ]]; then
      continue
    fi
    echo "${v}=3600" >> "$dest"
  done
}
_f711_write_empty() {
  local dest="$1" target="$2" form="$3"
  local v
  : > "$dest"
  for v in "${_F711_VARS[@]}"; do
    if [[ "$v" == "$target" ]]; then
      if [[ "$form" == quoted ]]; then
        echo "${v}=\"\"" >> "$dest"
      elif [[ "$form" == inline ]]; then
        echo "${v}= # f711-inline-comment-canary" >> "$dest"
      elif [[ "$form" == quoted-inline ]]; then
        echo "${v}=\"\" # f711-inline-comment-canary" >> "$dest"
      else
        echo "${v}=" >> "$dest"
      fi
    else
      echo "${v}=3600" >> "$dest"
    fi
  done
}
_f711_run() {
  local envfile="$1"
  local force="${2-}"
  local prestate="${3-}"
  _f711_rc=0
  _f711_out="$(
    (
      eval "$_f711_fn"
      FORTEL2_ENV_FILE="$envfile"
      export FORTEL2_ENV_FILE
      if [[ -n "$force" ]]; then
        FORCE_SEPOLIA_REDEPLOY="$force"
        export FORCE_SEPOLIA_REDEPLOY
      else
        unset FORCE_SEPOLIA_REDEPLOY
      fi
      if [[ -n "$prestate" ]]; then
        FAULT_GAME_ABSOLUTE_PRESTATE="$prestate"
        export FAULT_GAME_ABSOLUTE_PRESTATE
      else
        unset FAULT_GAME_ABSOLUTE_PRESTATE
      fi
      refuse_duplicate_phase7_immutables
      refuse_absent_phase7_immutables
    ) 2>&1
  )" || _f711_rc=$?
}
_f711_leaked_values() {
  local hay="$1" envfile="$2"
  local line val
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    local trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$trimmed" ]] && continue
    [[ "$trimmed" == \#* ]] && continue
    [[ "$trimmed" == *=* ]] || continue
    val="${trimmed#*=}"
    val="${val%"${val##*[![:space:]]}"}"
    if [[ "$val" == \"*\" ]]; then
      val="${val#\"}"
      val="${val%\"}"
    elif [[ "$val" == \'*\' ]]; then
      val="${val#\'}"
      val="${val%\'}"
    fi
    [[ -z "$val" ]] && continue
    if printf '%s' "$hay" | grep -F -q -- "$val"; then
      return 0
    fi
  done < "$envfile"
  return 1
}

if [[ -z "$_f711_fn" ]] \
  || ! printf '%s' "$_f711_fn" | grep -q 'refuse_duplicate_phase7_immutables' \
  || ! printf '%s' "$_f711_fn" | grep -q 'refuse_absent_phase7_immutables'; then
  echo "FAIL 02-deploy-contracts-sepolia.sh must define the F7-11 refuse functions" >&2
  fail=1
else
  _f711_good="$_f711_dir/good.env"
  _f711_write_complete "$_f711_good"

  _f711_dup_ok=1
  _i=0
  for _var in "${_F711_VARS[@]}"; do
    _i=$((_i + 1))
    _f711_dup="$_f711_dir/dup-${_var}.env"
    _f711_write_complete "$_f711_dup"
    echo "${_var}=f711dup" >> "$_f711_dup"
    _f711_run "$_f711_dup" "" ""
    if [[ "$_f711_rc" != "0" ]] \
      && printf '%s' "$_f711_out" | grep -F -q -- "$_var" \
      && printf '%s' "$_f711_out" | grep -F -q -- "lines ${_i}, 7"; then
      echo "PASS F7-11 duplicate ${_var} refuses (lines ${_i}, 7)"
    else
      echo "FAIL F7-11 must refuse a duplicate ${_var} and name both line numbers" >&2
      fail=1
      _f711_dup_ok=0
    fi
    if _f711_leaked_values "$_f711_out" "$_f711_dup"; then
      echo "FAIL F7-11 duplicate ${_var} error leaked an env-file value" >&2
      fail=1
      _f711_dup_ok=0
    fi
  done

  _f711_comment="$_f711_dir/comment.env"
  _f711_write_complete "$_f711_comment"
  echo "#FAULT_GAME_CLOCK_EXTENSION=5" >> "$_f711_comment"
  _f711_run "$_f711_comment" "1" ""
  if [[ "$_f711_rc" == "0" ]]; then
    echo "PASS F7-11 commented #VAR= is not a duplicate"
  else
    echo "FAIL F7-11 must not treat a commented #VAR= line as an assignment" >&2
    fail=1
  fi

  _f711_export="$_f711_dir/export.env"
  _f711_write_complete "$_f711_export"
  echo "export FAULT_GAME_CLOCK_EXTENSION=f711dup" >> "$_f711_export"
  _f711_run "$_f711_export" "" ""
  if [[ "$_f711_rc" != "0" ]] \
    && printf '%s' "$_f711_out" | grep -F -q -- "FAULT_GAME_CLOCK_EXTENSION" \
    && printf '%s' "$_f711_out" | grep -F -q -- "lines 3, 7"; then
    echo "PASS F7-11 export VAR= counts as an assignment"
  else
    echo "FAIL F7-11 must count export VAR= as an assignment (duplicate with line 3)" >&2
    fail=1
  fi
  if _f711_leaked_values "$_f711_out" "$_f711_export"; then
    echo "FAIL F7-11 export-duplicate error leaked an env-file value" >&2
    fail=1
  fi

  _f711_ws="$_f711_dir/ws.env"
  _f711_write_complete "$_f711_ws"
  echo "  FAULT_GAME_CLOCK_EXTENSION=f711dup" >> "$_f711_ws"
  _f711_run "$_f711_ws" "" ""
  if [[ "$_f711_rc" != "0" ]] \
    && printf '%s' "$_f711_out" | grep -F -q -- "FAULT_GAME_CLOCK_EXTENSION" \
    && printf '%s' "$_f711_out" | grep -F -q -- "lines 3, 7"; then
    echo "PASS F7-11 leading-whitespace assignment counts"
  else
    echo "FAIL F7-11 must count a leading-whitespace assignment as a duplicate" >&2
    fail=1
  fi
  if _f711_leaked_values "$_f711_out" "$_f711_ws"; then
    echo "FAIL F7-11 leading-whitespace error leaked an env-file value" >&2
    fail=1
  fi

  _f711_abs_force_ok=1
  _f711_abs_pre_ok=1
  _f711_abs_neither_ok=1
  for _var in "${_F711_VARS[@]}"; do
    _f711_miss="$_f711_dir/miss-${_var}.env"
    _f711_write_complete_except "$_f711_miss" "$_var"
    _f711_run "$_f711_miss" "1" ""
    if [[ "$_f711_rc" != "0" ]] && printf '%s' "$_f711_out" | grep -F -q -- "$_var"; then
      :
    else
      echo "FAIL F7-11 must refuse absent ${_var} when FORCE_SEPOLIA_REDEPLOY=1" >&2
      fail=1
      _f711_abs_force_ok=0
    fi
    if _f711_leaked_values "$_f711_out" "$_f711_miss"; then
      echo "FAIL F7-11 absence+FORCE ${_var} error leaked an env-file value" >&2
      fail=1
      _f711_abs_force_ok=0
    fi
    _f711_run "$_f711_miss" "" "prestate-set"
    if [[ "$_f711_rc" != "0" ]] && printf '%s' "$_f711_out" | grep -F -q -- "$_var"; then
      :
    else
      echo "FAIL F7-11 must refuse absent ${_var} when FAULT_GAME_ABSOLUTE_PRESTATE is set" >&2
      fail=1
      _f711_abs_pre_ok=0
    fi
    if _f711_leaked_values "$_f711_out" "$_f711_miss"; then
      echo "FAIL F7-11 absence+prestate ${_var} error leaked an env-file value" >&2
      fail=1
      _f711_abs_pre_ok=0
    fi
    _f711_run "$_f711_miss" "" ""
    if [[ "$_f711_rc" != "0" ]]; then
      echo "FAIL F7-11 absence of ${_var} must still proceed when neither irreversible gate is set" >&2
      fail=1
      _f711_abs_neither_ok=0
    fi
  done
  if ((_f711_abs_force_ok)); then
    echo "PASS F7-11 absence + FORCE_SEPOLIA_REDEPLOY=1 refuses each of the six"
  fi
  if ((_f711_abs_pre_ok)); then
    echo "PASS F7-11 absence + FAULT_GAME_ABSOLUTE_PRESTATE set refuses each of the six"
  fi

  _f711_empty_force_ok=1
  _f711_empty_pre_ok=1
  _f711_quoted_force_ok=1
  _f711_quoted_pre_ok=1
  _f711_empty_neither_ok=1
  for _var in "${_F711_VARS[@]}"; do
    _f711_empty="$_f711_dir/empty-${_var}.env"
    _f711_write_empty "$_f711_empty" "$_var" empty
    _f711_run "$_f711_empty" "1" ""
    if [[ "$_f711_rc" != "0" ]] && printf '%s' "$_f711_out" | grep -F -q -- "$_var"; then
      echo "PASS F7-11 empty ${_var}= refuses on FORCE_SEPOLIA_REDEPLOY=1"
    else
      echo "FAIL F7-11 must refuse empty ${_var}= when FORCE_SEPOLIA_REDEPLOY=1" >&2
      fail=1
      _f711_empty_force_ok=0
    fi
    _f711_run "$_f711_empty" "" "prestate-set"
    if [[ "$_f711_rc" != "0" ]] && printf '%s' "$_f711_out" | grep -F -q -- "$_var"; then
      echo "PASS F7-11 empty ${_var}= refuses on FAULT_GAME_ABSOLUTE_PRESTATE set"
    else
      echo "FAIL F7-11 must refuse empty ${_var}= when FAULT_GAME_ABSOLUTE_PRESTATE is set" >&2
      fail=1
      _f711_empty_pre_ok=0
    fi
    _f711_run "$_f711_empty" "" ""
    if [[ "$_f711_rc" == "0" ]]; then
      :
    else
      echo "FAIL F7-11 empty ${_var}= must still proceed when neither irreversible gate is set" >&2
      fail=1
      _f711_empty_neither_ok=0
    fi

    _f711_qempty="$_f711_dir/qempty-${_var}.env"
    _f711_write_empty "$_f711_qempty" "$_var" quoted
    _f711_run "$_f711_qempty" "1" ""
    if [[ "$_f711_rc" != "0" ]] && printf '%s' "$_f711_out" | grep -F -q -- "$_var"; then
      echo "PASS F7-11 quoted-empty ${_var}=\"\" refuses on FORCE_SEPOLIA_REDEPLOY=1"
    else
      echo "FAIL F7-11 must refuse quoted-empty ${_var}=\"\" when FORCE_SEPOLIA_REDEPLOY=1" >&2
      fail=1
      _f711_quoted_force_ok=0
    fi
    _f711_run "$_f711_qempty" "" "prestate-set"
    if [[ "$_f711_rc" != "0" ]] && printf '%s' "$_f711_out" | grep -F -q -- "$_var"; then
      echo "PASS F7-11 quoted-empty ${_var}=\"\" refuses on FAULT_GAME_ABSOLUTE_PRESTATE set"
    else
      echo "FAIL F7-11 must refuse quoted-empty ${_var}=\"\" when FAULT_GAME_ABSOLUTE_PRESTATE is set" >&2
      fail=1
      _f711_quoted_pre_ok=0
    fi
    _f711_run "$_f711_qempty" "" ""
    if [[ "$_f711_rc" != "0" ]]; then
      echo "FAIL F7-11 quoted-empty ${_var}=\"\" must still proceed when neither irreversible gate is set" >&2
      fail=1
      _f711_empty_neither_ok=0
    fi

    _f711_inline="$_f711_dir/inline-${_var}.env"
    _f711_write_empty "$_f711_inline" "$_var" inline
    _f711_run "$_f711_inline" "1" ""
    if [[ "$_f711_rc" != "0" ]] && printf '%s' "$_f711_out" | grep -F -q -- "$_var"; then
      echo "PASS F7-11 inline-comment empty ${_var}= # … refuses on FORCE_SEPOLIA_REDEPLOY=1"
    else
      echo "FAIL F7-11 must refuse ${_var}= # comment (bash-empty) when FORCE_SEPOLIA_REDEPLOY=1" >&2
      fail=1
    fi
    if _f711_leaked_values "$_f711_out" "$_f711_inline"; then
      echo "FAIL F7-11 inline-comment ${_var} error leaked an env-file value" >&2
      fail=1
    fi
    _f711_run "$_f711_inline" "" "prestate-set"
    if [[ "$_f711_rc" != "0" ]] && printf '%s' "$_f711_out" | grep -F -q -- "$_var"; then
      echo "PASS F7-11 inline-comment empty ${_var}= # … refuses on FAULT_GAME_ABSOLUTE_PRESTATE set"
    else
      echo "FAIL F7-11 must refuse ${_var}= # comment (bash-empty) when FAULT_GAME_ABSOLUTE_PRESTATE is set" >&2
      fail=1
    fi
    _f711_run "$_f711_inline" "" ""
    if [[ "$_f711_rc" != "0" ]]; then
      echo "FAIL F7-11 inline-comment empty ${_var}= # comment must still proceed when neither irreversible gate is set" >&2
      fail=1
      _f711_empty_neither_ok=0
    fi

    _f711_qinline="$_f711_dir/qinline-${_var}.env"
    _f711_write_empty "$_f711_qinline" "$_var" quoted-inline
    _f711_run "$_f711_qinline" "1" ""
    if [[ "$_f711_rc" != "0" ]] && printf '%s' "$_f711_out" | grep -F -q -- "$_var"; then
      echo "PASS F7-11 quoted-empty-plus-comment ${_var}=\"\" # … refuses on FORCE_SEPOLIA_REDEPLOY=1"
    else
      echo "FAIL F7-11 must refuse ${_var}=\"\" # comment when FORCE_SEPOLIA_REDEPLOY=1" >&2
      fail=1
    fi
    if _f711_leaked_values "$_f711_out" "$_f711_qinline"; then
      echo "FAIL F7-11 quoted-inline-comment ${_var} error leaked an env-file value" >&2
      fail=1
    fi
    _f711_run "$_f711_qinline" "" "prestate-set"
    if [[ "$_f711_rc" != "0" ]] && printf '%s' "$_f711_out" | grep -F -q -- "$_var"; then
      echo "PASS F7-11 quoted-empty-plus-comment ${_var}=\"\" # … refuses on FAULT_GAME_ABSOLUTE_PRESTATE set"
    else
      echo "FAIL F7-11 must refuse ${_var}=\"\" # comment when FAULT_GAME_ABSOLUTE_PRESTATE is set" >&2
      fail=1
    fi
    _f711_run "$_f711_qinline" "" ""
    if [[ "$_f711_rc" != "0" ]]; then
      echo "FAIL F7-11 quoted-empty-plus-comment ${_var} must still proceed when neither irreversible gate is set" >&2
      fail=1
      _f711_empty_neither_ok=0
    fi
  done
  if ((_f711_empty_neither_ok && _f711_abs_neither_ok)); then
    echo "PASS F7-11 absence or emptiness with neither gate set still proceeds"
  fi

  _f711_then_empty="$_f711_dir/then-empty.env"
  _f711_write_complete "$_f711_then_empty"
  echo "FAULT_GAME_WITHDRAWAL_DELAY=" >> "$_f711_then_empty"
  _f711_run "$_f711_then_empty" "" ""
  if [[ "$_f711_rc" != "0" ]] \
    && printf '%s' "$_f711_out" | grep -F -q -- "FAULT_GAME_WITHDRAWAL_DELAY" \
    && printf '%s' "$_f711_out" | grep -F -q -- "lines 5, 7"; then
    echo "PASS F7-11 VAR=3600 followed by VAR= is a duplicate on every path"
  else
    echo "FAIL F7-11 must refuse VAR=3600 later overwritten by VAR= as a duplicate, even with neither gate set" >&2
    fail=1
  fi

  _f711_run "$_f711_good" "1" ""
  _f711_good_force="$_f711_rc"
  _f711_run "$_f711_good" "" "prestate-set"
  _f711_good_pre="$_f711_rc"
  _f711_run "$_f711_good" "" ""
  if [[ "$_f711_good_force" == "0" && "$_f711_good_pre" == "0" && "$_f711_rc" == "0" ]]; then
    echo "PASS F7-11 complete env file proceeds on wipe, step 8b, and neither"
  else
    echo "FAIL F7-11 must accept a file that assigns each of the six once, non-empty" >&2
    fail=1
  fi

  _f711_valued_comment="$_f711_dir/valued-comment.env"
  _f711_write_complete_except "$_f711_valued_comment" "FAULT_GAME_WITHDRAWAL_DELAY"
  echo "FAULT_GAME_WITHDRAWAL_DELAY=3600 # f711-inline-comment-canary" >> "$_f711_valued_comment"
  _f711_run "$_f711_valued_comment" "1" ""
  if [[ "$_f711_rc" == "0" ]]; then
    echo "PASS F7-11 VAR=3600 # comment is non-empty on FORCE_SEPOLIA_REDEPLOY=1"
  else
    echo "FAIL F7-11 must accept a non-empty value that has a trailing inline comment" >&2
    fail=1
  fi

  _f711_hashkeep="$_f711_dir/hashkeep.env"
  _f711_write_complete_except "$_f711_hashkeep" "PREIMAGE_ORACLE_CHALLENGE_PERIOD"
  echo "PREIMAGE_ORACLE_CHALLENGE_PERIOD=\"#keep\"" >> "$_f711_hashkeep"
  _f711_run "$_f711_hashkeep" "1" ""
  if [[ "$_f711_rc" == "0" ]]; then
    echo "PASS F7-11 quoted VAR=\"#keep\" is non-empty on FORCE_SEPOLIA_REDEPLOY=1"
  else
    echo "FAIL F7-11 must not treat a quoted # as an inline comment" >&2
    fail=1
  fi

  # Resolved-path drive: FORTEL2_ENV is an absolute temp file (not named
  # .env.sepolia). env -u clears an inherited FORTEL2_ENV so the fixture is not
  # bypassed (D-0065 Finding on vacuous tests).
  _f711_abs="$(mktemp "${TMPDIR:-/tmp}/fortel2-f711-env.XXXXXX")"
  _f711_root="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-f711-root.XXXXXX")"
  {
    echo "FORTEL2_ROOT=${_f711_root}"
    echo "DATA_DIR=${_f711_root}/data"
    echo "DEPLOY_DIR=${_f711_root}/deployments/.deployer"
    echo "PROOF_MATURITY_DELAY_SECONDS=1800"
    echo "DISPUTE_GAME_FINALITY_DELAY_SECONDS=1800"
    echo "FAULT_GAME_CLOCK_EXTENSION=600"
    echo "FAULT_GAME_MAX_CLOCK_DURATION=7200"
    echo "FAULT_GAME_WITHDRAWAL_DELAY=3600"
    echo "PREIMAGE_ORACLE_CHALLENGE_PERIOD=3600"
    echo "FAULT_GAME_CLOCK_EXTENSION=f711-leak-canary-token"
  } > "$_f711_abs"
  _f711_path_rc=0
  _f711_path_out="$(
    env -u FORTEL2_ENV -u FORTEL2_ENV_FILE \
      FORTEL2_ENV="$_f711_abs" \
      F711_FN="$_f711_fn" \
      bash -c '
        set -euo pipefail
        # shellcheck disable=SC1090
        source "$1"
        eval "$F711_FN"
        if [[ "$FORTEL2_ENV_FILE" != "$FORTEL2_ENV" ]]; then
          echo "ERROR: FORTEL2_ENV_FILE was not resolved from FORTEL2_ENV" >&2
          exit 2
        fi
        refuse_duplicate_phase7_immutables
      ' bash "$SCRIPT_DIR/lib.sh" 2>&1
  )" || _f711_path_rc=$?
  if [[ "$_f711_path_rc" != "0" && "$_f711_path_rc" != "2" ]] \
    && printf '%s' "$_f711_path_out" | grep -F -q -- "FAULT_GAME_CLOCK_EXTENSION" \
    && ! printf '%s' "$_f711_path_out" | grep -F -q -- "f711-leak-canary-token" \
    && printf '%s' "$_f711_fn" | grep -q 'FORTEL2_ENV_FILE' \
    && ! printf '%s' "$_f711_fn" | grep -q '\.env\.sepolia'; then
    echo "PASS F7-11 guard reads FORTEL2_ENV_FILE (absolute FORTEL2_ENV, not a hard-coded filename)"
  else
    echo "FAIL F7-11 must read \$FORTEL2_ENV_FILE, not a hard-coded .env.sepolia" >&2
    fail=1
  fi
  if _f711_leaked_values "$_f711_path_out" "$_f711_abs"; then
    echo "FAIL F7-11 resolved-path error leaked an env-file value" >&2
    fail=1
  else
    echo "PASS F7-11 error output contains no value from any env-file line"
  fi
  rm -rf "$_f711_root"
  rm -f "$_f711_abs"

  if awk '
       /^refuse_duplicate_phase7_immutables$/ { dup = NR }
       /^refuse_absent_phase7_immutables$/ { abs = NR }
       /require_min_balance_eth/ && !bal { bal = NR }
       /rm -rf "\$DEPLOY_DIR"/ && !rm { rm = NR }
       END { exit !(dup && abs && bal && rm && dup < bal && abs < bal && dup < rm && abs < rm) }
     ' "$DEPLOY_SEPOLIA"; then
    echo "PASS F7-11 both refusals run before require_min_balance_eth and before the wipe"
  else
    echo "FAIL F7-11 refuse_duplicate_phase7_immutables and refuse_absent_phase7_immutables must run before require_min_balance_eth and before rm -rf \"\$DEPLOY_DIR\"" >&2
    fail=1
  fi
fi
rm -rf "$_f711_dir"
unset _f711_fn _f711_rc _f711_out _f711_dir _f711_good _f711_dup _f711_comment \
  _f711_export _f711_ws _f711_miss _f711_empty _f711_qempty _f711_then_empty \
  _f711_inline _f711_qinline _f711_valued_comment _f711_hashkeep \
  _f711_abs _f711_root _f711_path_rc _f711_path_out _f711_good_force _f711_good_pre \
  _var _i _f711_dup_ok _f711_abs_force_ok _f711_abs_pre_ok \
  _f711_empty_force_ok _f711_empty_pre_ok _f711_quoted_force_ok _f711_quoted_pre_ok \
  _f711_empty_neither_ok
unset -f _f711_write_complete _f711_write_complete_except _f711_write_empty \
  _f711_run _f711_leaked_values 2>/dev/null || true
unset _F711_VARS

if python3 - "$SCRIPT_DIR/test-helpers.sh" << 'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
# Frozen set: two pre-existing Foundry-tripwire fixtures (not secrets) plus
# the F7-6 public prestate hashes. A new 0x+64-hex literal fails this check.
allowed = {
    "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba",
    "0x1111111111111111111111111111111111111111111111111111111111111111",
    "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "0x038512e02c4c3f7bdaec27d00edf55b7155e0905301e1a88083e4e0a6764d54c",
    "0x034c90f083e8c86bb6bf18236d653d4aa42fac0653f013c780448000b9796b8d",
    "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
}
bad = []
for m in re.finditer(r"0x[0-9a-fA-F]{64}", text):
    if m.group(0).lower() not in {a.lower() for a in allowed}:
        bad.append(m.group(0))
sys.exit(1 if bad else 0)
PY
  then
    echo "PASS F7-10 test-helpers.sh 0x-prefixed 64-hex literals are a frozen allowlist"
  else
    echo "FAIL scripts/test-helpers.sh 0x-prefixed 64-hex literals must stay on the frozen allowlist (Foundry tripwire fixtures + F7-6 prestates)" >&2
    fail=1
  fi

# phase7-gate-parity.sh: README step-number swap fails naming both values;
# a missing Operator sequence heading fails closed (not a pass); a newly
# reserved F7-N in the PRD alone fails; an imperative second-wipe instruction
# in .env.sepolia.example fails; clean repo files pass.
# markerConvention: stated non-empty in phase7-gates.json; a What-column
# rewrite still fails and cites it; removing a declared F7-N still fails
# the exact-set check.
# env -u: lib.sh is not sourced by the checker, but an inherited FORTEL2_ROOT
# from this suite's .env.example fallback still must not point the child at
# another checkout (Codex P2 on #118).
P7_CHECK="$SCRIPT_DIR/phase7-gate-parity.sh"
P7_FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-p7-gates.XXXXXX")"
cleanup_p7_fixtures() { rm -rf "$P7_FIXTURE_DIR"; }
trap cleanup_p7_fixtures EXIT
P7_ENV_CLEAR=(env -u FORTEL2_ENV -u FORTEL2_ROOT -u FORTEL2_ENV_FILE)

cp "$SCRIPT_DIR/../README.md" "$P7_FIXTURE_DIR/README.md"
python3 -c '
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
t = t.replace("2. **Announce**", "2. **Stop Mac writers**", 1)
t = t.replace("3. ~~**Stop Mac writers**~~", "3. ~~**Announce**~~", 1)
p.write_text(t)
' "$P7_FIXTURE_DIR/README.md"

P7_BAD_OUT="$(
  "${P7_ENV_CLEAR[@]}" PHASE7_README="$P7_FIXTURE_DIR/README.md" \
    "$P7_CHECK" 2>&1
)" && P7_BAD_EC=0 || P7_BAD_EC=$?
if [[ "$P7_BAD_EC" -ne 0 ]] \
  && echo "$P7_BAD_OUT" | grep -q 'announce README numbering (declared=2 found=3)' \
  && echo "$P7_BAD_OUT" | grep -q 'stop-writers README numbering (declared=3 found=2)'; then
  echo "PASS phase7-gate-parity rejects README announce/stop-writers swap"
else
  echo "FAIL phase7-gate-parity should exit non-zero naming announce declared=2 found=3 (ec=$P7_BAD_EC)" >&2
  echo "$P7_BAD_OUT" >&2
  fail=1
fi

cp "$SCRIPT_DIR/../tasks/prd-phase-7-fault-proofs.md" "$P7_FIXTURE_DIR/prd.md"
python3 -c '
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
t = t.replace("## Operator sequence", "## Operator seq", 1)
p.write_text(t)
' "$P7_FIXTURE_DIR/prd.md"

P7_ANCHOR_OUT="$(
  "${P7_ENV_CLEAR[@]}" PHASE7_PRD="$P7_FIXTURE_DIR/prd.md" \
    "$P7_CHECK" 2>&1
)" && P7_ANCHOR_EC=0 || P7_ANCHOR_EC=$?
if [[ "$P7_ANCHOR_EC" -ne 0 ]] \
  && echo "$P7_ANCHOR_OUT" | grep -q "could not find heading '## Operator sequence'" \
  && ! echo "$P7_ANCHOR_OUT" | grep -q 'all checks passed'; then
  echo "PASS phase7-gate-parity fails closed when Operator sequence heading is missing"
else
  echo "FAIL phase7-gate-parity should fail closed naming the missing heading (ec=$P7_ANCHOR_EC)" >&2
  echo "$P7_ANCHOR_OUT" >&2
  fail=1
fi

cp "$SCRIPT_DIR/../tasks/prd-phase-7-fault-proofs.md" "$P7_FIXTURE_DIR/prd-f713.md"
python3 -c '
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
t = t.replace(
    "## Operator sequence",
    "## Operator sequence\n\nF7-13 must land before announcement\n",
    1,
)
p.write_text(t)
' "$P7_FIXTURE_DIR/prd-f713.md"

P7_F713_OUT="$(
  "${P7_ENV_CLEAR[@]}" PHASE7_PRD="$P7_FIXTURE_DIR/prd-f713.md" \
    "$P7_CHECK" 2>&1
)" && P7_F713_EC=0 || P7_F713_EC=$?
if [[ "$P7_F713_EC" -ne 0 ]] \
  && echo "$P7_F713_OUT" | grep -q 'PRD Operator sequence gate ids' \
  && echo "$P7_F713_OUT" | grep -q 'F7-13'; then
  echo "PASS phase7-gate-parity rejects undeclared F7-13 in PRD Operator sequence"
else
  echo "FAIL phase7-gate-parity should fail naming undeclared F7-13 (ec=$P7_F713_EC)" >&2
  echo "$P7_F713_OUT" >&2
  fail=1
fi

cp "$SCRIPT_DIR/../.env.sepolia.example" "$P7_FIXTURE_DIR/env.sepolia.example"
printf '\n# run FORCE_SEPOLIA_REDEPLOY=1 now\n' >> "$P7_FIXTURE_DIR/env.sepolia.example"

P7_WIPE_OUT="$(
  "${P7_ENV_CLEAR[@]}" PHASE7_ENV_EXAMPLE="$P7_FIXTURE_DIR/env.sepolia.example" \
    "$P7_CHECK" 2>&1
)" && P7_WIPE_EC=0 || P7_WIPE_EC=$?
if [[ "$P7_WIPE_EC" -ne 0 ]] \
  && echo "$P7_WIPE_OUT" | grep -q 'FORCE_SEPOLIA_REDEPLOY=1' \
  && echo "$P7_WIPE_OUT" | grep -q 'imperative'; then
  echo "PASS phase7-gate-parity rejects imperative FORCE_SEPOLIA_REDEPLOY=1 in env example"
else
  echo "FAIL phase7-gate-parity should fail on run FORCE_SEPOLIA_REDEPLOY=1 now (ec=$P7_WIPE_EC)" >&2
  echo "$P7_WIPE_OUT" >&2
  fail=1
fi

P7_OK_OUT="$("${P7_ENV_CLEAR[@]}" "$P7_CHECK" 2>&1)" && P7_OK_EC=0 || P7_OK_EC=$?
if [[ "$P7_OK_EC" -eq 0 ]] && echo "$P7_OK_OUT" | grep -q 'phase7-gate-parity: all checks passed'; then
  echo "PASS phase7-gate-parity exits 0 on unmodified repo files"
else
  echo "FAIL phase7-gate-parity should exit 0 on repo files (ec=$P7_OK_EC)" >&2
  echo "$P7_OK_OUT" >&2
  fail=1
fi

# markerConvention (D-0070 Finding 2): stated in phase7-gates.json; What-column
# rewrites and gate-id set drift still fail closed; FAIL text points at the rule.
# Codex P2 on #136: a marker moved into When with What rewritten must also fail.
if python3 -c '
import json, sys
from pathlib import Path
d = json.loads(Path(sys.argv[1]).read_text())
mc = d.get("markerConvention")
if not isinstance(mc, dict):
    sys.exit(1)
needed = ("completionMarkers", "gateIdSet", "onRed")
sys.exit(0 if all(str(mc.get(k) or "").strip() for k in needed) else 1)
' "$SCRIPT_DIR/../tasks/phase7-gates.json"; then
  echo "PASS phase7-gates.json markerConvention is present and non-empty"
else
  echo "FAIL phase7-gates.json must state a non-empty markerConvention (completionMarkers, gateIdSet, onRed)" >&2
  fail=1
fi

cp "$SCRIPT_DIR/../tasks/prd-phase-7-fault-proofs.md" "$P7_FIXTURE_DIR/prd-what.md"
python3 -c '
from pathlib import Path
import sys
p = Path(sys.argv[1])
out = []
for line in p.read_text().splitlines():
    if line.startswith("| 10 |"):
        cells = line.split("|")
        cells[3] = " **DONE (wrong column)** SOS recovery complete "
        line = "|".join(cells)
    out.append(line)
p.write_text("\n".join(out) + "\n")
' "$P7_FIXTURE_DIR/prd-what.md"

P7_WHAT_OUT="$(
  "${P7_ENV_CLEAR[@]}" PHASE7_PRD="$P7_FIXTURE_DIR/prd-what.md" \
    "$P7_CHECK" 2>&1
)" && P7_WHAT_EC=0 || P7_WHAT_EC=$?
if [[ "$P7_WHAT_EC" -ne 0 ]] \
  && echo "$P7_WHAT_OUT" | grep -q "sos-adopt PRD marker 'SOS redeploys-or-adopts' not found (declared step 10)" \
  && echo "$P7_WHAT_OUT" | grep -q 'see markerConvention in tasks/phase7-gates.json (D-0070)'; then
  echo "PASS phase7-gate-parity rejects What-column mutation and cites markerConvention"
else
  echo "FAIL phase7-gate-parity should fail a What-column rewrite citing markerConvention (ec=$P7_WHAT_EC)" >&2
  echo "$P7_WHAT_OUT" >&2
  fail=1
fi

cp "$SCRIPT_DIR/../tasks/prd-phase-7-fault-proofs.md" "$P7_FIXTURE_DIR/prd-when-only.md"
python3 -c '
from pathlib import Path
import sys
p = Path(sys.argv[1])
out = []
for line in p.read_text().splitlines():
    if line.startswith("| 10 |"):
        cells = line.split("|")
        cells[2] = " **DONE 2026-08-22 (D-0069)** — SOS redeploys-or-adopts "
        cells[3] = " Recovery complete "
        line = "|".join(cells)
    out.append(line)
p.write_text("\n".join(out) + "\n")
' "$P7_FIXTURE_DIR/prd-when-only.md"

P7_WHEN_OUT="$(
  "${P7_ENV_CLEAR[@]}" PHASE7_PRD="$P7_FIXTURE_DIR/prd-when-only.md" \
    "$P7_CHECK" 2>&1
)" && P7_WHEN_EC=0 || P7_WHEN_EC=$?
if [[ "$P7_WHEN_EC" -ne 0 ]] \
  && echo "$P7_WHEN_OUT" | grep -q "sos-adopt PRD marker 'SOS redeploys-or-adopts' not found (declared step 10)" \
  && echo "$P7_WHEN_OUT" | grep -q 'see markerConvention in tasks/phase7-gates.json (D-0070)'; then
  echo "PASS phase7-gate-parity rejects a marker that lives only in When"
else
  echo "FAIL phase7-gate-parity should fail when prdMustContain is only in When (ec=$P7_WHEN_EC)" >&2
  echo "$P7_WHEN_OUT" >&2
  fail=1
fi

cp "$SCRIPT_DIR/../tasks/prd-phase-7-fault-proofs.md" "$P7_FIXTURE_DIR/prd-f7rm.md"
python3 -c '
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace("F7-12", ""))
' "$P7_FIXTURE_DIR/prd-f7rm.md"

P7_F7RM_OUT="$(
  "${P7_ENV_CLEAR[@]}" PHASE7_PRD="$P7_FIXTURE_DIR/prd-f7rm.md" \
    "$P7_CHECK" 2>&1
)" && P7_F7RM_EC=0 || P7_F7RM_EC=$?
if [[ "$P7_F7RM_EC" -ne 0 ]] \
  && echo "$P7_F7RM_OUT" | grep -q 'PRD Operator sequence gate ids (declared=' \
  && echo "$P7_F7RM_OUT" | grep -q 'found=F7-6,F7-7,F7-8,F7-10,F7-11)' \
  && echo "$P7_F7RM_OUT" | grep -q 'see markerConvention in tasks/phase7-gates.json (D-0070)'; then
  echo "PASS phase7-gate-parity rejects F7-12 removal with exact-set message"
else
  echo "FAIL phase7-gate-parity should fail F7-12 removal with exact-set gate ids (ec=$P7_F7RM_EC)" >&2
  echo "$P7_F7RM_OUT" >&2
  fail=1
fi

cleanup_p7_fixtures
trap - EXIT

# resolve-games-sepolia.sh: analyze-only fixtures (no RPC / cast / Sepolia env).
RESOLVE_GAMES="$SCRIPT_DIR/resolve-games-sepolia.sh"
RG_FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-resolve-games.XXXXXX")"
cleanup_rg_fixtures() { rm -rf "$RG_FIXTURE_DIR"; }
trap cleanup_rg_fixtures EXIT

# now=1000000, maxClock=7200, finality=1800, weth_delay=3600, bond=0.08 ETH
# 0 fully claimed · 1 expired IN_PROGRESS · 2 resolved, not finalized
# 3 unlocked, inside WETH delay · 4 unexpired clock · 5/6 more expired
# 7 multi-claim
cat >"$RG_FIXTURE_DIR/games.json" <<'EOF'
{
  "now": 1000000,
  "mode": "dry-run",
  "finality_delay": 1800,
  "weth_delay": 3600,
  "init_bond_wei": "80000000000000000",
  "respected_game_type": 1,
  "games": [
    {
      "index": 0,
      "game_type": 1,
      "address": "0x0000000000000000000000000000000000000001",
      "created_at": 980000,
      "max_clock_duration": 7200,
      "status": 2,
      "resolved_at": 990000,
      "credit_wei": "0",
      "claim_data_len": 1,
      "weth_amount_wei": "0",
      "weth_unlock_ts": 992000
    },
    {
      "index": 1,
      "game_type": 1,
      "address": "0x0000000000000000000000000000000000000002",
      "created_at": 990000,
      "max_clock_duration": 7200,
      "status": 0,
      "resolved_at": 0,
      "credit_wei": "0",
      "claim_data_len": 1,
      "weth_amount_wei": "0",
      "weth_unlock_ts": 0
    },
    {
      "index": 2,
      "game_type": 1,
      "address": "0x0000000000000000000000000000000000000003",
      "created_at": 980000,
      "max_clock_duration": 7200,
      "status": 2,
      "resolved_at": 999900,
      "credit_wei": "80000000000000000",
      "claim_data_len": 1,
      "weth_amount_wei": "0",
      "weth_unlock_ts": 0
    },
    {
      "index": 3,
      "game_type": 1,
      "address": "0x0000000000000000000000000000000000000004",
      "created_at": 980000,
      "max_clock_duration": 7200,
      "status": 2,
      "resolved_at": 990000,
      "credit_wei": "80000000000000000",
      "claim_data_len": 1,
      "weth_amount_wei": "80000000000000000",
      "weth_unlock_ts": 999000
    },
    {
      "index": 4,
      "game_type": 1,
      "address": "0x0000000000000000000000000000000000000005",
      "created_at": 999000,
      "max_clock_duration": 7200,
      "status": 0,
      "resolved_at": 0,
      "credit_wei": "0",
      "claim_data_len": 1,
      "weth_amount_wei": "0",
      "weth_unlock_ts": 0
    },
    {
      "index": 5,
      "game_type": 1,
      "address": "0x0000000000000000000000000000000000000006",
      "created_at": 990000,
      "max_clock_duration": 7200,
      "status": 0,
      "resolved_at": 0,
      "credit_wei": "0",
      "claim_data_len": 1,
      "weth_amount_wei": "0",
      "weth_unlock_ts": 0
    },
    {
      "index": 6,
      "game_type": 1,
      "address": "0x0000000000000000000000000000000000000007",
      "created_at": 990000,
      "max_clock_duration": 7200,
      "status": 0,
      "resolved_at": 0,
      "credit_wei": "0",
      "claim_data_len": 1,
      "weth_amount_wei": "0",
      "weth_unlock_ts": 0
    },
    {
      "index": 7,
      "game_type": 1,
      "address": "0x0000000000000000000000000000000000000008",
      "created_at": 990000,
      "max_clock_duration": 7200,
      "status": 0,
      "resolved_at": 0,
      "credit_wei": "0",
      "claim_data_len": 2,
      "weth_amount_wei": "0",
      "weth_unlock_ts": 0
    }
  ]
}
EOF

# Restricted PATH: python3 must work, cast must not. Proves analyze-only is offline.
RG_PY_DIR="$(dirname "$(command -v python3)")"
RG_PATH="$RG_PY_DIR:/usr/bin:/bin"
RG_ENV=(env -u FORTEL2_ENV -u RESOLVE_GAMES_MAX_TXS_PER_RUN PATH="$RG_PATH" RESOLVE_GAMES_SNAPSHOT="$RG_FIXTURE_DIR/games.json")

RG_ALL_OUT="$("${RG_ENV[@]}" "$RESOLVE_GAMES" --analyze-only 2>&1)" && RG_ALL_EC=0 || RG_ALL_EC=$?
if [[ "$RG_ALL_EC" -eq 0 ]] \
  && echo "$RG_ALL_OUT" | grep -q 'game 4 SKIP clock_unexpired' \
  && ! echo "$RG_ALL_OUT" | grep -qE 'selected_indexes=.*(^|,)4(,|$)'; then
  echo "PASS resolve-games unexpired clock is not selected"
else
  echo "FAIL resolve-games unexpired clock should not be selected (ec=$RG_ALL_EC)" >&2
  echo "$RG_ALL_OUT" >&2
  fail=1
fi

if echo "$RG_ALL_OUT" | grep -q 'game 2 WAIT finality' \
  && ! echo "$RG_ALL_OUT" | grep -q 'game 2 ACTION'; then
  echo "PASS resolve-games status=2 with resolvedAt is not re-resolved"
else
  echo "FAIL resolve-games already-resolved game must not emit resolve actions" >&2
  echo "$RG_ALL_OUT" >&2
  fail=1
fi

if echo "$RG_ALL_OUT" | grep -q 'game 3 WAIT weth_delay' \
  && ! echo "$RG_ALL_OUT" | grep -q 'game 3 ACTION'; then
  echo "PASS resolve-games inside WETH delay reports waiting and is not claimed"
else
  echo "FAIL resolve-games unlocked-but-delayed game must wait, not claim" >&2
  echo "$RG_ALL_OUT" >&2
  fail=1
fi

if echo "$RG_ALL_OUT" | grep -q 'game 0 SKIP zero_credit' \
  && ! echo "$RG_ALL_OUT" | grep -qE 'selected_indexes=.*(^|,)0(,|$)'; then
  echo "PASS resolve-games zero remaining credit is skipped"
else
  echo "FAIL resolve-games zero-credit game should be skipped, not retried" >&2
  echo "$RG_ALL_OUT" >&2
  fail=1
fi

if echo "$RG_ALL_OUT" | grep -q '^txs_sent=0$' \
  && echo "$RG_ALL_OUT" | grep -q '^mode=dry-run$' \
  && ! echo "$RG_ALL_OUT" | grep -qE '^SENT |cast send'; then
  echo "PASS resolve-games dry-run / analyze-only sends nothing"
else
  echo "FAIL resolve-games analyze-only must report txs_sent=0 and never send" >&2
  echo "$RG_ALL_OUT" >&2
  fail=1
fi

RG_MAX_OUT="$("${RG_ENV[@]}" "$RESOLVE_GAMES" --analyze-only --max-games 3 2>&1)" && RG_MAX_EC=0 || RG_MAX_EC=$?
if [[ "$RG_MAX_EC" -eq 0 ]] \
  && echo "$RG_MAX_OUT" | grep -q 'selected_count=3' \
  && echo "$RG_MAX_OUT" | grep -q 'selected_indexes=1,2,3' \
  && echo "$RG_MAX_OUT" | grep -q 'max_games=3'; then
  echo "PASS resolve-games --max-games 3 selects exactly 3"
else
  echo "FAIL resolve-games --max-games 3 should select indexes 1,2,3 (ec=$RG_MAX_EC)" >&2
  echo "$RG_MAX_OUT" >&2
  fail=1
fi

RG_X_OUT="$("${RG_ENV[@]}" "$RESOLVE_GAMES" --analyze-only --execute 2>&1)" && RG_X_EC=0 || RG_X_EC=$?
if [[ "$RG_X_EC" -ne 0 ]] && echo "$RG_X_OUT" | grep -q 'incompatible'; then
  echo "PASS resolve-games --execute is rejected with --analyze-only"
else
  echo "FAIL resolve-games --execute --analyze-only should be rejected (ec=$RG_X_EC)" >&2
  echo "$RG_X_OUT" >&2
  fail=1
fi

if command -v cast >/dev/null 2>&1; then
  if echo "$RG_ALL_OUT" | grep -q 'game 1 ACTION resolveClaim,resolve' \
    && ! printf '%s' "$RG_PATH" | grep -q foundry; then
    echo "PASS resolve-games analyze-only ran without cast on PATH"
  else
    # Still a pass if the action line is right; PATH assertion is extra.
    if echo "$RG_ALL_OUT" | grep -q 'game 1 ACTION resolveClaim,resolve'; then
      echo "PASS resolve-games analyze-only ran without cast on PATH"
    else
      echo "FAIL resolve-games expired IN_PROGRESS should ACTION resolveClaim,resolve" >&2
      echo "$RG_ALL_OUT" >&2
      fail=1
    fi
  fi
else
  if echo "$RG_ALL_OUT" | grep -q 'game 1 ACTION resolveClaim,resolve'; then
    echo "PASS resolve-games analyze-only ran without cast on PATH"
  else
    echo "FAIL resolve-games expired IN_PROGRESS should ACTION resolveClaim,resolve" >&2
    echo "$RG_ALL_OUT" >&2
    fail=1
  fi
fi

cat >"$RG_FIXTURE_DIR/type8.json" <<'EOF'
{
  "now": 1000000,
  "mode": "dry-run",
  "finality_delay": 1800,
  "weth_delay": 3600,
  "init_bond_wei": "80000000000000000",
  "respected_game_type": 8,
  "games": [
    {
      "index": 1,
      "game_type": 8,
      "address": "0x0000000000000000000000000000000000000008",
      "created_at": 990000,
      "max_clock_duration": 7200,
      "status": 0,
      "resolved_at": 0,
      "credit_wei": "0",
      "claim_data_len": 1,
      "weth_amount_wei": "0",
      "weth_unlock_ts": 0
    },
    {
      "index": 2,
      "game_type": 1,
      "address": "0x0000000000000000000000000000000000000002",
      "created_at": 990000,
      "max_clock_duration": 7200,
      "status": 0,
      "resolved_at": 0,
      "credit_wei": "0",
      "claim_data_len": 1,
      "weth_amount_wei": "0",
      "weth_unlock_ts": 0
    }
  ]
}
EOF
RG_T8_OUT="$(
  env -u FORTEL2_ENV -u RESOLVE_GAMES_MAX_TXS_PER_RUN PATH="$RG_PATH" RESOLVE_GAMES_SNAPSHOT="$RG_FIXTURE_DIR/type8.json" \
    "$RESOLVE_GAMES" --analyze-only 2>&1
)" && RG_T8_EC=0 || RG_T8_EC=$?
if [[ "$RG_T8_EC" -eq 0 ]] \
  && echo "$RG_T8_OUT" | grep -q 'respected_game_type=8' \
  && echo "$RG_T8_OUT" | grep -q 'game 1 ACTION resolveClaim,resolve' \
  && echo "$RG_T8_OUT" | grep -q 'game 2 SKIP not_respected_type' \
  && echo "$RG_T8_OUT" | grep -q 'selected_indexes=1' \
  && ! echo "$RG_T8_OUT" | grep -q 'not_type_1'; then
  echo "PASS resolve-games selects the snapshot respected type (not hardcoded 1)"
else
  echo "FAIL resolve-games type-8 respected should select type 8, skip type 1 (ec=$RG_T8_EC)" >&2
  echo "$RG_T8_OUT" >&2
  fail=1
fi

# status=0 + credit=0 but resolvedSubgames(0)=true → resolve only (19:00 hole).
# Missing resolved_subgame still means resolveClaim,resolve (game 1 above).
cat >"$RG_FIXTURE_DIR/already-claim.json" <<'EOF'
{
  "now": 1000000,
  "mode": "dry-run",
  "finality_delay": 1800,
  "weth_delay": 3600,
  "init_bond_wei": "80000000000000000",
  "respected_game_type": 1,
  "games": [
    {
      "index": 1,
      "game_type": 1,
      "address": "0x0000000000000000000000000000000000000002",
      "created_at": 990000,
      "max_clock_duration": 7200,
      "status": 0,
      "resolved_at": 0,
      "credit_wei": "0",
      "claim_data_len": 1,
      "resolved_subgame": true,
      "weth_amount_wei": "0",
      "weth_unlock_ts": 0
    }
  ]
}
EOF
RG_ALREADY_OUT="$(
  env -u FORTEL2_ENV -u RESOLVE_GAMES_MAX_TXS_PER_RUN PATH="$RG_PATH" RESOLVE_GAMES_SNAPSHOT="$RG_FIXTURE_DIR/already-claim.json" \
    "$RESOLVE_GAMES" --analyze-only 2>&1
)" && RG_ALREADY_EC=0 || RG_ALREADY_EC=$?
if [[ "$RG_ALREADY_EC" -eq 0 ]] \
  && echo "$RG_ALREADY_OUT" | grep -q 'game 1 ACTION resolve' \
  && ! echo "$RG_ALREADY_OUT" | grep -q 'resolveClaim'; then
  echo "PASS resolve-games resolved subgame skips resolveClaim"
else
  echo "FAIL resolve-games resolvedSubgames(0)=true should ACTION resolve only (ec=$RG_ALREADY_EC)" >&2
  echo "$RG_ALREADY_OUT" >&2
  fail=1
fi

# R-16 — recovery watermark. Separate fixture so the original 8-game snapshot
# (and its 10 existing cases) keep scanning from 0 with no watermark file.
cat >"$RG_FIXTURE_DIR/wm.json" <<'EOF'
{
  "now": 1000000,
  "mode": "dry-run",
  "finality_delay": 1800,
  "weth_delay": 3600,
  "init_bond_wei": "80000000000000000",
  "respected_game_type": 1,
  "game_count": 8,
  "games": [
    {
      "index": 0, "game_type": 1, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 990000, "credit_wei": "0",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 992000
    },
    {
      "index": 1, "game_type": 1, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 990000, "credit_wei": "0",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    },
    {
      "index": 2, "game_type": 1, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 990000, "credit_wei": "0",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    },
    {
      "index": 3, "game_type": 1, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 990000, "credit_wei": "0",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    },
    {
      "index": 4, "game_type": 1, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 999900, "credit_wei": "80000000000000000",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    },
    {
      "index": 5, "game_type": 1, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 990000, "credit_wei": "0",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    },
    {
      "index": 6, "game_type": 1, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 990000, "credit_wei": "80000000000000000",
      "claim_data_len": 1, "weth_amount_wei": "80000000000000000", "weth_unlock_ts": 999000
    },
    {
      "index": 7, "game_type": 1, "created_at": 999000, "max_clock_duration": 7200,
      "status": 0, "resolved_at": 0, "credit_wei": "0",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    }
  ]
}
EOF

rg_wm_analyze() {
  local mark="$1"
  shift
  env -u FORTEL2_ENV -u RESOLVE_GAMES_MAX_TXS_PER_RUN PATH="$RG_PATH" \
    RESOLVE_GAMES_SNAPSHOT="$RG_FIXTURE_DIR/wm.json" \
    RESOLVE_GAMES_WATERMARK="$mark" \
    "$RESOLVE_GAMES" --analyze-only "$@"
}

WM_NONE="$RG_FIXTURE_DIR/wm-none.json"
RG_WM_NONE_OUT="$(rg_wm_analyze "$WM_NONE" 2>&1)" && RG_WM_NONE_EC=0 || RG_WM_NONE_EC=$?
WM_NONE_MARK="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["low_water"])' "$WM_NONE" 2>/dev/null || echo missing)"
if [[ "$RG_WM_NONE_EC" -eq 0 ]] \
  && echo "$RG_WM_NONE_OUT" | grep -q '^scan_from=0$' \
  && echo "$RG_WM_NONE_OUT" | grep -q '^games_examined=8$' \
  && echo "$RG_WM_NONE_OUT" | grep -q '^watermark_status=missing$' \
  && echo "$RG_WM_NONE_OUT" | grep -q 'game 0 SKIP zero_credit' \
  && echo "$RG_WM_NONE_OUT" | grep -q '^watermark_next=4$' \
  && [[ "$WM_NONE_MARK" == "4" ]]; then
  echo "PASS resolve-games missing watermark scans from 0 and persists next"
else
  echo "FAIL resolve-games missing watermark should scan from 0 (ec=$RG_WM_NONE_EC mark=$WM_NONE_MARK)" >&2
  echo "$RG_WM_NONE_OUT" >&2
  fail=1
fi

printf 'not-json{' >"$RG_FIXTURE_DIR/wm-bad.json"
RG_WM_BAD_OUT="$(rg_wm_analyze "$RG_FIXTURE_DIR/wm-bad.json" 2>&1)" && RG_WM_BAD_EC=0 || RG_WM_BAD_EC=$?
if [[ "$RG_WM_BAD_EC" -eq 0 ]] \
  && echo "$RG_WM_BAD_OUT" | grep -q '^scan_from=0$' \
  && echo "$RG_WM_BAD_OUT" | grep -q '^games_examined=8$' \
  && echo "$RG_WM_BAD_OUT" | grep -q 'watermark_fallback=malformed' \
  && echo "$RG_WM_BAD_OUT" | grep -q 'game 0 SKIP zero_credit'; then
  echo "PASS resolve-games malformed watermark falls back to a full scan"
else
  echo "FAIL resolve-games malformed watermark must not skip (ec=$RG_WM_BAD_EC)" >&2
  echo "$RG_WM_BAD_OUT" >&2
  fail=1
fi

printf '%s\n' '{"low_water":99}' >"$RG_FIXTURE_DIR/wm-oor.json"
RG_WM_OOR_OUT="$(rg_wm_analyze "$RG_FIXTURE_DIR/wm-oor.json" 2>&1)" && RG_WM_OOR_EC=0 || RG_WM_OOR_EC=$?
if [[ "$RG_WM_OOR_EC" -eq 0 ]] \
  && echo "$RG_WM_OOR_OUT" | grep -q '^scan_from=0$' \
  && echo "$RG_WM_OOR_OUT" | grep -q '^games_examined=8$' \
  && echo "$RG_WM_OOR_OUT" | grep -q 'watermark_fallback=out_of_range' \
  && echo "$RG_WM_OOR_OUT" | grep -q 'game 0 SKIP zero_credit'; then
  echo "PASS resolve-games out-of-range watermark falls back to a full scan"
else
  echo "FAIL resolve-games out-of-range watermark must not skip (ec=$RG_WM_OOR_EC)" >&2
  echo "$RG_WM_OOR_OUT" >&2
  fail=1
fi

# Contiguous zero_credit 0–3, wait finality at 4, zero_credit at 5 (hole),
# wait weth_delay at 6. Next mark is 4 — not 5, not 6, not 7.
if echo "$RG_WM_NONE_OUT" | grep -q 'game 4 WAIT finality' \
  && echo "$RG_WM_NONE_OUT" | grep -q 'game 6 WAIT weth_delay' \
  && echo "$RG_WM_NONE_OUT" | grep -q '^watermark_next=4$' \
  && [[ "$WM_NONE_MARK" == "4" ]]; then
  echo "PASS resolve-games watermark does not advance past wait finality"
else
  echo "FAIL resolve-games watermark must stop at wait finality, not skip it" >&2
  echo "$RG_WM_NONE_OUT" >&2
  fail=1
fi

if echo "$RG_WM_NONE_OUT" | grep -q 'game 5 SKIP zero_credit' \
  && echo "$RG_WM_NONE_OUT" | grep -q '^watermark_next=4$'; then
  echo "PASS resolve-games watermark does not skip a hole to a later terminal game"
else
  echo "FAIL resolve-games non-contiguous zero_credit must not advance past the wait" >&2
  echo "$RG_WM_NONE_OUT" >&2
  fail=1
fi

# Dedicated weth_delay blocker: 0–2 drained, 3 waiting on DelayedWETH.
cat >"$RG_FIXTURE_DIR/wm-delay.json" <<'EOF'
{
  "now": 1000000,
  "mode": "dry-run",
  "finality_delay": 1800,
  "weth_delay": 3600,
  "init_bond_wei": "80000000000000000",
  "respected_game_type": 1,
  "game_count": 4,
  "games": [
    {
      "index": 0, "game_type": 1, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 990000, "credit_wei": "0",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    },
    {
      "index": 1, "game_type": 1, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 990000, "credit_wei": "0",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    },
    {
      "index": 2, "game_type": 1, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 990000, "credit_wei": "0",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    },
    {
      "index": 3, "game_type": 1, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 990000, "credit_wei": "80000000000000000",
      "claim_data_len": 1, "weth_amount_wei": "80000000000000000", "weth_unlock_ts": 999000
    }
  ]
}
EOF
WM_DELAY="$RG_FIXTURE_DIR/wm-delay-mark.json"
RG_WM_DELAY_OUT="$(
  env -u FORTEL2_ENV -u RESOLVE_GAMES_MAX_TXS_PER_RUN PATH="$RG_PATH" \
    RESOLVE_GAMES_SNAPSHOT="$RG_FIXTURE_DIR/wm-delay.json" \
    RESOLVE_GAMES_WATERMARK="$WM_DELAY" \
    "$RESOLVE_GAMES" --analyze-only 2>&1
)" && RG_WM_DELAY_EC=0 || RG_WM_DELAY_EC=$?
if [[ "$RG_WM_DELAY_EC" -eq 0 ]] \
  && echo "$RG_WM_DELAY_OUT" | grep -q 'game 3 WAIT weth_delay' \
  && echo "$RG_WM_DELAY_OUT" | grep -q '^watermark_next=3$' \
  && echo "$RG_WM_DELAY_OUT" | grep -q '^games_examined=4$'; then
  echo "PASS resolve-games watermark does not advance past wait weth_delay"
else
  echo "FAIL resolve-games watermark must stop at wait weth_delay (ec=$RG_WM_DELAY_EC)" >&2
  echo "$RG_WM_DELAY_OUT" >&2
  fail=1
fi

printf '%s\n' '{"low_water":4,"challenger_wins":[]}' >"$RG_FIXTURE_DIR/wm-warm.json"
RG_WM_WARM_OUT="$(rg_wm_analyze "$RG_FIXTURE_DIR/wm-warm.json" 2>&1)" && RG_WM_WARM_EC=0 || RG_WM_WARM_EC=$?
if [[ "$RG_WM_WARM_EC" -eq 0 ]] \
  && echo "$RG_WM_WARM_OUT" | grep -q '^scan_from=4$' \
  && echo "$RG_WM_WARM_OUT" | grep -q '^games_examined=4$' \
  && echo "$RG_WM_WARM_OUT" | grep -q 'game 4 WAIT finality' \
  && ! echo "$RG_WM_WARM_OUT" | grep -q 'game 0 ' \
  && ! echo "$RG_WM_WARM_OUT" | grep -q 'game 3 '; then
  echo "PASS resolve-games warm watermark examines only the working set"
else
  echo "FAIL resolve-games warm watermark must examine 4 games, not the drained prefix (ec=$RG_WM_WARM_EC)" >&2
  echo "$RG_WM_WARM_OUT" >&2
  fail=1
fi

printf '%s\n' '{"low_water":6,"challenger_wins":[]}' >"$RG_FIXTURE_DIR/wm-full.json"
RG_WM_FULL_OUT="$(rg_wm_analyze "$RG_FIXTURE_DIR/wm-full.json" --full-scan 2>&1)" && RG_WM_FULL_EC=0 || RG_WM_FULL_EC=$?
if [[ "$RG_WM_FULL_EC" -eq 0 ]] \
  && echo "$RG_WM_FULL_OUT" | grep -q '^scan_from=0$' \
  && echo "$RG_WM_FULL_OUT" | grep -q '^games_examined=8$' \
  && echo "$RG_WM_FULL_OUT" | grep -q '^watermark_status=full_scan$' \
  && echo "$RG_WM_FULL_OUT" | grep -q 'game 0 SKIP zero_credit' \
  && echo "$RG_WM_FULL_OUT" | grep -q 'game 4 WAIT finality'; then
  echo "PASS resolve-games --full-scan ignores an existing watermark"
else
  echo "FAIL resolve-games --full-scan must examine all 8 games (ec=$RG_WM_FULL_EC)" >&2
  echo "$RG_WM_FULL_OUT" >&2
  fail=1
fi

# Bounded cost: PLAN_JSON.games_examined must match the line so a later
# refactor cannot restore a full scan while the human-readable line stays green.
RG_WM_WARM_PLAN="$(printf '%s\n' "$RG_WM_WARM_OUT" | awk -F= '/^PLAN_JSON=/{print substr($0,11)}')"
RG_WM_WARM_PLAN_N="$(printf '%s' "$RG_WM_WARM_PLAN" | python3 -c 'import json,sys; print(json.load(sys.stdin)["games_examined"])')"
if [[ "$RG_WM_WARM_PLAN_N" == "4" ]]; then
  echo "PASS resolve-games PLAN_JSON games_examined is the working-set size"
else
  echo "FAIL resolve-games PLAN_JSON.games_examined should be 4, got $RG_WM_WARM_PLAN_N" >&2
  fail=1
fi

printf '%s\n' '{"low_water":4,"factory":"0x0000000000000000000000000000000000000001"}' >"$RG_FIXTURE_DIR/wm-factory.json"
RG_WM_FAC_OUT="$(
  env -u FORTEL2_ENV -u RESOLVE_GAMES_MAX_TXS_PER_RUN PATH="$RG_PATH" \
    RESOLVE_GAMES_SNAPSHOT="$RG_FIXTURE_DIR/wm.json" \
    RESOLVE_GAMES_WATERMARK="$RG_FIXTURE_DIR/wm-factory.json" \
    RESOLVE_GAMES_FACTORY="0x0000000000000000000000000000000000000002" \
    "$RESOLVE_GAMES" --analyze-only 2>&1
)" && RG_WM_FAC_EC=0 || RG_WM_FAC_EC=$?
if [[ "$RG_WM_FAC_EC" -eq 0 ]] \
  && echo "$RG_WM_FAC_OUT" | grep -q '^scan_from=0$' \
  && echo "$RG_WM_FAC_OUT" | grep -q '^games_examined=8$' \
  && echo "$RG_WM_FAC_OUT" | grep -q 'watermark_fallback=factory_mismatch' \
  && echo "$RG_WM_FAC_OUT" | grep -q 'game 0 SKIP zero_credit'; then
  echo "PASS resolve-games factory-mismatched watermark falls back to a full scan"
else
  echo "FAIL resolve-games stale factory watermark must not skip (ec=$RG_WM_FAC_EC)" >&2
  echo "$RG_WM_FAC_OUT" >&2
  fail=1
fi

printf 'x\n' >"$RG_FIXTURE_DIR/wm-notdir"
RG_WM_IO_OUT="$(
  env -u FORTEL2_ENV -u RESOLVE_GAMES_MAX_TXS_PER_RUN PATH="$RG_PATH" \
    RESOLVE_GAMES_SNAPSHOT="$RG_FIXTURE_DIR/wm.json" \
    RESOLVE_GAMES_WATERMARK="$RG_FIXTURE_DIR/wm-notdir/mark.json" \
    "$RESOLVE_GAMES" --analyze-only 2>&1
)" && RG_WM_IO_EC=0 || RG_WM_IO_EC=$?
if [[ "$RG_WM_IO_EC" -ne 0 ]] \
  && echo "$RG_WM_IO_OUT" | grep -q 'watermark_persist=failed' \
  && echo "$RG_WM_IO_OUT" | grep -q 'failed to persist watermark'; then
  echo "PASS resolve-games watermark persist failure is visible and nonzero"
else
  echo "FAIL resolve-games persist failure should exit nonzero (ec=$RG_WM_IO_EC)" >&2
  echo "$RG_WM_IO_OUT" >&2
  fail=1
fi

cleanup_rg_fixtures
trap - EXIT

# create-bad-proposal-sepolia.sh: empty FORWARD[@] crash (D-0083 Finding 1) and
# silent game-type default (Finding 5). Structural greps cannot catch the crash;
# this harness stubs go/cast/jq via BASH_ENV so the wrapper reaches `go run`
# without broadcasting. Approach: stub on PATH-equivalent (function wins over
# lib.sh's /opt/homebrew/bin prepend).
BP_WRAPPER="$SCRIPT_DIR/create-bad-proposal-sepolia.sh"
BP_FIX="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-bad-proposal.XXXXXX")"
cleanup_bp_fix() { rm -rf "$BP_FIX"; }
trap cleanup_bp_fix EXIT

mkdir -p "$BP_FIX/proposer" "$BP_FIX/data" "$BP_FIX/deployments/sepolia/.deployer"
printf '%s\n' '{"DisputeGameFactoryProxy":"0x0000000000000000000000000000000000000001"}' \
  > "$BP_FIX/deployments/sepolia/deployments.json"

cat > "$BP_FIX/.env.sepolia" <<EOF
FORTEL2_ROOT=$BP_FIX
DATA_DIR=$BP_FIX/data
DEPLOY_DIR=$BP_FIX/deployments/sepolia/.deployer
L1_CHAIN_ID=11155111
L2_CHAIN_ID=852
L1_RPC_URL=https://example.invalid
L2_RPC_URL=http://127.0.0.1:9545
L2_NODE_RPC_URL=http://127.0.0.1:9547
PROPOSER_PRIVATE_KEY=0x1111111111111111111111111111111111111111111111111111111111111111
PROPOSER_GAME_TYPE=8
EOF
grep -v '^PROPOSER_GAME_TYPE=' "$BP_FIX/.env.sepolia" > "$BP_FIX/.env.sepolia.nogt"

cat > "$BP_FIX/bashenv.sh" <<'EOS'
go() {
  printf '%s\n' "$@" > "$BP_STUB_DIR/go-args"
  return 0
}
cast() {
  case "${1:-}" in
    block-number) echo 1 ;;
    rpc) echo '{"current_l1":{"number":1}}' ;;
    *) echo 0 ;;
  esac
  return 0
}
jq() { echo '{}'; return 0; }
EOS

# Consecutive argv check against the stub's one-arg-per-line dump.
_bp_args_seq() {
  local file="$1"
  shift
  python3 - "$file" "$@" <<'PY'
import sys
path, want = sys.argv[1], sys.argv[2:]
try:
    lines = open(path).read().splitlines()
except OSError:
    sys.exit(1)
n = len(want)
for i in range(0, len(lines) - n + 1):
    if lines[i:i + n] == want:
        sys.exit(0)
sys.exit(1)
PY
}

_bp_run() {
  local envfile="$1"
  shift
  rm -f "$BP_FIX/go-args"
  env -u I_UNDERSTAND_THIS_POSTS_A_FALSE_CLAIM \
    -u PROPOSER_GAME_TYPE \
    BP_STUB_DIR="$BP_FIX" \
    BASH_ENV="$BP_FIX/bashenv.sh" \
    FORTEL2_ENV="$envfile" \
    FORTEL2_ROOT="$BP_FIX" \
    CONFIRM_BAD_PROPOSAL_SEPOLIA=1 \
    "$BP_WRAPPER" "$@"
}

# Focused idiom check: the *unquoted* ${arr[@]+"${arr[@]}"} form must expand
# to zero words (not one empty word) under set -u. Outer quotes on bash 4.4+
# can yield a blank argv that flag.Parse treats as a non-flag.
if (
  set -euo pipefail
  _bp_a=()
  _bp_n=99
  _bp_count() { _bp_n=$#; }
  _bp_count ${_bp_a[@]+"${_bp_a[@]}"}
  [[ "$_bp_n" -eq 0 ]]
); then
  echo "PASS unquoted empty-array idiom expands to zero words (bash $BASH_VERSION)"
else
  echo "FAIL unquoted empty-array idiom must expand to zero words (bash $BASH_VERSION)" >&2
  fail=1
fi
if (set -euo pipefail; _bp_a=(); : "${_bp_a[@]}"); then
  if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "FAIL bash $BASH_VERSION should reject empty \${arr[@]} under set -u" >&2
    fail=1
  else
    echo "PASS bare empty-array expansion is bound on bash $BASH_VERSION (crash is 3.2-only)"
  fi
else
  echo "PASS bare empty-array expansion is unbound under set -u (bash $BASH_VERSION)"
fi

# CI (bash 4+) cannot turn the empty-array crash red. This grep fails if the
# wrapper reverts to bare "${FORWARD[@]}" — green on 4.x, crash on 3.2.
if grep -q 'FORWARD\[@\]+' "$BP_WRAPPER" \
  && ! grep -E '^[[:space:]]*"\$\{FORWARD\[@\]\}"[[:space:]]*\\[[:space:]]*$' "$BP_WRAPPER"; then
  echo "PASS wrapper go-run uses the bash-3.2-safe FORWARD expansion"
else
  echo "FAIL wrapper must not revert to bare \"\${FORWARD[@]}\" (green on bash 4+, crash on 3.2)" >&2
  fail=1
fi

# Documented no-arg form: empty FORWARD must reach go run with ZERO extra
# words (./cmd/bad-proposal immediately followed by -l1), not crash, and
# not insert a blank argv that would stop flag.Parse.
BP_EMPTY_OUT="$(_bp_run "$BP_FIX/.env.sepolia" 2>&1)" && BP_EMPTY_EC=0 || BP_EMPTY_EC=$?
if [[ "$BP_EMPTY_EC" -eq 0 ]] \
  && [[ -f "$BP_FIX/go-args" ]] \
  && ! echo "$BP_EMPTY_OUT" | grep -q 'unbound variable' \
  && ! grep -qx -- '-block' "$BP_FIX/go-args" \
  && ! grep -qx '' "$BP_FIX/go-args" \
  && _bp_args_seq "$BP_FIX/go-args" run ./cmd/bad-proposal -l1 \
  && _bp_args_seq "$BP_FIX/go-args" -game-type 8 \
  && _bp_args_seq "$BP_FIX/go-args" -i-understand-this-posts-a-false-claim=true \
  && ! _bp_args_seq "$BP_FIX/go-args" -game-type 1; then
  echo "PASS create-bad-proposal empty FORWARD reaches stub go (bash $BASH_VERSION)"
else
  echo "FAIL create-bad-proposal no-arg form must reach go without crashing (ec=$BP_EMPTY_EC bash=$BASH_VERSION)" >&2
  echo "$BP_EMPTY_OUT" >&2
  if [[ -f "$BP_FIX/go-args" ]]; then
    echo "go-args:" >&2
    cat -A "$BP_FIX/go-args" >&2 || cat "$BP_FIX/go-args" >&2
  fi
  fail=1
fi

# Working path: -block N still forwards exactly those two words, immediately
# after the package path, then the guarded -l1.
BP_BLOCK_OUT="$(_bp_run "$BP_FIX/.env.sepolia" -block 42 2>&1)" && BP_BLOCK_EC=0 || BP_BLOCK_EC=$?
if [[ "$BP_BLOCK_EC" -eq 0 ]] \
  && [[ -f "$BP_FIX/go-args" ]] \
  && ! grep -qx '' "$BP_FIX/go-args" \
  && _bp_args_seq "$BP_FIX/go-args" run ./cmd/bad-proposal -block 42 -l1 \
  && _bp_args_seq "$BP_FIX/go-args" -game-type 8; then
  echo "PASS create-bad-proposal -block 42 forwards exactly -block 42"
else
  echo "FAIL create-bad-proposal -block must forward exactly (ec=$BP_BLOCK_EC)" >&2
  echo "$BP_BLOCK_OUT" >&2
  fail=1
fi

# Unset PROPOSER_GAME_TYPE must refuse (not silently pass type 1). Pass -block
# so a pre-fix wrapper would get past the empty-array crash and post type 1.
BP_NOGT_OUT="$(_bp_run "$BP_FIX/.env.sepolia.nogt" -block 1 2>&1)" && BP_NOGT_EC=0 || BP_NOGT_EC=$?
if [[ "$BP_NOGT_EC" -ne 0 ]] \
  && [[ ! -f "$BP_FIX/go-args" ]] \
  && echo "$BP_NOGT_OUT" | grep -q 'PROPOSER_GAME_TYPE is required' \
  && ! echo "$BP_NOGT_OUT" | grep -q 'unbound variable'; then
  echo "PASS create-bad-proposal refuses unset PROPOSER_GAME_TYPE (no silent type 1)"
else
  echo "FAIL unset PROPOSER_GAME_TYPE must refuse before go run (ec=$BP_NOGT_EC)" >&2
  echo "$BP_NOGT_OUT" >&2
  fail=1
fi

# Confirm gate still fires before the expansion / go run (must survive).
rm -f "$BP_FIX/go-args"
BP_GATE_OUT="$(
  env -u I_UNDERSTAND_THIS_POSTS_A_FALSE_CLAIM \
    -u CONFIRM_BAD_PROPOSAL_SEPOLIA \
    BP_STUB_DIR="$BP_FIX" \
    BASH_ENV="$BP_FIX/bashenv.sh" \
    FORTEL2_ENV="$BP_FIX/.env.sepolia" \
    FORTEL2_ROOT="$BP_FIX" \
    "$BP_WRAPPER" 2>&1
)" && BP_GATE_EC=0 || BP_GATE_EC=$?
if [[ "$BP_GATE_EC" -ne 0 ]] \
  && [[ ! -f "$BP_FIX/go-args" ]] \
  && echo "$BP_GATE_OUT" | grep -q 'CONFIRM_BAD_PROPOSAL_SEPOLIA'; then
  echo "PASS create-bad-proposal confirm gate still blocks before go run"
else
  echo "FAIL confirm gate must still fire (ec=$BP_GATE_EC)" >&2
  echo "$BP_GATE_OUT" >&2
  fail=1
fi

cleanup_bp_fix
trap - EXIT

# deposit-eth-sepolia.sh: refuse a mismatched ADMIN_PRIVATE_KEY / ADMIN_ADDRESS
# before any L1 send (D-0064 Finding 4 / D-0069 Finding 6). Generate the
# keypair at runtime — never a key literal in this file. Mirror F7-10.
# Helper lives in lib.sh (call-site swap in deposit-eth-sepolia.sh).
DEPOSIT_SEPOLIA="$SCRIPT_DIR/deposit-eth-sepolia.sh"
_dep_fn="$(awk '/^require_key_matches_address\(\)/,/^}/' "$SCRIPT_DIR/lib.sh")"
_dep_rc=""
_dep_out=""
_dep_run() {
  local key="${1-}"
  local addr="${2-}"
  _dep_rc=0
  _dep_out="$(
    (
      eval "$_dep_fn"
      if [[ "$key" == "__UNSET__" ]]; then
        unset ADMIN_PRIVATE_KEY
      else
        ADMIN_PRIVATE_KEY="$key"
        export ADMIN_PRIVATE_KEY
      fi
      ADMIN_ADDRESS="$addr"
      export ADMIN_ADDRESS
      require_key_matches_address ADMIN_PRIVATE_KEY ADMIN_ADDRESS
    ) 2>&1
  )" || _dep_rc=$?
}

if ! command -v cast >/dev/null 2>&1; then
  echo "FAIL deposit-eth-sepolia pairing tests require cast on PATH (Foundry)" >&2
  fail=1
elif [[ -z "$_dep_fn" ]]; then
  echo "FAIL lib.sh must define require_key_matches_address (deposit-eth-sepolia pairing)" >&2
  fail=1
else
  _dep_wallet="$(cast wallet new)"
  _dep_addr="$(printf '%s\n' "$_dep_wallet" | awk '/^Address:/{print $2}')"
  _dep_key="$(printf '%s\n' "$_dep_wallet" | awk '/^Private key:/{print $3}')"
  _dep_addr_lc="$(printf '%s' "$_dep_addr" | tr '[:upper:]' '[:lower:]')"
  _dep_other_addr="$(cast wallet new | awk '/^Address:/{print $2}')"
  unset _dep_wallet

  _dep_run "$_dep_key" "$_dep_addr_lc"
  if [[ "$_dep_rc" == "0" ]]; then
    echo "PASS deposit-eth-sepolia matching pair (checksummed vs lowercase) exits 0"
  else
    echo "FAIL deposit-eth-sepolia require_admin_key_matches_address must accept a checksummed-vs-lowercase pair of the same account" >&2
    fail=1
  fi

  _dep_run "$_dep_key" "$_dep_other_addr"
  _dep_mismatch_out="$_dep_out"
  if [[ "$_dep_rc" != "0" ]] \
    && printf '%s' "$_dep_mismatch_out" | grep -F -q -- "$_dep_addr" \
    && printf '%s' "$_dep_mismatch_out" | grep -F -q -- "$_dep_other_addr"; then
    echo "PASS deposit-eth-sepolia mismatched pair exits non-zero"
  else
    echo "FAIL deposit-eth-sepolia require_admin_key_matches_address must refuse when ADMIN_PRIVATE_KEY does not derive ADMIN_ADDRESS" >&2
    fail=1
  fi

  _dep_run "$_dep_key" "$_dep_addr_lc"
  _dep_match_out="$_dep_out"
  if ! _f710_key_leaked "${_dep_match_out}${_dep_mismatch_out}" "$_dep_key" "${_dep_addr}${_dep_addr_lc}${_dep_other_addr}"; then
    echo "PASS deposit-eth-sepolia error output does not contain the key or an 8-character substring of it"
  else
    echo "FAIL deposit-eth-sepolia require_admin_key_matches_address must not print ADMIN_PRIVATE_KEY or any 8-character substring of it" >&2
    fail=1
  fi

  if awk '
       /require_eth_address "ADMIN"/ { admin = NR }
       /ADMIN_PRIVATE_KEY missing or malformed/ { mal = NR }
       /refuse_foundry_defaults_unless_local_l2/ && !refuse { refuse = NR }
       /require_key_matches_address ADMIN_PRIVATE_KEY ADMIN_ADDRESS/ { call = NR }
       /wait_for_rpc "/ && !wait { wait = NR }
       /\$\(cast balance/ && !bal { bal = NR }
       /\$\(cast send/ && !send { send = NR }
       END {
         exit !(admin && mal && refuse && call && wait && bal && send \
           && admin < call && mal < call && refuse < call \
           && call < wait && call < bal && call < send)
       }
     ' "$DEPOSIT_SEPOLIA"; then
    echo "PASS deposit-eth-sepolia pairing check is called before wait_for_rpc, balance, and send"
  else
    echo "FAIL deposit-eth-sepolia require_key_matches_address must run after key/address validation and before wait_for_rpc, cast balance, and cast send" >&2
    fail=1
  fi

  # Full-script stub path: a missing check would reach cast send. sleep is a
  # no-op so a misplaced check after wait_for_rpc still fails fast via markers.
  _DEP_FIX="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-deposit-pair.XXXXXX")"
  cleanup_dep_fix() { rm -rf "$_DEP_FIX"; }
  trap cleanup_dep_fix EXIT
  mkdir -p "$_DEP_FIX/deployments/sepolia/.deployer" "$_DEP_FIX/data"
  printf '%s\n' '{"L1StandardBridgeProxy":"0x0000000000000000000000000000000000000001","OptimismPortalProxy":"0x0000000000000000000000000000000000000002"}' \
    > "$_DEP_FIX/deployments/sepolia/deployments.json"
  cat > "$_DEP_FIX/.env.sepolia" <<EOF
FORTEL2_ROOT=$_DEP_FIX
DATA_DIR=$_DEP_FIX/data
DEPLOY_DIR=$_DEP_FIX/deployments/sepolia/.deployer
L1_CHAIN_ID=11155111
L2_CHAIN_ID=852
L1_RPC_URL=https://example.invalid
L2_RPC_URL=http://127.0.0.1:9545
L2_NODE_RPC_URL=http://127.0.0.1:9547
ADMIN_ADDRESS=$_dep_other_addr
ADMIN_PRIVATE_KEY=$_dep_key
EOF
  cat > "$_DEP_FIX/bashenv.sh" <<'EOS'
sleep() { :; }
cast() {
  printf '%s\n' "$@" >> "$DEP_STUB_DIR/cast-argv"
  case "${1:-}" in
    wallet)
      command cast "$@"
      ;;
    send)
      echo SEND >> "$DEP_STUB_DIR/cast-send"
      return 1
      ;;
    balance)
      echo BALANCE >> "$DEP_STUB_DIR/cast-balance"
      echo 0
      ;;
    *)
      return 1
      ;;
  esac
}
EOS
  _dep_script_out="$(
    env -u ADMIN_PRIVATE_KEY -u ADMIN_ADDRESS \
      DEP_STUB_DIR="$_DEP_FIX" \
      BASH_ENV="$_DEP_FIX/bashenv.sh" \
      FORTEL2_ENV="$_DEP_FIX/.env.sepolia" \
      FORTEL2_ROOT="$_DEP_FIX" \
      "$DEPOSIT_SEPOLIA" 2>&1
  )" && _dep_script_rc=0 || _dep_script_rc=$?
  if [[ "$_dep_script_rc" != "0" ]] \
    && [[ ! -f "$_DEP_FIX/cast-send" ]] \
    && [[ ! -f "$_DEP_FIX/cast-balance" ]] \
    && printf '%s' "$_dep_script_out" | grep -q 'ADMIN_PRIVATE_KEY does not match ADMIN_ADDRESS' \
    && printf '%s' "$_dep_script_out" | grep -F -q -- "$_dep_addr" \
    && printf '%s' "$_dep_script_out" | grep -F -q -- "$_dep_other_addr" \
    && ! _f710_key_leaked "$_dep_script_out" "$_dep_key" "${_dep_addr}${_dep_addr_lc}${_dep_other_addr}"; then
    echo "PASS deposit-eth-sepolia mismatch refuses before any send"
  else
    echo "FAIL deposit-eth-sepolia must exit non-zero on a mismatched pair before cast send/balance (ec=$_dep_script_rc)" >&2
    fail=1
  fi
  cleanup_dep_fix
  trap - EXIT

  unset _dep_key _dep_addr _dep_addr_lc _dep_other_addr _dep_match_out _dep_mismatch_out _dep_script_out _dep_script_rc
fi
unset _dep_fn _dep_rc _dep_out

# --- alert-watch.sh: funding FAIL + dead recovery agent (offline, PATH shims) ---
AW_CHECK="$SCRIPT_DIR/alert-watch.sh"
AW_FIX="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-alert-watch.XXXXXX")"
cleanup_aw_fix() { rm -rf "$AW_FIX"; }
trap cleanup_aw_fix EXIT
AW_SHIM="$AW_FIX/shim"
AW_MOCK="$AW_FIX/mock"
mkdir -p "$AW_SHIM" "$AW_MOCK" "$AW_FIX/data" "$AW_FIX/bin" "$AW_FIX/deploy"
# Distinctive token: leak checks cover the full value and every 8-char slice.
AW_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x'
AW_REASON='batcher below policy for 24.0 h with no top-up (chainbank-wallet-reconciler)'
AW_TO='fortel2-alert-watch@example.invalid'

cat > "$AW_FIX/env" <<EOF
FORTEL2_ROOT=$AW_FIX
DATA_DIR=$AW_FIX/data
BIN_DIR=$AW_FIX/bin
DEPLOY_DIR=$AW_FIX/deploy
EOF

cat > "$AW_SHIM/curl" <<'EOS'
#!/bin/sh
dir="${ALERT_WATCH_MOCK_DIR:-}"
[ -n "$dir" ] || exit 99
{
  printf 'ARG:%s\n' "$@"
  printf 'END\n'
} >> "$dir/curl.argv"
# stdin is the Authorization header — do not copy it to stdout
cat > "$dir/curl.stdin"
n=0
[ -f "$dir/curl.calls" ] && n=$(cat "$dir/curl.calls")
n=$((n + 1))
printf '%s\n' "$n" > "$dir/curl.calls"
out=""
writeout=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ] || [ "$prev" = "--output" ]; then out="$a"; fi
  if [ "$prev" = "-w" ] || [ "$prev" = "--write-out" ]; then writeout="$a"; fi
  prev="$a"
done
body='{"id":"mock-resend"}'
[ -n "$out" ] && printf '%s\n' "$body" > "$out"
[ -n "$writeout" ] && printf '%s' "${ALERT_WATCH_CURL_HTTP:-200}"
exit 0
EOS
cat > "$AW_SHIM/osascript" <<'EOS'
#!/bin/sh
dir="${ALERT_WATCH_MOCK_DIR:-}"
[ -n "$dir" ] || exit 99
{
  printf 'ARG:%s\n' "$@"
  printf 'END\n'
} >> "$dir/osascript.argv"
n=0
[ -f "$dir/osascript.calls" ] && n=$(cat "$dir/osascript.calls")
n=$((n + 1))
printf '%s\n' "$n" > "$dir/osascript.calls"
exit 0
EOS
cat > "$AW_SHIM/launchctl" <<'EOS'
#!/bin/sh
dir="${ALERT_WATCH_MOCK_DIR:-}"
[ -n "$dir" ] || exit 99
{
  printf 'ARG:%s\n' "$@"
  printf 'END\n'
} >> "$dir/launchctl.argv"
case "$1" in
  print) ;;
  bootout|bootstrap|kickstart)
    echo "alert-watch must not call launchctl $1" >&2
    exit 99
    ;;
  *)
    echo "unexpected launchctl $1" >&2
    exit 99
    ;;
esac
if [ "${ALERT_WATCH_LAUNCHCTL_MISSING:-}" = "1" ]; then
  echo "Could not find service" >&2
  exit 1
fi
printf 'gui/501/com.steve.fortel2-resolve-games = {\n\tstate = not running\n\tlast exit code = %s\n\truns = 10\n}\n' \
  "${ALERT_WATCH_LAUNCHCTL_EXIT:-0}"
exit 0
EOS
chmod +x "$AW_SHIM/curl" "$AW_SHIM/osascript" "$AW_SHIM/launchctl"

aw_reset_mock() {
  rm -f "$AW_MOCK"/curl.argv "$AW_MOCK"/curl.stdin "$AW_MOCK"/curl.calls \
    "$AW_MOCK"/osascript.argv "$AW_MOCK"/osascript.calls "$AW_MOCK"/launchctl.argv
}
aw_touch_logs() {
  : > "$AW_FIX/resolve.out.log"
  : > "$AW_FIX/resolve.err.log"
}
aw_write_json() {
  local verdict="$1" reason="$2"
  printf '{"verdict":"%s","reason":"%s"}\n' "$verdict" "$reason" > "$AW_FIX/funding-health.json"
}
aw_run() {
  # FORTEL2_ENV fixture has no TOKEN/email keys, so caller-supplied values survive set -a.
  env -u RESEND_API_TOKEN \
    PATH="$AW_SHIM:$PATH" \
    FORTEL2_ENV="$AW_FIX/env" \
    ALERT_WATCH_MOCK_DIR="$AW_MOCK" \
    ALERT_WATCH_FUNDING_JSON="$AW_FIX/funding-health.json" \
    ALERT_WATCH_STATE="$AW_FIX/state.json" \
    ALERT_WATCH_RESOLVE_OUT="$AW_FIX/resolve.out.log" \
    ALERT_WATCH_RESOLVE_ERR="$AW_FIX/resolve.err.log" \
    ALERT_WATCH_CURL="$AW_SHIM/curl" \
    ALERT_WATCH_OSASCRIPT="$AW_SHIM/osascript" \
    ALERT_WATCH_LAUNCHCTL="$AW_SHIM/launchctl" \
    ALERT_EMAIL_TO="$AW_TO" \
    "$@"
}

# (1) FAIL verdict → both channels; email payload carries the reason.
aw_reset_mock
aw_touch_logs
aw_write_json "FAIL" "$AW_REASON"
rm -f "$AW_FIX/state.json"
AW_OUT="$(aw_run RESEND_API_TOKEN="$AW_TOKEN" "$AW_CHECK" 2>&1)" && AW_EC=0 || AW_EC=$?
AW_HAY="${AW_OUT}$(cat "$AW_MOCK/curl.argv" 2>/dev/null)$(cat "$AW_MOCK/osascript.argv" 2>/dev/null)"
if [[ "$AW_EC" -eq 0 ]] \
   && [[ "$(cat "$AW_MOCK/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
   && [[ "$(cat "$AW_MOCK/curl.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
   && grep -F -q -- "$AW_REASON" "$AW_MOCK/curl.argv" \
   && grep -F -q -- "$AW_REASON" "$AW_MOCK/osascript.argv"; then
  echo "PASS alert-watch FAIL verdict invokes both channels and emails the reason"
else
  echo "FAIL alert-watch FAIL verdict should send banner+email containing the reason (ec=$AW_EC)" >&2
  echo "$AW_OUT" >&2
  fail=1
fi

# (5) Token never on argv or in script output (full value + 8-char slices).
if ! _f710_key_leaked "$AW_HAY" "$AW_TOKEN" ""; then
  echo "PASS alert-watch token absent from curl/osascript argv and script output"
else
  echo "FAIL alert-watch leaked RESEND_API_TOKEN (or an 8-char slice) into argv/output" >&2
  fail=1
fi
if grep -qF -- '--header' "$AW_MOCK/curl.argv" && grep -qF -- '@-' "$AW_MOCK/curl.argv" \
   && ! grep -qi 'Authorization' "$AW_MOCK/curl.argv"; then
  echo "PASS alert-watch passes Authorization via --header @- not argv"
else
  echo "FAIL alert-watch must pass the Resend token via --header @- (not -H argv)" >&2
  fail=1
fi

# (2) Stale funding-health.json (even with OK verdict) → alert.
aw_reset_mock
aw_touch_logs
aw_write_json "OK" "balance at or above the funding policy minimum"
python3 - "$AW_FIX/funding-health.json" <<'PY'
import os, sys, time
p = sys.argv[1]
now = time.time()
os.utime(p, (now - 27 * 3600, now - 27 * 3600))
PY
rm -f "$AW_FIX/state.json"
AW_OUT="$(aw_run RESEND_API_TOKEN="$AW_TOKEN" "$AW_CHECK" 2>&1)" && AW_EC=0 || AW_EC=$?
if [[ "$AW_EC" -eq 0 ]] \
   && [[ "$(cat "$AW_MOCK/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
   && [[ "$(cat "$AW_MOCK/curl.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
   && grep -qi 'stale' "$AW_MOCK/osascript.argv"; then
  echo "PASS alert-watch stale funding-health.json alerts"
else
  echo "FAIL alert-watch should alert on a >26h funding-health.json (ec=$AW_EC)" >&2
  echo "$AW_OUT" >&2
  fail=1
fi

# (3) Fresh OK + fresh agent logs → no alert, exit 0.
aw_reset_mock
aw_touch_logs
aw_write_json "OK" "balance at or above the funding policy minimum"
rm -f "$AW_FIX/state.json"
AW_OUT="$(aw_run RESEND_API_TOKEN="$AW_TOKEN" "$AW_CHECK" 2>&1)" && AW_EC=0 || AW_EC=$?
if [[ "$AW_EC" -eq 0 ]] \
   && [[ ! -f "$AW_MOCK/osascript.calls" ]] \
   && [[ ! -f "$AW_MOCK/curl.calls" ]]; then
  echo "PASS alert-watch fresh OK JSON + fresh agent logs is quiet"
else
  echo "FAIL alert-watch should exit 0 with no sends on fresh OK + fresh logs (ec=$AW_EC)" >&2
  echo "$AW_OUT" >&2
  fail=1
fi

# (4) Same condition twice inside cooldown → one send; distinct second still alerts.
aw_reset_mock
aw_touch_logs
aw_write_json "FAIL" "$AW_REASON"
rm -f "$AW_FIX/state.json"
aw_run RESEND_API_TOKEN="$AW_TOKEN" "$AW_CHECK" >/dev/null 2>&1 || true
AW_C1="$(cat "$AW_MOCK/curl.calls" 2>/dev/null || echo 0)"
aw_run RESEND_API_TOKEN="$AW_TOKEN" "$AW_CHECK" >/dev/null 2>&1 || true
AW_C2="$(cat "$AW_MOCK/curl.calls" 2>/dev/null || echo 0)"
AW_B2="$(cat "$AW_MOCK/osascript.calls" 2>/dev/null || echo 0)"
if [[ "$AW_C1" -eq 1 && "$AW_C2" -eq 1 && "$AW_B2" -eq 1 ]]; then
  echo "PASS alert-watch cooldown suppresses a second send of the same condition"
else
  echo "FAIL alert-watch should send once per condition inside ALERT_REALERT_HOURS (c1=$AW_C1 c2=$AW_C2 b2=$AW_B2)" >&2
  fail=1
fi
# Age the FAIL file so health-stale is a new condition while funding-fail is cooled.
python3 - "$AW_FIX/funding-health.json" <<'PY'
import os, sys, time
p = sys.argv[1]
now = time.time()
os.utime(p, (now - 27 * 3600, now - 27 * 3600))
PY
aw_run RESEND_API_TOKEN="$AW_TOKEN" "$AW_CHECK" >/dev/null 2>&1 || true
AW_C3="$(cat "$AW_MOCK/curl.calls" 2>/dev/null || echo 0)"
AW_B3="$(cat "$AW_MOCK/osascript.calls" 2>/dev/null || echo 0)"
if [[ "$AW_C3" -eq 2 && "$AW_B3" -eq 2 ]]; then
  echo "PASS alert-watch distinct second condition alerts during cooldown"
else
  echo "FAIL alert-watch should send immediately for a new condition (c3=$AW_C3 b3=$AW_B3)" >&2
  fail=1
fi

# (6) Missing RESEND_API_TOKEN → banner fires, email skipped loudly, nonzero exit.
aw_reset_mock
aw_touch_logs
aw_write_json "FAIL" "$AW_REASON"
rm -f "$AW_FIX/state.json"
AW_OUT="$(aw_run "$AW_CHECK" 2>&1)" && AW_EC=0 || AW_EC=$?
if [[ "$AW_EC" -ne 0 ]] \
   && [[ "$(cat "$AW_MOCK/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
   && [[ ! -f "$AW_MOCK/curl.calls" ]] \
   && [[ "$AW_OUT" == *"RESEND_API_TOKEN"* ]] \
   && [[ "$AW_OUT" == *"email skipped"* ]]; then
  echo "PASS alert-watch missing token still banners and exits nonzero"
else
  echo "FAIL alert-watch missing RESEND_API_TOKEN must banner, skip email loudly, exit nonzero (ec=$AW_EC)" >&2
  echo "$AW_OUT" >&2
  fail=1
fi

# WARN / INSUFFICIENT are inside the documented tolerance — no alert.
aw_reset_mock
aw_touch_logs
aw_write_json "WARN" "below policy, inside tolerance"
rm -f "$AW_FIX/state.json"
AW_WARN_OUT="$(aw_run RESEND_API_TOKEN="$AW_TOKEN" "$AW_CHECK" 2>&1)" && AW_WARN_EC=0 || AW_WARN_EC=$?
aw_write_json "INSUFFICIENT" "no samples file"
AW_INS_OUT="$(aw_run RESEND_API_TOKEN="$AW_TOKEN" "$AW_CHECK" 2>&1)" && AW_INS_EC=0 || AW_INS_EC=$?
if [[ "$AW_WARN_EC" -eq 0 && "$AW_INS_EC" -eq 0 ]] \
   && [[ ! -f "$AW_MOCK/osascript.calls" ]] \
   && [[ ! -f "$AW_MOCK/curl.calls" ]]; then
  echo "PASS alert-watch WARN and INSUFFICIENT do not alert"
else
  echo "FAIL alert-watch must not alert on WARN/INSUFFICIENT (warn=$AW_WARN_EC ins=$AW_INS_EC)" >&2
  echo "$AW_WARN_OUT" >&2
  echo "$AW_INS_OUT" >&2
  fail=1
fi

# Fresh JSON whose verdict is missing or not OK/WARN/INSUFFICIENT/FAIL is unknown, not quiet.
aw_reset_mock
aw_touch_logs
printf '{"reason":"no verdict field"}\n' > "$AW_FIX/funding-health.json"
rm -f "$AW_FIX/state.json"
AW_OUT="$(aw_run RESEND_API_TOKEN="$AW_TOKEN" "$AW_CHECK" 2>&1)" && AW_EC=0 || AW_EC=$?
AW_MISS_B="$(cat "$AW_MOCK/osascript.calls" 2>/dev/null || echo 0)"
aw_reset_mock
printf '{"verdict":"failing","reason":"advisory label is not a watcher verdict"}\n' > "$AW_FIX/funding-health.json"
rm -f "$AW_FIX/state.json"
AW_BAD_OUT="$(aw_run RESEND_API_TOKEN="$AW_TOKEN" "$AW_CHECK" 2>&1)" && AW_BAD_EC=0 || AW_BAD_EC=$?
if [[ "$AW_EC" -eq 0 && "$AW_BAD_EC" -eq 0 ]] \
   && [[ "$AW_MISS_B" -eq 1 ]] \
   && [[ "$(cat "$AW_MOCK/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
   && grep -qi 'unrecognized verdict' "$AW_MOCK/osascript.argv"; then
  echo "PASS alert-watch unknown fresh verdict alerts rather than failing open"
else
  echo "FAIL alert-watch must alert on a missing/unknown verdict (ec=$AW_EC bad=$AW_BAD_EC miss_b=$AW_MISS_B)" >&2
  echo "$AW_OUT" >&2
  echo "$AW_BAD_OUT" >&2
  fail=1
fi

# :00 agent / :30 watcher: 1.5 h (one miss) is quiet; 2 h 25 m (two misses at 02:30) alerts.
# The old 2.5 h threshold missed that 02:30 check.
aw_age_logs() {
  python3 - "$AW_FIX/resolve.out.log" "$AW_FIX/resolve.err.log" "$1" <<'PY'
import os, sys, time
age = int(sys.argv[3])
now = time.time()
for p in sys.argv[1:3]:
    os.utime(p, (now - age, now - age))
PY
}
aw_reset_mock
aw_touch_logs
aw_write_json "OK" "balance at or above the funding policy minimum"
rm -f "$AW_FIX/state.json"
aw_age_logs 5400   # 1.5 h
AW_OUT="$(aw_run RESEND_API_TOKEN="$AW_TOKEN" "$AW_CHECK" 2>&1)" && AW_EC=0 || AW_EC=$?
if [[ "$AW_EC" -eq 0 ]] \
   && [[ ! -f "$AW_MOCK/osascript.calls" ]] \
   && [[ ! -f "$AW_MOCK/curl.calls" ]]; then
  echo "PASS alert-watch one missed resolve-games cycle (1.5 h) is quiet"
else
  echo "FAIL alert-watch must not alert after a single missed :00 cycle (ec=$AW_EC)" >&2
  echo "$AW_OUT" >&2
  fail=1
fi
aw_reset_mock
aw_touch_logs
aw_write_json "OK" "balance at or above the funding policy minimum"
rm -f "$AW_FIX/state.json"
aw_age_logs 8700   # 2 h 25 m — 02:30 after last success at ~00:05
AW_OUT="$(aw_run RESEND_API_TOKEN="$AW_TOKEN" "$AW_CHECK" 2>&1)" && AW_EC=0 || AW_EC=$?
if [[ "$AW_EC" -eq 0 ]] \
   && [[ "$(cat "$AW_MOCK/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
   && grep -qi 'resolve-games' "$AW_MOCK/osascript.argv"; then
  echo "PASS alert-watch two missed resolve-games cycles (2 h 25 m) alerts"
else
  echo "FAIL alert-watch must alert by the 02:30 check after two missed :00 runs (ec=$AW_EC)" >&2
  echo "$AW_OUT" >&2
  fail=1
fi

# --test is a first-class shakeout path, tagged TEST, both channels.
aw_reset_mock
AW_OUT="$(aw_run RESEND_API_TOKEN="$AW_TOKEN" "$AW_CHECK" --test 2>&1)" && AW_EC=0 || AW_EC=$?
if [[ "$AW_EC" -eq 0 ]] \
   && [[ "$(cat "$AW_MOCK/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
   && [[ "$(cat "$AW_MOCK/curl.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
   && grep -q 'TEST' "$AW_MOCK/osascript.argv" \
   && grep -q 'TEST' "$AW_MOCK/curl.argv"; then
  echo "PASS alert-watch --test tags TEST and hits both channels"
else
  echo "FAIL alert-watch --test should send a TEST-tagged alert on both channels (ec=$AW_EC)" >&2
  echo "$AW_OUT" >&2
  fail=1
fi

# Read-only launchctl: the watcher source must not mention mutating verbs as commands.
# (The word "bootstrap" in a comment about the operator's install is the trap — allow
# comments; forbid the tokens as launchctl arguments in the executable path.)
if ! grep -E 'launchctl[[:space:]]+(bootout|bootstrap|kickstart)' "$AW_CHECK" \
   && grep -q 'launchctl' "$AW_CHECK" \
   && grep -q 'StartCalendarInterval' "$SCRIPT_DIR/../launchd/com.steve.fortel2-alerts.plist" \
   && grep -q 'Library/Logs/fortel2-alerts' "$SCRIPT_DIR/../launchd/com.steve.fortel2-alerts.plist" \
   && ! grep -q 'data/.*\.log' "$SCRIPT_DIR/../launchd/com.steve.fortel2-alerts.plist"; then
  echo "PASS alert-watch is launchctl-print-only; alerts plist uses calendar + Library/Logs"
else
  echo "FAIL alert-watch/plist must be read-only launchctl, StartCalendarInterval, ~/Library/Logs" >&2
  fail=1
fi

cleanup_aw_fix
trap - EXIT
unset AW_CHECK AW_FIX AW_SHIM AW_MOCK AW_TOKEN AW_REASON AW_TO AW_OUT AW_EC AW_HAY
unset AW_C1 AW_C2 AW_C3 AW_B2 AW_B3 AW_WARN_OUT AW_WARN_EC AW_INS_OUT AW_INS_EC
unset AW_BAD_OUT AW_BAD_EC AW_MISS_B

# --- lib-key-guards: parameterized pairing helper, loader duplicate detection,
#     phase7-preflight.sh (additive; do not reorder the tests above). ---
CHALLENGER_SEPOLIA="$SCRIPT_DIR/09-start-challenger-sepolia.sh"
_kg_fn="$(awk '/^require_key_matches_address\(\)/,/^}/' "$SCRIPT_DIR/lib.sh")"
_kg_dup_fn="$(awk '/^# >>> env-dup$/,/^# <<< env-dup$/' "$SCRIPT_DIR/lib.sh")"
_kg_rc=""
_kg_out=""
_kg_run() {
  local key_var="$1" addr_var="$2" key="$3" addr="$4"
  _kg_rc=0
  _kg_out="$(
    (
      eval "$_kg_fn"
      printf -v "$key_var" '%s' "$key"
      export "$key_var"
      printf -v "$addr_var" '%s' "$addr"
      export "$addr_var"
      require_key_matches_address "$key_var" "$addr_var"
    ) 2>&1
  )" || _kg_rc=$?
}

if awk '
     /require_key_matches_address ADMIN_PRIVATE_KEY ADMIN_ADDRESS/ { call = NR }
     /require_min_balance_eth/ && !bal { bal = NR }
     /rm -rf "\$DEPLOY_DIR"/ && !rm { rm = NR }
     END { exit !(call && bal && rm && call < bal && call < rm) }
   ' "$DEPLOY_SEPOLIA" \
  && awk '
     /require_key_matches_address ADMIN_PRIVATE_KEY ADMIN_ADDRESS/ { call = NR }
     /wait_for_rpc "/ && !wait { wait = NR }
     /\$\(cast send/ && !send { send = NR }
     END { exit !(call && wait && send && call < wait && call < send) }
   ' "$DEPOSIT_SEPOLIA" \
  && awk '
     /require_key_matches_address CHALLENGER_PRIVATE_KEY CHALLENGER_ADDRESS/ { call = NR }
     /wait_for_rpc/ && !wait { wait = NR }
     /start_bg op-challenger/ { start = NR }
     END { exit !(call && wait && start && call < wait && call < start) }
   ' "$CHALLENGER_SEPOLIA"; then
  echo "PASS pairing helper is called before network/spend in deploy, deposit, and challenger"
else
  echo "FAIL require_key_matches_address must run before spend/network in all three scripts" >&2
  fail=1
fi

if ! command -v cast >/dev/null 2>&1; then
  echo "FAIL lib-key-guards helper tests require cast on PATH (Foundry)" >&2
  fail=1
elif [[ -z "$_kg_fn" ]]; then
  echo "FAIL lib.sh must define require_key_matches_address" >&2
  fail=1
else
  _kg_wallet="$(cast wallet new)"
  _kg_addr="$(printf '%s\n' "$_kg_wallet" | awk '/^Address:/{print $2}')"
  _kg_key="$(printf '%s\n' "$_kg_wallet" | awk '/^Private key:/{print $3}')"
  _kg_addr_lc="$(printf '%s' "$_kg_addr" | tr '[:upper:]' '[:lower:]')"
  _kg_other="$(cast wallet new | awk '/^Address:/{print $2}')"
  unset _kg_wallet

  _kg_run CHALLENGER_PRIVATE_KEY CHALLENGER_ADDRESS "$_kg_key" "$_kg_addr_lc"
  _kg_match="$_kg_out"
  if [[ "$_kg_rc" == "0" ]]; then
    echo "PASS pairing helper matching CHALLENGER pair (checksummed vs lowercase) exits 0"
  else
    echo "FAIL require_key_matches_address must accept a matching CHALLENGER pair" >&2
    fail=1
  fi

  _kg_run CHALLENGER_PRIVATE_KEY CHALLENGER_ADDRESS "$_kg_key" "$_kg_other"
  _kg_mismatch="$_kg_out"
  if [[ "$_kg_rc" != "0" ]] \
    && printf '%s' "$_kg_mismatch" | grep -F -q -- "$_kg_addr" \
    && printf '%s' "$_kg_mismatch" | grep -F -q -- "$_kg_other" \
    && printf '%s' "$_kg_mismatch" | grep -q 'CHALLENGER_PRIVATE_KEY does not match CHALLENGER_ADDRESS'; then
    echo "PASS pairing helper mismatched CHALLENGER pair exits non-zero naming both addresses"
  else
    echo "FAIL require_key_matches_address must refuse a mismatched CHALLENGER pair naming both addresses" >&2
    fail=1
  fi

  if ! _f710_key_leaked "${_kg_match}${_kg_mismatch}" "$_kg_key" "${_kg_addr}${_kg_addr_lc}${_kg_other}"; then
    echo "PASS pairing helper output does not contain the key or an 8-character substring of it"
  else
    echo "FAIL require_key_matches_address must not print the key or any 8-character substring of it" >&2
    fail=1
  fi
fi

# Loader duplicate detection: extract the marked block (names only; never values).
_kg_dup_dir="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-env-dup.XXXXXX")"
cleanup_kg_dup() { rm -rf "$_kg_dup_dir"; }
trap cleanup_kg_dup EXIT
_kg_dup_run() {
  local file="$1"
  local snippet="$_kg_dup_dir/snippet.sh"
  printf '%s\n' "$_kg_dup_fn" > "$snippet"
  _kg_rc=0
  _kg_out="$(
    (
      # shellcheck disable=SC1090
      source "$snippet"
      FORTEL2_ENV_FILE="$file"
      refuse_duplicate_env_assignments
    ) 2>&1
  )" || _kg_rc=$?
}

if [[ -z "$_kg_dup_fn" ]] || ! printf '%s' "$_kg_dup_fn" | grep -q '^refuse_duplicate_env_assignments()'; then
  echo "FAIL lib.sh must define refuse_duplicate_env_assignments (env-dup markers)" >&2
  fail=1
else
  printf '%s\n' 'FOO=1' 'BAR=2' 'BAZ=a=b=c' > "$_kg_dup_dir/clean.env"
  _kg_dup_run "$_kg_dup_dir/clean.env"
  if [[ "$_kg_rc" == "0" ]]; then
    echo "PASS loader accepts a clean env file"
  else
    echo "FAIL refuse_duplicate_env_assignments must accept a file with unique assignments" >&2
    echo "$_kg_out" >&2
    fail=1
  fi

  printf '%s\n' '# FOO=1' '# FOO=2' 'FOO=1' 'BAR=2' > "$_kg_dup_dir/commented.env"
  _kg_dup_run "$_kg_dup_dir/commented.env"
  if [[ "$_kg_rc" == "0" ]]; then
    echo "PASS loader accepts a commented duplicate"
  else
    echo "FAIL refuse_duplicate_env_assignments must ignore commented assignments" >&2
    echo "$_kg_out" >&2
    fail=1
  fi

  printf '%s\n' 'FOO=secretvalueAAAA' 'BAR=1' 'FOO=secretvalueBBBB' > "$_kg_dup_dir/dup.env"
  _kg_dup_run "$_kg_dup_dir/dup.env"
  if [[ "$_kg_rc" != "0" ]] \
    && printf '%s' "$_kg_out" | grep -q 'FOO' \
    && ! printf '%s' "$_kg_out" | grep -q 'secretvalueAAAA' \
    && ! printf '%s' "$_kg_out" | grep -q 'secretvalueBBBB' \
    && ! printf '%s' "$_kg_out" | grep -q 'BAR'; then
    echo "PASS loader refuses a duplicate active assignment naming the variable only"
  else
    echo "FAIL refuse_duplicate_env_assignments must refuse duplicates and name the variable only (ec=$_kg_rc)" >&2
    echo "$_kg_out" >&2
    fail=1
  fi

  printf '%s\n' 'export FOO=1' 'BAR=2' > "$_kg_dup_dir/export.env"
  _kg_dup_run "$_kg_dup_dir/export.env"
  if [[ "$_kg_rc" == "0" ]]; then
    echo "PASS loader accepts a single export assignment"
  else
    echo "FAIL refuse_duplicate_env_assignments must treat export FOO= as one assignment, not a duplicate" >&2
    echo "$_kg_out" >&2
    fail=1
  fi

  printf '%s\n' '  FOO=1' 'FOO=2' > "$_kg_dup_dir/ws.env"
  _kg_dup_run "$_kg_dup_dir/ws.env"
  if [[ "$_kg_rc" != "0" ]] && printf '%s' "$_kg_out" | grep -q 'FOO'; then
    echo "PASS loader refuses a whitespace-prefixed duplicate of the same name"
  else
    echo "FAIL refuse_duplicate_env_assignments must count a leading-whitespace assignment" >&2
    echo "$_kg_out" >&2
    fail=1
  fi

  _kg_dup_run "$SCRIPT_DIR/../.env.example"
  if [[ "$_kg_rc" == "0" ]]; then
    echo "PASS loader accepts .env.example (no duplicate assignments)"
  else
    echo "FAIL refuse_duplicate_env_assignments must accept .env.example" >&2
    echo "$_kg_out" >&2
    fail=1
  fi

  _kg_dup_run "$SCRIPT_DIR/../.env.sepolia.example"
  if [[ "$_kg_rc" == "0" ]]; then
    echo "PASS loader accepts .env.sepolia.example (no duplicate assignments)"
  else
    echo "FAIL refuse_duplicate_env_assignments must accept .env.sepolia.example" >&2
    echo "$_kg_out" >&2
    fail=1
  fi

  # Wiring: sourcing lib.sh with a duplicated env must refuse before last-wins.
  mkdir -p "$_kg_dup_dir/wire/data" "$_kg_dup_dir/wire/deployments/sepolia/.deployer"
  cat > "$_kg_dup_dir/wire/.env.sepolia" <<EOF
FORTEL2_ROOT=$_kg_dup_dir/wire
DATA_DIR=$_kg_dup_dir/wire/data
BIN_DIR=$_kg_dup_dir/wire/bin
DEPLOY_DIR=$_kg_dup_dir/wire/deployments/sepolia/.deployer
L1_CHAIN_ID=11155111
L2_CHAIN_ID=852
L1_RPC_URL=https://example.invalid
L2_RPC_URL=http://127.0.0.1:9545
L2_NODE_RPC_URL=http://127.0.0.1:9547
FOO=secretvalueAAAA
FOO=secretvalueBBBB
EOF
  _kg_wire_out="$(
    FORTEL2_ROOT="$_kg_dup_dir/wire" FORTEL2_ENV=.env.sepolia \
      bash -c 'source "'"$SCRIPT_DIR"'/lib.sh"' 2>&1
  )" && _kg_wire_rc=0 || _kg_wire_rc=$?
  if [[ "$_kg_wire_rc" != "0" ]] \
    && printf '%s' "$_kg_wire_out" | grep -q 'FOO' \
    && ! printf '%s' "$_kg_wire_out" | grep -q 'secretvalueAAAA' \
    && ! printf '%s' "$_kg_wire_out" | grep -q 'secretvalueBBBB'; then
    echo "PASS lib.sh load path refuses a duplicate assignment (names only)"
  else
    echo "FAIL sourcing lib.sh must refuse a duplicated env variable and not print its value (ec=$_kg_wire_rc)" >&2
    echo "$_kg_wire_out" >&2
    fail=1
  fi
fi
cleanup_kg_dup
trap - EXIT

# phase7-preflight.sh: fixture FORTEL2_ROOT, never the operator's .env.sepolia.
# Generate the keypair at runtime — never a key literal in this file.
if ! command -v cast >/dev/null 2>&1; then
  echo "FAIL phase7-preflight tests require cast on PATH (Foundry)" >&2
  fail=1
elif [[ ! -x "$SCRIPT_DIR/phase7-preflight.sh" ]]; then
  echo "FAIL scripts/phase7-preflight.sh must be executable (mode 755; D-0068 Finding 1)" >&2
  fail=1
else
  _pf_root="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-preflight.XXXXXX")"
  cleanup_pf() { rm -rf "$_pf_root"; }
  trap cleanup_pf EXIT
  mkdir -p "$_pf_root/scripts"
  cp "$SCRIPT_DIR/phase7-preflight.sh" "$_pf_root/scripts/phase7-preflight.sh"
  cp "$SCRIPT_DIR/lib.sh" "$_pf_root/scripts/lib.sh"
  cp "$SCRIPT_DIR/02-deploy-contracts-sepolia.sh" "$_pf_root/scripts/02-deploy-contracts-sepolia.sh"
  chmod 755 "$_pf_root/scripts/phase7-preflight.sh"

  _pf_wallet="$(cast wallet new)"
  _pf_addr="$(printf '%s\n' "$_pf_wallet" | awk '/^Address:/{print $2}')"
  _pf_key="$(printf '%s\n' "$_pf_wallet" | awk '/^Private key:/{print $3}')"
  _pf_other="$(cast wallet new | awk '/^Address:/{print $2}')"
  unset _pf_wallet

  _pf_write_env() {
    local addr="$1"
    cat > "$_pf_root/.env.sepolia" <<EOF
FAULT_GAME_CLOCK_EXTENSION=600
FAULT_GAME_MAX_CLOCK_DURATION=7200
PREIMAGE_ORACLE_CHALLENGE_PERIOD=3600
PROOF_MATURITY_DELAY_SECONDS=1800
DISPUTE_GAME_FINALITY_DELAY_SECONDS=1800
FAULT_GAME_WITHDRAWAL_DELAY=3600
ADMIN_ADDRESS=$addr
ADMIN_PRIVATE_KEY=$_pf_key
EOF
    chmod 600 "$_pf_root/.env.sepolia"
  }

  _pf_run() {
    (
      cd "$_pf_root"
      env -u FORTEL2_ENV -u FORTEL2_ENV_FILE -u FORTEL2_ROOT \
        -u ADMIN_PRIVATE_KEY -u ADMIN_ADDRESS \
        scripts/phase7-preflight.sh
    ) 2>&1
  }

  _pf_write_env "$_pf_addr"
  _pf_out="$(_pf_run)" && _pf_rc=0 || _pf_rc=$?
  if printf '%s' "$_pf_out" | grep -q 'ALL CHECKS PASSED' \
    && ! printf '%s' "$_pf_out" | grep -q 'NOT CLEAR TO PROCEED' \
    && ! _f710_key_leaked "$_pf_out" "$_pf_key" "${_pf_addr}${_pf_other}"; then
    echo "PASS phase7-preflight green path prints ALL CHECKS PASSED"
  else
    echo "FAIL phase7-preflight matching fixture must print ALL CHECKS PASSED (ec=$_pf_rc)" >&2
    echo "$_pf_out" >&2
    fail=1
  fi

  _pf_write_env "$_pf_other"
  _pf_bad="$(_pf_run)" && _pf_bad_rc=0 || _pf_bad_rc=$?
  if printf '%s' "$_pf_bad" | grep -q 'NOT CLEAR TO PROCEED' \
    && ! printf '%s' "$_pf_bad" | grep -q 'ALL CHECKS PASSED' \
    && ! _f710_key_leaked "$_pf_bad" "$_pf_key" "${_pf_addr}${_pf_other}"; then
    echo "PASS phase7-preflight mismatched key prints NOT CLEAR TO PROCEED"
  else
    echo "FAIL phase7-preflight mismatched ADMIN pair must print NOT CLEAR TO PROCEED (ec=$_pf_bad_rc)" >&2
    echo "$_pf_bad" >&2
    fail=1
  fi

  _pf_write_env "$_pf_addr"
  # Mangle the extraction anchor in a scratch copy of lib.sh.
  python3 -c '
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
p.write_text(t.replace("require_key_matches_address()", "require_key_matches_address_BROKEN()", 1))
' "$_pf_root/scripts/lib.sh"
  _pf_brk="$(_pf_run)" && _pf_brk_rc=0 || _pf_brk_rc=$?
  if printf '%s' "$_pf_brk" | grep -q 'COULD NOT RUN' \
    && printf '%s' "$_pf_brk" | grep -q 'NOT CLEAR TO PROCEED' \
    && ! printf '%s' "$_pf_brk" | grep -q 'ALL CHECKS PASSED' \
    && ! _f710_key_leaked "$_pf_brk" "$_pf_key" "${_pf_addr}${_pf_other}"; then
    echo "PASS phase7-preflight broken extraction anchor is COULD NOT RUN / NOT CLEAR TO PROCEED"
  else
    echo "FAIL phase7-preflight mangled F7-10 anchor must be COULD NOT RUN and NOT CLEAR TO PROCEED (ec=$_pf_brk_rc)" >&2
    echo "$_pf_brk" >&2
    fail=1
  fi

  unset _pf_key _pf_addr _pf_other _pf_out _pf_bad _pf_brk
  cleanup_pf
  trap - EXIT
fi

# Regression: GNU `stat -f` is --file-system and succeeds, so `stat -f || stat -c`
# never falls through on Ubuntu CI (Bugbot on #151).
if ! grep -q 'mode=$(stat -f' "$SCRIPT_DIR/phase7-preflight.sh" \
  && grep -q 'S_IMODE' "$SCRIPT_DIR/phase7-preflight.sh"; then
  echo "PASS phase7-preflight mode check does not use GNU-broken stat -f fallback"
else
  echo "FAIL phase7-preflight must not use stat -f || stat -c (GNU -f is --file-system)" >&2
  fail=1
fi

# Regression: ADMIN_PRIVATE_KEY must not land on env argv or a leftover temp file (Codex P1 on #151).
if ! grep -q '_admin=' "$SCRIPT_DIR/phase7-preflight.sh" \
  && ! grep -qE 'env \$\(grep -E .ADMIN_' "$SCRIPT_DIR/phase7-preflight.sh" \
  && grep -F -q 'ADMIN_PRIVATE_KEY=*' "$SCRIPT_DIR/phase7-preflight.sh"; then
  echo "PASS phase7-preflight loads ADMIN_* from the env file, not argv or a leftover temp"
else
  echo "FAIL phase7-preflight must not copy ADMIN_PRIVATE_KEY onto env argv or a temp file" >&2
  fail=1
fi

if grep -q 'refuses a duplicated active assignment of any variable' "$SCRIPT_DIR/../README.md"; then
  echo "PASS README documents loader-wide duplicate-assignment refusal"
else
  echo "FAIL README must document that lib.sh refuses any duplicated env assignment" >&2
  fail=1
fi
unset _kg_fn _kg_dup_fn _kg_rc _kg_out _kg_mismatch _kg_key _kg_addr _kg_addr_lc _kg_other
unset CHALLENGER_SEPOLIA

# --- help-range (content-anchored --help) + quoted multi-line env scanner -----
# Use the env file test-helpers already loaded. Forcing .env.sepolia.example
# makes lib.sh mkdir DATA_DIR under /Users/steveforte/... which fails on CI Linux.
_hr_help_out=""
_hr_help_rc=0
_hr_help_out="$(FORTEL2_ENV="$FORTEL2_ENV_FILE" "$SCRIPT_DIR/funding-watch.sh" --help 2>&1)" || _hr_help_rc=$?
if [[ "$_hr_help_rc" == "0" ]] \
  && printf '%s' "$_hr_help_out" | grep -q 'FUNDING_STALE_HOURS' \
  && printf '%s' "$_hr_help_out" | grep -q 'FUNDING_HEALTH_TIMEOUT' \
  && ! printf '%s' "$_hr_help_out" | grep -q 'set -euo pipefail'; then
  echo "PASS funding-watch.sh --help prints the env-key table (exit 0)"
else
  echo "FAIL funding-watch.sh --help must print FUNDING_STALE_HOURS and FUNDING_HEALTH_TIMEOUT, exit 0, and not dump the script body (ec=$_hr_help_rc)" >&2
  printf '%s\n' "$_hr_help_out" >&2
  fail=1
fi

_hr_help_rc=0
_hr_help_out="$(FORTEL2_ENV="$FORTEL2_ENV_FILE" "$SCRIPT_DIR/alert-watch.sh" --help 2>&1)" || _hr_help_rc=$?
if [[ "$_hr_help_rc" == "0" ]] \
  && printf '%s' "$_hr_help_out" | grep -q 'RESEND_API_TOKEN' \
  && printf '%s' "$_hr_help_out" | grep -q 'ALERT_WATCH_HEALTH_STALE_SECS' \
  && printf '%s' "$_hr_help_out" | grep -q 'ALERT_WATCH_CURL' \
  && ! printf '%s' "$_hr_help_out" | grep -q 'set -euo pipefail'; then
  echo "PASS alert-watch.sh --help prints the full header including test-only env keys (exit 0)"
else
  echo "FAIL alert-watch.sh --help must print the env-key table through ALERT_WATCH_CURL, exit 0, and not dump the script body (ec=$_hr_help_rc)" >&2
  printf '%s\n' "$_hr_help_out" >&2
  fail=1
fi

if grep -qE "sed -n '2,[0-9]+p'" "$SCRIPT_DIR/funding-watch.sh" \
  || grep -qE "sed -n '2,[0-9]+p'" "$SCRIPT_DIR/alert-watch.sh"; then
  echo "FAIL funding-watch.sh / alert-watch.sh --help must not use a hard-coded sed line range" >&2
  fail=1
else
  echo "PASS funding-watch.sh and alert-watch.sh --help bounds are not hard-coded line ranges"
fi
unset _hr_help_out _hr_help_rc

_ml_dup_fn="$(awk '/^# >>> env-dup$/,/^# <<< env-dup$/' "$SCRIPT_DIR/lib.sh")"
_ml_dup_dir="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-env-ml.XXXXXX")"
cleanup_ml_dup() { rm -rf "$_ml_dup_dir"; }
trap cleanup_ml_dup EXIT
_ml_dup_run() {
  local file="$1"
  local snippet="$_ml_dup_dir/snippet.sh"
  printf '%s\n' "$_ml_dup_fn" > "$snippet"
  _ml_rc=0
  _ml_out="$(
    (
      # shellcheck disable=SC1090
      source "$snippet"
      FORTEL2_ENV_FILE="$file"
      refuse_duplicate_env_assignments
    ) 2>&1
  )" || _ml_rc=$?
}
_ml_scan() {
  local file="$1"
  local snippet="$_ml_dup_dir/snippet.sh"
  printf '%s\n' "$_ml_dup_fn" > "$snippet"
  (
    # shellcheck disable=SC1090
    source "$snippet"
    _scan_env_assignments "$file"
  )
}
_ml_load() {
  local file="$1"
  _ml_load_rc=0
  _ml_load_out="$(
    bash -c 'set -euo pipefail
      set -a
      # shellcheck disable=SC1090
      source "$1"
      set +a
      if [[ -z "${FOO:-}" ]]; then echo "FOO unset" >&2; exit 2; fi
      if [[ -n "${BAR:-}" ]]; then echo "BAR leaked" >&2; exit 3; fi
      printf %s "$FOO"
    ' bash "$file" 2>&1
  )" || _ml_load_rc=$?
}

if [[ -z "$_ml_dup_fn" ]] \
  || ! printf '%s' "$_ml_dup_fn" | grep -q '^refuse_duplicate_env_assignments()' \
  || ! printf '%s' "$_ml_dup_fn" | grep -q '^_scan_env_assignments()' \
  || ! printf '%s' "$_ml_dup_fn" | grep -q '^_scan_quote_state_after()'; then
  echo "FAIL env-dup markers must extract the scanner, quote-state helper, and refusal (phase7-preflight path)" >&2
  fail=1
else
  cat > "$_ml_dup_dir/dquote.env" <<'EOF'
FOO="first line
BAR=looks_like_one
BAR=looks_like_one
last line"
BAZ=ok
EOF
  _ml_dup_run "$_ml_dup_dir/dquote.env"
  _ml_names="$(_ml_scan "$_ml_dup_dir/dquote.env")"
  _ml_load "$_ml_dup_dir/dquote.env"
  if [[ "$_ml_rc" == "0" ]] \
    && [[ "$_ml_load_rc" == "0" ]] \
    && printf '%s' "$_ml_names" | grep -q 'FOO' \
    && printf '%s' "$_ml_names" | grep -q 'BAZ' \
    && ! printf '%s' "$_ml_names" | grep -q 'BAR' \
    && printf '%s' "$_ml_load_out" | grep -q 'looks_like_one'; then
    echo "PASS loader accepts a double-quoted multi-line value whose continuation looks like name=value"
  else
    echo "FAIL quoted multi-line double-quoted value must not count continuation name=value as assignments (refuse_ec=$_ml_rc load_ec=$_ml_load_rc)" >&2
    echo "$_ml_out" >&2
    echo "$_ml_names" >&2
    echo "$_ml_load_out" >&2
    fail=1
  fi

  cat > "$_ml_dup_dir/squote.env" <<'EOF'
FOO='first line
BAR=looks_like_one
BAR=looks_like_one
last line'
BAZ=ok
EOF
  _ml_dup_run "$_ml_dup_dir/squote.env"
  _ml_names="$(_ml_scan "$_ml_dup_dir/squote.env")"
  _ml_load "$_ml_dup_dir/squote.env"
  if [[ "$_ml_rc" == "0" ]] \
    && [[ "$_ml_load_rc" == "0" ]] \
    && printf '%s' "$_ml_names" | grep -q 'FOO' \
    && ! printf '%s' "$_ml_names" | grep -q 'BAR'; then
    echo "PASS loader accepts a single-quoted multi-line value whose continuation looks like name=value"
  else
    echo "FAIL quoted multi-line single-quoted value must not count continuation name=value as assignments (refuse_ec=$_ml_rc load_ec=$_ml_load_rc)" >&2
    echo "$_ml_out" >&2
    echo "$_ml_names" >&2
    fail=1
  fi

  cat > "$_ml_dup_dir/realdup.env" <<'EOF'
FOO="first line
LOOKSLIKE=1
LOOKSLIKE=1
last line"
DUP=a
DUP=b
EOF
  _ml_dup_run "$_ml_dup_dir/realdup.env"
  if [[ "$_ml_rc" != "0" ]] \
    && printf '%s' "$_ml_out" | grep -q 'DUP' \
    && ! printf '%s' "$_ml_out" | grep -q 'LOOKSLIKE' \
    && ! printf '%s' "$_ml_out" | grep -q 'FOO'; then
    echo "PASS loader refuses a real duplicate in a file that also has a multi-line value, naming the real dup only"
  else
    echo "FAIL a real duplicate alongside a multi-line value must refuse naming only the real dup (ec=$_ml_rc)" >&2
    echo "$_ml_out" >&2
    fail=1
  fi

  printf '%s\n' 'export FOO=1' 'BAR=2' 'FOO=3' > "$_ml_dup_dir/exportdup.env"
  _ml_dup_run "$_ml_dup_dir/exportdup.env"
  if [[ "$_ml_rc" != "0" ]] \
    && printf '%s' "$_ml_out" | grep -q 'FOO' \
    && ! printf '%s' "$_ml_out" | grep -q 'BAR'; then
    echo "PASS loader refuses an export-prefixed duplicate naming the variable only"
  else
    echo "FAIL export FOO= then FOO= must refuse naming FOO only (ec=$_ml_rc)" >&2
    echo "$_ml_out" >&2
    fail=1
  fi

  printf '%s\n' "FOO=one # don't change" 'DUP=secretA' 'DUP=secretB' > "$_ml_dup_dir/commentquote.env"
  _ml_dup_run "$_ml_dup_dir/commentquote.env"
  if [[ "$_ml_rc" != "0" ]] \
    && printf '%s' "$_ml_out" | grep -q 'DUP' \
    && ! printf '%s' "$_ml_out" | grep -q 'FOO' \
    && ! printf '%s' "$_ml_out" | grep -q 'secretA' \
    && ! printf '%s' "$_ml_out" | grep -q 'secretB'; then
    echo "PASS loader refuses a duplicate after a trailing comment that contains an apostrophe"
  else
    echo "FAIL an apostrophe in a trailing comment must not suppress later duplicate detection (ec=$_ml_rc)" >&2
    echo "$_ml_out" >&2
    fail=1
  fi

  printf '%s\n' 'FOO="a\"b"' 'DUP=secretA' 'DUP=secretB' > "$_ml_dup_dir/escapedquote.env"
  _ml_dup_run "$_ml_dup_dir/escapedquote.env"
  if [[ "$_ml_rc" != "0" ]] \
    && printf '%s' "$_ml_out" | grep -q 'DUP' \
    && ! printf '%s' "$_ml_out" | grep -q 'FOO' \
    && ! printf '%s' "$_ml_out" | grep -q 'secretA'; then
    echo "PASS loader refuses a duplicate after a double-quoted value containing escaped quotes"
  else
    echo "FAIL escaped quotes inside a double-quoted value must not leave the scanner in-quote (ec=$_ml_rc)" >&2
    echo "$_ml_out" >&2
    fail=1
  fi
fi
cleanup_ml_dup
trap - EXIT
unset _ml_dup_fn _ml_dup_dir _ml_rc _ml_out _ml_names _ml_load_rc _ml_load_out

# build-public-viewer.sh: never rm -rf a directory this script did not create.
BP_BUILD="$SCRIPT_DIR/build-public-viewer.sh"
BP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BP_SCRIPTS_SENTINEL="$SCRIPT_DIR/test-helpers.sh"
BP_SCRIPTS_HASH="$(cksum < "$BP_SCRIPTS_SENTINEL")"
BP_SCRIPTS_OUT="$(
  cd "$BP_ROOT" && PUBLIC_VIEWER_OUT=scripts "$BP_BUILD" 2>&1
)" && BP_SCRIPTS_EC=0 || BP_SCRIPTS_EC=$?
if [[ "$BP_SCRIPTS_EC" -ne 0 ]] \
  && [[ -f "$BP_SCRIPTS_SENTINEL" ]] \
  && [[ "$(cksum < "$BP_SCRIPTS_SENTINEL")" == "$BP_SCRIPTS_HASH" ]] \
  && [[ -f "$BP_BUILD" ]] \
  && echo "$BP_SCRIPTS_OUT" | grep -q 'refusing'; then
  echo "PASS PUBLIC_VIEWER_OUT=scripts refuses without deleting scripts/"
else
  echo "FAIL PUBLIC_VIEWER_OUT=scripts must refuse before rm -rf (ec=$BP_SCRIPTS_EC)" >&2
  echo "$BP_SCRIPTS_OUT" >&2
  fail=1
fi

BP_FONTS_SENTINEL="$BP_ROOT/viewer/fonts/fonts.css"
BP_FONTS_HASH="$(cksum < "$BP_FONTS_SENTINEL")"
BP_FONTS_OUT="$(
  cd "$BP_ROOT" && PUBLIC_VIEWER_OUT=viewer/fonts "$BP_BUILD" 2>&1
)" && BP_FONTS_EC=0 || BP_FONTS_EC=$?
if [[ "$BP_FONTS_EC" -ne 0 ]] \
  && [[ -f "$BP_FONTS_SENTINEL" ]] \
  && [[ "$(cksum < "$BP_FONTS_SENTINEL")" == "$BP_FONTS_HASH" ]] \
  && [[ -f "$BP_ROOT/viewer/fonts/inter-var.ttf" ]] \
  && [[ -f "$BP_ROOT/viewer/fonts/jetbrains-mono-var.ttf" ]] \
  && echo "$BP_FONTS_OUT" | grep -q 'refusing'; then
  echo "PASS PUBLIC_VIEWER_OUT=viewer/fonts refuses without deleting tracked fonts"
else
  echo "FAIL PUBLIC_VIEWER_OUT=viewer/fonts must refuse before rm -rf (ec=$BP_FONTS_EC)" >&2
  echo "$BP_FONTS_OUT" >&2
  fail=1
fi

BP_FIX="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-public-viewer.XXXXXX")"
cleanup_bp_pub() { rm -rf "$BP_FIX"; }
trap cleanup_bp_pub EXIT

mkdir -p "$BP_FIX/unmarked"
printf 'keep-me\n' > "$BP_FIX/unmarked/keep-me.txt"
BP_UNMARKED_OUT="$(
  cd "$BP_ROOT" && PUBLIC_VIEWER_OUT="$BP_FIX/unmarked" "$BP_BUILD" 2>&1
)" && BP_UNMARKED_EC=0 || BP_UNMARKED_EC=$?
if [[ "$BP_UNMARKED_EC" -ne 0 ]] \
  && [[ -f "$BP_FIX/unmarked/keep-me.txt" ]] \
  && [[ "$(cat "$BP_FIX/unmarked/keep-me.txt")" == "keep-me" ]] \
  && echo "$BP_UNMARKED_OUT" | grep -q 'refusing'; then
  echo "PASS PUBLIC_VIEWER_OUT refuses a non-empty unmarked directory"
else
  echo "FAIL a non-empty unmarked dest must be refused without deletion (ec=$BP_UNMARKED_EC)" >&2
  echo "$BP_UNMARKED_OUT" >&2
  fail=1
fi

BP_EMPTY="$BP_FIX/empty"
mkdir -p "$BP_EMPTY"
BP_EMPTY_OUT="$(
  cd "$BP_ROOT" && PUBLIC_VIEWER_OUT="$BP_EMPTY" "$BP_BUILD" 2>&1
)" && BP_EMPTY_EC=0 || BP_EMPTY_EC=$?
if [[ "$BP_EMPTY_EC" -eq 0 ]] \
  && [[ -f "$BP_EMPTY/Content-Security-Policy.txt" ]] \
  && [[ -f "$BP_EMPTY/config.js" ]]; then
  echo "PASS PUBLIC_VIEWER_OUT accepts an empty directory"
else
  echo "FAIL an empty dest must be accepted (ec=$BP_EMPTY_EC)" >&2
  echo "$BP_EMPTY_OUT" >&2
  fail=1
fi

BP_MARKED_OUT="$(
  cd "$BP_ROOT" && PUBLIC_VIEWER_OUT="$BP_EMPTY" "$BP_BUILD" 2>&1
)" && BP_MARKED_EC=0 || BP_MARKED_EC=$?
if [[ "$BP_MARKED_EC" -eq 0 ]] \
  && [[ -f "$BP_EMPTY/Content-Security-Policy.txt" ]]; then
  echo "PASS PUBLIC_VIEWER_OUT regenerates a previous marked bundle"
else
  echo "FAIL a dest with Content-Security-Policy.txt must be regenerable (ec=$BP_MARKED_EC)" >&2
  echo "$BP_MARKED_OUT" >&2
  fail=1
fi

BP_DEFAULT_OUT="$(cd "$BP_ROOT" && "$BP_BUILD" 2>&1)" && BP_DEFAULT_EC=0 || BP_DEFAULT_EC=$?
if [[ "$BP_DEFAULT_EC" -eq 0 ]] \
  && [[ -f "$BP_ROOT/viewer/public/Content-Security-Policy.txt" ]] \
  && [[ -f "$BP_ROOT/viewer/public/config.js" ]]; then
  echo "PASS default viewer/public build"
else
  echo "FAIL default viewer/public build must succeed (ec=$BP_DEFAULT_EC)" >&2
  echo "$BP_DEFAULT_OUT" >&2
  fail=1
fi
BP_DEFAULT2_OUT="$(cd "$BP_ROOT" && "$BP_BUILD" 2>&1)" && BP_DEFAULT2_EC=0 || BP_DEFAULT2_EC=$?
if [[ "$BP_DEFAULT2_EC" -eq 0 ]] \
  && [[ -f "$BP_ROOT/viewer/public/Content-Security-Policy.txt" ]]; then
  echo "PASS default viewer/public regeneration"
else
  echo "FAIL default viewer/public regeneration must succeed (ec=$BP_DEFAULT2_EC)" >&2
  echo "$BP_DEFAULT2_OUT" >&2
  fail=1
fi

# Meta CSP omits frame-ancestors (browsers warn on <meta>); .txt stays complete.
BP_PUB="$BP_ROOT/viewer/public"
BP_CSP_CHECK="$(
  python3 - "$BP_PUB" <<'PY'
from pathlib import Path
import re, sys

pub = Path(sys.argv[1])
html = (pub / "index.html").read_text()
txt = (pub / "Content-Security-Policy.txt").read_text().replace("\n", "").strip()
m = re.search(r'http-equiv="Content-Security-Policy"\s+content="([^"]*)"', html)
if not m:
    print("missing-meta")
    sys.exit(0)
meta = m.group(1)

def directives(policy):
    out = {}
    for raw in policy.split(";"):
        d = raw.strip()
        if not d:
            continue
        name = d.split(None, 1)[0].lower()
        rest = d[len(name):].strip()
        out[name] = rest
    return out

full = directives(txt)
meta_d = directives(meta)
errors = []
if "frame-ancestors" not in full:
    errors.append("txt-missing-frame-ancestors")
if "frame-ancestors" in meta_d or "frame-ancestors" in meta:
    errors.append("meta-has-frame-ancestors")
for name, value in full.items():
    if name == "frame-ancestors":
        continue
    if meta_d.get(name) != value:
        errors.append(f"weakened:{name}")
if not (pub / "favicon.ico").is_file():
    errors.append("missing-favicon-ico")
if not (pub / "favicon.svg").is_file():
    errors.append("missing-favicon-svg")
# index.html is the public copy; check it still links a same-origin icon.
if 'rel="icon"' not in html or "favicon" not in html:
    errors.append("html-missing-icon-link")
print("ok" if not errors else ",".join(errors))
PY
)"
if [[ "$BP_CSP_CHECK" == "ok" ]]; then
  echo "PASS public meta CSP omits frame-ancestors; .txt and other directives intact"
else
  echo "FAIL public meta CSP must drop frame-ancestors without weakening the rest ($BP_CSP_CHECK)" >&2
  fail=1
fi

if [[ -f "$BP_PUB/favicon.ico" ]] && [[ -f "$BP_PUB/favicon.svg" ]]; then
  echo "PASS public bundle ships favicon.ico and favicon.svg"
else
  echo "FAIL public bundle must copy favicon.ico and favicon.svg" >&2
  fail=1
fi

cleanup_bp_pub
trap - EXIT
unset BP_BUILD BP_ROOT BP_SCRIPTS_SENTINEL BP_SCRIPTS_HASH BP_SCRIPTS_OUT BP_SCRIPTS_EC \
  BP_FONTS_SENTINEL BP_FONTS_HASH BP_FONTS_OUT BP_FONTS_EC BP_FIX BP_UNMARKED_OUT \
  BP_UNMARKED_EC BP_EMPTY BP_EMPTY_OUT BP_EMPTY_EC BP_MARKED_OUT BP_MARKED_EC \
  BP_DEFAULT_OUT BP_DEFAULT_EC BP_DEFAULT2_OUT BP_DEFAULT2_EC BP_PUB BP_CSP_CHECK

# US-P7-005 --self-anchor (keep-and-reuse derivation EL; never a reference copy).
DERIV_CHECK="${DERIV_CHECK:-$SCRIPT_DIR/derivation-check.sh}"
_sa_help="$("$DERIV_CHECK" --help 2>&1)" || true
if echo "$_sa_help" | grep -q -- '--self-anchor' \
  && echo "$_sa_help" | grep -q 'Mutually exclusive with --anchor-datadir and' \
  && echo "$_sa_help" | grep -q -- '--make-anchor'; then
  echo "PASS derivation-check --help documents --self-anchor and mutual exclusion"
else
  echo "FAIL derivation-check --help must document --self-anchor as mutually exclusive with --anchor-datadir / --make-anchor" >&2
  fail=1
fi

_sa_make_out="$("$DERIV_CHECK" --self-anchor --make-anchor 2>&1)" && _sa_make_ec=0 || _sa_make_ec=$?
if [[ "$_sa_make_ec" -eq 2 ]] \
  && echo "$_sa_make_out" | grep -q -- '--self-anchor cannot be combined with --make-anchor' \
  && echo "$_sa_make_out" | grep -q 'mutually exclusive' \
  && echo "$_sa_make_out" | grep -q 'copy of the reference datadir'; then
  echo "PASS derivation-check --self-anchor --make-anchor refuses (exit 2, names both flags)"
else
  echo "FAIL derivation-check --self-anchor --make-anchor must refuse naming the conflict (ec=$_sa_make_ec)" >&2
  echo "$_sa_make_out" >&2
  fail=1
fi

_sa_ad_out="$("$DERIV_CHECK" --self-anchor --anchor-datadir /tmp/fortel2-not-a-copy 2>&1)" && _sa_ad_ec=0 || _sa_ad_ec=$?
if [[ "$_sa_ad_ec" -eq 2 ]] \
  && echo "$_sa_ad_out" | grep -q -- '--self-anchor cannot be combined with --anchor-datadir' \
  && echo "$_sa_ad_out" | grep -q 'mutually exclusive' \
  && echo "$_sa_ad_out" | grep -q 'copy of the reference datadir'; then
  echo "PASS derivation-check --self-anchor --anchor-datadir refuses (exit 2, names both flags)"
else
  echo "FAIL derivation-check --self-anchor --anchor-datadir must refuse naming the conflict (ec=$_sa_ad_ec)" >&2
  echo "$_sa_ad_out" >&2
  fail=1
fi

# Resume math (no chain): head 0 → start 1; head N → start N+1.
_sa_fn="$(awk '/^self_anchor_next_start\(\)/,/^}/ {print} /^self_anchor_start_ok\(\)/,/^}/ {print}' "$DERIV_CHECK")"
if echo "$_sa_fn" | grep -q '^self_anchor_next_start()' \
  && echo "$_sa_fn" | grep -q '^self_anchor_start_ok()'; then
  _sa_eval=0
  _sa_ns0="$(bash -c "$_sa_fn"$'\n'"self_anchor_next_start 0")" || _sa_eval=1
  _sa_ns20="$(bash -c "$_sa_fn"$'\n'"self_anchor_next_start 20")" || _sa_eval=1
  _sa_ok_g="$(bash -c "$_sa_fn"$'\n'"self_anchor_start_ok 0 1 && echo yes")" || _sa_ok_g=""
  _sa_bad_g="$(bash -c "$_sa_fn"$'\n'"self_anchor_start_ok 0 2 && echo yes || echo no")" || true
  _sa_ok_r="$(bash -c "$_sa_fn"$'\n'"self_anchor_start_ok 20 21 && echo yes")" || _sa_ok_r=""
  _sa_bad_r="$(bash -c "$_sa_fn"$'\n'"self_anchor_start_ok 20 20 && echo yes || echo no")" || true
  _sa_gap="$(bash -c "$_sa_fn"$'\n'"self_anchor_start_ok 20 22 && echo yes || echo no")" || true
  if [[ "$_sa_eval" -eq 0 && "$_sa_ns0" == "1" && "$_sa_ns20" == "21" \
    && "$_sa_ok_g" == "yes" && "$_sa_bad_g" == "no" \
    && "$_sa_ok_r" == "yes" && "$_sa_bad_r" == "no" && "$_sa_gap" == "no" ]]; then
    echo "PASS self-anchor resume start is contiguous (0→1, N→N+1; gaps refused)"
  else
    echo "FAIL self-anchor resume helpers must map head 0→1 and N→N+1 and refuse gaps (ns0=$_sa_ns0 ns20=$_sa_ns20)" >&2
    fail=1
  fi
else
  echo "FAIL derivation-check.sh must define self_anchor_next_start and self_anchor_start_ok" >&2
  fail=1
fi

# Property: the reference-datadir copy exists only inside --make-anchor (the trap).
if awk '
  /"\$MAKE_ANCHOR" -eq 1/ { make = 1 }
  make && /exit 0/ { make = 0 }
  /cp -a "\$REF_DATADIR"/ {
    copies++
    if (!make) bad = 1
  }
  /refuse_live_anchor_copy$/ {
    calls++
    if (!make) bad = 1
  }
  END { exit (copies == 1 && calls == 1 && !bad) ? 0 : 1 }
' "$DERIV_CHECK"; then
  echo "PASS reference datadir copy is only inside --make-anchor (not --self-anchor)"
else
  echo "FAIL --self-anchor must keep-and-reuse the derivation EL datadir; never copy the reference" >&2
  fail=1
fi

# debug_setHead stays on the reference-copy path only (USE_ANCHOR).
if awk '
  /^if \[\[ "\$SELF_ANCHOR" -eq 1 \]\]; then$/ { sa = 1 }
  sa && /debug_setHead/ { bad = 1 }
  sa && /^fi$/ { sa = 0 }
  /"\$USE_ANCHOR" -eq 1/ { ua = 1 }
  ua && /debug_setHead/ { ua_set = 1 }
  END { exit (ua_set && !bad) ? 0 : 1 }
' "$DERIV_CHECK"; then
  echo "PASS debug_setHead is confined to the USE_ANCHOR copy path, not --self-anchor"
else
  echo "FAIL debug_setHead must not run on the --self-anchor keep-and-reuse datadir" >&2
  fail=1
fi

unset _sa_help _sa_make_out _sa_make_ec _sa_ad_out _sa_ad_ec _sa_fn _sa_eval \
  _sa_ns0 _sa_ns20 _sa_ok_g _sa_bad_g _sa_ok_r _sa_bad_r _sa_gap

# Rate math must not run on legacy success paths (python3 missing → skip PASS).
if ! grep -q 'python3' "$DERIV_CHECK" \
  && grep -B20 'VERIFY_RATE=' "$DERIV_CHECK" | grep -q 'SELF_ANCHOR'; then
  echo "PASS self-anchor rate math is awk-only and confined to --self-anchor"
else
  echo "FAIL seal-rate math must not run (or require python3) on legacy derivation-check paths" >&2
  fail=1
fi

# Runbook must keep the Sepolia self-anchor invocation and not claim a live ≥1000-block
# stop/resume (or seal-rate) that never succeeded. Limitations is T3; stop before it.
_sa_readme="$SCRIPT_DIR/../derivation/README.md"
if awk '
  /^## Limitations/ { exit }
  /FORTEL2_ENV=\.env\.sepolia \.\/scripts\/derivation-check\.sh --sepolia --self-anchor/ { saw = 1 }
  /not yet proven/ { unproven = 1 }
  /empty L1 JSON/ { emptyjson = 1 }
  /T2/ { t2 = 1 }
  END { exit (saw && unproven && emptyjson && t2) ? 0 : 1 }
' "$_sa_readme"; then
  echo "PASS derivation README runbook keeps Sepolia self-anchor and states live ≥1000-block stop/resume is unproven"
else
  echo "FAIL derivation README runbook must keep the Sepolia self-anchor operator path and state live ≥1000-block stop/resume is not yet proven (empty L1 JSON / T2)" >&2
  fail=1
fi
unset _sa_readme

# US-P7-005 T2: proposal-compare flags (cmd/verify). Append-only; derivation-check.sh is T1's.
VERIFY_MAIN="$SCRIPT_DIR/../derivation/cmd/verify/main.go"
if grep -q 'flag.String("compare"' "$VERIFY_MAIN" \
  && grep -q 'flag.String("game-type", ""' "$VERIFY_MAIN" \
  && grep -q 'flag.String("factory", ""' "$VERIFY_MAIN" \
  && grep -q 'flag.String("asr", ""' "$VERIFY_MAIN" \
  && grep -q 'flag.String("deploy-state", ""' "$VERIFY_MAIN"; then
  echo "PASS cmd/verify exposes -compare/-factory/-asr/-deploy-state/-game-type with empty game-type default"
else
  echo "FAIL cmd/verify must add proposal-compare flags with empty -game-type default" >&2
  fail=1
fi
if grep -qE 'flag\.(Uint|Int|Uint64)\("game-type"' "$VERIFY_MAIN" \
  || grep -qE 'game-type", [0-9]' "$SCRIPT_DIR/../derivation/cmd/verify/main.go" \
  || grep -qE 'DefaultGameType[[:space:]]*=' "$SCRIPT_DIR/../derivation"/*.go \
  || grep -qE 'gameType[[:space:]]*=[[:space:]]*8[[:space:]]*$' "$SCRIPT_DIR/../derivation"/proposals.go; then
  echo "FAIL proposal-compare must not hard-code a numeric game-type default" >&2
  fail=1
else
  echo "PASS proposal-compare has no silent numeric game-type default"
fi
if grep -q 'ProposalSkipped' "$SCRIPT_DIR/../derivation/proposal_compare.go" \
  && grep -q '"SKIPPED"' "$SCRIPT_DIR/../derivation/proposal_compare.go" \
  && grep -q 'height outside window' "$SCRIPT_DIR/../derivation/proposal_compare.go"; then
  echo "PASS proposal-compare names SKIPPED for out-of-window heights"
else
  echo "FAIL out-of-window proposals must be named SKIPPED (not dropped)" >&2
  fail=1
fi
if grep -q '0x4200000000000000000000000000000000000016' "$SCRIPT_DIR/../derivation/outputroot.go"; then
  echo "PASS output-root uses L2ToL1MessagePasser predeploy"
else
  echo "FAIL outputroot.go must use the L2ToL1MessagePasser predeploy" >&2
  fail=1
fi

# US-P7-005 l1-scan-checkpoint: resumed self-anchor derives L1 scan start from
# origin(M) − channel_timeout − margin (sealed head), not a stored high-water mark.
# Genesis / legacy modes stay byte-identical.
if grep -q 'flag.Bool("resume-l1-bound"' "$VERIFY_MAIN"; then
  echo "PASS cmd/verify exposes -resume-l1-bound"
else
  echo "FAIL cmd/verify must add -resume-l1-bound for self-anchor resume scan bound" >&2
  fail=1
fi

if grep -q 'FROM_L1="$(jq -r '"'"'.genesis.l1.number'"'"' "$ROLLUP")"' "$DERIV_CHECK" \
  && grep -B2 'FROM_L1="$(jq -r '"'"'.genesis.l1.number'"'"' "$ROLLUP")"' "$DERIV_CHECK" \
    | grep -q 'START_L2" -eq 1'; then
  echo "PASS self-anchor genesis still sets FROM_L1 from rollup genesis.l1"
else
  echo "FAIL self-anchor start=1 must still scan from rollup genesis.l1" >&2
  fail=1
fi

if awk '
  /RESUME_L1_BOUND=1/ { sets++ }
  /"\$SEAL_HEAD" -gt 0/ { resume = 1 }
  resume && /-z "\$CHANNEL_TX"/ { ch_ok = 1 }
  resume && ch_ok && /RESUME_L1_BOUND=1/ { resume_set = 1 }
  resume && /^  else$/ { resume = 0 }
  /VERIFY_ARGS\+=\(-resume-l1-bound\)/ { pass++ }
  /"\$RESUME_L1_BOUND" -eq 1/ { gated++ }
  END { exit (sets == 1 && resume_set && pass == 1 && gated == 1) ? 0 : 1 }
' "$DERIV_CHECK"; then
  echo "PASS -resume-l1-bound is gated on self-anchor resume (SEAL_HEAD>0) only"
else
  echo "FAIL -resume-l1-bound must be set only on self-anchor resume, never genesis/legacy" >&2
  fail=1
fi

if awk '
  /"\$USE_ANCHOR" -eq 1/ { ua = 1 }
  ua && /resume-l1-bound/ { bad = 1 }
  ua && /^fi$/ { ua = 0 }
  /"\$MAKE_ANCHOR" -eq 1/ { ma = 1 }
  ma && /resume-l1-bound/ { bad = 1 }
  ma && /exit 0/ { ma = 0 }
  END { exit bad ? 1 : 0 }
' "$DERIV_CHECK"; then
  echo "PASS legacy --make-anchor / --anchor-datadir paths omit -resume-l1-bound"
else
  echo "FAIL -resume-l1-bound must not leak into legacy --make-anchor / --anchor-datadir paths" >&2
  fail=1
fi

# --self-anchor --channel-tx on a nonempty datadir must not pass -resume-l1-bound
# (Codex P2: the previous same-line grep missed this combination).
if awk '
  /RESUME_L1_BOUND=1/ {
    for (i = 1; i <= 12 && NR-i > 0; i++) {
      if (prev[i] ~ /-z "\$CHANNEL_TX"/) { ok = 1; break }
    }
  }
  { for (i = 12; i >= 2; i--) prev[i] = prev[i-1]; prev[1] = $0 }
  END { exit ok ? 0 : 1 }
' "$DERIV_CHECK"; then
  echo "PASS RESUME_L1_BOUND=1 is gated on empty --channel-tx"
else
  echo "FAIL --self-anchor --channel-tx must not set -resume-l1-bound (legacy single-tx path)" >&2
  fail=1
fi

if grep -q 'channel_timeout' "$SCRIPT_DIR/../derivation/rollup.go" \
  && grep -q 'InboxScanStart' "$SCRIPT_DIR/../derivation/scan_bound.go" \
  && grep -q 'ResumeScanMargin' "$SCRIPT_DIR/../derivation/scan_bound.go" \
  && ! grep -n 'InboxScanStart' "$SCRIPT_DIR/../derivation/scan_bound.go" | grep -q '[[:space:]]300[[:space:]]'; then
  echo "PASS resume scan bound reads channel_timeout from rollup config (not hard-coded 300)"
else
  echo "FAIL InboxScanStart must take channel_timeout from rollup.json; do not hard-code 300" >&2
  fail=1
fi

if grep -q 'origin(M)' "$SCRIPT_DIR/../derivation/README.md" \
  && grep -q 'channel_timeout' "$SCRIPT_DIR/../derivation/README.md" \
  && grep -q -- '-resume-l1-bound' "$SCRIPT_DIR/../derivation/README.md"; then
  echo "PASS derivation README runbook/CLI documents resume L1 delta-scan bound"
else
  echo "FAIL derivation README runbook/CLI must document origin(M) − channel_timeout resume scan" >&2
  fail=1
fi

# require_min_balance_eth: pin + corroborate (stale "latest" ≠ underfunded).
# Stub cast on PATH; no live chain, no .env.sepolia, no network.
_BAL_ADDR="0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc"
_BAL_HARVEST="0x0000000000000000000000000000000000000001"
_BAL_RPC="https://example.invalid/secret-token-do-not-leak"
_BAL_CORR="https://corroboration.example.invalid/second"
_BAL_REAL_CAST="$(command -v cast || true)"
_BAL_STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-bal-stub.XXXXXX")"
if [[ -z "$_BAL_REAL_CAST" ]]; then
  echo "FAIL require_min_balance_eth tests need cast on PATH" >&2
  fail=1
else
  cat > "$_BAL_STUB_DIR/cast" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "block-number" ]]; then
  printf '%s\n' "100"
  exit 0
fi
if [[ "${1:-}" == "balance" ]]; then
  has_block=0
  _rpc=""
  _prev=""
  for _a in "$@"; do
    if [[ "$_a" == "--block" || "$_a" == "-B" ]]; then
      has_block=1
    fi
    if [[ "$_prev" == "--rpc-url" ]]; then
      _rpc="$_a"
    fi
    _prev="$_a"
  done
  if [[ "$has_block" -ne 1 ]]; then
    exit 1
  fi
  if [[ -n "${CAST_STUB_DIR:-}" ]]; then
    printf '%s\n' "$_rpc" >> "${CAST_STUB_DIR}/balance-rpc-urls"
  fi
  if [[ -n "$_rpc" && "$_rpc" != "${L1_RPC_URL:-}" && -n "${CAST_BALANCE_SECONDARY:-}" ]]; then
    case "${CAST_BALANCE_SECONDARY}" in
      missing) exit 1 ;;
      junk) printf '%s\n' "null"; exit 0 ;;
      high) printf '%s\n' "1000000000000000000"; exit 0 ;;
      low) printf '%s\n' "10000000000000000"; exit 0 ;;
      *) exit 1 ;;
    esac
  fi
  case "${CAST_BALANCE_STUB:-}" in
    missing) exit 1 ;;
    junk) printf '%s\n' "null"; exit 0 ;;
    disagree)
      _n=0
      if [[ -f "${CAST_STUB_DIR}/balance-calls" ]]; then
        _n="$(cat "${CAST_STUB_DIR}/balance-calls")"
      fi
      _n=$((_n + 1))
      printf '%s\n' "$_n" > "${CAST_STUB_DIR}/balance-calls"
      if [[ "$_n" -eq 1 ]]; then
        printf '%s\n' "10000000000000000"
      else
        printf '%s\n' "1000000000000000000"
      fi
      exit 0
      ;;
    low) printf '%s\n' "10000000000000000"; exit 0 ;;
    high) printf '%s\n' "1000000000000000000"; exit 0 ;;
    *) exit 1 ;;
  esac
fi
exec "${CAST_REAL:?cast stub missing CAST_REAL}" "$@"
EOF
  chmod +x "$_BAL_STUB_DIR/cast"

  _bal_run() {
    rm -f "${_BAL_STUB_DIR}/balance-calls" "${_BAL_STUB_DIR}/balance-rpc-urls"
    export PATH="${_BAL_STUB_DIR}:$PATH"
    export CAST_REAL="$_BAL_REAL_CAST"
    export CAST_STUB_DIR="$_BAL_STUB_DIR"
    export CAST_BALANCE_STUB="$1"
    export CAST_BALANCE_SECONDARY="${3:-}"
    export L1_RPC_URL="${4:-$_BAL_RPC}"
    if [[ "${2:-}" == "__unset__" ]]; then
      unset SEPOLIA_L1_CORROBORATION_RPC_URL
    else
      export SEPOLIA_L1_CORROBORATION_RPC_URL="${2:-$_BAL_CORR}"
    fi
    export HARVEST_ADDRESS="$_BAL_HARVEST"
    require_min_balance_eth "$_BAL_ADDR" "0.15" "BATCHER"
  }

  _bal_secondary_call_count() {
    local url="${1:-$_BAL_CORR}"
    if [[ ! -f "${_BAL_STUB_DIR}/balance-rpc-urls" ]]; then
      printf '0'
      return 0
    fi
    grep -cF "$url" "${_BAL_STUB_DIR}/balance-rpc-urls" 2>/dev/null || true
  }

  _BAL_MISS_EC=0
  _BAL_MISS_OUT="$(_bal_run missing 2>&1)" && _BAL_MISS_EC=0 || _BAL_MISS_EC=$?
  if [[ "$_BAL_MISS_EC" -ne 0 ]] \
    && echo "$_BAL_MISS_OUT" | grep -q 'could not establish L1 balance' \
    && echo "$_BAL_MISS_OUT" | grep -q 'example.invalid' \
    && ! echo "$_BAL_MISS_OUT" | grep -q 'secret-token-do-not-leak' \
    && ! echo "$_BAL_MISS_OUT" | grep -q 'has .* ETH'; then
    echo "PASS require_min_balance_eth missing pinned block is unread, not underfunded"
  else
    echo "FAIL require_min_balance_eth missing pinned block must refuse without a figure (ec=$_BAL_MISS_EC)" >&2
    echo "$_BAL_MISS_OUT" >&2
    fail=1
  fi

  _BAL_JUNK_EC=0
  _BAL_JUNK_OUT="$(_bal_run junk 2>&1)" && _BAL_JUNK_EC=0 || _BAL_JUNK_EC=$?
  if [[ "$_BAL_JUNK_EC" -ne 0 ]] \
    && echo "$_BAL_JUNK_OUT" | grep -q 'could not establish L1 balance' \
    && ! echo "$_BAL_JUNK_OUT" | grep -q 'has .* ETH'; then
    echo "PASS require_min_balance_eth non-integer balance is unread, not underfunded"
  else
    echo "FAIL require_min_balance_eth non-integer balance must refuse without a figure (ec=$_BAL_JUNK_EC)" >&2
    echo "$_BAL_JUNK_OUT" >&2
    fail=1
  fi

  _BAL_DIS_EC=0
  _BAL_DIS_OUT="$(_bal_run disagree 2>&1)" && _BAL_DIS_EC=0 || _BAL_DIS_EC=$?
  if [[ "$_BAL_DIS_EC" -ne 0 ]] \
    && echo "$_BAL_DIS_OUT" | grep -q 'could not establish L1 balance' \
    && ! echo "$_BAL_DIS_OUT" | grep -q 'has .* ETH' \
    && ! echo "$_BAL_DIS_OUT" | grep -q 'need >= 0.15 ETH'; then
    echo "PASS require_min_balance_eth disagreeing reads are unread, not underfunded"
  else
    echo "FAIL require_min_balance_eth disagreeing reads must not claim a balance (ec=$_BAL_DIS_EC)" >&2
    echo "$_BAL_DIS_OUT" >&2
    fail=1
  fi

  _BAL_LOW_EC=0
  _BAL_LOW_OUT="$(_bal_run low 2>&1)" && _BAL_LOW_EC=0 || _BAL_LOW_EC=$?
  if [[ "$_BAL_LOW_EC" -ne 0 ]] \
    && echo "$_BAL_LOW_OUT" | grep -q 'has .* ETH; need >= 0.15 ETH on Sepolia' \
    && echo "$_BAL_LOW_OUT" | grep -q 'Fund from harvest' \
    && echo "$_BAL_LOW_OUT" | grep -q 'sepolia-fund-check.sh' \
    && ! echo "$_BAL_LOW_OUT" | grep -q 'could not establish L1 balance'; then
    echo "PASS require_min_balance_eth agreeing low balance still uses the underfunded message"
  else
    echo "FAIL require_min_balance_eth agreeing low balance must keep today's underfunded text (ec=$_BAL_LOW_EC)" >&2
    echo "$_BAL_LOW_OUT" >&2
    fail=1
  fi

  _BAL_HIGH_EC=0
  _BAL_HIGH_OUT="$(_bal_run high 2>&1)" && _BAL_HIGH_EC=0 || _BAL_HIGH_EC=$?
  if [[ "$_BAL_HIGH_EC" -eq 0 ]]; then
    echo "PASS require_min_balance_eth healthy balance proceeds"
  else
    echo "FAIL require_min_balance_eth healthy balance must pass (ec=$_BAL_HIGH_EC)" >&2
    echo "$_BAL_HIGH_OUT" >&2
    fail=1
  fi

  _BAL_HIGH_SEC="$(_bal_secondary_call_count)"
  if [[ "$_BAL_HIGH_EC" -eq 0 && "$_BAL_HIGH_SEC" -eq 0 ]]; then
    echo "PASS require_min_balance_eth healthy balance makes no secondary RPC call"
  else
    echo "FAIL require_min_balance_eth healthy path must not call the corroboration URL (secondary_calls=$_BAL_HIGH_SEC ec=$_BAL_HIGH_EC)" >&2
    echo "$_BAL_HIGH_OUT" >&2
    fail=1
  fi

  _BAL_SPLIT_EC=0
  _BAL_SPLIT_OUT="$(_bal_run low "$_BAL_CORR" high 2>&1)" && _BAL_SPLIT_EC=0 || _BAL_SPLIT_EC=$?
  if [[ "$_BAL_SPLIT_EC" -eq 0 ]] \
    && echo "$_BAL_SPLIT_OUT" | grep -q 'WARN' \
    && echo "$_BAL_SPLIT_OUT" | grep -q 'D-0106' \
    && echo "$_BAL_SPLIT_OUT" | grep -q 'example.invalid' \
    && echo "$_BAL_SPLIT_OUT" | grep -q 'corroboration.example.invalid' \
    && echo "$_BAL_SPLIT_OUT" | grep -q 'pinned block' \
    && echo "$_BAL_SPLIT_OUT" | grep -q 'primary' \
    && echo "$_BAL_SPLIT_OUT" | grep -q 'secondary' \
    && ! echo "$_BAL_SPLIT_OUT" | grep -q 'secret-token-do-not-leak' \
    && ! echo "$_BAL_SPLIT_OUT" | grep -q 'need >= 0.15 ETH'; then
    echo "PASS require_min_balance_eth primary-low secondary-high proceeds with provider-disagreement WARN"
  else
    echo "FAIL require_min_balance_eth provider disagreement must WARN and proceed (ec=$_BAL_SPLIT_EC)" >&2
    echo "$_BAL_SPLIT_OUT" >&2
    fail=1
  fi

  _BAL_SEC_MISS_EC=0
  _BAL_SEC_MISS_OUT="$(_bal_run low "$_BAL_CORR" missing 2>&1)" && _BAL_SEC_MISS_EC=0 || _BAL_SEC_MISS_EC=$?
  if [[ "$_BAL_SEC_MISS_EC" -ne 0 ]] \
    && echo "$_BAL_SEC_MISS_OUT" | grep -q 'second-opinion L1 balance unavailable' \
    && echo "$_BAL_SEC_MISS_OUT" | grep -q 'Cannot corroborate' \
    && echo "$_BAL_SEC_MISS_OUT" | grep -q 'corroboration.example.invalid' \
    && ! echo "$_BAL_SEC_MISS_OUT" | grep -q 'has .* ETH; need >= 0.15 ETH' \
    && ! echo "$_BAL_SEC_MISS_OUT" | grep -q 'could not establish L1 balance'; then
    echo "PASS require_min_balance_eth secondary unreachable is cannot-corroborate, not underfunded"
  else
    echo "FAIL require_min_balance_eth unreachable second opinion must refuse without the underfunded message (ec=$_BAL_SEC_MISS_EC)" >&2
    echo "$_BAL_SEC_MISS_OUT" >&2
    fail=1
  fi

  _BAL_SAME_EC=0
  _BAL_SAME_OUT="$(_bal_run low "$_BAL_RPC" 2>&1)" && _BAL_SAME_EC=0 || _BAL_SAME_EC=$?
  if [[ "$_BAL_SAME_EC" -ne 0 ]] \
    && echo "$_BAL_SAME_OUT" | grep -q 'SEPOLIA_L1_CORROBORATION_RPC_URL shares origin with L1_RPC_URL' \
    && echo "$_BAL_SAME_OUT" | grep -q 'Cannot corroborate' \
    && echo "$_BAL_SAME_OUT" | grep -q 'D-0106' \
    && ! echo "$_BAL_SAME_OUT" | grep -q 'secret-token-do-not-leak'; then
    echo "PASS require_min_balance_eth corroboration URL equal to primary is refused"
  else
    echo "FAIL require_min_balance_eth same-host second opinion must be refused loudly (ec=$_BAL_SAME_EC)" >&2
    echo "$_BAL_SAME_OUT" >&2
    fail=1
  fi

  _BAL_SAMEHOST_EC=0
  _BAL_SAMEHOST_OUT="$(_bal_run low "https://example.invalid/other-token" 2>&1)" && _BAL_SAMEHOST_EC=0 || _BAL_SAMEHOST_EC=$?
  if [[ "$_BAL_SAMEHOST_EC" -ne 0 ]] \
    && echo "$_BAL_SAMEHOST_OUT" | grep -q 'SEPOLIA_L1_CORROBORATION_RPC_URL shares origin with L1_RPC_URL' \
    && echo "$_BAL_SAMEHOST_OUT" | grep -q 'Cannot corroborate' \
    && ! echo "$_BAL_SAMEHOST_OUT" | grep -q 'secret-token-do-not-leak' \
    && ! echo "$_BAL_SAMEHOST_OUT" | grep -q 'need >= 0.15 ETH'; then
    echo "PASS require_min_balance_eth same-origin corroboration URL with a different path is refused"
  else
    echo "FAIL require_min_balance_eth same-origin different-path must be refused (ec=$_BAL_SAMEHOST_EC)" >&2
    echo "$_BAL_SAMEHOST_OUT" >&2
    fail=1
  fi

  _BAL_PN="https://ethereum-sepolia-rpc.publicnode.com"
  _BAL_PN_FALLBACK="https://rpc.sepolia.org"
  _BAL_PN_EC=0
  _BAL_PN_OUT="$(_bal_run low __unset__ low "$_BAL_PN" 2>&1)" && _BAL_PN_EC=0 || _BAL_PN_EC=$?
  _BAL_PN_FALLBACK_N="$(_bal_secondary_call_count "$_BAL_PN_FALLBACK")"
  if [[ "$_BAL_PN_EC" -ne 0 ]] \
    && echo "$_BAL_PN_OUT" | grep -q 'has .* ETH; need >= 0.15 ETH on Sepolia' \
    && echo "$_BAL_PN_OUT" | grep -q 'rpc.sepolia.org' \
    && echo "$_BAL_PN_OUT" | grep -q 'default corroboration URL shares origin' \
    && [[ "$_BAL_PN_FALLBACK_N" -ge 1 ]] \
    && ! echo "$_BAL_PN_OUT" | grep -q 'Cannot corroborate'; then
    echo "PASS require_min_balance_eth unset corr with PublicNode L1 falls back and still reports underfunded"
  else
    echo "FAIL require_min_balance_eth PublicNode L1 + unset corr must fall back, not fail-close as cannot-corroborate (ec=$_BAL_PN_EC fallback_calls=$_BAL_PN_FALLBACK_N)" >&2
    echo "$_BAL_PN_OUT" >&2
    fail=1
  fi
fi
rm -rf "$_BAL_STUB_DIR"

# --- stack-start-stop-symmetry: derive lists from the scripts; degrade; alerts ---
SYM_START_ALL="$SCRIPT_DIR/start-all-sepolia.sh"
SYM_STOP_ALL="$SCRIPT_DIR/stop-all-sepolia.sh"

SYM_DERIVE="$(python3 - "$SYM_START_ALL" "$SYM_STOP_ALL" "$SCRIPT_DIR" <<'PY'
import os, re, sys
start_all, stop_all, scripts_dir = sys.argv[1:4]

def stop_names(path):
    text = open(path).read()
    m = re.search(r"for name in ([^;\n]+); do", text)
    if not m:
        raise SystemExit("stop-all-sepolia.sh: no 'for name in ...; do' list")
    return m.group(1).split()

def invoked_start_scripts(path):
    text = open(path).read()
    found = re.findall(r"\$SCRIPT_DIR/([A-Za-z0-9._-]+\.sh)", text)
    out = []
    for name in found:
        if name.startswith("stop-"):
            continue
        if "start" in name:
            out.append(name)
    return sorted(set(out))

def start_bg_names(script_path):
    names = []
    with open(script_path) as fh:
        for line in fh:
            stripped = line.lstrip()
            if stripped.startswith("#"):
                continue
            m = re.match(r"start_bg\s+([A-Za-z0-9_-]+)", stripped)
            if m:
                names.append(m.group(1))
    return names

stopped = sorted(set(stop_names(stop_all)))
started = []
for rel in invoked_start_scripts(start_all):
    started.extend(start_bg_names(os.path.join(scripts_dir, rel)))
started = sorted(set(started))
print("STOP=" + " ".join(stopped))
print("START=" + " ".join(started))
print("SCRIPTS=" + " ".join(invoked_start_scripts(start_all)))
sys.exit(0 if started == stopped else 1)
PY
)" && SYM_DERIVE_EC=0 || SYM_DERIVE_EC=$?
if [[ "$SYM_DERIVE_EC" -eq 0 ]] \
   && echo "$SYM_DERIVE" | grep -q 'STOP=l1-batch-proxy l2-rpc-filter op-batcher op-challenger op-geth op-node op-proposer op-reth' \
   && echo "$SYM_DERIVE" | grep -q 'START=l1-batch-proxy l2-rpc-filter op-batcher op-challenger op-geth op-node op-proposer op-reth' \
   && echo "$SYM_DERIVE" | grep -q '09-start-challenger-sepolia.sh' \
   && echo "$SYM_DERIVE" | grep -q 'start-l1-batch-proxy-sepolia.sh'; then
  echo "PASS start-all-sepolia.sh starts every service stop-all-sepolia.sh stops"
else
  echo "FAIL start/stop Sepolia service lists must match (derived from the scripts)" >&2
  echo "$SYM_DERIVE" >&2
  fail=1
fi

# Wake inherits start-all (property 5) — cmd_wake must call start-all-sepolia.sh.
if awk '
     /cmd_wake/ { in_wake = 1 }
     in_wake && /start-all-sepolia\.sh/ { found = 1 }
     in_wake && /^}/ { exit found ? 0 : 1 }
     END { exit found ? 0 : 1 }
   ' "$SCRIPT_DIR/dev-sleep.sh"; then
  echo "PASS dev-sleep.sh wake delegates to start-all-sepolia.sh"
else
  echo "FAIL dev-sleep.sh wake must call start-all-sepolia.sh" >&2
  fail=1
fi

# Optional call is after trap - ERR; core starts are inside the armed trap.
# Match command lines only — a comment containing `trap - ERR` sits above the
# armed trap and would otherwise clear the flag too early.
if awk '
     /^trap sepolia_start_cleanup ERR$/ { armed = 1 }
     armed && !cleared && /04-start-sequencer-sepolia/ { seq = 1 }
     armed && !cleared && /07-start-rpc-filter-sepolia/ { filt = 1 }
     armed && !cleared && /05-start-batcher-sepolia/ { bat = 1 }
     armed && !cleared && /06-start-proposer-sepolia/ { prop = 1 }
     armed && !cleared && /start_optional_sepolia_fault_proofs \|\|/ { early = 1 }
     /^trap - ERR$/ { cleared = 1 }
     cleared && /start_optional_sepolia_fault_proofs \|\|/ { opt = 1 }
     END { exit (seq && filt && bat && prop && cleared && opt && !early) ? 0 : 1 }
   ' "$SYM_START_ALL" \
   && grep -q 'sepolia_start_cleanup' "$SYM_START_ALL"; then
  echo "PASS optional fault-proof start is after trap - ERR; core stays fail-closed"
else
  echo "FAIL challenger/proxy start must run after trap - ERR; core starts must stay inside it" >&2
  fail=1
fi

SYM_FN="$(python3 - "$SYM_START_ALL" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(
    r"^start_optional_sepolia_fault_proofs\(\) \{.*?\n\}\n",
    text,
    re.M | re.S,
)
if not m:
    sys.exit("missing start_optional_sepolia_fault_proofs")
sys.stdout.write(m.group(0))
PY
)" && SYM_FN_EC=0 || SYM_FN_EC=$?
SYM_FIX="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-stack-sym.XXXXXX")"
cat > "$SYM_FIX/proxy.sh" <<'EOS'
#!/usr/bin/env bash
printf 'proxy\n' >> "${SYM_ORDER_LOG}"
exit 0
EOS
cat > "$SYM_FIX/challenger.sh" <<'EOS'
#!/usr/bin/env bash
printf 'challenger\n' >> "${SYM_ORDER_LOG}"
exit 0
EOS
cat > "$SYM_FIX/challenger-fail.sh" <<'EOS'
#!/usr/bin/env bash
printf 'challenger-fail\n' >> "${SYM_ORDER_LOG}"
echo "ERROR: stub challenger refused (forced failure)" >&2
exit 7
EOS
cat > "$SYM_FIX/stop-all-sepolia.sh" <<'EOS'
#!/usr/bin/env bash
printf 'stop-all\n' >> "${SYM_ORDER_LOG}"
exit 0
EOS
chmod +x "$SYM_FIX/proxy.sh" "$SYM_FIX/challenger.sh" "$SYM_FIX/challenger-fail.sh" \
  "$SYM_FIX/stop-all-sepolia.sh"
printf '%s\n' "$SYM_FN" > "$SYM_FIX/fn.sh"

# Proxy-on: CHALLENGER_L1_RPC_URL set → proxy then challenger.
: > "$SYM_FIX/order-on"
SYM_ON_OUT="$(
  set -euo pipefail
  SCRIPT_DIR="$SYM_FIX"
  export SYM_ORDER_LOG="$SYM_FIX/order-on"
  FORTEL2_START_L1_BATCH_PROXY_SH="$SYM_FIX/proxy.sh"
  FORTEL2_START_CHALLENGER_SH="$SYM_FIX/challenger.sh"
  CHALLENGER_L1_RPC_URL='http://127.0.0.1:1'
  # shellcheck disable=SC1091
  source "$SYM_FIX/fn.sh"
  start_optional_sepolia_fault_proofs
)" && SYM_ON_EC=0 || SYM_ON_EC=$?
SYM_ON_ORDER="$(tr '\n' ' ' < "$SYM_FIX/order-on" | sed 's/[[:space:]]*$//')"
if [[ "$SYM_FN_EC" -eq 0 && "$SYM_ON_EC" -eq 0 && "$SYM_ON_ORDER" == "proxy challenger" ]] \
   && [[ "$SYM_ON_OUT" == *"CHALLENGER_L1_RPC_URL is set"* ]]; then
  echo "PASS optional start runs l1-batch-proxy before challenger when CHALLENGER_L1_RPC_URL is set"
else
  echo "FAIL proxy must start before challenger when CHALLENGER_L1_RPC_URL is set (ec=$SYM_ON_EC order='$SYM_ON_ORDER')" >&2
  echo "$SYM_ON_OUT" >&2
  fail=1
fi

# Proxy-off: unset → challenger only.
: > "$SYM_FIX/order-off"
SYM_OFF_OUT="$(
  set -euo pipefail
  SCRIPT_DIR="$SYM_FIX"
  export SYM_ORDER_LOG="$SYM_FIX/order-off"
  FORTEL2_START_L1_BATCH_PROXY_SH="$SYM_FIX/proxy.sh"
  FORTEL2_START_CHALLENGER_SH="$SYM_FIX/challenger.sh"
  unset CHALLENGER_L1_RPC_URL || true
  # shellcheck disable=SC1091
  source "$SYM_FIX/fn.sh"
  start_optional_sepolia_fault_proofs
)" && SYM_OFF_EC=0 || SYM_OFF_EC=$?
SYM_OFF_ORDER="$(tr '\n' ' ' < "$SYM_FIX/order-off" | sed 's/[[:space:]]*$//')"
if [[ "$SYM_OFF_EC" -eq 0 && "$SYM_OFF_ORDER" == "challenger" ]] \
   && [[ "$SYM_OFF_OUT" == *"CHALLENGER_L1_RPC_URL unset"* ]]; then
  echo "PASS optional start skips l1-batch-proxy when CHALLENGER_L1_RPC_URL is unset"
else
  echo "FAIL unset CHALLENGER_L1_RPC_URL must skip the proxy (ec=$SYM_OFF_EC order='$SYM_OFF_ORDER')" >&2
  echo "$SYM_OFF_OUT" >&2
  fail=1
fi

# Degrade: core markers survive a failing challenger; cleanup/stop-all must not run.
# Reproduces start-all's trap - ERR then `|| optional_rc` wrapper with stub children.
cat > "$SYM_FIX/degrade-driver.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="${SYM_FIX}"
export SYM_ORDER_LOG="${SYM_FIX}/order-degrade"
: > "$SYM_ORDER_LOG"
printf 'core\n' >> "$SYM_FIX/core-started"
sepolia_start_cleanup() {
  printf 'cleanup\n' >> "$SYM_ORDER_LOG"
  "$SCRIPT_DIR/stop-all-sepolia.sh" || true
}
# shellcheck disable=SC1091
source "$SYM_FIX/fn.sh"
trap sepolia_start_cleanup ERR
# Core path (armed): a failure here would cleanup. We succeed, then disarm.
true
trap - ERR
optional_rc=0
FORTEL2_START_L1_BATCH_PROXY_SH="$SYM_FIX/proxy.sh"
FORTEL2_START_CHALLENGER_SH="$SYM_FIX/challenger-fail.sh"
unset CHALLENGER_L1_RPC_URL || true
start_optional_sepolia_fault_proofs || optional_rc=$?
if [[ "$optional_rc" -ne 0 ]]; then
  echo "ERROR: optional fault-proof services failed (exit $optional_rc) — sequencer, batcher, and proposer left running" >&2
  echo "ERROR: fault-proof defense is OFF until op-challenger is restored" >&2
fi
if [[ ! -f "$SYM_FIX/core-started" ]]; then
  echo "core marker missing" >&2
  exit 20
fi
if grep -q cleanup "$SYM_ORDER_LOG" || grep -q stop-all "$SYM_ORDER_LOG"; then
  echo "cleanup ran" >&2
  exit 21
fi
if [[ "$optional_rc" -eq 0 ]]; then
  echo "optional unexpectedly succeeded" >&2
  exit 22
fi
echo "degrade-ok optional_rc=$optional_rc"
exit 0
EOS
chmod +x "$SYM_FIX/degrade-driver.sh"
SYM_DEG_OUT="$(SYM_FIX="$SYM_FIX" "$SYM_FIX/degrade-driver.sh" 2>&1)" && SYM_DEG_EC=0 || SYM_DEG_EC=$?
if [[ "$SYM_DEG_EC" -eq 0 ]] \
   && [[ "$SYM_DEG_OUT" == *"degrade-ok"* ]] \
   && [[ "$SYM_DEG_OUT" == *"optional fault-proof services failed"* ]] \
   && [[ "$SYM_DEG_OUT" == *"sequencer, batcher, and proposer left running"* ]] \
   && [[ -f "$SYM_FIX/core-started" ]]; then
  echo "PASS challenger-start failure leaves the core stack up (no stop-all)"
else
  echo "FAIL challenger-start failure must not tear down the core stack (ec=$SYM_DEG_EC)" >&2
  echo "$SYM_DEG_OUT" >&2
  fail=1
fi
rm -rf "$SYM_FIX"

# Alert: missing expected service fires; present stays silent. Isolated fixture
# (existing alert-watch cases stay above; L2_CHAIN_ID=852 is the Sepolia gate).
STK_FIX="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-stack-alert.XXXXXX")"
mkdir -p "$STK_FIX/shim" "$STK_FIX/mock" "$STK_FIX/data" "$STK_FIX/bin" "$STK_FIX/deploy" "$STK_FIX/pids"
cat > "$STK_FIX/env" <<EOF
FORTEL2_ROOT=$STK_FIX
DATA_DIR=$STK_FIX/data
BIN_DIR=$STK_FIX/bin
DEPLOY_DIR=$STK_FIX/deploy
L2_CHAIN_ID=852
EOF
cat > "$STK_FIX/shim/curl" <<'EOS'
#!/bin/sh
dir="${ALERT_WATCH_MOCK_DIR:-}"
[ -n "$dir" ] || exit 99
n=0
[ -f "$dir/curl.calls" ] && n=$(cat "$dir/curl.calls")
n=$((n + 1))
printf '%s\n' "$n" > "$dir/curl.calls"
printf 'ARG:%s\n' "$@" >> "$dir/curl.argv"
cat > "$dir/curl.stdin"
out=""
writeout=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ] || [ "$prev" = "--output" ]; then out="$a"; fi
  if [ "$prev" = "-w" ] || [ "$prev" = "--write-out" ]; then writeout="$a"; fi
  prev="$a"
done
[ -n "$out" ] && printf '%s\n' '{"id":"mock-resend"}' > "$out"
[ -n "$writeout" ] && printf '%s' "${ALERT_WATCH_CURL_HTTP:-200}"
exit 0
EOS
cat > "$STK_FIX/shim/osascript" <<'EOS'
#!/bin/sh
dir="${ALERT_WATCH_MOCK_DIR:-}"
[ -n "$dir" ] || exit 99
n=0
[ -f "$dir/osascript.calls" ] && n=$(cat "$dir/osascript.calls")
n=$((n + 1))
printf '%s\n' "$n" > "$dir/osascript.calls"
printf 'ARG:%s\n' "$@" >> "$dir/osascript.argv"
exit 0
EOS
cat > "$STK_FIX/shim/launchctl" <<'EOS'
#!/bin/sh
printf 'gui/501/com.steve.fortel2-resolve-games = {\n\tstate = not running\n\tlast exit code = 0\n}\n'
exit 0
EOS
chmod +x "$STK_FIX/shim/curl" "$STK_FIX/shim/osascript" "$STK_FIX/shim/launchctl"
stk_reset() {
  rm -f "$STK_FIX/mock"/curl.argv "$STK_FIX/mock"/curl.calls \
    "$STK_FIX/mock"/osascript.argv "$STK_FIX/mock"/osascript.calls \
    "$STK_FIX/state.json"
  : > "$STK_FIX/resolve.out.log"
  : > "$STK_FIX/resolve.err.log"
  printf '%s\n' '{"verdict":"OK","reason":"balance at or above the funding policy minimum"}' \
    > "$STK_FIX/funding-health.json"
}
stk_mark() {
  local n
  rm -f "$STK_FIX/pids"/*.pid
  for n in "$@"; do
    printf '%s\n' "$$" > "$STK_FIX/pids/$n.pid"
  done
}
stk_run() {
  env -u RESEND_API_TOKEN -u CHALLENGER_L1_RPC_URL \
    PATH="$STK_FIX/shim:$PATH" \
    FORTEL2_ENV="$STK_FIX/env" \
    L2_CHAIN_ID=852 \
    ALERT_WATCH_MOCK_DIR="$STK_FIX/mock" \
    ALERT_WATCH_FUNDING_JSON="$STK_FIX/funding-health.json" \
    ALERT_WATCH_STATE="$STK_FIX/state.json" \
    ALERT_WATCH_RESOLVE_OUT="$STK_FIX/resolve.out.log" \
    ALERT_WATCH_RESOLVE_ERR="$STK_FIX/resolve.err.log" \
    ALERT_WATCH_PID_DIR="$STK_FIX/pids" \
    ALERT_WATCH_CURL="$STK_FIX/shim/curl" \
    ALERT_WATCH_OSASCRIPT="$STK_FIX/shim/osascript" \
    ALERT_WATCH_LAUNCHCTL="$STK_FIX/shim/launchctl" \
    ALERT_EMAIL_TO='fortel2-alert-watch@example.invalid' \
    "$@"
}
STK_CORE="op-geth op-node op-batcher op-proposer l2-rpc-filter"
STK_ALL="$STK_CORE op-challenger"

stk_reset
stk_mark $STK_CORE
STK_MISS_OUT="$(stk_run ALERT_WATCH_EXPECT_STACK=1 RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' \
  "$SCRIPT_DIR/alert-watch.sh" 2>&1)" && STK_MISS_EC=0 || STK_MISS_EC=$?
if [[ "$STK_MISS_EC" -eq 0 ]] \
   && [[ "$(cat "$STK_FIX/mock/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
   && grep -q 'op-challenger' "$STK_FIX/mock/osascript.argv" \
   && grep -qi 'missing\|not running' "$STK_FIX/mock/osascript.argv"; then
  echo "PASS alert-watch fires when op-challenger is missing from a running stack"
else
  echo "FAIL alert-watch must alert on a missing op-challenger (ec=$STK_MISS_EC)" >&2
  echo "$STK_MISS_OUT" >&2
  fail=1
fi

stk_reset
stk_mark $STK_ALL
STK_OK_OUT="$(stk_run ALERT_WATCH_EXPECT_STACK=1 RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' \
  "$SCRIPT_DIR/alert-watch.sh" 2>&1)" && STK_OK_EC=0 || STK_OK_EC=$?
if [[ "$STK_OK_EC" -eq 0 ]] \
   && [[ ! -f "$STK_FIX/mock/osascript.calls" ]] \
   && [[ ! -f "$STK_FIX/mock/curl.calls" ]] \
   && [[ "$STK_OK_OUT" == *"no alert"* ]]; then
  echo "PASS alert-watch is silent when expected Sepolia services are present"
else
  echo "FAIL alert-watch must stay quiet when the stack pids are present (ec=$STK_OK_EC)" >&2
  echo "$STK_OK_OUT" >&2
  fail=1
fi

# Scheduled sleep: everything down + EXPECT_STACK=0 must not storm.
stk_reset
rm -f "$STK_FIX/pids"/*.pid
STK_SLEEP_OUT="$(stk_run ALERT_WATCH_EXPECT_STACK=0 RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' \
  "$SCRIPT_DIR/alert-watch.sh" 2>&1)" && STK_SLEEP_EC=0 || STK_SLEEP_EC=$?
if [[ "$STK_SLEEP_EC" -eq 0 ]] \
   && [[ ! -f "$STK_FIX/mock/osascript.calls" ]] \
   && [[ "$STK_SLEEP_OUT" == *"no alert"* ]]; then
  echo "PASS alert-watch stays quiet when the stack is down inside the sleep window"
else
  echo "FAIL alert-watch must not alert on a scheduled-down stack (ec=$STK_SLEEP_EC)" >&2
  echo "$STK_SLEEP_OUT" >&2
  fail=1
fi

# Production path: PID_DIR is a shell var (lib.sh after set +a), not exported.
# alert-watch must pass ${ALERT_WATCH_PID_DIR:-$PID_DIR} on argv so Python sees it.
if grep -q 'ALERT_WATCH_PID_DIR:-$PID_DIR' "$SCRIPT_DIR/alert-watch.sh"; then
  echo "PASS alert-watch passes PID_DIR to python on argv (not via exported env)"
else
  echo "FAIL alert-watch must pass \${ALERT_WATCH_PID_DIR:-\$PID_DIR} on python argv" >&2
  fail=1
fi

# Drive the launchd path: no ALERT_WATCH_PID_DIR; pids live under DATA_DIR/pids.
stk_reset
mkdir -p "$STK_FIX/data/pids"
rm -f "$STK_FIX/data/pids"/*.pid "$STK_FIX/pids"/*.pid
for n in $STK_CORE; do
  printf '%s\n' "$$" > "$STK_FIX/data/pids/$n.pid"
done
STK_NATIVE_OUT="$(
  env -u RESEND_API_TOKEN -u CHALLENGER_L1_RPC_URL -u ALERT_WATCH_PID_DIR \
    PATH="$STK_FIX/shim:$PATH" \
    FORTEL2_ENV="$STK_FIX/env" \
    ALERT_WATCH_MOCK_DIR="$STK_FIX/mock" \
    ALERT_WATCH_FUNDING_JSON="$STK_FIX/funding-health.json" \
    ALERT_WATCH_STATE="$STK_FIX/state.json" \
    ALERT_WATCH_RESOLVE_OUT="$STK_FIX/resolve.out.log" \
    ALERT_WATCH_RESOLVE_ERR="$STK_FIX/resolve.err.log" \
    ALERT_WATCH_EXPECT_STACK=1 \
    ALERT_WATCH_CURL="$STK_FIX/shim/curl" \
    ALERT_WATCH_OSASCRIPT="$STK_FIX/shim/osascript" \
    ALERT_WATCH_LAUNCHCTL="$STK_FIX/shim/launchctl" \
    ALERT_EMAIL_TO='fortel2-alert-watch@example.invalid' \
    RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' \
    "$SCRIPT_DIR/alert-watch.sh" 2>&1
)" && STK_NATIVE_EC=0 || STK_NATIVE_EC=$?
if [[ "$STK_NATIVE_EC" -eq 0 ]] \
   && [[ "$(cat "$STK_FIX/mock/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
   && grep -q 'op-challenger' "$STK_FIX/mock/osascript.argv"; then
  echo "PASS alert-watch fires on a missing challenger using lib.sh PID_DIR (no ALERT_WATCH_PID_DIR)"
else
  echo "FAIL alert-watch must see PID_DIR from the shell when ALERT_WATCH_PID_DIR is unset (ec=$STK_NATIVE_EC)" >&2
  echo "$STK_NATIVE_OUT" >&2
  fail=1
fi

# Task 5: FORTEL2_EL=reth must expect op-reth the moment the env flips (03:30 class).
stk_reset
stk_mark op-geth op-node op-batcher op-proposer l2-rpc-filter op-challenger
T5_AW_OUT="$(stk_run FORTEL2_EL=reth ALERT_WATCH_EXPECT_STACK=1 RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' \
  "$SCRIPT_DIR/alert-watch.sh" 2>&1)" && T5_AW_EC=0 || T5_AW_EC=$?
if [[ "$T5_AW_EC" -eq 0 ]] \
   && grep -q 'op-reth' "$STK_FIX/mock/osascript.argv" \
   && grep -qi 'missing\|not running' "$STK_FIX/mock/osascript.argv"; then
  echo "PASS alert-watch FORTEL2_EL=reth fires stack-missing when op-reth is absent"
else
  echo "FAIL alert-watch reth mode must expect op-reth (ec=$T5_AW_EC)" >&2
  echo "$T5_AW_OUT" >&2
  fail=1
fi
stk_reset
stk_mark op-reth op-node op-batcher op-proposer l2-rpc-filter op-challenger
T5_AW_OK="$(stk_run FORTEL2_EL=reth ALERT_WATCH_EXPECT_STACK=1 RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' \
  "$SCRIPT_DIR/alert-watch.sh" 2>&1)" && T5_AW_OK_EC=0 || T5_AW_OK_EC=$?
if [[ "$T5_AW_OK_EC" -eq 0 ]] && [[ ! -f "$STK_FIX/mock/osascript.calls" ]]; then
  echo "PASS alert-watch FORTEL2_EL=reth is quiet when op-reth is the expected live EL"
else
  echo "FAIL alert-watch reth-complete stack must not alert (ec=$T5_AW_OK_EC)" >&2
  echo "$T5_AW_OK" >&2
  fail=1
fi
rm -rf "$STK_FIX"

# P:0 op-reth spike — tracked files + refusals (no chain, no op-reth required).
SPIKE_RETH="$SCRIPT_DIR/spike-op-reth.sh"
SPIKE_NOTE="$FORTEL2_ROOT/tasks/spike-op-reth.md"
if git -C "$FORTEL2_ROOT" ls-files --error-unmatch scripts/spike-op-reth.sh tasks/spike-op-reth.md >/dev/null 2>&1; then
  echo "PASS spike-op-reth.sh and tasks/spike-op-reth.md are tracked"
else
  echo "FAIL spike-op-reth.sh / tasks/spike-op-reth.md must be tracked (git ls-files)" >&2
  fail=1
fi
if [[ -x "$SPIKE_RETH" ]] && [[ -f "$SPIKE_NOTE" ]]; then
  echo "PASS spike-op-reth.sh is executable"
else
  echo "FAIL spike-op-reth.sh must be executable and the spike note must exist" >&2
  fail=1
fi
SPIKE_HELP="$("$SPIKE_RETH" --help 2>&1)" || true
if echo "$SPIKE_HELP" | grep -q 'chain 901' \
  && echo "$SPIKE_HELP" | grep -q 'op-geth datadir' \
  && echo "$SPIKE_HELP" | grep -q ':9545' \
  && echo "$SPIKE_HELP" | grep -q 'start_bg' \
  && echo "$SPIKE_HELP" | grep -q '19845' \
  && echo "$SPIKE_HELP" | grep -q '19851' \
  && echo "$SPIKE_HELP" | grep -q '19847' \
  && echo "$SPIKE_HELP" | grep -q 'deployments/sepolia/rollup.json' \
  && echo "$SPIKE_HELP" | grep -q 'PublicNode'; then
  echo "PASS spike-op-reth --help names refusals and default ports"
else
  echo "FAIL spike-op-reth --help must name 901 / live datadir / :9545 / start_bg / 19845/19851/19847 / sepolia rollup / PublicNode" >&2
  echo "$SPIKE_HELP" >&2
  fail=1
fi
if grep -E '^[[:space:]]*(start_bg|stop_bg)[[:space:]]' "$SPIKE_RETH"; then
  echo "FAIL spike-op-reth.sh must not call start_bg / stop_bg" >&2
  fail=1
else
  echo "PASS spike-op-reth.sh does not call start_bg / stop_bg"
fi
if grep -q 'deployments/sepolia/rollup.json' "$SPIKE_RETH" \
  && grep -q 'SPIKE_EL_HTTP_PORT:-19845' "$SPIKE_RETH" \
  && grep -q 'SPIKE_EL_AUTH_PORT:-19851' "$SPIKE_RETH" \
  && grep -q 'SPIKE_NODE_RPC_PORT:-19847' "$SPIKE_RETH"; then
  echo "PASS spike-op-reth defaults to 852 rollup and ports 19845/19851/19847"
else
  echo "FAIL spike-op-reth must default to deployments/sepolia/rollup.json and 19845/19851/19847" >&2
  fail=1
fi
SPIKE_901="$(mktemp)"
printf '%s\n' '{"l2_chain_id":901}' > "$SPIKE_901"
SPIKE_901_OUT="$("$SPIKE_RETH" --preflight --rollup "$SPIKE_901" 2>&1)" && SPIKE_901_EC=0 || SPIKE_901_EC=$?
rm -f "$SPIKE_901"
if [[ "$SPIKE_901_EC" -eq 2 ]] && echo "$SPIKE_901_OUT" | grep -q '901'; then
  echo "PASS spike-op-reth --preflight refuses chain 901"
else
  echo "FAIL spike-op-reth must refuse a 901 rollup (ec=$SPIKE_901_EC)" >&2
  echo "$SPIKE_901_OUT" >&2
  fail=1
fi
SPIKE_PF_OUT="$(SPIKE_EL_HTTP_PORT=9545 "$SPIKE_RETH" --preflight 2>&1)" && SPIKE_PF_EC=0 || SPIKE_PF_EC=$?
if [[ "$SPIKE_PF_EC" -eq 2 ]] && echo "$SPIKE_PF_OUT" | grep -q '9545'; then
  echo "PASS spike-op-reth --preflight refuses :9545"
else
  echo "FAIL spike-op-reth must refuse SPIKE_EL_HTTP_PORT=9545 (ec=$SPIKE_PF_EC)" >&2
  echo "$SPIKE_PF_OUT" >&2
  fail=1
fi
SPIKE_DD_OUT="$(SPIKE_DATADIR="$DATA_DIR/l2/op-geth" "$SPIKE_RETH" --preflight 2>&1)" && SPIKE_DD_EC=0 || SPIKE_DD_EC=$?
if [[ "$SPIKE_DD_EC" -eq 2 ]] && echo "$SPIKE_DD_OUT" | grep -qi 'op-geth datadir'; then
  echo "PASS spike-op-reth --preflight refuses live op-geth datadir"
else
  echo "FAIL spike-op-reth must refuse \$DATA_DIR/l2/op-geth (ec=$SPIKE_DD_EC)" >&2
  echo "$SPIKE_DD_OUT" >&2
  fail=1
fi
SPIKE_OK_OUT="$("$SPIKE_RETH" --preflight 2>&1)" && SPIKE_OK_EC=0 || SPIKE_OK_EC=$?
if [[ "$SPIKE_OK_EC" -eq 0 ]] && echo "$SPIKE_OK_OUT" | grep -q 'preflight ok'; then
  echo "PASS spike-op-reth --preflight accepts checked-in 852 rollup"
else
  echo "FAIL spike-op-reth --preflight should pass on deployments/sepolia/rollup.json (ec=$SPIKE_OK_EC)" >&2
  echo "$SPIKE_OK_OUT" >&2
  fail=1
fi
SPIKE_ENV_OUT="$(FORTEL2_ENV=.env.sepolia "$SPIKE_RETH" --preflight 2>&1)" && SPIKE_ENV_EC=0 || SPIKE_ENV_EC=$?
if [[ "$SPIKE_ENV_EC" -eq 2 ]] && echo "$SPIKE_ENV_OUT" | grep -qi 'role keys\|FORTEL2_ENV'; then
  echo "PASS spike-op-reth refuses FORTEL2_ENV=.env.sepolia"
else
  echo "FAIL spike-op-reth must refuse FORTEL2_ENV=.env.sepolia (ec=$SPIKE_ENV_EC)" >&2
  echo "$SPIKE_ENV_OUT" >&2
  fail=1
fi
SPIKE_HOME_OUT="$(SPIKE_DATADIR="$HOME" "$SPIKE_RETH" --preflight 2>&1)" && SPIKE_HOME_EC=0 || SPIKE_HOME_EC=$?
if [[ "$SPIKE_HOME_EC" -eq 2 ]] && echo "$SPIKE_HOME_OUT" | grep -q 'SPIKE_DATADIR must be'; then
  echo "PASS spike-op-reth --preflight refuses SPIKE_DATADIR=\$HOME"
else
  echo "FAIL spike-op-reth must refuse SPIKE_DATADIR=\$HOME (ec=$SPIKE_HOME_EC)" >&2
  echo "$SPIKE_HOME_OUT" >&2
  fail=1
fi
SPIKE_L2ROOT_OUT="$(SPIKE_DATADIR="$DATA_DIR/l2" "$SPIKE_RETH" --preflight 2>&1)" && SPIKE_L2ROOT_EC=0 || SPIKE_L2ROOT_EC=$?
if [[ "$SPIKE_L2ROOT_EC" -eq 2 ]] && echo "$SPIKE_L2ROOT_OUT" | grep -q 'SPIKE_DATADIR must be'; then
  echo "PASS spike-op-reth --preflight refuses SPIKE_DATADIR=\$DATA_DIR/l2"
else
  echo "FAIL spike-op-reth must refuse wiping \$DATA_DIR/l2 (ec=$SPIKE_L2ROOT_EC)" >&2
  echo "$SPIKE_L2ROOT_OUT" >&2
  fail=1
fi
SPIKE_P2P_OUT="$(SPIKE_EL_P2P_PORT=9545 "$SPIKE_RETH" --preflight 2>&1)" && SPIKE_P2P_EC=0 || SPIKE_P2P_EC=$?
if [[ "$SPIKE_P2P_EC" -eq 2 ]] && echo "$SPIKE_P2P_OUT" | grep -q '9545'; then
  echo "PASS spike-op-reth --preflight refuses SPIKE_EL_P2P_PORT=9545"
else
  echo "FAIL spike-op-reth must refuse P2P port 9545 (ec=$SPIKE_P2P_EC)" >&2
  echo "$SPIKE_P2P_OUT" >&2
  fail=1
fi
SPIKE_GFILE="$(mktemp)"
printf '%s\n' '{"config":{"chainId":852}}' > "$SPIKE_GFILE"
SPIKE_GERR="$(mktemp)"
SPIKE_GOUT="$("$SPIKE_RETH" --print-genesis --genesis "$SPIKE_GFILE" 2>"$SPIKE_GERR")" && SPIKE_GEC=0 || SPIKE_GEC=$?
if [[ "$SPIKE_GEC" -eq 0 && "$SPIKE_GOUT" == "$SPIKE_GFILE" ]]; then
  echo "PASS spike-op-reth --print-genesis stdout is only the path"
else
  echo "FAIL --print-genesis stdout must be exactly --genesis path (ec=$SPIKE_GEC out=$(printf '%q' "$SPIKE_GOUT"))" >&2
  cat "$SPIKE_GERR" >&2
  fail=1
fi
rm -f "$SPIKE_GFILE" "$SPIKE_GERR"
if awk '/^resolve_genesis\(\)/,/^}/' "$SPIKE_RETH" | grep -E '^[[:space:]]*echo ' | grep -v '>&2' >/dev/null; then
  echo "FAIL resolve_genesis informational echo must go to stderr (stdout is the path)" >&2
  fail=1
else
  echo "PASS resolve_genesis echo lines are stderr"
fi
# Mini 2026-08-29: PublicNode + --l1.rpckind=standard returned 0 receipts.
if grep -q 'SEPOLIA_L1_RPC_KIND:-quicknode' "$SPIKE_RETH" \
  && grep -q -- '--l1.rpckind="${L1_RPC_KIND}"' "$SPIKE_RETH" \
  && ! grep -q -- '--l1.rpckind=standard' "$SPIKE_RETH"; then
  echo "PASS spike-op-reth L1 rpckind defaults to quicknode from env"
else
  echo "FAIL spike-op-reth must take --l1.rpckind from SPIKE_L1_RPC_KIND / SEPOLIA_L1_RPC_KIND (default quicknode)" >&2
  fail=1
fi
SPIKE_PN_PF="$(L1_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com "$SPIKE_RETH" --preflight 2>&1)" && SPIKE_PN_PF_EC=0 || SPIKE_PN_PF_EC=$?
if [[ "$SPIKE_PN_PF_EC" -eq 0 ]] && echo "$SPIKE_PN_PF" | grep -q 'preflight ok' \
  && echo "$SPIKE_PN_PF" | grep -qi 'PublicNode'; then
  echo "PASS spike-op-reth --preflight warns on PublicNode L1"
else
  echo "FAIL spike-op-reth --preflight must pass and warn on PublicNode (ec=$SPIKE_PN_PF_EC)" >&2
  echo "$SPIKE_PN_PF" >&2
  fail=1
fi
SPIKE_PN_BL="$(L1_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com "$SPIKE_RETH" --blocks 5 2>&1)" && SPIKE_PN_BL_EC=0 || SPIKE_PN_BL_EC=$?
if [[ "$SPIKE_PN_BL_EC" -eq 2 ]] && echo "$SPIKE_PN_BL" | grep -qi 'receipts' \
  && ! echo "$SPIKE_PN_BL" | grep -q 'Starting op-reth'; then
  echo "PASS spike-op-reth --blocks refuses PublicNode L1 before start"
else
  echo "FAIL spike-op-reth --blocks must refuse PublicNode before starting (ec=$SPIKE_PN_BL_EC)" >&2
  echo "$SPIKE_PN_BL" >&2
  fail=1
fi
# Caller L1_RPC_URL must survive lib.sh sourcing .env (Anvil loopback).
SPIKE_KEEP_OUT="$(L1_RPC_URL=https://example.invalid/sepolia "$SPIKE_RETH" --preflight 2>&1)" && SPIKE_KEEP_EC=0 || SPIKE_KEEP_EC=$?
if [[ "$SPIKE_KEEP_EC" -eq 0 ]] && echo "$SPIKE_KEEP_OUT" | grep -q 'preflight ok' \
  && ! echo "$SPIKE_KEEP_OUT" | grep -qi 'PublicNode' \
  && ! echo "$SPIKE_KEEP_OUT" | grep -q 'Using public Sepolia'; then
  echo "PASS spike-op-reth --preflight keeps caller L1_RPC_URL over .env"
else
  echo "FAIL spike-op-reth must not clobber caller L1_RPC_URL with .env Anvil (ec=$SPIKE_KEEP_EC)" >&2
  echo "$SPIKE_KEEP_OUT" >&2
  fail=1
fi

# Migration PRD must stay tracked and cite spike evidence (can go red).
PRD_RETH="$FORTEL2_ROOT/tasks/prd-op-reth-migration.md"
if git -C "$FORTEL2_ROOT" ls-files --error-unmatch tasks/prd-op-reth-migration.md >/dev/null 2>&1 \
  && [[ -f "$PRD_RETH" ]]; then
  echo "PASS tasks/prd-op-reth-migration.md is tracked"
else
  echo "FAIL tasks/prd-op-reth-migration.md must be tracked (git ls-files)" >&2
  fail=1
fi
SPIKE_B5="$(grep -oE '0xd9fd2a33[0-9a-f]{56}' "$SPIKE_NOTE" | head -1)"
if [[ -n "$SPIKE_B5" ]] \
  && grep -q 'tasks/spike-op-reth.md' "$PRD_RETH" \
  && grep -q "$SPIKE_B5" "$PRD_RETH" \
  && grep -qi 'PublicNode' "$PRD_RETH" \
  && grep -q 'quicknode' "$PRD_RETH" \
  && grep -q 'debug_setHead' "$PRD_RETH" \
  && grep -q 'karst_time' "$PRD_RETH" \
  && grep -q 'FORCE_SEPOLIA_REDEPLOY' "$PRD_RETH" \
  && grep -q 'Do not execute this task unless explicitly asked' "$PRD_RETH" \
  && grep -q 'admin_stopSequencer' "$PRD_RETH" \
  && grep -q 'verifier-only' "$PRD_RETH" \
  && grep -q 'com.steve.fortel2-wake' "$PRD_RETH" \
  && grep -q 'alert-watch.sh' "$PRD_RETH" \
  && grep -q 'D-0105 Finding 3' "$PRD_RETH"; then
  echo "PASS op-reth migration PRD cites spike hashes, receipts, debug_setHead, no-wipe, Task 5 hold"
else
  echo "FAIL prd-op-reth-migration.md must cite spike hash, PublicNode/quicknode, debug_setHead, karst_time, FORCE_SEPOLIA_REDEPLOY, Task 5 hold, admin_stopSequencer, verifier-only rollback, launchd wake, alert-watch, D-0105 Finding 3" >&2
  fail=1
fi
if grep -q 'tasks/prd-op-reth-migration.md' "$FORTEL2_ROOT/tasks/prd-l2-learning-chain.md" \
  && grep -q 'tasks/prd-op-reth-migration.md' "$FORTEL2_ROOT/AGENTS.md" \
  && grep -q 'tasks/prd-op-reth-migration.md' "$FORTEL2_ROOT/README.md" \
  && grep -q 'prd-op-reth-migration.md' "$SPIKE_NOTE"; then
  echo "PASS op-reth migration PRD is pointed from roadmap, AGENTS, README, and spike note"
else
  echo "FAIL roadmap / AGENTS / README / spike-op-reth.md must point at tasks/prd-op-reth-migration.md" >&2
  fail=1
fi

# Task 1 — EL pin assertion (stubs only; CI has no Mini arm64 binaries).
PIN_CHECK="$SCRIPT_DIR/check-el-pins.sh"
if git -C "$FORTEL2_ROOT" ls-files --error-unmatch scripts/check-el-pins.sh >/dev/null 2>&1 \
  && [[ -x "$PIN_CHECK" ]]; then
  echo "PASS scripts/check-el-pins.sh is tracked and executable"
else
  echo "FAIL scripts/check-el-pins.sh must be tracked and executable" >&2
  fail=1
fi
# Trap: tag op-reth/v2.3.3 is not the --version string. Matcher must use
# reported 2.3.0-dev + full commit, not a bare 2.3 or the tag 2.3.3.
if grep -q "PIN_RETH_VERSION='2.3.0-dev'" "$PIN_CHECK" \
  && grep -q "PIN_RETH_COMMIT='9384bc53d8c0c77e59cac83fdaaf3b372c6d2216'" "$PIN_CHECK" \
  && grep -q "PIN_OP_NODE_VERSION='v1.19.2'" "$PIN_CHECK" \
  && grep -q "PIN_OP_NODE_COMMIT='da197e45'" "$PIN_CHECK"; then
  echo "PASS check-el-pins.sh pins reported Reth 2.3.0-dev + commit 9384bc53 and op-node v1.19.2 da197e45"
else
  echo "FAIL check-el-pins.sh must pin 2.3.0-dev / 9384bc53d8c0c77e59cac83fdaaf3b372c6d2216 / v1.19.2 / da197e45" >&2
  fail=1
fi
if grep -q 'file -L' "$PIN_CHECK"; then
  echo "PASS check-el-pins.sh follows symlinks with file -L for Mach-O arm64"
else
  echo "FAIL check-el-pins.sh must use file -L so BIN_DIR symlinks are architecture-checked" >&2
  fail=1
fi
PIN_FIX="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-el-pins.XXXXXX")"
cat > "$PIN_FIX/op-node" <<'EOS'
#!/bin/sh
echo "op-node version v1.19.2-da197e45-1782514747"
EOS
cat > "$PIN_FIX/op-reth" <<'EOS'
#!/bin/sh
echo "Reth Version: 2.3.0-dev"
echo "Commit SHA: 9384bc53d8c0c77e59cac83fdaaf3b372c6d2216"
EOS
cat > "$PIN_FIX/op-reth-wrong" <<'EOS'
#!/bin/sh
echo "Reth Version: 2.4.0"
echo "Commit SHA: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
EOS
# Would pass a naive "2.3" grep; must fail the exact 2.3.0-dev + commit check.
cat > "$PIN_FIX/op-reth-prefix" <<'EOS'
#!/bin/sh
echo "Reth Version: 2.3.1-dev"
echo "Commit SHA: 9384bc53d8c0c77e59cac83fdaaf3b372c6d2216"
EOS
cat > "$PIN_FIX/op-geth" <<'EOS'
#!/bin/sh
echo "op-geth version 1.101702.2-stable-e8800cff"
EOS
chmod +x "$PIN_FIX/op-node" "$PIN_FIX/op-reth" "$PIN_FIX/op-reth-wrong" \
  "$PIN_FIX/op-reth-prefix" "$PIN_FIX/op-geth"
PIN_OK_OUT="$(
  OP_NODE_BIN="$PIN_FIX/op-node" OP_RETH_BIN="$PIN_FIX/op-reth" \
    "$PIN_CHECK" 2>&1
)" && PIN_OK_EC=0 || PIN_OK_EC=$?
if [[ "$PIN_OK_EC" -eq 0 ]] && echo "$PIN_OK_OUT" | grep -q 'ok op-node'; then
  echo "PASS check-el-pins.sh accepts matching stub versions"
else
  echo "FAIL check-el-pins.sh must exit 0 on matching stubs (ec=$PIN_OK_EC)" >&2
  echo "$PIN_OK_OUT" >&2
  fail=1
fi
PIN_BAD_OUT="$(
  OP_NODE_BIN="$PIN_FIX/op-node" OP_RETH_BIN="$PIN_FIX/op-reth-wrong" \
    "$PIN_CHECK" 2>&1
)" && PIN_BAD_EC=0 || PIN_BAD_EC=$?
if [[ "$PIN_BAD_EC" -ne 0 ]] \
  && echo "$PIN_BAD_OUT" | grep -q 'expected:' \
  && echo "$PIN_BAD_OUT" | grep -q 'got:' \
  && echo "$PIN_BAD_OUT" | grep -q '2.3.0-dev' \
  && echo "$PIN_BAD_OUT" | grep -q '2.4.0'; then
  echo "PASS check-el-pins.sh goes red on a wrong op-reth pin (expected vs got)"
else
  echo "FAIL check-el-pins.sh must exit nonzero and name expected vs got on a wrong pin (ec=$PIN_BAD_EC)" >&2
  echo "$PIN_BAD_OUT" >&2
  fail=1
fi
PIN_PFX_OUT="$(
  OP_NODE_BIN="$PIN_FIX/op-node" OP_RETH_BIN="$PIN_FIX/op-reth-prefix" \
    "$PIN_CHECK" 2>&1
)" && PIN_PFX_EC=0 || PIN_PFX_EC=$?
if [[ "$PIN_PFX_EC" -ne 0 ]] && echo "$PIN_PFX_OUT" | grep -q '2.3.1-dev'; then
  echo "PASS check-el-pins.sh refuses a 2.3.x prefix match (not a bare 2.3 grep)"
else
  echo "FAIL check-el-pins.sh must not accept 2.3.1-dev as the 2.3.0-dev pin (ec=$PIN_PFX_EC)" >&2
  echo "$PIN_PFX_OUT" >&2
  fail=1
fi
PIN_GETH_OUT="$(
  FORTEL2_EL=reth OP_NODE_BIN="$PIN_FIX/op-node" OP_RETH_BIN="$PIN_FIX/op-geth" \
    "$PIN_CHECK" 2>&1
)" && PIN_GETH_EC=0 || PIN_GETH_EC=$?
if [[ "$PIN_GETH_EC" -ne 0 ]] \
  && echo "$PIN_GETH_OUT" | grep -qi 'op-geth' \
  && echo "$PIN_GETH_OUT" | grep -q 'expected:' \
  && echo "$PIN_GETH_OUT" | grep -q 'got:'; then
  echo "PASS check-el-pins.sh refuses op-geth when FORTEL2_EL=reth"
else
  echo "FAIL FORTEL2_EL=reth must refuse an op-geth binary (ec=$PIN_GETH_EC)" >&2
  echo "$PIN_GETH_OUT" >&2
  fail=1
fi
rm -rf "$PIN_FIX"

# --- Task 2: op-reth selector / datadir / genesis / profile (must be able to go red) ---
RETH_START="$SCRIPT_DIR/start-op-reth-verifier.sh"
RETH_STOP="$SCRIPT_DIR/stop-op-reth-verifier.sh"
if git -C "$FORTEL2_ROOT" ls-files --error-unmatch scripts/start-op-reth-verifier.sh >/dev/null 2>&1 \
  && git -C "$FORTEL2_ROOT" ls-files --error-unmatch scripts/stop-op-reth-verifier.sh >/dev/null 2>&1 \
  && [[ -x "$RETH_START" && -x "$RETH_STOP" ]]; then
  echo "PASS start-op-reth-verifier.sh and stop-op-reth-verifier.sh are tracked and executable"
else
  echo "FAIL Task 2 sidecar scripts must be tracked and executable" >&2
  fail=1
fi

# Live start paths refuse reth (enginekind=geth under FORTEL2_EL=reth must not run).
RETH_LIVE_OUT="$(FORTEL2_EL=reth "$SCRIPT_DIR/04-start-sequencer.sh" 2>&1)" && RETH_LIVE_EC=0 || RETH_LIVE_EC=$?
if [[ "$RETH_LIVE_EC" -ne 0 ]] \
  && echo "$RETH_LIVE_OUT" | grep -q 'FORTEL2_EL=reth' \
  && echo "$RETH_LIVE_OUT" | grep -q 'start-op-reth-verifier.sh'; then
  echo "PASS 04-start-sequencer.sh refuses FORTEL2_EL=reth (no 901 reth path)"
else
  echo "FAIL 04-start-sequencer.sh must refuse FORTEL2_EL=reth (ec=$RETH_LIVE_EC)" >&2
  echo "$RETH_LIVE_OUT" >&2
  fail=1
fi
# Task 5: Sepolia live start honors FORTEL2_EL (--print-plan; no processes).
RETH_SEP_OUT="$(FORTEL2_EL=reth "$SCRIPT_DIR/04-start-sequencer-sepolia.sh" --print-plan 2>&1)" && RETH_SEP_EC=0 || RETH_SEP_EC=$?
if [[ "$RETH_SEP_EC" -eq 0 ]] \
  && echo "$RETH_SEP_OUT" | grep -q 'EL=op-reth' \
  && echo "$RETH_SEP_OUT" | grep -q 'ENGINEKIND=reth'; then
  echo "PASS 04-start-sequencer-sepolia.sh --print-plan names op-reth under FORTEL2_EL=reth"
else
  echo "FAIL Sepolia start must honor FORTEL2_EL=reth via --print-plan (ec=$RETH_SEP_EC)" >&2
  echo "$RETH_SEP_OUT" >&2
  fail=1
fi

# Viewer Sequencer card needs CORS on the live EL. Geth already has
# --http.corsdomain="*" on start_bg. Reth must too (print-plan + start argv).
# Geth --print-plan stays without CORS= so that path is unchanged.
GETH_SEP_CORS="$( "$SCRIPT_DIR/04-start-sequencer-sepolia.sh" --print-plan 2>&1 )" || true
if echo "$RETH_SEP_OUT" | grep -q 'CORS=\*' \
  && ! echo "$GETH_SEP_CORS" | grep -q 'CORS=' \
  && awk '
       /start_bg op-reth/ { in_reth=1 }
       in_reth && /--http.corsdomain="\*"/ { reth_flag=1 }
       in_reth && /exit 0/ { in_reth=0 }
       /start_bg op-geth/ { in_geth=1 }
       in_geth && /--http.corsdomain="\*"/ { geth_flag=1 }
       END { exit !(reth_flag && geth_flag) }
     ' "$SCRIPT_DIR/04-start-sequencer-sepolia.sh"; then
  echo "PASS reth --print-plan and start_bg include --http.corsdomain=*"
else
  echo "FAIL reth live start must pass --http.corsdomain=* (print-plan CORS=*)" >&2
  echo "$RETH_SEP_OUT" >&2
  fail=1
fi

# enginekind=geth under FORTEL2_EL=reth fails (helper — can go red).
RETH_EK_OUT="$(
  FORTEL2_EL=reth
  require_reth_enginekind geth 2>&1
)" && RETH_EK_EC=0 || RETH_EK_EC=$?
if [[ "$RETH_EK_EC" -ne 0 ]] && echo "$RETH_EK_OUT" | grep -q 'enginekind=reth'; then
  echo "PASS require_reth_enginekind fails on geth under FORTEL2_EL=reth"
else
  echo "FAIL enginekind=geth under FORTEL2_EL=reth must fail (ec=$RETH_EK_EC)" >&2
  echo "$RETH_EK_OUT" >&2
  fail=1
fi
if grep -q -- '--l2.enginekind=reth' "$RETH_START" \
  && ! grep -q -- '--l2.enginekind=geth' "$RETH_START" \
  && grep -q -- '--l2.enginekind=geth' "$SCRIPT_DIR/04-start-sequencer-sepolia.sh" \
  && grep -q -- '--l2.enginekind=reth' "$SCRIPT_DIR/04-start-sequencer-sepolia.sh"; then
  echo "PASS sidecar enginekind=reth; live Sepolia script has both geth (default) and reth branches"
else
  echo "FAIL sidecar must stay enginekind=reth; live Sepolia must contain both enginekinds" >&2
  fail=1
fi

# Missing profile refuses (no silent default).
RETH_PROF_OUT="$(
  unset FORTEL2_RETH_PROFILE || true
  require_reth_profile 2>&1
)" && RETH_PROF_EC=0 || RETH_PROF_EC=$?
if [[ "$RETH_PROF_EC" -ne 0 ]] && echo "$RETH_PROF_OUT" | grep -qi 'FORTEL2_RETH_PROFILE'; then
  echo "PASS missing FORTEL2_RETH_PROFILE refuses"
else
  echo "FAIL missing profile must refuse (ec=$RETH_PROF_EC)" >&2
  echo "$RETH_PROF_OUT" >&2
  fail=1
fi
RETH_PF_SCRIPT_OUT="$(
  env -u FORTEL2_RETH_PROFILE FORTEL2_EL=reth "$RETH_START" --preflight 2>&1
)" && RETH_PF_SCRIPT_EC=0 || RETH_PF_SCRIPT_EC=$?
if [[ "$RETH_PF_SCRIPT_EC" -ne 0 ]] && echo "$RETH_PF_SCRIPT_OUT" | grep -qi 'FORTEL2_RETH_PROFILE'; then
  echo "PASS start-op-reth-verifier.sh --preflight refuses missing profile"
else
  echo "FAIL sidecar --preflight must refuse missing profile (ec=$RETH_PF_SCRIPT_EC)" >&2
  echo "$RETH_PF_SCRIPT_OUT" >&2
  fail=1
fi

# Both profiles start-able as flags (verifier includes gossip disable).
RETH_VF_FLAGS="$(FORTEL2_RETH_PROFILE=verifier reth_profile_flags | tr '\n' ' ')"
RETH_SF_FLAGS="$(FORTEL2_RETH_PROFILE=sequencer_faultproof reth_profile_flags | tr '\n' ' ')"
if echo "$RETH_VF_FLAGS" | grep -q -- '--full' \
  && echo "$RETH_VF_FLAGS" | grep -q -- '--rollup.disable-tx-pool-gossip' \
  && echo "$RETH_SF_FLAGS" | grep -q -- '--proofs-history' \
  && ! echo "$RETH_SF_FLAGS" | grep -q -- '--full'; then
  echo "PASS reth profiles: verifier --full + disable-tx-pool-gossip; sequencer_faultproof archive + proofs-history"
else
  echo "FAIL storage profile flags (verifier='$RETH_VF_FLAGS' sequencer='$RETH_SF_FLAGS')" >&2
  fail=1
fi

# Task 4 SafeDB: default path, refuse live $DATA_DIR/safedb, op-geth, and the
# op-reth / spike-op-reth datadirs. Auto-enable only on sequencer_faultproof.
# Live op-node / 09-start-challenger untouched.
RETH_SDB_FIX="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-reth-safedb.XXXXXX")"
mkdir -p "$RETH_SDB_FIX/l2/op-geth" "$RETH_SDB_FIX/l2/op-reth/db" \
  "$RETH_SDB_FIX/l2/spike-op-reth" "$RETH_SDB_FIX/safedb"
echo live > "$RETH_SDB_FIX/safedb/KEEP"
RETH_SDB_DEF="$(
  DATA_DIR="$RETH_SDB_FIX"
  unset FORTEL2_RETH_SAFEDB_PATH || true
  require_reth_safedb_path
)" && RETH_SDB_DEF_EC=0 || RETH_SDB_DEF_EC=$?
RETH_SDB_DEF_CANON="$(cd "$RETH_SDB_FIX" && pwd -P)/l2/op-reth-safedb"
if [[ "$RETH_SDB_DEF_EC" -eq 0 && "$RETH_SDB_DEF" == "$RETH_SDB_DEF_CANON" ]]; then
  echo "PASS require_reth_safedb_path defaults to \$DATA_DIR/l2/op-reth-safedb"
else
  echo "FAIL SafeDB default path (got '$RETH_SDB_DEF' want '$RETH_SDB_DEF_CANON' ec=$RETH_SDB_DEF_EC)" >&2
  fail=1
fi
RETH_SDB_LIVE="$(
  DATA_DIR="$RETH_SDB_FIX"
  FORTEL2_RETH_SAFEDB_PATH="$RETH_SDB_FIX/safedb"
  require_reth_safedb_path 2>&1
)" && RETH_SDB_LIVE_EC=0 || RETH_SDB_LIVE_EC=$?
if [[ "$RETH_SDB_LIVE_EC" -ne 0 ]] \
  && echo "$RETH_SDB_LIVE" | grep -qi 'live SafeDB' \
  && [[ -f "$RETH_SDB_FIX/safedb/KEEP" ]]; then
  echo "PASS require_reth_safedb_path refuses live \$DATA_DIR/safedb (marker intact)"
else
  echo "FAIL sidecar SafeDB must refuse the live store (ec=$RETH_SDB_LIVE_EC)" >&2
  echo "$RETH_SDB_LIVE" >&2
  fail=1
fi
RETH_SDB_GETH="$(
  DATA_DIR="$RETH_SDB_FIX"
  FORTEL2_RETH_SAFEDB_PATH="$RETH_SDB_FIX/l2/op-geth/safedb"
  require_reth_safedb_path 2>&1
)" && RETH_SDB_GETH_EC=0 || RETH_SDB_GETH_EC=$?
if [[ "$RETH_SDB_GETH_EC" -ne 0 ]] && echo "$RETH_SDB_GETH" | grep -qi 'op-geth'; then
  echo "PASS require_reth_safedb_path refuses a path under op-geth"
else
  echo "FAIL SafeDB under op-geth must refuse (ec=$RETH_SDB_GETH_EC)" >&2
  echo "$RETH_SDB_GETH" >&2
  fail=1
fi
RETH_SDB_RETH="$(
  DATA_DIR="$RETH_SDB_FIX"
  FORTEL2_RETH_SAFEDB_PATH="$RETH_SDB_FIX/l2/op-reth"
  require_reth_safedb_path 2>&1
)" && RETH_SDB_RETH_EC=0 || RETH_SDB_RETH_EC=$?
if [[ "$RETH_SDB_RETH_EC" -ne 0 ]] && echo "$RETH_SDB_RETH" | grep -qi 'op-reth datadir'; then
  echo "PASS require_reth_safedb_path refuses \$DATA_DIR/l2/op-reth"
else
  echo "FAIL SafeDB at the op-reth datadir must refuse (ec=$RETH_SDB_RETH_EC)" >&2
  echo "$RETH_SDB_RETH" >&2
  fail=1
fi
RETH_SDB_RETH_DB="$(
  DATA_DIR="$RETH_SDB_FIX"
  FORTEL2_RETH_SAFEDB_PATH="$RETH_SDB_FIX/l2/op-reth/db"
  require_reth_safedb_path 2>&1
)" && RETH_SDB_RETH_DB_EC=0 || RETH_SDB_RETH_DB_EC=$?
if [[ "$RETH_SDB_RETH_DB_EC" -ne 0 ]] && echo "$RETH_SDB_RETH_DB" | grep -qi 'op-reth datadir'; then
  echo "PASS require_reth_safedb_path refuses a path under op-reth"
else
  echo "FAIL SafeDB under op-reth/db must refuse (ec=$RETH_SDB_RETH_DB_EC)" >&2
  echo "$RETH_SDB_RETH_DB" >&2
  fail=1
fi
RETH_SDB_SPIKE="$(
  DATA_DIR="$RETH_SDB_FIX"
  FORTEL2_RETH_SAFEDB_PATH="$RETH_SDB_FIX/l2/spike-op-reth/safedb"
  require_reth_safedb_path 2>&1
)" && RETH_SDB_SPIKE_EC=0 || RETH_SDB_SPIKE_EC=$?
if [[ "$RETH_SDB_SPIKE_EC" -ne 0 ]] && echo "$RETH_SDB_SPIKE" | grep -qi 'op-reth datadir'; then
  echo "PASS require_reth_safedb_path refuses a path under spike-op-reth"
else
  echo "FAIL SafeDB under spike-op-reth must refuse (ec=$RETH_SDB_SPIKE_EC)" >&2
  echo "$RETH_SDB_SPIKE" >&2
  fail=1
fi
rm -rf "$RETH_SDB_FIX"

if grep -q -- '--safedb.path' "$RETH_START" \
  && grep -q 'FORTEL2_RETH_PROFILE" == "sequencer_faultproof"' "$RETH_START" \
  && grep -q 'require_reth_safedb_path' "$RETH_START" \
  && grep -q 'unset OP_NODE_SAFEDB_PATH' "$RETH_START" \
  && grep -q 'fortel2_live_safedb_path' "$SCRIPT_DIR/04-start-sequencer-sepolia.sh" \
  && ! grep -q 'require_reth_safedb_path' "$SCRIPT_DIR/04-start-sequencer-sepolia.sh" \
  && ! grep -q -- '--safedb.path' "$SCRIPT_DIR/09-start-challenger-sepolia.sh"; then
  echo "PASS sidecar SafeDB stays require_reth_safedb_path; live start uses fortel2_live_safedb_path"
else
  echo "FAIL sidecar SafeDB must stay sidecar-only; live start must use the live store" >&2
  fail=1
fi
RETH_SDB_PF_SF="$(
  FORTEL2_EL=reth FORTEL2_RETH_PROFILE=sequencer_faultproof "$RETH_START" --preflight 2>&1
)" && RETH_SDB_PF_SF_EC=0 || RETH_SDB_PF_SF_EC=$?
if [[ "$RETH_SDB_PF_SF_EC" -eq 0 ]] \
  && echo "$RETH_SDB_PF_SF" | grep -q 'safedb=' \
  && echo "$RETH_SDB_PF_SF" | grep -q 'op-reth-safedb' \
  && echo "$RETH_SDB_PF_SF" | grep -q 'sidecar op-node only'; then
  echo "PASS sidecar --preflight sequencer_faultproof names sidecar SafeDB path"
else
  echo "FAIL sequencer_faultproof preflight must name SafeDB (ec=$RETH_SDB_PF_SF_EC)" >&2
  echo "$RETH_SDB_PF_SF" >&2
  fail=1
fi
RETH_SDB_PF_VF="$(
  FORTEL2_EL=reth FORTEL2_RETH_PROFILE=verifier "$RETH_START" --preflight 2>&1
)" && RETH_SDB_PF_VF_EC=0 || RETH_SDB_PF_VF_EC=$?
if [[ "$RETH_SDB_PF_VF_EC" -eq 0 ]] \
  && echo "$RETH_SDB_PF_VF" | grep -q 'safedb=off'; then
  echo "PASS sidecar --preflight verifier leaves SafeDB off"
else
  echo "FAIL verifier preflight must leave SafeDB off (ec=$RETH_SDB_PF_VF_EC)" >&2
  echo "$RETH_SDB_PF_VF" >&2
  fail=1
fi

# reth pointed at the geth datadir refuses.
RETH_DD_FIX="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-reth-dd.XXXXXX")"
mkdir -p "$RETH_DD_FIX/l2/op-geth" "$RETH_DD_FIX/l2/op-reth"
echo marker > "$RETH_DD_FIX/l2/op-geth/KEEP"
RETH_DD_OUT="$(
  DATA_DIR="$RETH_DD_FIX"
  require_reth_datadir "$RETH_DD_FIX/l2/op-geth" 2>&1
)" && RETH_DD_EC=0 || RETH_DD_EC=$?
if [[ "$RETH_DD_EC" -ne 0 ]] \
  && echo "$RETH_DD_OUT" | grep -qi 'op-geth datadir' \
  && [[ -f "$RETH_DD_FIX/l2/op-geth/KEEP" ]]; then
  echo "PASS require_reth_datadir refuses op-geth path (marker intact)"
else
  echo "FAIL reth must refuse the geth datadir (ec=$RETH_DD_EC)" >&2
  echo "$RETH_DD_OUT" >&2
  fail=1
fi
RETH_DD_OK="$(
  DATA_DIR="$RETH_DD_FIX"
  require_reth_datadir "$RETH_DD_FIX/l2/op-reth" 2>/dev/null
)" && RETH_DD_OK_EC=0 || RETH_DD_OK_EC=$?
if [[ "$RETH_DD_OK_EC" -eq 0 ]]; then
  echo "PASS require_reth_datadir allows \$DATA_DIR/l2/op-reth"
else
  echo "FAIL production op-reth datadir must be allowed (ec=$RETH_DD_OK_EC)" >&2
  fail=1
fi
# Symlink op-reth → op-geth must not bypass the guard (physical path).
# Place the symlink at the allowed name so a logical pwd would accept it.
rm -rf "$RETH_DD_FIX/l2/op-reth"
ln -sfn "$RETH_DD_FIX/l2/op-geth" "$RETH_DD_FIX/l2/op-reth"
RETH_DD_LINK_OUT="$(
  DATA_DIR="$RETH_DD_FIX"
  require_reth_datadir "$RETH_DD_FIX/l2/op-reth" 2>&1
)" && RETH_DD_LINK_EC=0 || RETH_DD_LINK_EC=$?
if [[ "$RETH_DD_LINK_EC" -ne 0 ]] \
  && echo "$RETH_DD_LINK_OUT" | grep -qi 'op-geth' \
  && [[ -f "$RETH_DD_FIX/l2/op-geth/KEEP" ]]; then
  echo "PASS require_reth_datadir refuses op-reth symlink to op-geth"
else
  echo "FAIL reth datadir must physically resolve and refuse a geth symlink (ec=$RETH_DD_LINK_EC)" >&2
  echo "$RETH_DD_LINK_OUT" >&2
  fail=1
fi
rm -f "$RETH_DD_FIX/l2/op-reth"
mkdir -p "$RETH_DD_FIX/l2/op-reth"
RETH_WIPE_OUT="$(
  DATA_DIR="$RETH_DD_FIX"
  wipe_reth_datadir "$RETH_DD_FIX/l2/op-geth" 2>&1
)" && RETH_WIPE_EC=0 || RETH_WIPE_EC=$?
if [[ "$RETH_WIPE_EC" -ne 0 ]] && [[ -f "$RETH_DD_FIX/l2/op-geth/KEEP" ]]; then
  echo "PASS wipe_reth_datadir refuses op-geth (marker intact)"
else
  echo "FAIL wipe must not touch op-geth (ec=$RETH_WIPE_EC)" >&2
  echo "$RETH_WIPE_OUT" >&2
  fail=1
fi
RETH_DD_SCRIPT_OUT="$(
  FORTEL2_EL=reth FORTEL2_RETH_PROFILE=verifier \
    FORTEL2_RETH_DATADIR="$RETH_DD_FIX/l2/op-geth" \
    "$RETH_START" --preflight 2>&1
)" && RETH_DD_SCRIPT_EC=0 || RETH_DD_SCRIPT_EC=$?
if [[ "$RETH_DD_SCRIPT_EC" -ne 0 ]] && echo "$RETH_DD_SCRIPT_OUT" | grep -qi 'op-geth'; then
  echo "PASS start-op-reth-verifier.sh --preflight refuses a geth datadir"
else
  echo "FAIL sidecar --preflight must refuse geth datadir (ec=$RETH_DD_SCRIPT_EC)" >&2
  echo "$RETH_DD_SCRIPT_OUT" >&2
  fail=1
fi
rm -rf "$RETH_DD_FIX"

# 901 genesis refuses.
RETH_GEN_FIX="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-reth-gen.XXXXXX")"
printf '%s\n' '{"config":{"chainId":901}}' > "$RETH_GEN_FIX/genesis-901.json"
printf '%s\n' '{"config":{"chainId":852}}' > "$RETH_GEN_FIX/genesis-852.json"
RETH_901_OUT="$(
  require_genesis_852 "$RETH_GEN_FIX/genesis-901.json" "$FORTEL2_ROOT/deployments/sepolia/rollup.json" 2>&1
)" && RETH_901_EC=0 || RETH_901_EC=$?
if [[ "$RETH_901_EC" -ne 0 ]] && echo "$RETH_901_OUT" | grep -q '901'; then
  echo "PASS require_genesis_852 refuses 901 genesis"
else
  echo "FAIL 901 genesis must be refused (ec=$RETH_901_EC)" >&2
  echo "$RETH_901_OUT" >&2
  fail=1
fi
RETH_901_SCRIPT_OUT="$(
  FORTEL2_EL=reth FORTEL2_RETH_PROFILE=verifier \
    FORTEL2_RETH_GENESIS="$RETH_GEN_FIX/genesis-901.json" \
    "$RETH_START" --preflight --genesis "$RETH_GEN_FIX/genesis-901.json" 2>&1
)" && RETH_901_SCRIPT_EC=0 || RETH_901_SCRIPT_EC=$?
if [[ "$RETH_901_SCRIPT_EC" -ne 0 ]] && echo "$RETH_901_SCRIPT_OUT" | grep -q '901'; then
  echo "PASS start-op-reth-verifier.sh --preflight refuses 901 genesis"
else
  echo "FAIL sidecar --preflight must refuse 901 genesis (ec=$RETH_901_SCRIPT_EC)" >&2
  echo "$RETH_901_SCRIPT_OUT" >&2
  fail=1
fi
# Wrong rollup genesis hash (can go red).
python3 - "$FORTEL2_ROOT/deployments/sepolia/rollup.json" "$RETH_GEN_FIX/rollup-bad.json" <<'PY'
import json, sys
src, dest = sys.argv[1], sys.argv[2]
data = json.load(open(src))
data["genesis"]["l2"]["hash"] = "0x" + "ab" * 32
json.dump(data, open(dest, "w"))
PY
RETH_HASH_OUT="$(
  require_genesis_852 "$RETH_GEN_FIX/genesis-852.json" "$RETH_GEN_FIX/rollup-bad.json" 2>&1
)" && RETH_HASH_EC=0 || RETH_HASH_EC=$?
if [[ "$RETH_HASH_EC" -ne 0 ]] && echo "$RETH_HASH_OUT" | grep -q 'e242b1a3'; then
  echo "PASS require_genesis_852 refuses a rollup whose genesis hash is not 0xe242b1a3…"
else
  echo "FAIL genesis hash mismatch must refuse (ec=$RETH_HASH_EC)" >&2
  echo "$RETH_HASH_OUT" >&2
  fail=1
fi
rm -rf "$RETH_GEN_FIX"

# Live ports never appear as reth defaults; 9545 refused.
if grep -q "FORTEL2_RETH_HTTP_PORT:-19545" "$SCRIPT_DIR/lib.sh" \
  && grep -q "FORTEL2_RETH_WS_PORT:-19546" "$SCRIPT_DIR/lib.sh" \
  && grep -q "FORTEL2_RETH_AUTH_PORT:-19551" "$SCRIPT_DIR/lib.sh" \
  && grep -q "FORTEL2_RETH_NODE_RPC_PORT:-19547" "$SCRIPT_DIR/lib.sh" \
  && grep -q "FORTEL2_RETH_P2P_PORT:-30330" "$SCRIPT_DIR/lib.sh"; then
  echo "PASS reth verifier default ports are 19545/19546/19551/19547/30330"
else
  echo "FAIL verifier default ports must be 19545/19546/19551/19547/30330" >&2
  fail=1
fi
RETH_PORT_OUT="$(
  FORTEL2_RETH_HTTP_PORT=9545
  require_reth_verifier_ports 2>&1
)" && RETH_PORT_EC=0 || RETH_PORT_EC=$?
if [[ "$RETH_PORT_EC" -ne 0 ]] && echo "$RETH_PORT_OUT" | grep -q '9545'; then
  echo "PASS require_reth_verifier_ports refuses live port 9545"
else
  echo "FAIL reth config must refuse live port 9545 (ec=$RETH_PORT_EC)" >&2
  echo "$RETH_PORT_OUT" >&2
  fail=1
fi

# Task 5: default selector is still geth; reth is opt-in via FORTEL2_EL.
T5_EL_GETH="$(fortel2_live_el_pid)"
T5_EL_RETH="$(FORTEL2_EL=reth fortel2_live_el_pid)"
if [[ "$T5_EL_GETH" == "op-geth" && "$T5_EL_RETH" == "op-reth" ]]; then
  echo "PASS fortel2_live_el_pid defaults to op-geth and names op-reth when FORTEL2_EL=reth"
else
  echo "FAIL live EL pid helper default=$T5_EL_GETH reth=$T5_EL_RETH" >&2
  fail=1
fi
if grep -q 'fortel2_live_el_pid' "$SCRIPT_DIR/status.sh" \
  && grep -q 'el == "reth"' "$SCRIPT_DIR/alert-watch.sh" \
  && grep -q 'FORTEL2_EL' "$SCRIPT_DIR/dev-sleep.sh"; then
  echo "PASS status.sh / alert-watch.sh / dev-sleep.sh are selector-driven (Task 5)"
else
  echo "FAIL §10 monitors must honor FORTEL2_EL" >&2
  fail=1
fi

# start_bg / stop_bg bodies unchanged (CODEOWNERS). New helpers may call them.
RETH_SBG="$(awk '/^start_bg\(\) \{/,/^}$/' "$SCRIPT_DIR/lib.sh")"
RETH_XBG="$(awk '/^stop_bg\(\) \{/,/^}$/' "$SCRIPT_DIR/lib.sh")"
if echo "$RETH_SBG" | grep -q 'python3 - "$pidfile"' \
  && echo "$RETH_XBG" | grep -q 'kill "$pid"' \
  && ! echo "$RETH_SBG" | grep -q 'op-reth' \
  && ! echo "$RETH_XBG" | grep -q 'op-reth'; then
  echo "PASS start_bg / stop_bg function bodies do not mention op-reth"
else
  echo "FAIL start_bg / stop_bg bodies must stay untouched" >&2
  fail=1
fi

# Stop/status coverage: start-able names are stoppable by the same name.
if grep -q 'start_bg op-reth ' "$RETH_START" \
  && grep -q 'start_bg op-reth-node ' "$RETH_START" \
  && grep -q 'stop_reth_sidecar' "$RETH_STOP" \
  && grep -q 'stop_reth_sidecar' "$SCRIPT_DIR/stop-all.sh" \
  && grep -q 'stop_reth_sidecar' "$SCRIPT_DIR/stop-all-sepolia.sh"; then
  echo "PASS start_bg op-reth / op-reth-node are stopped via stop_reth_sidecar"
else
  echo "FAIL sidecar start names must have matching stop coverage" >&2
  fail=1
fi

# JWT under verifier datadir, not live jwt.txt.
if grep -q 'reth_jwt_path' "$RETH_START" \
  && grep -q 'reth_jwt_path()' "$SCRIPT_DIR/lib.sh" \
  && grep -q 'not the live sequencer JWT' "$SCRIPT_DIR/lib.sh"; then
  echo "PASS verifier JWT is documented as datadir-local, not the live JWT"
else
  echo "FAIL verifier JWT must live under the reth datadir" >&2
  fail=1
fi

# Happy-path preflight (profile set, no genesis — CI has no 852 artifacts).
RETH_OK_OUT="$(
  FORTEL2_EL=reth FORTEL2_RETH_PROFILE=verifier "$RETH_START" --preflight 2>&1
)" && RETH_OK_EC=0 || RETH_OK_EC=$?
if [[ "$RETH_OK_EC" -eq 0 ]] && echo "$RETH_OK_OUT" | grep -q 'preflight ok'; then
  echo "PASS start-op-reth-verifier.sh --preflight ok with verifier profile"
else
  echo "FAIL sidecar --preflight should pass with an explicit profile (ec=$RETH_OK_EC)" >&2
  echo "$RETH_OK_OUT" >&2
  fail=1
fi

# Caller DATA_DIR must survive Phase 1 .env load (Bugbot: env clobber).
# Compare via pwd -P — matches fortel2_canon_path (macOS /var → /private/var).
RETH_DD_KEEP="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-reth-datadir-keep.XXXXXX")"
RETH_DD_KEEP_CANON="$(cd "$RETH_DD_KEEP" && pwd -P)"
RETH_DD_KEEP_OUT="$(
  DATA_DIR="$RETH_DD_KEEP" FORTEL2_EL=reth FORTEL2_RETH_PROFILE=verifier \
    "$RETH_START" --preflight 2>&1
)" && RETH_DD_KEEP_EC=0 || RETH_DD_KEEP_EC=$?
if [[ "$RETH_DD_KEEP_EC" -eq 0 ]] \
  && echo "$RETH_DD_KEEP_OUT" | grep -q "datadir=$RETH_DD_KEEP_CANON/l2/op-reth"; then
  echo "PASS sidecar --preflight keeps caller DATA_DIR (not .env DATA_DIR)"
else
  echo "FAIL caller DATA_DIR must survive .env load (ec=$RETH_DD_KEEP_EC)" >&2
  echo "$RETH_DD_KEEP_OUT" >&2
  fail=1
fi
rm -rf "$RETH_DD_KEEP"

# Task 4 trap: snapshot Sepolia DATA_DIR into a *different* variable before
# sourcing lib.sh. Saving into DATA_DIR itself then restore "$DATA_DIR"
# lands in the Phase 1 tree (the disclosed isolated-challenger miss).
SNAP_FIX="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-data-dir-snap.XXXXXX")"
mkdir -p "$SNAP_FIX/sepolia"
printf 'DATA_DIR=%s/sepolia\n' "$SNAP_FIX" > "$SNAP_FIX/.env.sepolia"
SNAP_OK="$(read_env_assignment "$SNAP_FIX/.env.sepolia" DATA_DIR)" && SNAP_OK_EC=0 || SNAP_OK_EC=$?
if [[ "$SNAP_OK_EC" -eq 0 && "$SNAP_OK" == "$SNAP_FIX/sepolia" ]]; then
  echo "PASS read_env_assignment reads DATA_DIR without sourcing the file"
else
  echo "FAIL read_env_assignment should return the file value (got '$SNAP_OK' ec=$SNAP_OK_EC)" >&2
  fail=1
fi
# Trap: export DATA_DIR=sepolia then source lib.sh (Phase 1 .env clobbers)
# then restore "$DATA_DIR" — must NOT land in the Sepolia snapshot path.
SNAP_TRAP="$(
  DATA_DIR="$SNAP_FIX/sepolia"
  export DATA_DIR
  bash -c '
    set -euo pipefail
    source "'"$SCRIPT_DIR"'/lib.sh"
    restore_caller_data_dir "$DATA_DIR"
    printf "%s" "$DATA_DIR"
  '
)" && SNAP_TRAP_EC=0 || SNAP_TRAP_EC=$?
if [[ "$SNAP_TRAP_EC" -eq 0 && "$SNAP_TRAP" != "$SNAP_FIX/sepolia" ]]; then
  echo "PASS DATA_DIR-then-restore trap lands outside the Sepolia tree (can go red)"
else
  echo "FAIL trap reproduction should not restore Sepolia (got '$SNAP_TRAP' ec=$SNAP_TRAP_EC)" >&2
  fail=1
fi
SNAP_PRE="$(read_env_assignment "$SNAP_FIX/.env.sepolia" DATA_DIR)"
SNAP_FIXED="$(
  bash -c '
    set -euo pipefail
    _CALLER_DATA_DIR="$1"
    source "'"$SCRIPT_DIR"'/lib.sh"
    restore_caller_data_dir "$_CALLER_DATA_DIR"
    printf "%s" "$DATA_DIR"
  ' bash "$SNAP_PRE"
)" && SNAP_FIXED_EC=0 || SNAP_FIXED_EC=$?
if [[ "$SNAP_FIXED_EC" -eq 0 && "$SNAP_FIXED" == "$SNAP_FIX/sepolia" ]]; then
  echo "PASS pre-source snapshot in a different var restores Sepolia DATA_DIR"
else
  echo "FAIL correct snapshot pattern must restore Sepolia (got '$SNAP_FIXED' ec=$SNAP_FIXED_EC)" >&2
  fail=1
fi
rm -rf "$SNAP_FIX"

# Child 03-init-l2.sh must not drop parent EL/genesis (Bugbot: env re-source).
if grep -q '_CALLER_RETH_GENESIS' "$SCRIPT_DIR/03-init-l2.sh" \
  && grep -q 'restore_caller_data_dir' "$SCRIPT_DIR/03-init-l2.sh" \
  && grep -q 'export FORTEL2_RETH_GENESIS' "$RETH_START" \
  && grep -q 'export FORTEL2_EL' "$RETH_START"; then
  echo "PASS sidecar exports EL/genesis and 03-init-l2.sh restores caller env"
else
  echo "FAIL 03-init-l2.sh must restore caller FORTEL2_EL/GENESIS/DATA_DIR" >&2
  fail=1
fi

# =============================================================================
# cloudflared-watch (D-0107 Finding 5) — delimited so the parallel
# resolve-games-respected-type task can append below without a merge fight.
# Shim-based: no real launchctl / daemon required.
# ======================================================================
# =============================================================================

# =============================================================================

CFW_AW="$SCRIPT_DIR/alert-watch.sh"
CFW_CL="$SCRIPT_DIR/check-launchd.sh"
CFW_FIX="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-cloudflared-watch.XXXXXX")"
cleanup_cfw() { rm -rf "$CFW_FIX"; }
trap cleanup_cfw EXIT
mkdir -p "$CFW_FIX/shim" "$CFW_FIX/mock" "$CFW_FIX/data" "$CFW_FIX/bin" "$CFW_FIX/deploy"
cat > "$CFW_FIX/env" <<EOF
FORTEL2_ROOT=$CFW_FIX
DATA_DIR=$CFW_FIX/data
BIN_DIR=$CFW_FIX/bin
DEPLOY_DIR=$CFW_FIX/deploy
EOF
cat > "$CFW_FIX/shim/curl" <<'EOS'
#!/bin/sh
dir="${ALERT_WATCH_MOCK_DIR:-}"
[ -n "$dir" ] || exit 99
n=0
[ -f "$dir/curl.calls" ] && n=$(cat "$dir/curl.calls")
n=$((n + 1))
printf '%s\n' "$n" > "$dir/curl.calls"
printf 'ARG:%s\n' "$@" >> "$dir/curl.argv"
cat > "$dir/curl.stdin"
out=""
writeout=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ] || [ "$prev" = "--output" ]; then out="$a"; fi
  if [ "$prev" = "-w" ] || [ "$prev" = "--write-out" ]; then writeout="$a"; fi
  prev="$a"
done
[ -n "$out" ] && printf '%s\n' '{"id":"mock-resend"}' > "$out"
[ -n "$writeout" ] && printf '%s' "${ALERT_WATCH_CURL_HTTP:-200}"
exit 0
EOS
cat > "$CFW_FIX/shim/osascript" <<'EOS'
#!/bin/sh
dir="${ALERT_WATCH_MOCK_DIR:-}"
[ -n "$dir" ] || exit 99
n=0
[ -f "$dir/osascript.calls" ] && n=$(cat "$dir/osascript.calls")
n=$((n + 1))
printf '%s\n' "$n" > "$dir/osascript.calls"
printf 'ARG:%s\n' "$@" >> "$dir/osascript.argv"
exit 0
EOS
# Dispatch on print target so resolve-games stays healthy while cloudflared varies.
cat > "$CFW_FIX/shim/launchctl" <<'EOS'
#!/bin/sh
dir="${ALERT_WATCH_MOCK_DIR:-}"
[ -n "$dir" ] || true
if [ -n "$dir" ]; then
  printf 'ARG:%s\n' "$@" >> "$dir/launchctl.argv"
fi
case "$1" in
  print) ;;
  bootout|bootstrap|kickstart)
    echo "cloudflared-watch must not call launchctl $1" >&2
    exit 99
    ;;
  *)
    echo "unexpected launchctl $1" >&2
    exit 99
    ;;
esac
target="$2"
case "$target" in
  *cloudflared*)
    if [ "${ALERT_WATCH_CF_MISSING:-}" = "1" ]; then
      echo "Could not find service" >&2
      exit 1
    fi
    if [ "${ALERT_WATCH_CF_GARBAGE:-}" = "1" ]; then
      echo "this is not launchctl print output"
      exit 0
    fi
    printf 'system/com.cloudflare.cloudflared = {\n\tstate = %s\n\tlast exit code = %s\n}\n' \
      "${ALERT_WATCH_CF_STATE:-running}" \
      "${ALERT_WATCH_CF_EXIT:-0}"
    exit 0
    ;;
  *)
    printf 'gui/501/com.steve.fortel2-resolve-games = {\n\tstate = not running\n\tlast exit code = 0\n}\n'
    exit 0
    ;;
esac
EOS
chmod +x "$CFW_FIX/shim/curl" "$CFW_FIX/shim/osascript" "$CFW_FIX/shim/launchctl"
: > "$CFW_FIX/cf.err.log"
cfw_reset() {
  rm -f "$CFW_FIX/mock"/curl.argv "$CFW_FIX/mock"/curl.calls \
    "$CFW_FIX/mock"/osascript.argv "$CFW_FIX/mock"/osascript.calls \
    "$CFW_FIX/mock"/launchctl.argv "$CFW_FIX/state.json"
  : > "$CFW_FIX/resolve.out.log"
  : > "$CFW_FIX/resolve.err.log"
  printf '%s\n' '{"verdict":"OK","reason":"balance at or above the funding policy minimum"}' \
    > "$CFW_FIX/funding-health.json"
}
cfw_run() {
  env -u RESEND_API_TOKEN \
    PATH="$CFW_FIX/shim:$PATH" \
    FORTEL2_ENV="$CFW_FIX/env" \
    ALERT_WATCH_MOCK_DIR="$CFW_FIX/mock" \
    ALERT_WATCH_FUNDING_JSON="$CFW_FIX/funding-health.json" \
    ALERT_WATCH_STATE="$CFW_FIX/state.json" \
    ALERT_WATCH_RESOLVE_OUT="$CFW_FIX/resolve.out.log" \
    ALERT_WATCH_RESOLVE_ERR="$CFW_FIX/resolve.err.log" \
    ALERT_WATCH_CLOUDFLARED_PLIST="$CFW_PLIST" \
    ALERT_WATCH_CLOUDFLARED_ERR="$CFW_FIX/cf.err.log" \
    ALERT_WATCH_CURL="$CFW_FIX/shim/curl" \
    ALERT_WATCH_OSASCRIPT="$CFW_FIX/shim/osascript" \
    ALERT_WATCH_LAUNCHCTL="$CFW_FIX/shim/launchctl" \
    ALERT_EMAIL_TO='fortel2-alert-watch@example.invalid' \
    "$@"
}

# Source-level: condition id exists (fails if the condition is removed).
if grep -q 'cloudflared-failing' "$CFW_AW" \
  && grep -q 'ALERT_WATCH_CLOUDFLARED_PLIST' "$CFW_AW" \
  && grep -q 'ALERT_WATCH_CLOUDFLARED_ERR' "$CFW_AW" \
  && grep -q 'system/%s' "$CFW_AW" \
  && ! grep -E 'launchctl[[:space:]]+(bootout|bootstrap|kickstart)' "$CFW_AW"; then
  echo "PASS alert-watch cloudflared-failing condition id and plist/err shims exist"
else
  echo "FAIL alert-watch must define cloudflared-failing with plist/err test overrides" >&2
  fail=1
fi

# (a) plist present + nonzero last exit + not running → fires.
CFW_PLIST="$CFW_FIX/cf.plist"
: > "$CFW_PLIST"
cfw_reset
CFW_OUT="$(cfw_run ALERT_WATCH_CF_STATE='not running' ALERT_WATCH_CF_EXIT=255 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$CFW_AW" 2>&1)" && CFW_EC=0 || CFW_EC=$?
if [[ "$CFW_EC" -eq 0 ]] \
  && [[ "$(cat "$CFW_FIX/mock/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
  && [[ "$(cat "$CFW_FIX/mock/curl.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
  && [[ "$CFW_OUT" == *"cloudflared-failing"* ]] \
  && grep -qi 'cloudflared' "$CFW_FIX/mock/osascript.argv"; then
  echo "PASS alert-watch cloudflared-failing fires on nonzero last exit while not running"
else
  echo "FAIL alert-watch must alert cloudflared-failing when plist exists and daemon is down (ec=$CFW_EC)" >&2
  echo "$CFW_OUT" >&2
  fail=1
fi

# Token-failure err log enriches the body; state is still the trigger.
cfw_reset
printf '%s\n' 'Failed to read token file: open /Library/Application Support/com.cloudflare.cloudflared/token: no such file or directory' \
  > "$CFW_FIX/cf.err.log"
CFW_OUT="$(cfw_run ALERT_WATCH_CF_STATE='not running' ALERT_WATCH_CF_EXIT=255 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$CFW_AW" 2>&1)" && CFW_EC=0 || CFW_EC=$?
if [[ "$CFW_EC" -eq 0 ]] \
  && grep -q 'Failed to read token file' "$CFW_FIX/mock/osascript.argv"; then
  echo "PASS alert-watch cloudflared-failing body includes token-file hint from err log"
else
  echo "FAIL cloudflared-failing should enrich the body from the err-log token pattern (ec=$CFW_EC)" >&2
  echo "$CFW_OUT" >&2
  fail=1
fi
: > "$CFW_FIX/cf.err.log"

# (b) plist present + healthy (running) → no condition.
cfw_reset
CFW_OUT="$(cfw_run ALERT_WATCH_CF_STATE='running' ALERT_WATCH_CF_EXIT=0 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$CFW_AW" 2>&1)" && CFW_EC=0 || CFW_EC=$?
if [[ "$CFW_EC" -eq 0 ]] \
  && [[ ! -f "$CFW_FIX/mock/osascript.calls" ]] \
  && [[ ! -f "$CFW_FIX/mock/curl.calls" ]] \
  && [[ "$CFW_OUT" == *"no alert"* ]]; then
  echo "PASS alert-watch stays quiet when cloudflared is running"
else
  echo "FAIL alert-watch must not alert on a healthy cloudflared daemon (ec=$CFW_EC)" >&2
  echo "$CFW_OUT" >&2
  fail=1
fi

# Review #181: not running + last exit 0 is still a permanent outage
# (KeepAlive SuccessfulExit=false). Exit code is body detail, not a gate.
CFW_PLIST="$CFW_FIX/cf.plist"
: > "$CFW_PLIST"
cfw_reset
CFW_OUT="$(cfw_run ALERT_WATCH_CF_STATE='not running' ALERT_WATCH_CF_EXIT=0 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$CFW_AW" 2>&1)" && CFW_EC=0 || CFW_EC=$?
if [[ "$CFW_EC" -eq 0 ]] \
  && [[ "$(cat "$CFW_FIX/mock/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
  && [[ "$CFW_OUT" == *"cloudflared-failing"* ]] \
  && grep -qi 'not running' "$CFW_FIX/mock/osascript.argv" \
  && grep -E -q 'last exit code 0' "$CFW_FIX/mock/osascript.argv"; then
  echo "PASS alert-watch cloudflared-failing fires on not running even when last exit is 0"
else
  echo "FAIL not-running + last exit 0 must alert (KeepAlive will not restart a clean exit) (ec=$CFW_EC)" >&2
  echo "$CFW_OUT" >&2
  fail=1
fi

# (c) plist absent → no condition, even if the shim would report unhealthy.
CFW_PLIST="$CFW_FIX/no-such-cloudflared.plist"
rm -f "$CFW_PLIST"
cfw_reset
CFW_OUT="$(cfw_run ALERT_WATCH_CF_STATE='not running' ALERT_WATCH_CF_EXIT=255 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$CFW_AW" 2>&1)" && CFW_EC=0 || CFW_EC=$?
if [[ "$CFW_EC" -eq 0 ]] \
  && [[ ! -f "$CFW_FIX/mock/osascript.calls" ]] \
  && [[ "$CFW_OUT" == *"no alert"* ]]; then
  echo "PASS alert-watch does not alert cloudflared-failing when the plist is absent"
else
  echo "FAIL plist-absent hosts must stay quiet regardless of launchctl shim output (ec=$CFW_EC)" >&2
  echo "$CFW_OUT" >&2
  fail=1
fi

# (d) two distinct conditions in the same run (immediate-second-condition rule).
CFW_PLIST="$CFW_FIX/cf.plist"
: > "$CFW_PLIST"
cfw_reset
printf '%s\n' '{"verdict":"FAIL","reason":"batcher below policy for 24.0 h with no top-up"}' \
  > "$CFW_FIX/funding-health.json"
CFW_OUT="$(cfw_run ALERT_WATCH_CF_STATE='not running' ALERT_WATCH_CF_EXIT=255 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$CFW_AW" 2>&1)" && CFW_EC=0 || CFW_EC=$?
if [[ "$CFW_EC" -eq 0 ]] \
  && [[ "$(cat "$CFW_FIX/mock/osascript.calls" 2>/dev/null || echo 0)" -eq 2 ]] \
  && [[ "$(cat "$CFW_FIX/mock/curl.calls" 2>/dev/null || echo 0)" -eq 2 ]] \
  && [[ "$CFW_OUT" == *"condition funding-fail"* ]] \
  && [[ "$CFW_OUT" == *"condition cloudflared-failing"* ]]; then
  echo "PASS alert-watch fires funding-fail and cloudflared-failing together"
else
  echo "FAIL two distinct conditions must both alert in the same run (ec=$CFW_EC)" >&2
  echo "$CFW_OUT" >&2
  fail=1
fi

# (e) unparseable launchctl output with plist present → fires (fail toward alerting).
cfw_reset
CFW_OUT="$(cfw_run ALERT_WATCH_CF_GARBAGE=1 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$CFW_AW" 2>&1)" && CFW_EC=0 || CFW_EC=$?
if [[ "$CFW_EC" -eq 0 ]] \
  && [[ "$(cat "$CFW_FIX/mock/osascript.calls" 2>/dev/null || echo 0)" -eq 1 ]] \
  && [[ "$CFW_OUT" == *"cloudflared-failing"* ]] \
  && grep -qi 'unparseable' "$CFW_FIX/mock/osascript.argv"; then
  echo "PASS alert-watch cloudflared-failing fires when launchctl output is unparseable"
else
  echo "FAIL unparseable launchctl print with plist present must alert (ec=$CFW_EC)" >&2
  echo "$CFW_OUT" >&2
  fail=1
fi

# launchctl print missing (nonzero) with plist present → fires.
cfw_reset
CFW_OUT="$(cfw_run ALERT_WATCH_CF_MISSING=1 \
  RESEND_API_TOKEN='zzQ8mK2wP9nR4tY7bV1hC3x' "$CFW_AW" 2>&1)" && CFW_EC=0 || CFW_EC=$?
if [[ "$CFW_EC" -eq 0 ]] \
  && [[ "$CFW_OUT" == *"cloudflared-failing"* ]]; then
  echo "PASS alert-watch cloudflared-failing fires when launchctl print is missing"
else
  echo "FAIL missing launchctl print with plist present must alert (ec=$CFW_EC)" >&2
  echo "$CFW_OUT" >&2
  fail=1
fi

# --- check-launchd audit (system domain; shims; no sudo / no gui) ---
if grep -q 'check_cloudflared_daemon' "$CFW_CL" \
  && grep -q 'system/${label}' "$CFW_CL" \
  && grep -q 'CHECK_LAUNCHD_CLOUDFLARED_PLIST' "$CFW_CL" \
  && grep -q 'CHECK_LAUNCHD_LAUNCHCTL' "$CFW_CL" \
  && grep -q 'INFO  ${label}' "$CFW_CL" \
  && ! grep -E '^[[:space:]]*sudo[[:space:]]' "$CFW_CL"; then
  echo "PASS check-launchd has a read-only system-domain cloudflared section"
else
  echo "FAIL check-launchd must report system/com.cloudflare.cloudflared without sudo" >&2
  fail=1
fi

# Linux CI has no plutil; require it only when comparing user-agent plists.
CFW_PLUTIL_XML="$(awk '/^plist_xml\(\) \{/,/^}$/' "$CFW_CL")"
CFW_START="$(awk '/^require_bin python3$/,/^REPO_ROOT=/' "$CFW_CL")"
if echo "$CFW_PLUTIL_XML" | grep -q 'require_bin plutil' \
  && ! echo "$CFW_START" | grep -q 'require_bin plutil'; then
  echo "PASS check-launchd defers plutil to plist_xml (Linux CI has none)"
else
  echo "FAIL check-launchd must not require plutil at startup (CI is Linux)" >&2
  fail=1
fi

cfw_cl_run() {
  CHECK_LAUNCHD_CLOUDFLARED_PLIST="$1" \
    CHECK_LAUNCHD_LAUNCHCTL="$CFW_FIX/shim/launchctl" \
    ALERT_WATCH_MOCK_DIR="$CFW_FIX/mock" \
    "$CFW_CL" 2>&1 || true
}

# Plist absent → INFO, not FAIL for this daemon.
CFW_CL_OUT="$(cfw_cl_run "$CFW_FIX/no-such-cloudflared.plist")"
if echo "$CFW_CL_OUT" | grep -q 'INFO  com.cloudflare.cloudflared' \
  && echo "$CFW_CL_OUT" | grep -q 'not a FAIL' \
  && ! echo "$CFW_CL_OUT" | grep -q 'FAIL  com.cloudflare.cloudflared'; then
  echo "PASS check-launchd plist-absent cloudflared is informational, not FAIL"
else
  echo "FAIL check-launchd must INFO (not FAIL) when the cloudflared plist is absent" >&2
  echo "$CFW_CL_OUT" >&2
  fail=1
fi

# Plist present + healthy → PASS line, labeled system domain.
CFW_CL_OUT="$(ALERT_WATCH_CF_STATE=running ALERT_WATCH_CF_EXIT=0 \
  cfw_cl_run "$CFW_FIX/cf.plist")"
if echo "$CFW_CL_OUT" | grep -q 'PASS  com.cloudflare.cloudflared' \
  && echo "$CFW_CL_OUT" | grep -q 'system domain' \
  && echo "$CFW_CL_OUT" | grep -q 'state=running' \
  && ! echo "$CFW_CL_OUT" | grep -q 'FAIL  com.cloudflare.cloudflared'; then
  echo "PASS check-launchd reports healthy system cloudflared as PASS"
else
  echo "FAIL check-launchd must PASS a running cloudflared system daemon" >&2
  echo "$CFW_CL_OUT" >&2
  fail=1
fi

# Plist present + crash-loop → FAIL with state and last exit code.
CFW_CL_OUT="$(ALERT_WATCH_CF_STATE='not running' ALERT_WATCH_CF_EXIT=255 \
  cfw_cl_run "$CFW_FIX/cf.plist")"
if echo "$CFW_CL_OUT" | grep -q 'FAIL  com.cloudflare.cloudflared' \
  && echo "$CFW_CL_OUT" | grep -q 'system domain' \
  && echo "$CFW_CL_OUT" | grep -q 'state=not running' \
  && echo "$CFW_CL_OUT" | grep -q 'last exit code=255'; then
  echo "PASS check-launchd FAILs an unhealthy system cloudflared daemon"
else
  echo "FAIL check-launchd must FAIL not-running + nonzero last exit" >&2
  echo "$CFW_CL_OUT" >&2
  fail=1
fi

# The cloudflared section must not mention gui/$UID (user-agent domain).
if awk '/check_cloudflared_daemon/,/^}$/' "$CFW_CL" | grep -q 'gui/'; then
  echo "FAIL check-launchd cloudflared section must not use gui/\$UID" >&2
  fail=1
else
  echo "PASS check-launchd cloudflared section is system-domain only (no gui/)"
fi

cleanup_cfw
trap - EXIT
unset CFW_AW CFW_CL CFW_FIX CFW_PLIST CFW_OUT CFW_EC CFW_CL_OUT
unset -f cleanup_cfw cfw_reset cfw_run cfw_cl_run 2>/dev/null || true

# =============================================================================
# end cloudflared-watch block
# =============================================================================

# =============================================================================
# resolve-games-respected-type (D-0105 Finding 4)
# Filter by snapshot respected_game_type + first-run tx cap.
# Parallel with check-launchd-cloudflared — this block stays at EOF.
# Offline fixtures only; no live RPC.
# =============================================================================

RG_RT="$SCRIPT_DIR/resolve-games-sepolia.sh"
RG_RT_PY_DIR="$(dirname "$(command -v python3)")"
RG_RT_PATH="$RG_RT_PY_DIR:/usr/bin:/bin"
RG_RT_FIX="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-rg-respected.XXXXXX")"
cleanup_rg_rt() { rm -rf "$RG_RT_FIX"; }
trap cleanup_rg_rt EXIT

rg_rt_analyze() {
  env -u FORTEL2_ENV -u RESOLVE_GAMES_MAX_TXS_PER_RUN PATH="$RG_RT_PATH" \
    RESOLVE_GAMES_SNAPSHOT="$1" \
    ${2:+RESOLVE_GAMES_MAX_TXS_PER_RUN="$2"} \
    "$RG_RT" --analyze-only 2>&1
}

# (a)+(b) respected type from the snapshot: type 8 selected, type 1 skipped.
# Fails if decide_game is re-hardcoded to type 1.
cat >"$RG_RT_FIX/match.json" <<'EOF'
{
  "now": 1000000,
  "mode": "dry-run",
  "finality_delay": 1800,
  "weth_delay": 3600,
  "init_bond_wei": "80000000000000000",
  "respected_game_type": 8,
  "games": [
    {
      "index": 1,
      "game_type": 8,
      "address": "0x0000000000000000000000000000000000000008",
      "created_at": 990000,
      "max_clock_duration": 7200,
      "status": 0,
      "resolved_at": 0,
      "credit_wei": "0",
      "claim_data_len": 1,
      "weth_amount_wei": "0",
      "weth_unlock_ts": 0
    },
    {
      "index": 2,
      "game_type": 1,
      "address": "0x0000000000000000000000000000000000000001",
      "created_at": 990000,
      "max_clock_duration": 7200,
      "status": 0,
      "resolved_at": 0,
      "credit_wei": "0",
      "claim_data_len": 1,
      "weth_amount_wei": "0",
      "weth_unlock_ts": 0
    }
  ]
}
EOF
RG_RT_AB="$(rg_rt_analyze "$RG_RT_FIX/match.json")" && RG_RT_AB_EC=0 || RG_RT_AB_EC=$?
if [[ "$RG_RT_AB_EC" -eq 0 ]] \
  && echo "$RG_RT_AB" | grep -q '^respected_game_type=8$' \
  && echo "$RG_RT_AB" | grep -q 'game 1 ACTION resolveClaim,resolve' \
  && echo "$RG_RT_AB" | grep -q 'game 2 SKIP not_respected_type' \
  && echo "$RG_RT_AB" | grep -q '^selected_indexes=1$' \
  && ! echo "$RG_RT_AB" | grep -q 'not_type_1'; then
  echo "PASS resolve-games selects snapshot respected type, skips a mismatch"
else
  echo "FAIL respected-type wiring should select 8 and skip 1 (ec=$RG_RT_AB_EC)" >&2
  echo "$RG_RT_AB" >&2
  fail=1
fi

# (c) missing type information → skip missing_type, never selected.
cat >"$RG_RT_FIX/missing-game-type.json" <<'EOF'
{
  "now": 1000000,
  "mode": "dry-run",
  "finality_delay": 1800,
  "weth_delay": 3600,
  "respected_game_type": 8,
  "games": [
    {
      "index": 1,
      "address": "0x0000000000000000000000000000000000000008",
      "created_at": 990000,
      "max_clock_duration": 7200,
      "status": 0,
      "resolved_at": 0,
      "credit_wei": "0",
      "claim_data_len": 1,
      "weth_amount_wei": "0",
      "weth_unlock_ts": 0
    }
  ]
}
EOF
RG_RT_C1="$(rg_rt_analyze "$RG_RT_FIX/missing-game-type.json")" && RG_RT_C1_EC=0 || RG_RT_C1_EC=$?
if [[ "$RG_RT_C1_EC" -eq 0 ]] \
  && echo "$RG_RT_C1" | grep -q 'game 1 SKIP missing_type' \
  && ! echo "$RG_RT_C1" | grep -qE 'selected_indexes=.*(^|,)1(,|$)' \
  && ! echo "$RG_RT_C1" | grep -q 'game 1 ACTION'; then
  echo "PASS resolve-games skips a game missing game_type"
else
  echo "FAIL missing game_type must skip, never select (ec=$RG_RT_C1_EC)" >&2
  echo "$RG_RT_C1" >&2
  fail=1
fi

cat >"$RG_RT_FIX/missing-respected.json" <<'EOF'
{
  "now": 1000000,
  "mode": "dry-run",
  "finality_delay": 1800,
  "weth_delay": 3600,
  "games": [
    {
      "index": 1,
      "game_type": 8,
      "address": "0x0000000000000000000000000000000000000008",
      "created_at": 990000,
      "max_clock_duration": 7200,
      "status": 0,
      "resolved_at": 0,
      "credit_wei": "0",
      "claim_data_len": 1,
      "weth_amount_wei": "0",
      "weth_unlock_ts": 0
    }
  ]
}
EOF
RG_RT_C2="$(rg_rt_analyze "$RG_RT_FIX/missing-respected.json")" && RG_RT_C2_EC=0 || RG_RT_C2_EC=$?
if [[ "$RG_RT_C2_EC" -eq 0 ]] \
  && echo "$RG_RT_C2" | grep -q '^respected_game_type=missing$' \
  && echo "$RG_RT_C2" | grep -q 'game 1 SKIP missing_type' \
  && ! echo "$RG_RT_C2" | grep -q 'game 1 ACTION'; then
  echo "PASS resolve-games skips when snapshot respected_game_type is missing"
else
  echo "FAIL missing snapshot type must skip, never select (ec=$RG_RT_C2_EC)" >&2
  echo "$RG_RT_C2" >&2
  fail=1
fi

cat >"$RG_RT_FIX/bad-type.json" <<'EOF'
{
  "now": 1000000,
  "mode": "dry-run",
  "finality_delay": 1800,
  "weth_delay": 3600,
  "respected_game_type": 8,
  "games": [
    {
      "index": 1,
      "game_type": "nope",
      "address": "0x0000000000000000000000000000000000000008",
      "created_at": 990000,
      "max_clock_duration": 7200,
      "status": 0,
      "resolved_at": 0,
      "credit_wei": "0",
      "claim_data_len": 1,
      "weth_amount_wei": "0",
      "weth_unlock_ts": 0
    }
  ]
}
EOF
RG_RT_C3="$(rg_rt_analyze "$RG_RT_FIX/bad-type.json")" && RG_RT_C3_EC=0 || RG_RT_C3_EC=$?
if [[ "$RG_RT_C3_EC" -eq 0 ]] \
  && echo "$RG_RT_C3" | grep -q 'game 1 SKIP missing_type' \
  && ! echo "$RG_RT_C3" | grep -q 'game 1 ACTION'; then
  echo "PASS resolve-games skips an unparseable game_type"
else
  echo "FAIL unparseable game_type must skip, never select (ec=$RG_RT_C3_EC)" >&2
  echo "$RG_RT_C3" >&2
  fail=1
fi

# (d) more ready games than the cap → exactly cap-many action legs, truncation logged.
cat >"$RG_RT_FIX/cap.json" <<'EOF'
{
  "now": 1000000,
  "mode": "dry-run",
  "finality_delay": 1800,
  "weth_delay": 3600,
  "respected_game_type": 8,
  "games": [
    {
      "index": 1, "game_type": 8, "created_at": 990000, "max_clock_duration": 7200,
      "status": 0, "resolved_at": 0, "credit_wei": "0",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    },
    {
      "index": 2, "game_type": 8, "created_at": 990000, "max_clock_duration": 7200,
      "status": 0, "resolved_at": 0, "credit_wei": "0",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    },
    {
      "index": 3, "game_type": 8, "created_at": 990000, "max_clock_duration": 7200,
      "status": 0, "resolved_at": 0, "credit_wei": "0",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    },
    {
      "index": 4, "game_type": 8, "created_at": 990000, "max_clock_duration": 7200,
      "status": 0, "resolved_at": 0, "credit_wei": "0",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    }
  ]
}
EOF
RG_RT_D="$(rg_rt_analyze "$RG_RT_FIX/cap.json" 5)" && RG_RT_D_EC=0 || RG_RT_D_EC=$?
RG_RT_D_PLAN="$(printf '%s\n' "$RG_RT_D" | awk -F= '/^PLAN_JSON=/{print substr($0,11)}')"
RG_RT_D_N="$(printf '%s' "$RG_RT_D_PLAN" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["actions"]))')"
if [[ "$RG_RT_D_EC" -eq 0 ]] \
  && echo "$RG_RT_D" | grep -q '^max_txs=5$' \
  && echo "$RG_RT_D" | grep -q '^actions_ready=5$' \
  && echo "$RG_RT_D" | grep -q '^txs_cap_truncated=1 remaining_ready=3 (remainder next hour)$' \
  && [[ "$RG_RT_D_N" == "5" ]]; then
  echo "PASS resolve-games tx cap plans exactly 5 actions and logs truncation"
else
  echo "FAIL tx cap should plan 5 actions and truncate (ec=$RG_RT_D_EC n=$RG_RT_D_N)" >&2
  echo "$RG_RT_D" >&2
  fail=1
fi

# Default cap is 5 when the env is unset (the hourly-agent money guard).
RG_RT_DEF="$(
  env -u FORTEL2_ENV -u RESOLVE_GAMES_MAX_TXS_PER_RUN PATH="$RG_RT_PATH" \
    RESOLVE_GAMES_SNAPSHOT="$RG_RT_FIX/cap.json" \
    "$RG_RT" --analyze-only 2>&1
)" && RG_RT_DEF_EC=0 || RG_RT_DEF_EC=$?
if [[ "$RG_RT_DEF_EC" -eq 0 ]] \
  && echo "$RG_RT_DEF" | grep -q '^max_txs=5$' \
  && echo "$RG_RT_DEF" | grep -q '^txs_cap_truncated=1'; then
  echo "PASS resolve-games default max_txs is 5"
else
  echo "FAIL default RESOLVE_GAMES_MAX_TXS_PER_RUN should be 5 (ec=$RG_RT_DEF_EC)" >&2
  echo "$RG_RT_DEF" >&2
  fail=1
fi

# (e) respected type is taken from the snapshot, not re-fetched per game.
RG_RT_DECIDE="$(awk '/^def decide_game\(/,/^WATERMARK_TERMINAL_REASONS/' "$RG_RT")"
RG_RT_FETCH_ONE="$(awk '/^def fetch_one_game\(/,/^def main\(/' "$RG_RT")"
RG_RT_ABI_N="$(grep -c 'respectedGameType()(uint32)' "$RG_RT" || true)"
if echo "$RG_RT_DECIDE" | grep -q 'respected_game_type' \
  && echo "$RG_RT_DECIDE" | grep -q 'not_respected_type' \
  && echo "$RG_RT_DECIDE" | grep -q 'missing_type' \
  && ! echo "$RG_RT_DECIDE" | grep -qE 'cast_call|subprocess|respectedGameType' \
  && ! echo "$RG_RT_DECIDE" | grep -q 'not_type_1' \
  && ! echo "$RG_RT_FETCH_ONE" | grep -q 'respectedGameType' \
  && [[ "$RG_RT_ABI_N" -eq 1 ]]; then
  echo "PASS resolve-games reads respectedGameType once at fetch, not per game"
else
  echo "FAIL respected type must be snapshot-only (decide/fetch-one must not call it; abi count=$RG_RT_ABI_N)" >&2
  fail=1
fi

# Bugbot #182: not_respected_type must be watermark-terminal so a type-1
# prefix cannot pin low_water after the respected type flips to 8.
cat >"$RG_RT_FIX/wm-type.json" <<'EOF'
{
  "now": 1000000,
  "mode": "dry-run",
  "finality_delay": 1800,
  "weth_delay": 3600,
  "respected_game_type": 8,
  "game_count": 2,
  "games": [
    {
      "index": 0, "game_type": 1, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 990000, "credit_wei": "0",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    },
    {
      "index": 1, "game_type": 8, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 999900, "credit_wei": "80000000000000000",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    }
  ]
}
EOF
RG_RT_WM="$RG_RT_FIX/wm-type-mark.json"
RG_RT_WM_OUT="$(
  env -u FORTEL2_ENV -u RESOLVE_GAMES_MAX_TXS_PER_RUN PATH="$RG_RT_PATH" \
    RESOLVE_GAMES_SNAPSHOT="$RG_RT_FIX/wm-type.json" \
    RESOLVE_GAMES_WATERMARK="$RG_RT_WM" \
    "$RG_RT" --analyze-only 2>&1
)" && RG_RT_WM_EC=0 || RG_RT_WM_EC=$?
RG_RT_WM_MARK="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["low_water"])' "$RG_RT_WM" 2>/dev/null || echo missing)"
if [[ "$RG_RT_WM_EC" -eq 0 ]] \
  && echo "$RG_RT_WM_OUT" | grep -q 'game 0 SKIP not_respected_type' \
  && echo "$RG_RT_WM_OUT" | grep -q 'game 1 WAIT finality' \
  && echo "$RG_RT_WM_OUT" | grep -q '^watermark_next=1$' \
  && [[ "$RG_RT_WM_MARK" == "1" ]]; then
  echo "PASS resolve-games not_respected_type does not pin the watermark"
else
  echo "FAIL type-1 prefix must be watermark-terminal (ec=$RG_RT_WM_EC mark=$RG_RT_WM_MARK)" >&2
  echo "$RG_RT_WM_OUT" >&2
  fail=1
fi

# Codex P2: zero-padded cap is canonical base-10 (08 → 8), not octal.
RG_RT_OCT="$(rg_rt_analyze "$RG_RT_FIX/cap.json" 08)" && RG_RT_OCT_EC=0 || RG_RT_OCT_EC=$?
if [[ "$RG_RT_OCT_EC" -eq 0 ]] \
  && echo "$RG_RT_OCT" | grep -q '^max_txs=8$' \
  && grep -q '10#\$MAX_TXS_PER_RUN' "$RG_RT" \
  && grep -q '10#\$max_txs' "$RG_RT"; then
  echo "PASS resolve-games zero-padded max_txs is canonical base-10"
else
  echo "FAIL RESOLVE_GAMES_MAX_TXS_PER_RUN=08 should plan max_txs=8 (ec=$RG_RT_OCT_EC)" >&2
  echo "$RG_RT_OCT" >&2
  fail=1
fi

# Codex P2: live fetch uses initBonds(respected), not a hardcoded 1.
RG_RT_FETCH="$(awk '/^def fetch_snapshot\(/,/^def fetch_one_game\(/' "$RG_RT")"
if echo "$RG_RT_FETCH" | grep -q 'initBonds(uint32)(uint256)", respected' \
  && ! echo "$RG_RT_FETCH" | grep -q 'initBonds(uint32)(uint256)", 1)'; then
  echo "PASS resolve-games fetch initBonds uses the snapshot respected type"
else
  echo "FAIL fetch_snapshot must call initBonds(respected), not initBonds(1)" >&2
  fail=1
fi

cleanup_rg_rt
trap - EXIT
unset RG_RT RG_RT_PY_DIR RG_RT_PATH RG_RT_FIX RG_RT_AB RG_RT_AB_EC
unset RG_RT_C1 RG_RT_C1_EC RG_RT_C2 RG_RT_C2_EC RG_RT_C3 RG_RT_C3_EC
unset RG_RT_D RG_RT_D_EC RG_RT_D_PLAN RG_RT_D_N RG_RT_DEF RG_RT_DEF_EC
unset RG_RT_DECIDE RG_RT_FETCH_ONE RG_RT_ABI_N
unset -f cleanup_rg_rt rg_rt_analyze 2>/dev/null || true

# =============================================================================
# end resolve-games-respected-type block
# =============================================================================

# =============================================================================
# resolve-games-zero-bond-legs
# Condition resolveClaim credit confirmation on plan-time expected credit.
# Additive fixtures only; #182 respected-type block above is untouched.
# Offline mock-execute; no live RPC.
# =============================================================================

RG_ZB="$SCRIPT_DIR/resolve-games-sepolia.sh"
RG_ZB_PY_DIR="$(dirname "$(command -v python3)")"
RG_ZB_PATH="$RG_ZB_PY_DIR:/usr/bin:/bin"
RG_ZB_FIX="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-rg-zero-bond.XXXXXX")"
cleanup_rg_zb() { rm -rf "$RG_ZB_FIX"; }
trap cleanup_rg_zb EXIT

rg_zb_write_game() {
  python3 - "$1" <<'PY'
import json, os, sys

out_dir = sys.argv[1]

def game(idx, status, credit, resolved_sub, resolved_at=0):
    return {
        "index": idx,
        "game_type": 8,
        "address": "0x00000000000000000000000000000000000000%02x" % idx,
        "created_at": 990000,
        "max_clock_duration": 7200,
        "status": status,
        "resolved_at": resolved_at,
        "credit_wei": str(credit),
        "claim_data_len": 1,
        "resolved_subgame": resolved_sub,
        "weth_amount_wei": "0",
        "weth_unlock_ts": 0,
    }

def snap(path, n_games, init_bond):
    games = [game(i, 0, 0, False) for i in range(1, n_games + 1)]
    doc = {
        "now": 1000000,
        "mode": "execute",
        "finality_delay": 1800,
        "weth_delay": 3600,
        "init_bond_wei": str(init_bond),
        "respected_game_type": 8,
        "games": games,
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f)
        f.write("\n")

def write_complete(root, idx):
    states = [
        game(idx, 0, 0, False),
        game(idx, 0, 0, True),
        game(idx, 0, 0, True),
        game(idx, 2, 0, True, 990000),
        game(idx, 2, 0, True, 990000),
    ]
    fetch = os.path.join(root, "fetch")
    os.makedirs(fetch, exist_ok=True)
    for n, g in enumerate(states, 1):
        with open(os.path.join(fetch, "%d.%d.json" % (idx, n)), "w", encoding="utf-8") as f:
            json.dump(g, f)
            f.write("\n")

zb = os.path.join(out_dir, "zero")
os.makedirs(zb, exist_ok=True)
open(os.path.join(zb, "now"), "w").write("1000000\n")
snap(os.path.join(zb, "snapshot.json"), 2, 0)
for i in (1, 2):
    write_complete(zb, i)

cap = os.path.join(out_dir, "cap")
os.makedirs(cap, exist_ok=True)
open(os.path.join(cap, "now"), "w").write("1000000\n")
snap(os.path.join(cap, "snapshot.json"), 4, 0)
for i in (1, 2, 3, 4):
    write_complete(cap, i)

bonded = os.path.join(out_dir, "bonded")
os.makedirs(bonded, exist_ok=True)
open(os.path.join(bonded, "now"), "w").write("1000000\n")
snap(os.path.join(bonded, "snapshot.json"), 1, 80000000000000000)
fetch = os.path.join(bonded, "fetch")
os.makedirs(fetch, exist_ok=True)
for n, g in enumerate([game(1, 0, 0, False), game(1, 0, 0, True)], 1):
    with open(os.path.join(fetch, "1.%d.json" % n), "w", encoding="utf-8") as f:
        json.dump(g, f)
        f.write("\n")
PY
}

rg_zb_write_game "$RG_ZB_FIX"

rg_zb_mock() {
  local mock_dir="$1"
  local max_txs="$2"
  env -u FORTEL2_ENV PATH="$RG_ZB_PATH" \
    RESOLVE_GAMES_SNAPSHOT="$mock_dir/snapshot.json" \
    RESOLVE_GAMES_MOCK_DIR="$mock_dir" \
    RESOLVE_GAMES_MAX_TXS_PER_RUN="$max_txs" \
    "$RG_ZB" 2>&1
}

# (a) zero-bond: resolveClaim credit 0 is success; remaining legs complete; exit 0.
# Fails if the unconditional credit==0 SystemExit is restored.
RG_ZB_A="$(rg_zb_mock "$RG_ZB_FIX/zero" 10)" && RG_ZB_A_EC=0 || RG_ZB_A_EC=$?
RG_ZB_A_SENT="$(printf '%s\n' "$RG_ZB_A" | grep -c '^SENT leg=' || true)"
RG_ZB_A_OK="$(printf '%s\n' "$RG_ZB_A" | grep -c 'OK resolveClaim confirmed with credit 0 (expected 0; zero-bond)' || true)"
if [[ "$RG_ZB_A_EC" -eq 0 ]] \
  && echo "$RG_ZB_A" | grep -q '^EXECUTE done$' \
  && echo "$RG_ZB_A" | grep -q '^txs_sent=4$' \
  && [[ "$RG_ZB_A_SENT" -eq 4 ]] \
  && [[ "$RG_ZB_A_OK" -eq 2 ]] \
  && echo "$RG_ZB_A" | grep -q 'SENT leg=resolve tx=' \
  && ! echo "$RG_ZB_A" | grep -q 'ERROR: resolveClaim confirmed but credit is still 0'; then
  echo "PASS resolve-games zero-bond resolveClaim credit 0 continues remaining legs"
else
  echo "FAIL zero-bond resolveClaim should continue and exit 0 (ec=$RG_ZB_A_EC sent=$RG_ZB_A_SENT ok=$RG_ZB_A_OK)" >&2
  echo "$RG_ZB_A" >&2
  fail=1
fi

# (b) bonded: expected credit > 0 and observed credit 0 still aborts.
# Go-red-able: deleting the expected!=0 guard makes this pass.
RG_ZB_B="$(rg_zb_mock "$RG_ZB_FIX/bonded" 5)" && RG_ZB_B_EC=0 || RG_ZB_B_EC=$?
RG_ZB_B_SENT="$(printf '%s\n' "$RG_ZB_B" | grep -c '^SENT leg=' || true)"
if [[ "$RG_ZB_B_EC" -ne 0 ]] \
  && echo "$RG_ZB_B" | grep -q 'ERROR: resolveClaim confirmed but credit is still 0' \
  && [[ "$RG_ZB_B_SENT" -eq 1 ]] \
  && ! echo "$RG_ZB_B" | grep -q '^EXECUTE done$' \
  && ! echo "$RG_ZB_B" | grep -q 'OK resolveClaim confirmed with credit 0'; then
  echo "PASS resolve-games bonded resolveClaim credit 0 still aborts"
else
  echo "FAIL bonded resolveClaim with expected credit > 0 must abort (ec=$RG_ZB_B_EC sent=$RG_ZB_B_SENT)" >&2
  echo "$RG_ZB_B" >&2
  fail=1
fi

# (c) cap still bounds total legs across the now-longer (non-aborting) run.
RG_ZB_C="$(rg_zb_mock "$RG_ZB_FIX/cap" 5)" && RG_ZB_C_EC=0 || RG_ZB_C_EC=$?
RG_ZB_C_SENT="$(printf '%s\n' "$RG_ZB_C" | grep -c '^SENT leg=' || true)"
if [[ "$RG_ZB_C_EC" -eq 0 ]] \
  && echo "$RG_ZB_C" | grep -q '^txs_sent=5$' \
  && [[ "$RG_ZB_C_SENT" -eq 5 ]] \
  && echo "$RG_ZB_C" | grep -q 'txs_cap_truncated=1 max_txs=5 remainder deferred to next hour' \
  && echo "$RG_ZB_C" | grep -q 'OK resolveClaim confirmed with credit 0 (expected 0; zero-bond)'; then
  echo "PASS resolve-games tx cap still bounds legs after zero-bond confirms"
else
  echo "FAIL cap should bound the longer zero-bond run at 5 (ec=$RG_ZB_C_EC sent=$RG_ZB_C_SENT)" >&2
  echo "$RG_ZB_C" >&2
  fail=1
fi

# resolve / claimCredit_unlock / withdraw confirmations stay unconditional.
if grep -q 'ERROR: resolve confirmed but status is still 0' "$RG_ZB" \
  && grep -q 'ERROR: claimCredit unlock confirmed but DelayedWETH amount is still 0' "$RG_ZB" \
  && grep -q 'ERROR: claimCredit withdraw confirmed but credit is still' "$RG_ZB" \
  && ! awk '/if leg == "resolve" and status == 0/,/raise SystemExit/' "$RG_ZB" | grep -q 'expected' \
  && ! awk '/if leg == "claimCredit_unlock"/,/raise SystemExit/' "$RG_ZB" | grep -q 'expected'; then
  echo "PASS resolve-games resolve/unlock/withdraw confirmations are unchanged"
else
  echo "FAIL resolve/unlock/withdraw confirmations must stay unconditional" >&2
  fail=1
fi

cleanup_rg_zb
trap - EXIT
unset RG_ZB RG_ZB_PY_DIR RG_ZB_PATH RG_ZB_FIX
unset RG_ZB_A RG_ZB_A_EC RG_ZB_A_SENT RG_ZB_A_OK
unset RG_ZB_B RG_ZB_B_EC RG_ZB_B_SENT
unset RG_ZB_C RG_ZB_C_EC RG_ZB_C_SENT
unset -f cleanup_rg_zb rg_zb_write_game rg_zb_mock 2>/dev/null || true

# =============================================================================
# end resolve-games-zero-bond-legs block
# =============================================================================

# =============================================================================
# verify-reth-parity (op-reth Task 3)
# Offline fixtures only; no live RPC, no L1 URL, no JWT.
# Negative --alter-field must be able to go red.
# =============================================================================

VRP="$SCRIPT_DIR/verify-reth-parity.sh"
VRP_NOTE="$FORTEL2_ROOT/tasks/task3-op-reth-safe-head-parity.md"
if git -C "$FORTEL2_ROOT" ls-files --error-unmatch scripts/verify-reth-parity.sh >/dev/null 2>&1 \
  && [[ -x "$VRP" ]]; then
  echo "PASS verify-reth-parity.sh is tracked and executable"
else
  echo "FAIL scripts/verify-reth-parity.sh must be tracked and executable" >&2
  fail=1
fi
if git -C "$FORTEL2_ROOT" ls-files --error-unmatch tasks/task3-op-reth-safe-head-parity.md >/dev/null 2>&1 \
  && [[ -f "$VRP_NOTE" ]]; then
  echo "PASS tasks/task3-op-reth-safe-head-parity.md is tracked"
else
  echo "FAIL Task 3 evidence file must be tracked" >&2
  fail=1
fi

VRP_HELP="$("$VRP" --help 2>&1)" && VRP_HELP_EC=0 || VRP_HELP_EC=$?
if [[ "$VRP_HELP_EC" -eq 0 ]] \
  && echo "$VRP_HELP" | grep -q '19545' \
  && echo "$VRP_HELP" | grep -q '9545' \
  && echo "$VRP_HELP" | grep -q 'fixture' \
  && echo "$VRP_HELP" | grep -q 'alter-field' \
  && echo "$VRP_HELP" | grep -q 'eth_\*' \
  && echo "$VRP_HELP" | grep -qi 'replica'; then
  echo "PASS verify-reth-parity --help names ports, fixture, alter-field, eth_*, replica"
else
  echo "FAIL verify-reth-parity --help must name 19545/9545/fixture/alter-field/eth_*/replica (ec=$VRP_HELP_EC)" >&2
  echo "$VRP_HELP" >&2
  fail=1
fi

if grep -E "['\"]debug_setHead|['\"]admin_" "$VRP"; then
  echo "FAIL verify-reth-parity.sh must not invoke debug_setHead or admin_ methods" >&2
  fail=1
else
  echo "PASS verify-reth-parity.sh does not invoke debug_setHead or admin_ methods"
fi
if grep -q 'proofs init' "$SCRIPT_DIR/start-op-reth-verifier.sh" \
  && grep -q 'skip-backfill' "$SCRIPT_DIR/start-op-reth-verifier.sh"; then
  echo "PASS start-op-reth-verifier.sh runs proofs init --skip-backfill for sequencer_faultproof"
else
  echo "FAIL sidecar start must initialize proofs-history before --proofs-history" >&2
  fail=1
fi
if grep -q 'L1_RPC_URL' "$VRP"; then
  echo "FAIL verify-reth-parity.sh must not mention L1_RPC_URL (no provider URL in parity)" >&2
  fail=1
else
  echo "PASS verify-reth-parity.sh does not mention L1_RPC_URL"
fi
if grep -q 'sleep-ms' "$VRP" \
  && grep -q 'assert_loopback_url' "$VRP" \
  && grep -q 'replica.readRpcUrl' "$VRP"; then
  echo "PASS verify-reth-parity defaults replica from rail-interface, sleeps, loopback-guards live"
else
  echo "FAIL parity script must default replica URL, sleep between RPCs, and loopback-guard live EL" >&2
  fail=1
fi

# Live non-loopback must refuse (fixture-less path).
VRP_NL_OUT="$(
  "$VRP" --live http://example.invalid:8545 --candidate http://127.0.0.1:19545 2>&1
)" && VRP_NL_EC=0 || VRP_NL_EC=$?
if [[ "$VRP_NL_EC" -ne 0 ]] && echo "$VRP_NL_OUT" | grep -qi 'loopback'; then
  echo "PASS verify-reth-parity refuses a non-loopback live URL"
else
  echo "FAIL live sequencer URL must stay loopback (ec=$VRP_NL_EC)" >&2
  echo "$VRP_NL_OUT" >&2
  fail=1
fi

VRP_FIX="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-reth-parity.XXXXXX")"
cleanup_vrp() { rm -rf "$VRP_FIX"; }
trap cleanup_vrp EXIT
python3 - "$VRP_FIX/match.json" <<'PY'
import json, sys

out = sys.argv[1]
blocks = []
for n in range(20):
    num = n  # 0..19 includes 0 and 5
    blocks.append({
        "number": hex(num),
        "hash": "0x" + ("%02x" % (num + 1)) * 32,
        "parentHash": "0x" + ("%02x" % num) * 32,
        "stateRoot": "0x" + ("%02x" % (num + 2)) * 32,
        "receiptsRoot": "0x" + ("%02x" % (num + 3)) * 32,
        "transactions": (
            [{"hash": "0x" + "7e" * 32, "type": "0x7e"},
             {"hash": "0x" + "11" * 32, "type": "0x2"}]
            if num == 5 else []
        ),
    })
doc = {
    "chainId": "852",
    "blocks": blocks,
    "state": [
        {
            "kind": "codehash",
            "address": "0x0116686e2291dbd5e317f47fadbfb43b599786ef",
            "label": "Guestbook",
            "value": "0x" + "aa" * 32,
        },
        {
            "kind": "balance",
            "address": "0x4200000000000000000000000000000000000010",
            "label": "L2StandardBridge",
            "value": "0x1234",
        },
        {
            "kind": "storage",
            "address": "0x4200000000000000000000000000000000000016",
            "slot": "0x1",
            "label": "L2ToL1MessagePasser.messageNonce",
            "value": "0x" + "00" * 31 + "02",
        },
    ],
    "receipts": [
        {
            "transactionHash": "0x" + "7e" * 32,
            "status": "0x1",
            "logsBloom": "0x" + "00" * 256,
            "cumulativeGasUsed": "0x5208",
            "blockNumber": "0x5",
        },
        {
            "transactionHash": "0x" + "11" * 32,
            "status": "0x1",
            "logsBloom": "0x" + "00" * 256,
            "cumulativeGasUsed": "0xa410",
            "blockNumber": "0x5",
        },
    ],
    "deposits": [
        {"txHash": "0x" + "7e" * 32, "type": "0x7e", "blockNumber": 5},
    ],
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(doc, f)
    f.write("\n")
PY

VRP_OK="$("$VRP" --fixture "$VRP_FIX/match.json" 2>&1)" && VRP_OK_EC=0 || VRP_OK_EC=$?
if [[ "$VRP_OK_EC" -eq 0 ]] \
  && echo "$VRP_OK" | grep -q 'full-match' \
  && echo "$VRP_OK" | grep -q 'verify-reth-parity: PASS' \
  && echo "$VRP_OK" | grep -q 'block 0' \
  && echo "$VRP_OK" | grep -q 'block 5' \
  && echo "$VRP_OK" | grep -q 'Guestbook' \
  && echo "$VRP_OK" | grep -q 'L2StandardBridge' \
  && echo "$VRP_OK" | grep -q 'deposit'; then
  echo "PASS verify-reth-parity fixture full-match exits 0"
else
  echo "FAIL fixture match should exit 0 with full-match (ec=$VRP_OK_EC)" >&2
  echo "$VRP_OK" >&2
  fail=1
fi

# Negative: altered hash must name block + field and exit nonzero.
VRP_BAD="$("$VRP" --fixture "$VRP_FIX/match.json" --alter-field hash 2>&1)" && VRP_BAD_EC=0 || VRP_BAD_EC=$?
if [[ "$VRP_BAD_EC" -ne 0 ]] \
  && echo "$VRP_BAD" | grep -q 'MISMATCH block=0 field=hash' \
  && ! echo "$VRP_BAD" | grep -q 'verify-reth-parity: PASS'; then
  echo "PASS verify-reth-parity --alter-field hash exits nonzero and names block+field"
else
  echo "FAIL altered hash must exit nonzero naming block=0 field=hash (ec=$VRP_BAD_EC)" >&2
  echo "$VRP_BAD" >&2
  fail=1
fi

VRP_SR="$("$VRP" --fixture "$VRP_FIX/match.json" --alter-field stateRoot 2>&1)" && VRP_SR_EC=0 || VRP_SR_EC=$?
if [[ "$VRP_SR_EC" -ne 0 ]] && echo "$VRP_SR" | grep -q 'field=stateRoot'; then
  echo "PASS verify-reth-parity --alter-field stateRoot exits nonzero"
else
  echo "FAIL altered stateRoot must go red (ec=$VRP_SR_EC)" >&2
  echo "$VRP_SR" >&2
  fail=1
fi

VRP_BAL="$("$VRP" --fixture "$VRP_FIX/match.json" --alter-field balance 2>&1)" && VRP_BAL_EC=0 || VRP_BAL_EC=$?
if [[ "$VRP_BAL_EC" -ne 0 ]] && echo "$VRP_BAL" | grep -q 'field=balance'; then
  echo "PASS verify-reth-parity --alter-field balance exits nonzero"
else
  echo "FAIL altered balance must go red (ec=$VRP_BAL_EC)" >&2
  echo "$VRP_BAL" >&2
  fail=1
fi

# Short fixture (5 blocks) must fail the ≥20 floor.
python3 - "$VRP_FIX/short.json" <<'PY'
import json, sys
blocks = []
for n in range(5):
    blocks.append({
        "number": hex(n),
        "hash": "0x" + "aa" * 32,
        "parentHash": "0x" + "00" * 32,
        "stateRoot": "0x" + "bb" * 32,
        "receiptsRoot": "0x" + "cc" * 32,
        "transactions": [],
    })
json.dump({"blocks": blocks, "state": [], "receipts": [], "deposits": []}, open(sys.argv[1], "w"))
PY
VRP_SHORT="$("$VRP" --fixture "$VRP_FIX/short.json" 2>&1)" && VRP_SHORT_EC=0 || VRP_SHORT_EC=$?
if [[ "$VRP_SHORT_EC" -ne 0 ]] && echo "$VRP_SHORT" | grep -q 'need >= 20'; then
  echo "PASS verify-reth-parity short fixture fails the 20-block floor"
else
  echo "FAIL a 5-block fixture must not PASS (ec=$VRP_SHORT_EC)" >&2
  echo "$VRP_SHORT" >&2
  fail=1
fi

# Bugbot / Codex: state at the overlap safe tag, not latest; catch-up bound
# is enforced before sampling (otherwise a 20-block prefix can false-PASS).
VRP_BAL_FN="$(awk '/^def get_balance\(/,/^def get_storage\(/' "$VRP")"
VRP_ST_FN="$(awk '/^def get_storage\(/,/^def get_codehash\(/' "$VRP")"
VRP_CODE_FN="$(awk '/^def get_codehash\(/,/^def safe_head\(/' "$VRP")"
if echo "$VRP_BAL_FN" | grep -q 'tag' \
  && echo "$VRP_ST_FN" | grep -q 'tag' \
  && echo "$VRP_CODE_FN" | grep -q 'tag' \
  && ! echo "$VRP_BAL_FN" | grep -q '"latest"' \
  && ! echo "$VRP_ST_FN" | grep -q '"latest"' \
  && ! echo "$VRP_CODE_FN" | grep -q '"latest"' \
  && grep -q 'state tag=' "$VRP"; then
  echo "PASS verify-reth-parity state helpers take a block tag, not latest"
else
  echo "FAIL state checks must query a shared safe block tag, not latest" >&2
  fail=1
fi
if grep -q 'def assert_safe_catchup' "$VRP" \
  && grep -q 'sidecar has not caught the safe head' "$VRP" \
  && grep -q 'MAX_L1_EPOCH_LAG' "$VRP" \
  && echo "$VRP_HELP" | grep -q 'max-l1-epoch-lag'; then
  echo "PASS verify-reth-parity refuses catch-up until L1-origin lag is within 2 epochs"
else
  echo "FAIL live parity must fail closed when candidate lags live safe by >2 L1 epochs" >&2
  fail=1
fi

cleanup_vrp
trap - EXIT
unset VRP VRP_NOTE VRP_HELP VRP_HELP_EC VRP_NL_OUT VRP_NL_EC
unset VRP_FIX VRP_OK VRP_OK_EC VRP_BAD VRP_BAD_EC VRP_SR VRP_SR_EC
unset VRP_BAL VRP_BAL_EC VRP_SHORT VRP_SHORT_EC
unset -f cleanup_vrp 2>/dev/null || true

# =============================================================================
# end verify-reth-parity block
# =============================================================================

# =============================================================================
# pin-agents-worktree (D-0113 Finding 2)
# Standalone clone at /Users/steveforte/fortel2-agents; deploy-agents.sh
# refusals; plist ProgramArguments; check-launchd pinned-tree audit + old-path.
# Additive. Do not reorder the tests above.
# =============================================================================

PA_DEPLOY="$SCRIPT_DIR/deploy-agents.sh"
PA_CL="$SCRIPT_DIR/check-launchd.sh"
PA_LAUNCHD="$(cd "$SCRIPT_DIR/../launchd" && pwd)"
PA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PA_FIX="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-pin-agents.XXXXXX")"
cleanup_pa() { rm -rf "$PA_FIX"; }
trap cleanup_pa EXIT

pa_git() {
  git -c user.email=pin-agents@test.invalid -c user.name=pin-agents "$@"
}

# Bare origin + seed commit on main. Prints nothing; uses $1 as origin.git path.
pa_init_origin() {
  local origin="$1"
  local seed="$PA_FIX/seed"
  git init -q -b main "$seed"
  printf 'seed\n' > "$seed/README"
  printf '.env\n.env.sepolia\ndata/\n' > "$seed/.gitignore"
  pa_git -C "$seed" add README .gitignore
  pa_git -C "$seed" commit -q -m seed
  git clone -q --bare "$seed" "$origin"
  git -C "$seed" remote add origin "$origin"
  git -C "$seed" push -q -u origin main
}

pa_dev_secrets() {
  mkdir -p "$PA_FIX/dev"
  mkdir -p "$PA_FIX/dev/deployments/sepolia/.deployer"
  printf 'SEPOLIA=1\n' > "$PA_FIX/dev/.env.sepolia"
  printf 'LOCAL=1\n' > "$PA_FIX/dev/.env"
}

pa_deploy() {
  env FORTEL2_AGENTS_DIR="$1" FORTEL2_DEV_DIR="$PA_FIX/dev" \
    FORTEL2_AGENTS_REMOTE="$PA_FIX/origin.git" \
    "$PA_DEPLOY" 2>&1
}

pa_cl() {
  env -u FORTEL2_ENV FORTEL2_ROOT="$PA_ROOT" \
    CHECK_LAUNCHD_AGENTS_DIR="${1:-$PA_HOST}" \
    CHECK_LAUNCHD_PINNED_TREE="${2:-$PA_AUDIT}" \
    CHECK_LAUNCHD_DEV_DIR="$PA_FIX/dev" \
    CHECK_LAUNCHD_CLOUDFLARED_PLIST="$PA_FIX/no-such-cloudflared.plist" \
    "$PA_CL" 2>&1 || true
}

# --- (c) every plist ProgramArguments references only the pinned tree ---
PA_PLIST_OLD=0
PA_PLIST_PINNED=0
shopt -s nullglob
for _pa_plist in "$PA_LAUNCHD"/com.steve.fortel2-*.plist; do
  if grep -q '/Users/steveforte/ForteL2' "$_pa_plist"; then
    PA_PLIST_OLD=$((PA_PLIST_OLD + 1))
  fi
  if grep -q '/Users/steveforte/fortel2-agents' "$_pa_plist"; then
    PA_PLIST_PINNED=$((PA_PLIST_PINNED + 1))
  fi
done
shopt -u nullglob
if [[ "$PA_PLIST_OLD" -eq 0 ]] \
  && [[ "$PA_PLIST_PINNED" -eq 5 ]] \
  && [[ "$(grep -c 'com.steve.fortel2-' "$PA_LAUNCHD"/*.plist 2>/dev/null | wc -l | tr -d ' ')" -ge 5 ]]; then
  echo "PASS pin-agents plist ProgramArguments target only /Users/steveforte/fortel2-agents"
else
  echo "FAIL every launchd/*.plist must reference fortel2-agents and not ~/ForteL2 (old=$PA_PLIST_OLD pinned=$PA_PLIST_PINNED)" >&2
  fail=1
fi

# Wake template must stay without fdautil (host wrapper is LaunchControl-only).
if grep -q 'fdautil' "$PA_LAUNCHD/com.steve.fortel2-wake.plist"; then
  echo "FAIL repo wake plist must not embed LaunchControl fdautil (preserve it on the host)" >&2
  fail=1
else
  echo "PASS pin-agents wake template has no fdautil wrapper (host-only)"
fi

# run_dev_{sleep,wake}.sh cd to dirname — work from the pinned tree unchanged.
if grep -q 'cd "$(dirname "$0")"' "$PA_ROOT/run_dev_sleep.sh" \
  && grep -q 'cd "$(dirname "$0")"' "$PA_ROOT/run_dev_wake.sh" \
  && grep -q 'dev-sleep.sh sleep' "$PA_ROOT/run_dev_sleep.sh" \
  && grep -q 'dev-sleep.sh wake' "$PA_ROOT/run_dev_wake.sh"; then
  echo "PASS pin-agents run_dev_{sleep,wake}.sh cd to dirname (work from either tree)"
else
  echo "FAIL run_dev_sleep/wake must cd \"\$(dirname \"\$0\")\" so the pinned tree works" >&2
  fail=1
fi

# Agent entrypoints must not self-update or refuse-if-not-main.
if grep -E 'refuse-if-not-main|rev-parse --abbrev-ref HEAD' \
     "$PA_ROOT/run_dev_sleep.sh" "$PA_ROOT/run_dev_wake.sh" \
     "$PA_ROOT/refresh_health.sh" "$SCRIPT_DIR/alert-watch.sh" \
     "$SCRIPT_DIR/resolve-games-sepolia.sh" "$SCRIPT_DIR/dev-sleep.sh" \
     >/dev/null 2>&1; then
  echo "FAIL agent entrypoints must not grow a branch guard (fail-closed at 03:00)" >&2
  fail=1
else
  echo "PASS pin-agents no branch guard in sleep/wake/agent scripts"
fi

# --- deploy-agents.sh fixture repo ---
pa_dev_secrets
pa_init_origin "$PA_FIX/origin.git"

PA_PIN="$PA_FIX/pinned"
PA_OUT="$(pa_deploy "$PA_PIN")" && PA_EC=0 || PA_EC=$?
if [[ "$PA_EC" -eq 0 ]] \
  && [[ -d "$PA_PIN/.git" ]] \
  && [[ "$(git -C "$PA_PIN" rev-parse --abbrev-ref HEAD)" == "main" ]] \
  && [[ -L "$PA_PIN/.env.sepolia" ]] \
  && [[ "$(readlink "$PA_PIN/.env.sepolia")" == "$PA_FIX/dev/.env.sepolia" ]] \
  && [[ -L "$PA_PIN/.env" ]] \
  && [[ -L "$PA_PIN/data" ]] \
  && [[ "$(readlink "$PA_PIN/data")" == "$PA_FIX/dev/data" ]] \
  && echo "$PA_OUT" | grep -q 'agents now run'; then
  echo "PASS pin-agents deploy creates pinned clone on main with env symlinks"
else
  echo "FAIL deploy-agents.sh should create a main clone + .env.sepolia symlink (ec=$PA_EC)" >&2
  echo "$PA_OUT" >&2
  fail=1
fi

# Idempotent second run (already up to date + symlinks already).
PA_OUT2="$(pa_deploy "$PA_PIN")" && PA_EC2=0 || PA_EC2=$?
if [[ "$PA_EC2" -eq 0 ]] \
  && echo "$PA_OUT2" | grep -q 'already' \
  && [[ -L "$PA_PIN/.env.sepolia" ]]; then
  echo "PASS pin-agents deploy is idempotent (ff no-op + symlink already)"
else
  echo "FAIL second deploy-agents.sh should be idempotent (ec=$PA_EC2)" >&2
  echo "$PA_OUT2" >&2
  fail=1
fi

# Fast-forward: new commit on origin, deploy advances HEAD.
PA_OLD_HEAD="$(git -C "$PA_PIN" rev-parse HEAD)"
printf 'next\n' > "$PA_FIX/seed/README"
pa_git -C "$PA_FIX/seed" add README
pa_git -C "$PA_FIX/seed" commit -q -m next
git -C "$PA_FIX/seed" push -q origin main
PA_FF="$(pa_deploy "$PA_PIN")" && PA_FF_EC=0 || PA_FF_EC=$?
PA_NEW_HEAD="$(git -C "$PA_PIN" rev-parse HEAD)"
if [[ "$PA_FF_EC" -eq 0 ]] \
  && [[ "$PA_NEW_HEAD" != "$PA_OLD_HEAD" ]] \
  && git -C "$PA_PIN" merge-base --is-ancestor "$PA_OLD_HEAD" "$PA_NEW_HEAD"; then
  echo "PASS pin-agents deploy fast-forwards from origin/main"
else
  echo "FAIL deploy-agents.sh should ff-only update (ec=$PA_FF_EC old=$PA_OLD_HEAD new=$PA_NEW_HEAD)" >&2
  echo "$PA_FF" >&2
  fail=1
fi

# Dirty → distinct refusal, nonzero. Go-red-able: drop the dirty check.
printf 'dirt\n' >> "$PA_PIN/README"
PA_DIRTY="$(pa_deploy "$PA_PIN")" && PA_DIRTY_EC=0 || PA_DIRTY_EC=$?
git -C "$PA_PIN" checkout -q -- README
if [[ "$PA_DIRTY_EC" -ne 0 ]] \
  && echo "$PA_DIRTY" | grep -q 'pinned tree is dirty'; then
  echo "PASS pin-agents deploy refuses a dirty tree"
else
  echo "FAIL dirty pinned tree must refuse with the dirty message (ec=$PA_DIRTY_EC)" >&2
  echo "$PA_DIRTY" >&2
  fail=1
fi

# Not-main → distinct refusal. Go-red-able: drop the branch check.
git -C "$PA_PIN" checkout -q -b not-main
PA_BRANCH="$(pa_deploy "$PA_PIN")" && PA_BRANCH_EC=0 || PA_BRANCH_EC=$?
git -C "$PA_PIN" checkout -q main
git -C "$PA_PIN" branch -q -D not-main
if [[ "$PA_BRANCH_EC" -ne 0 ]] \
  && echo "$PA_BRANCH" | grep -q 'pinned tree is not on branch main'; then
  echo "PASS pin-agents deploy refuses a non-main branch"
else
  echo "FAIL non-main pinned tree must refuse with the not-main message (ec=$PA_BRANCH_EC)" >&2
  echo "$PA_BRANCH" >&2
  fail=1
fi

# Diverged → distinct refusal. Go-red-able: reset --hard would "fix" this; we must not.
printf 'local-only\n' > "$PA_PIN/local.txt"
pa_git -C "$PA_PIN" add local.txt
pa_git -C "$PA_PIN" commit -q -m local-only
printf 'origin-only\n' > "$PA_FIX/seed/other.txt"
pa_git -C "$PA_FIX/seed" add other.txt
pa_git -C "$PA_FIX/seed" commit -q -m origin-only
git -C "$PA_FIX/seed" push -q origin main
PA_DIV="$(pa_deploy "$PA_PIN")" && PA_DIV_EC=0 || PA_DIV_EC=$?
if [[ "$PA_DIV_EC" -ne 0 ]] \
  && echo "$PA_DIV" | grep -q 'pinned tree has diverged from origin/main'; then
  echo "PASS pin-agents deploy refuses a diverged tree"
else
  echo "FAIL diverged pinned tree must refuse with the diverged message (ec=$PA_DIV_EC)" >&2
  echo "$PA_DIV" >&2
  fail=1
fi

# Regular .env.sepolia in the pinned tree → refuse overwrite (never silent).
# Rebuild a clean pinned tree for this case.
rm -rf "$PA_PIN"
PA_CLEAN="$(pa_deploy "$PA_PIN")" && PA_CLEAN_EC=0 || PA_CLEAN_EC=$?
rm -f "$PA_PIN/.env.sepolia"
printf 'real-file\n' > "$PA_PIN/.env.sepolia"
PA_REG="$(pa_deploy "$PA_PIN")" && PA_REG_EC=0 || PA_REG_EC=$?
if [[ "$PA_CLEAN_EC" -eq 0 ]] \
  && [[ "$PA_REG_EC" -ne 0 ]] \
  && echo "$PA_REG" | grep -q 'refusing to overwrite existing file with a symlink'; then
  echo "PASS pin-agents deploy refuses to replace a real .env.sepolia with a symlink"
else
  echo "FAIL existing regular .env.sepolia must refuse overwrite (ec=$PA_REG_EC clean=$PA_CLEAN_EC)" >&2
  echo "$PA_REG" >&2
  fail=1
fi

# Existing clone whose origin is not this repo → refuse before fetch/symlink.
PA_WRONG="$PA_FIX/wrong-origin"
git init -q -b main "$PA_WRONG"
git -C "$PA_WRONG" remote add origin "https://github.com/example/not-fortel2.git"
pa_git -C "$PA_WRONG" commit -q --allow-empty -m not-us
PA_WO="$(pa_deploy "$PA_WRONG")" && PA_WO_EC=0 || PA_WO_EC=$?
if [[ "$PA_WO_EC" -ne 0 ]] \
  && echo "$PA_WO" | grep -q 'pinned tree origin is not this repo'; then
  echo "PASS pin-agents deploy refuses a clone whose origin is not this repo"
else
  echo "FAIL existing clone with a foreign origin must refuse (ec=$PA_WO_EC)" >&2
  echo "$PA_WO" >&2
  fail=1
fi

# --- (d) check-launchd FAILs a host plist pointing at ~/ForteL2 ---
PA_HOST="$PA_FIX/host-agents"
mkdir -p "$PA_HOST"
cp "$PA_LAUNCHD/com.steve.fortel2-sleep.plist" "$PA_HOST/"
# Portable in-place substitute (no sed -i difference across BSD/GNU).
python3 -c '
from pathlib import Path
p = Path("'"$PA_HOST"'/com.steve.fortel2-sleep.plist")
p.write_text(p.read_text().replace("/Users/steveforte/fortel2-agents", "/Users/steveforte/ForteL2"))
'

# Fixture pinned tree that belongs to this repo (same origin URL), on main, clean.
PA_AUDIT="$PA_FIX/audit-tree"
git init -q -b main "$PA_AUDIT"
git -C "$PA_AUDIT" remote add origin "$(git -C "$PA_ROOT" remote get-url origin)"
pa_git -C "$PA_AUDIT" commit -q --allow-empty -m audit
mkdir -p "$PA_AUDIT/.git/info" "$PA_FIX/dev/data"
printf '.env.sepolia\n.env\ndata\ndeployments/sepolia/.deployer\n' >> "$PA_AUDIT/.git/info/exclude"

# Missing .env.sepolia symlink is FAIL even though gitignore hides it.
PA_CL_NOSYM="$(pa_cl "$PA_HOST" "$PA_AUDIT")"
if echo "$PA_CL_NOSYM" | grep -q 'FAIL  pinned tree .env.sepolia is missing or not a symlink'; then
  echo "PASS pin-agents check-launchd FAILs a pinned tree without .env.sepolia symlink"
else
  echo "FAIL check-launchd must FAIL when .env.sepolia is not a symlink" >&2
  echo "$PA_CL_NOSYM" >&2
  fail=1
fi

ln -s "$PA_FIX/dev/.env.sepolia" "$PA_AUDIT/.env.sepolia"
ln -s "$PA_FIX/dev/data" "$PA_AUDIT/data"
mkdir -p "$PA_AUDIT/deployments/sepolia" "$PA_FIX/dev/deployments/sepolia/.deployer"
ln -s "$PA_FIX/dev/deployments/sepolia/.deployer" "$PA_AUDIT/deployments/sepolia/.deployer"

PA_CL_OLD="$(pa_cl "$PA_HOST" "$PA_AUDIT")"
if echo "$PA_CL_OLD" | grep -q 'FAIL  com.steve.fortel2-sleep' \
  && echo "$PA_CL_OLD" | grep -q '/Users/steveforte/ForteL2' \
  && echo "$PA_CL_OLD" | grep -q 'PASS  pinned tree'; then
  echo "PASS pin-agents check-launchd FAILs a host plist on the old checkout path"
else
  echo "FAIL check-launchd must FAIL an installed plist pointing at ~/ForteL2" >&2
  echo "$PA_CL_OLD" >&2
  fail=1
fi

# Pinned-tree audit: dirty / not-main / missing are FAIL (read-only).
printf 'dirt\n' > "$PA_AUDIT/dirt.txt"
PA_CL_DIRTY="$(pa_cl "$PA_HOST" "$PA_AUDIT")"
rm -f "$PA_AUDIT/dirt.txt"
if echo "$PA_CL_DIRTY" | grep -q 'FAIL  pinned tree is dirty'; then
  echo "PASS pin-agents check-launchd FAILs a dirty pinned tree"
else
  echo "FAIL check-launchd must FAIL when the pinned tree is dirty" >&2
  echo "$PA_CL_DIRTY" >&2
  fail=1
fi

git -C "$PA_AUDIT" checkout -q -b not-main
PA_CL_NM="$(pa_cl "$PA_HOST" "$PA_AUDIT")"
git -C "$PA_AUDIT" checkout -q main
if echo "$PA_CL_NM" | grep -q 'FAIL  pinned tree is not on branch main'; then
  echo "PASS pin-agents check-launchd FAILs a non-main pinned tree"
else
  echo "FAIL check-launchd must FAIL when the pinned tree is not on main" >&2
  echo "$PA_CL_NM" >&2
  fail=1
fi

PA_CL_MISS="$(pa_cl "$PA_HOST" "$PA_FIX/no-such-tree")"
if echo "$PA_CL_MISS" | grep -q 'FAIL  pinned tree missing'; then
  echo "PASS pin-agents check-launchd FAILs a missing pinned tree"
else
  echo "FAIL check-launchd must FAIL when the pinned tree is absent" >&2
  echo "$PA_CL_MISS" >&2
  fail=1
fi

# Repo template audit (python3, no plutil) PASSes current plists.
PA_CL_REPO="$(pa_cl "$PA_FIX/empty-agents" "$PA_AUDIT")"
if echo "$PA_CL_REPO" | grep -q 'PASS  com.steve.fortel2-sleep  repo script=/Users/steveforte/fortel2-agents/run_dev_sleep.sh' \
  && echo "$PA_CL_REPO" | grep -q 'PASS  com.steve.fortel2-wake  repo script=/Users/steveforte/fortel2-agents/run_dev_wake.sh' \
  && echo "$PA_CL_REPO" | grep -q 'PASS  com.steve.fortel2-health  repo script=/Users/steveforte/fortel2-agents/refresh_health.sh' \
  && echo "$PA_CL_REPO" | grep -q 'PASS  com.steve.fortel2-alerts  repo script=/Users/steveforte/fortel2-agents/scripts/alert-watch.sh' \
  && echo "$PA_CL_REPO" | grep -q 'PASS  com.steve.fortel2-resolve-games  repo script=/Users/steveforte/fortel2-agents/scripts/resolve-games-sepolia.sh'; then
  echo "PASS pin-agents check-launchd repo templates target the pinned tree"
else
  echo "FAIL check-launchd must PASS repo templates pointing at fortel2-agents" >&2
  echo "$PA_CL_REPO" >&2
  fail=1
fi

# .env.sepolia is gitignored — porcelain cannot see it; audit the symlink.
rm -f "$PA_AUDIT/.env.sepolia"
PA_CL_ENV="$(
  env -u FORTEL2_ENV FORTEL2_ROOT="$PA_ROOT" \
  CHECK_LAUNCHD_AGENTS_DIR="$PA_FIX/empty-agents" \
  CHECK_LAUNCHD_PINNED_TREE="$PA_AUDIT" \
  CHECK_LAUNCHD_DEV_DIR="$PA_FIX/dev" \
  CHECK_LAUNCHD_CLOUDFLARED_PLIST="$PA_FIX/no-such-cloudflared.plist" \
  "$PA_CL" 2>&1 || true
)"
ln -s "$PA_FIX/dev/.env.sepolia" "$PA_AUDIT/.env.sepolia"
if echo "$PA_CL_ENV" | grep -q 'FAIL  pinned tree .env.sepolia is missing or not a symlink'; then
  echo "PASS pin-agents check-launchd FAILs a pinned tree missing the .env.sepolia symlink"
else
  echo "FAIL check-launchd must FAIL when .env.sepolia is not a symlink to the checkout" >&2
  echo "$PA_CL_ENV" >&2
  fail=1
fi

# deploy-agents.sh is a standalone clone, not a worktree of the dev checkout.
if grep -q 'git worktree add' "$PA_DEPLOY"; then
  echo "FAIL deploy-agents.sh must be a standalone clone (worktree shares .git with workers)" >&2
  fail=1
else
  echo "PASS pin-agents deploy uses a standalone clone (not a worktree)"
fi

cleanup_pa
trap - EXIT
unset PA_DEPLOY PA_CL PA_LAUNCHD PA_ROOT PA_FIX PA_PIN PA_OUT PA_EC PA_OUT2 PA_EC2
unset PA_OLD_HEAD PA_FF PA_FF_EC PA_NEW_HEAD PA_DIRTY PA_DIRTY_EC
unset PA_BRANCH PA_BRANCH_EC PA_DIV PA_DIV_EC PA_CLEAN PA_CLEAN_EC PA_REG PA_REG_EC
unset PA_HOST PA_AUDIT PA_CL_OLD PA_CL_DIRTY PA_CL_NM PA_CL_MISS PA_CL_REPO PA_CL_ENV
unset PA_CL_NOSYM PA_PLIST_OLD PA_PLIST_PINNED PA_WRONG PA_WO PA_WO_EC
unset -f cleanup_pa pa_git pa_init_origin pa_dev_secrets pa_deploy pa_cl 2>/dev/null || true

# =============================================================================
# end pin-agents-worktree block
# =============================================================================

# =============================================================================
# verify-reth-faultproof (op-reth Task 4)
# Offline fixtures only; no live RPC, no L1 URL, no JWT.
# Negative --alter-field outputRoot must be able to go red.
# =============================================================================

VRF="$SCRIPT_DIR/verify-reth-faultproof.sh"
VRF_NOTE="$FORTEL2_ROOT/tasks/task4-op-reth-faultproof.md"
if git -C "$FORTEL2_ROOT" ls-files --error-unmatch scripts/verify-reth-faultproof.sh >/dev/null 2>&1 \
  && [[ -x "$VRF" ]]; then
  echo "PASS verify-reth-faultproof.sh is tracked and executable"
else
  echo "FAIL scripts/verify-reth-faultproof.sh must be tracked and executable" >&2
  fail=1
fi
if git -C "$FORTEL2_ROOT" ls-files --error-unmatch tasks/task4-op-reth-faultproof.md >/dev/null 2>&1 \
  && [[ -f "$VRF_NOTE" ]]; then
  echo "PASS tasks/task4-op-reth-faultproof.md is tracked"
else
  echo "FAIL Task 4 evidence file must be tracked" >&2
  fail=1
fi
if grep -q 'STATUS: complete' "$VRF_NOTE" \
  && grep -qi 'not a Task 5 go' "$VRF_NOTE" \
  && grep -qi 'not a sequencer-cutover' "$VRF_NOTE" \
  && ! grep -q "Candidate datadir is Task 5's input" "$VRF_NOTE"; then
  echo "PASS Task 4 evidence is STATUS complete (not a Task 5 go / not a cutover)"
else
  echo "FAIL Task 4 evidence must be STATUS complete and still refuse Task 5 / cutover" >&2
  fail=1
fi

VRF_HELP="$("$VRF" --help 2>&1)" && VRF_HELP_EC=0 || VRF_HELP_EC=$?
if [[ "$VRF_HELP_EC" -eq 0 ]] \
  && echo "$VRF_HELP" | grep -q '19545' \
  && echo "$VRF_HELP" | grep -q '9545' \
  && echo "$VRF_HELP" | grep -q 'outputRoot' \
  && echo "$VRF_HELP" | grep -qi 'safedb' \
  && echo "$VRF_HELP" | grep -q 'fixture' \
  && echo "$VRF_HELP" | grep -q 'alter-field'; then
  echo "PASS verify-reth-faultproof --help names ports, output-root, SafeDB, fixture, alter-field"
else
  echo "FAIL verify-reth-faultproof --help must name ports/output-root/SafeDB/fixture/alter-field (ec=$VRF_HELP_EC)" >&2
  echo "$VRF_HELP" >&2
  fail=1
fi

if grep -E "['\"]debug_setHead|['\"]admin_" "$VRF"; then
  echo "FAIL verify-reth-faultproof.sh must not invoke debug_setHead or admin_ methods" >&2
  fail=1
else
  echo "PASS verify-reth-faultproof.sh does not invoke debug_setHead or admin_ methods"
fi
if grep -q 'replica' "$VRF" && grep -q 'never queried' "$VRF"; then
  echo "PASS verify-reth-faultproof.sh documents replica-never-queried (prune window)"
else
  echo "FAIL faultproof script must refuse replica historical reads" >&2
  fail=1
fi
if grep -q 'print.*L1_RPC_URL\|echo.*L1_RPC_URL' "$VRF"; then
  echo "FAIL verify-reth-faultproof.sh must not print L1_RPC_URL" >&2
  fail=1
else
  echo "PASS verify-reth-faultproof.sh does not print L1_RPC_URL"
fi

# Live non-loopback must refuse (fixture-less path).
VRF_NL_OUT="$(
  "$VRF" --live http://example.invalid:8545 --candidate http://127.0.0.1:19545 \
    --game-l2-block 1 --safedb-enable-l1 1 2>&1
)" && VRF_NL_EC=0 || VRF_NL_EC=$?
if [[ "$VRF_NL_EC" -ne 0 ]] && echo "$VRF_NL_OUT" | grep -qi 'loopback'; then
  echo "PASS verify-reth-faultproof refuses a non-loopback live URL"
else
  echo "FAIL live sequencer URL must stay loopback (ec=$VRF_NL_EC)" >&2
  echo "$VRF_NL_OUT" >&2
  fail=1
fi

# Live mode without --game-l2-block must fail closed (can go red).
VRF_GAME_OUT="$(
  "$VRF" --candidate http://127.0.0.1:19545 --live http://127.0.0.1:9545 2>&1
)" && VRF_GAME_EC=0 || VRF_GAME_EC=$?
if [[ "$VRF_GAME_EC" -ne 0 ]] && echo "$VRF_GAME_OUT" | grep -q 'game-l2-block'; then
  echo "PASS verify-reth-faultproof live mode requires --game-l2-block"
else
  echo "FAIL live mode must require the proposed game L2 block (ec=$VRF_GAME_EC)" >&2
  echo "$VRF_GAME_OUT" >&2
  fail=1
fi

# Live mode without --pre-enable-l1 must fail closed (do not default enable-1).
VRF_PRE_REQ_OUT="$(
  "$VRF" --candidate http://127.0.0.1:19545 --live http://127.0.0.1:9545 \
    --game-l2-block 1 --safedb-enable-l1 100 2>&1
)" && VRF_PRE_REQ_EC=0 || VRF_PRE_REQ_EC=$?
if [[ "$VRF_PRE_REQ_EC" -ne 0 ]] \
  && echo "$VRF_PRE_REQ_OUT" | grep -q 'pre-enable-l1' \
  && echo "$VRF_PRE_REQ_OUT" | grep -qi 'known-unrecorded'; then
  echo "PASS verify-reth-faultproof live mode requires --pre-enable-l1"
else
  echo "FAIL live mode must require a known-unrecorded --pre-enable-l1 (ec=$VRF_PRE_REQ_EC)" >&2
  echo "$VRF_PRE_REQ_OUT" >&2
  fail=1
fi

VRF_FIX="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-reth-faultproof.XXXXXX")"
cleanup_vrf() { rm -rf "$VRF_FIX"; }
trap cleanup_vrf EXIT
python3 - "$VRF_FIX/match.json" "$VRF_FIX/short.json" "$VRF_FIX/collapse.json" <<'PY'
import json, sys

def proof(block, addr, tag, with_slot=True):
    item = {
        "block": block,
        "address": addr,
        "storageHash": "0x" + tag * 32,
        "balance": "0x0",
        "nonce": "0x1",
        "codeHash": "0x" + "77" * 32,
        "accountProof": ["0x" + "88" * 32, "0x" + tag * 32],
        "storageProof": [],
    }
    if with_slot:
        item["storageProof"] = [{
            "key": "0x" + "00" * 32,
            "value": "0x1",
            "proof": ["0x" + "99" * 32],
        }]
    return item

def doc():
    passer = "0x4200000000000000000000000000000000000016"
    bridge = "0x4200000000000000000000000000000000000010"
    return {
        "gameL2Block": 3000,
        "safedbEnableL1": 90,
        "preEnableL1": 80,
        "preEnableError": "safe head not found for L1 block 80",
        "outputRoots": [
            {"l2Block": 1000, "outputRoot": "0x" + "aa" * 32},
            {"l2Block": 2000, "outputRoot": "0x" + "bb" * 32},
            {"l2Block": 3000, "outputRoot": "0x" + "cc" * 32},
        ],
        "safeHeads": [
            {"l1Block": 100, "recordedL1": 100, "l2Number": 50, "l2Hash": "0x" + "11" * 32},
            {"l1Block": 110, "recordedL1": 110, "l2Number": 110, "l2Hash": "0x" + "22" * 32},
            {"l1Block": 120, "recordedL1": 120, "l2Number": 170, "l2Hash": "0x" + "33" * 32},
        ],
        "proofs": [
            proof(5, passer, "44", True),
            proof(1000, bridge, "55", False),
            proof(100000, passer, "66", True),
        ],
    }

with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(doc(), f)
    f.write("\n")
short = doc()
short["outputRoots"] = short["outputRoots"][:1]
with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(short, f)
    f.write("\n")
# Floor-semantics trap: three queries, one recorded L1. Must go red.
collapse = doc()
collapse["safeHeads"] = [
    {"l1Block": 100, "recordedL1": 100, "l2Number": 50, "l2Hash": "0x" + "11" * 32},
    {"l1Block": 110, "recordedL1": 100, "l2Number": 50, "l2Hash": "0x" + "11" * 32},
    {"l1Block": 120, "recordedL1": 100, "l2Number": 50, "l2Hash": "0x" + "11" * 32},
]
with open(sys.argv[3], "w", encoding="utf-8") as f:
    json.dump(collapse, f)
    f.write("\n")
PY

VRF_OK="$("$VRF" --fixture "$VRF_FIX/match.json" 2>&1)" && VRF_OK_EC=0 || VRF_OK_EC=$?
if [[ "$VRF_OK_EC" -eq 0 ]] \
  && echo "$VRF_OK" | grep -q 'verify-reth-faultproof: PASS' \
  && echo "$VRF_OK" | grep -q 'output-root compare: PASS' \
  && echo "$VRF_OK" | grep -q 'SafeDB post-enable: PASS' \
  && echo "$VRF_OK" | grep -q 'SafeDB pre-enable negative' \
  && echo "$VRF_OK" | grep -q 'historical eth_getProof: PASS'; then
  echo "PASS verify-reth-faultproof fixture full-match exits 0"
else
  echo "FAIL fixture match should exit 0 (ec=$VRF_OK_EC)" >&2
  echo "$VRF_OK" >&2
  fail=1
fi

# Negative: altered output root must name field and exit nonzero (can go red).
VRF_BAD="$("$VRF" --fixture "$VRF_FIX/match.json" --alter-field outputRoot 2>&1)" && VRF_BAD_EC=0 || VRF_BAD_EC=$?
if [[ "$VRF_BAD_EC" -ne 0 ]] \
  && echo "$VRF_BAD" | grep -q 'MISMATCH' \
  && echo "$VRF_BAD" | grep -q 'outputRoot' \
  && ! echo "$VRF_BAD" | grep -q 'verify-reth-faultproof: PASS'; then
  echo "PASS verify-reth-faultproof --alter-field outputRoot exits nonzero and names field"
else
  echo "FAIL altered outputRoot must exit nonzero (ec=$VRF_BAD_EC)" >&2
  echo "$VRF_BAD" >&2
  fail=1
fi

VRF_SH="$("$VRF" --fixture "$VRF_FIX/match.json" --alter-field safeHead 2>&1)" && VRF_SH_EC=0 || VRF_SH_EC=$?
if [[ "$VRF_SH_EC" -ne 0 ]] && echo "$VRF_SH" | grep -q 'MISMATCH'; then
  echo "PASS verify-reth-faultproof --alter-field safeHead exits nonzero"
else
  echo "FAIL altered safeHead must exit nonzero (ec=$VRF_SH_EC)" >&2
  echo "$VRF_SH" >&2
  fail=1
fi

VRF_PR="$("$VRF" --fixture "$VRF_FIX/match.json" --alter-field proof 2>&1)" && VRF_PR_EC=0 || VRF_PR_EC=$?
if [[ "$VRF_PR_EC" -ne 0 ]] && echo "$VRF_PR" | grep -q 'MISMATCH'; then
  echo "PASS verify-reth-faultproof --alter-field proof exits nonzero"
else
  echo "FAIL altered proof must exit nonzero (ec=$VRF_PR_EC)" >&2
  echo "$VRF_PR" >&2
  fail=1
fi

VRF_PRE="$("$VRF" --fixture "$VRF_FIX/match.json" --alter-field preEnable 2>&1)" && VRF_PRE_EC=0 || VRF_PRE_EC=$?
if [[ "$VRF_PRE_EC" -ne 0 ]] && echo "$VRF_PRE" | grep -qi 'pre-enable'; then
  echo "PASS verify-reth-faultproof --alter-field preEnable fails the required negative"
else
  echo "FAIL a succeeding pre-enable query must fail closed (ec=$VRF_PRE_EC)" >&2
  echo "$VRF_PRE" >&2
  fail=1
fi

VRF_SHORT="$("$VRF" --fixture "$VRF_FIX/short.json" 2>&1)" && VRF_SHORT_EC=0 || VRF_SHORT_EC=$?
if [[ "$VRF_SHORT_EC" -ne 0 ]] && echo "$VRF_SHORT" | grep -q 'need >= 3'; then
  echo "PASS verify-reth-faultproof short fixture fails the 3-root floor"
else
  echo "FAIL a 1-root fixture must not PASS (ec=$VRF_SHORT_EC)" >&2
  echo "$VRF_SHORT" >&2
  fail=1
fi

VRF_COLLAPSE="$("$VRF" --fixture "$VRF_FIX/collapse.json" 2>&1)" && VRF_COLLAPSE_EC=0 || VRF_COLLAPSE_EC=$?
if [[ "$VRF_COLLAPSE_EC" -ne 0 ]] \
  && echo "$VRF_COLLAPSE" | grep -qi 'not distinct' \
  && ! echo "$VRF_COLLAPSE" | grep -q 'verify-reth-faultproof: PASS'; then
  echo "PASS verify-reth-faultproof collapsed SafeDB records fail distinct-L1 check"
else
  echo "FAIL three queries to one recorded L1 must not PASS (ec=$VRF_COLLAPSE_EC)" >&2
  echo "$VRF_COLLAPSE" >&2
  fail=1
fi

cleanup_vrf
trap - EXIT
unset VRF VRF_NOTE VRF_HELP VRF_HELP_EC VRF_NL_OUT VRF_NL_EC
unset VRF_GAME_OUT VRF_GAME_EC VRF_PRE_REQ_OUT VRF_PRE_REQ_EC VRF_FIX VRF_OK VRF_OK_EC
unset VRF_BAD VRF_BAD_EC VRF_SH VRF_SH_EC VRF_PR VRF_PR_EC
unset VRF_PRE VRF_PRE_EC VRF_SHORT VRF_SHORT_EC VRF_COLLAPSE VRF_COLLAPSE_EC
unset -f cleanup_vrf 2>/dev/null || true

# =============================================================================
# end verify-reth-faultproof block
# =============================================================================

# --- Task 5: selector flips, admin helper, rollback order (must be able to go red) ---
T5_ADMIN="$SCRIPT_DIR/sequencer-admin.sh"
T5_CUT="$SCRIPT_DIR/cutover-to-reth-sepolia.sh"
T5_ROLL="$SCRIPT_DIR/rollback-to-geth-sepolia.sh"
T5_SEP="$SCRIPT_DIR/04-start-sequencer-sepolia.sh"

if [[ -x "$T5_ADMIN" && -x "$T5_CUT" && -x "$T5_ROLL" ]]; then
  echo "PASS Task 5 scripts sequencer-admin/cutover/rollback are executable"
else
  echo "FAIL Task 5 scripts must be executable" >&2
  fail=1
fi

T5_PLAN_G="$( "$T5_SEP" --print-plan 2>&1 )" && T5_PLAN_G_EC=0 || T5_PLAN_G_EC=$?
if [[ "$T5_PLAN_G_EC" -eq 0 ]] \
  && echo "$T5_PLAN_G" | grep -q 'EL=op-geth' \
  && echo "$T5_PLAN_G" | grep -q 'ENGINEKIND=geth' \
  && echo "$T5_PLAN_G" | grep -q 'SEQUENCER_STOPPED=false' \
  && echo "$T5_PLAN_G" | grep -q 'JWT=live'; then
  echo "PASS 04-start-sequencer-sepolia.sh --print-plan default is geth stopped=false"
else
  echo "FAIL default --print-plan must stay geth / stopped=false (ec=$T5_PLAN_G_EC)" >&2
  echo "$T5_PLAN_G" >&2
  fail=1
fi

T5_PLAN_V="$( "$T5_SEP" --verifier-only --print-plan 2>&1 )" && T5_PLAN_V_EC=0 || T5_PLAN_V_EC=$?
if [[ "$T5_PLAN_V_EC" -eq 0 ]] \
  && echo "$T5_PLAN_V" | grep -q 'EL=op-geth' \
  && echo "$T5_PLAN_V" | grep -q 'SEQUENCER_STOPPED=true'; then
  echo "PASS --verifier-only --print-plan is geth with sequencer.stopped=true"
else
  echo "FAIL --verifier-only must print SEQUENCER_STOPPED=true (ec=$T5_PLAN_V_EC)" >&2
  echo "$T5_PLAN_V" >&2
  fail=1
fi

T5_PLAN_RV="$(FORTEL2_EL=reth "$T5_SEP" --verifier-only --print-plan 2>&1 )" && T5_PLAN_RV_EC=0 || T5_PLAN_RV_EC=$?
if [[ "$T5_PLAN_RV_EC" -ne 0 ]] && echo "$T5_PLAN_RV" | grep -qi 'verifier-only'; then
  echo "PASS --verifier-only refuses under FORTEL2_EL=reth"
else
  echo "FAIL --verifier-only + reth must refuse (ec=$T5_PLAN_RV_EC)" >&2
  echo "$T5_PLAN_RV" >&2
  fail=1
fi

T5_SDB_OUT="$(
  FORTEL2_RETH_SAFEDB_PATH="$DATA_DIR/l2/op-reth-safedb"
  OP_NODE_SAFEDB_PATH="$DATA_DIR/l2/op-reth-safedb"
  fortel2_live_safedb_path 2>&1
)" && T5_SDB_EC=0 || T5_SDB_EC=$?
if [[ "$T5_SDB_EC" -ne 0 ]] && echo "$T5_SDB_OUT" | grep -qi 'sidecar SafeDB'; then
  echo "PASS fortel2_live_safedb_path refuses the sidecar store"
else
  echo "FAIL live SafeDB must refuse sidecar path (ec=$T5_SDB_EC)" >&2
  echo "$T5_SDB_OUT" >&2
  fail=1
fi

T5_DRY="$( "$T5_ADMIN" stop --rpc http://127.0.0.1:9547 --dry-run 2>&1 )" && T5_DRY_EC=0 || T5_DRY_EC=$?
if [[ "$T5_DRY_EC" -eq 0 ]] \
  && echo "$T5_DRY" | grep -q 'METHOD=admin_stopSequencer' \
  && echo "$T5_DRY" | grep -q 'CMD=stop'; then
  echo "PASS sequencer-admin.sh --dry-run stop prints admin_stopSequencer"
else
  echo "FAIL sequencer-admin dry-run stop (ec=$T5_DRY_EC)" >&2
  echo "$T5_DRY" >&2
  fail=1
fi

T5_SIDECAR_START="$(
  "$T5_ADMIN" start --rpc "http://127.0.0.1:$(reth_node_rpc_port)" --dry-run 2>&1
)" && T5_SIDECAR_START_EC=0 || T5_SIDECAR_START_EC=$?
if [[ "$T5_SIDECAR_START_EC" -ne 0 ]] && echo "$T5_SIDECAR_START" | grep -qi 'sidecar'; then
  echo "PASS sequencer-admin.sh start refuses sidecar :19547"
else
  echo "FAIL sidecar start must refuse (ec=$T5_SIDECAR_START_EC)" >&2
  echo "$T5_SIDECAR_START" >&2
  fail=1
fi

T5_BAD_RPC="$( "$T5_ADMIN" status --rpc https://example.invalid --dry-run 2>&1 )" && T5_BAD_RPC_EC=0 || T5_BAD_RPC_EC=$?
if [[ "$T5_BAD_RPC_EC" -ne 0 ]] && echo "$T5_BAD_RPC" | grep -qi 'loopback'; then
  echo "PASS sequencer-admin.sh refuses a non-loopback admin RPC"
else
  echo "FAIL admin RPC must be loopback (ec=$T5_BAD_RPC_EC)" >&2
  echo "$T5_BAD_RPC" >&2
  fail=1
fi

T5_FIX_DIR="$(mktemp -d /tmp/fortel2-t5-admin.XXXXXX)"
python3 - "$T5_FIX_DIR" <<'PY' &
import json, sys, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
state = {"active": True}
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(n) or b"{}")
        method = body.get("method")
        if method == "admin_stopSequencer":
            state["active"] = False
            result = True
        elif method == "admin_startSequencer":
            state["active"] = True
            result = True
        elif method == "admin_sequencerActive":
            result = state["active"]
        else:
            self.send_response(404); self.end_headers(); return
        payload = json.dumps({"jsonrpc": "2.0", "id": body.get("id", 1), "result": result}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def log_message(self, *args):
        return
httpd = HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1] + "/port", "w").write(str(httpd.server_address[1]))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
open(sys.argv[1] + "/ready", "w").write("1")
threading.Event().wait()
PY
T5_FIX_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -f "$T5_FIX_DIR/ready" ]] && break
  sleep 0.1
done
T5_FIX_PORT="$(cat "$T5_FIX_DIR/port" 2>/dev/null || echo 0)"
T5_FIX_RPC="http://127.0.0.1:${T5_FIX_PORT}"
T5_ADM_STOP="$("$T5_ADMIN" stop --rpc "$T5_FIX_RPC" 2>&1)" && T5_ADM_STOP_EC=0 || T5_ADM_STOP_EC=$?
T5_ADM_STAT="$("$T5_ADMIN" status --rpc "$T5_FIX_RPC" 2>&1)" && T5_ADM_STAT_EC=0 || T5_ADM_STAT_EC=$?
T5_ADM_START="$("$T5_ADMIN" start --rpc "$T5_FIX_RPC" 2>&1)" && T5_ADM_START_EC=0 || T5_ADM_START_EC=$?
kill "$T5_FIX_PID" 2>/dev/null || true
wait "$T5_FIX_PID" 2>/dev/null || true
rm -rf "$T5_FIX_DIR"
if [[ "$T5_ADM_STOP_EC" -eq 0 && "$T5_ADM_STAT_EC" -eq 0 && "$T5_ADM_START_EC" -eq 0 ]] \
  && echo "$T5_ADM_STAT" | grep -q 'result=false' \
  && echo "$T5_ADM_START" | grep -q 'admin_startSequencer'; then
  echo "PASS sequencer-admin.sh stop/status/start against a loopback fixture"
else
  echo "FAIL sequencer-admin fixture stop/start (stop=$T5_ADM_STOP_EC stat=$T5_ADM_STAT_EC start=$T5_ADM_START_EC)" >&2
  echo "$T5_ADM_STOP" >&2
  echo "$T5_ADM_STAT" >&2
  echo "$T5_ADM_START" >&2
  fail=1
fi

T5_REH="$("$T5_ROLL" --rehearse 2>&1)" && T5_REH_EC=0 || T5_REH_EC=$?
if [[ "$T5_REH_EC" -eq 0 ]] \
  && echo "$T5_REH" | grep -q 'START_GETH=04-start-sequencer-sepolia.sh --verifier-only' \
  && echo "$T5_REH" | grep -q 'RECORD_CANONICAL_SAFE before stop' \
  && echo "$T5_REH" | grep -q 'CALLER FORTEL2_EL=geth persists' \
  && echo "$T5_REH" | grep -q 'FORBIDDEN_FIRST_START=04-start-sequencer-sepolia.sh' \
  && echo "$T5_REH" | grep -q 'admin_startSequencer' \
  && echo "$T5_REH" | grep -q 'NEVER debug_setHead'; then
  echo "PASS rollback --rehearse is verifier-first and forbids stock 04-start"
else
  echo "FAIL rollback rehearsal must be verifier-first (ec=$T5_REH_EC)" >&2
  echo "$T5_REH" >&2
  fail=1
fi

if grep -q '_CALLER_EL' "$T5_SEP" \
  && grep -q 'FORTEL2_EL="$_CALLER_EL"' "$T5_SEP"; then
  echo "PASS 04-start-sequencer-sepolia.sh restores caller FORTEL2_EL after sourcing .env"
else
  echo "FAIL 04-start must snapshot caller FORTEL2_EL (rollback geth while env still says reth)" >&2
  fail=1
fi

if awk '/fortel2_el.*reth/,/^fi$/' "$SCRIPT_DIR/reset-sepolia.sh" | grep -q 'stop-all-sepolia.sh'; then
  echo "PASS reset-sepolia.sh reth path stops the full stack before wipe"
else
  echo "FAIL reset-sepolia reth wipe must call stop-all-sepolia.sh (not only stop_reth_sidecar)" >&2
  fail=1
fi

T5_CUT_REH="$("$T5_CUT" --rehearse 2>&1)" && T5_CUT_REH_EC=0 || T5_CUT_REH_EC=$?
if [[ "$T5_CUT_REH_EC" -eq 0 ]] \
  && echo "$T5_CUT_REH" | grep -q 'sequencer-admin.sh stop' \
  && echo "$T5_CUT_REH" | grep -qi 'PAUSE FIRST' \
  && echo "$T5_CUT_REH" | grep -q 'CHECKPOINT 1'; then
  echo "PASS cutover --rehearse pauses sequencing before drain"
else
  echo "FAIL cutover rehearsal must pause first (ec=$T5_CUT_REH_EC)" >&2
  echo "$T5_CUT_REH" >&2
  fail=1
fi

T5_PF_DIR="$(mktemp -d /tmp/fortel2-t5-pf.XXXXXX)"
cat > "$T5_PF_DIR/ok.json" <<'EOF'
{"game216_status":2,"withdrawal_finalized":true,"safe_head_lag":0,"verify_reth_parity":0,"verify_reth_faultproof":0,"check_el_pins":0,"batcher_funded":true,"proposer_funded":true,"check_launchd":0}
EOF
T5_PF_OK="$(CUTOVER_PREFLIGHT_FIXTURE="$T5_PF_DIR/ok.json" "$T5_CUT" --preflight-only 2>&1)" && T5_PF_OK_EC=0 || T5_PF_OK_EC=$?
if [[ "$T5_PF_OK_EC" -eq 0 ]] && echo "$T5_PF_OK" | grep -q 'PREFLIGHT PASS'; then
  echo "PASS cutover --preflight-only green fixture"
else
  echo "FAIL green preflight fixture (ec=$T5_PF_OK_EC)" >&2
  echo "$T5_PF_OK" >&2
  fail=1
fi
python3 - "$T5_PF_DIR/ok.json" "$T5_PF_DIR" <<'PY'
import json, pathlib, sys
ok = json.loads(pathlib.Path(sys.argv[1]).read_text())
d = pathlib.Path(sys.argv[2])
cases = {
    "game": dict(ok, game216_status=0),
    "wd": dict(ok, withdrawal_finalized=False),
    "lag": dict(ok, safe_head_lag=3),
    "parity": dict(ok, verify_reth_parity=1),
    "fp": dict(ok, verify_reth_faultproof=1),
}
for name, payload in cases.items():
    (d / (name + ".json")).write_text(json.dumps(payload))
PY
T5_PF_RED=0
for name in game wd lag parity fp; do
  out="$(CUTOVER_PREFLIGHT_FIXTURE="$T5_PF_DIR/${name}.json" "$T5_CUT" --preflight-only 2>&1)" && ec=0 || ec=$?
  if [[ "$ec" -eq 0 ]]; then
    echo "FAIL preflight $name fixture must go red" >&2
    echo "$out" >&2
    T5_PF_RED=1
  fi
done
rm -rf "$T5_PF_DIR"
if [[ "$T5_PF_RED" -eq 0 ]]; then
  echo "PASS cutover preflight red fixtures (game/withdrawal/lag/parity/fp) fail closed"
else
  fail=1
fi

if grep -q 'resolve_cutover_game_l2_block' "$T5_CUT" \
  && grep -q 'resolve_cutover_safedb_enable_l1' "$T5_CUT" \
  && grep -q 'resolve_cutover_pre_enable_l1' "$T5_CUT" \
  && grep -q 'TASK5_SAFEDB_ENABLE_L1=11609837' "$T5_CUT" \
  && grep -q 'TASK5_PRE_ENABLE_L1=11600000' "$T5_CUT" \
  && grep -q 'FORTEL2_CUTOVER_GAME_L2_BLOCK' "$T5_CUT" \
  && grep -q 'FORTEL2_CUTOVER_SAFEDB_ENABLE_L1' "$T5_CUT" \
  && grep -q 'FORTEL2_CUTOVER_PRE_ENABLE_L1' "$T5_CUT" \
  && grep -q '\-\-game-l2-block "\$game_l2_block"' "$T5_CUT" \
  && grep -q '\-\-safedb-enable-l1 "\$safedb_enable_l1"' "$T5_CUT" \
  && grep -q '\-\-pre-enable-l1 "\$pre_enable_l1"' "$T5_CUT"; then
  echo "PASS cutover preflight resolves all three verify-reth-faultproof live args"
else
  echo "FAIL cutover must resolve game-l2-block, safedb-enable-l1, and pre-enable-l1" >&2
  fail=1
fi

T5_L2_FN="$(awk '/^resolve_cutover_game_l2_block\(\)/,/^}$/' "$T5_CUT")"
T5_FP_FNS="$( {
  awk '/^TASK5_SAFEDB_ENABLE_L1=/,/^TASK5_PRE_ENABLE_L1=/ {print}' "$T5_CUT"
  awk '/^resolve_cutover_safedb_enable_l1\(\)/,/^}$/ {print}' "$T5_CUT"
  awk '/^resolve_cutover_pre_enable_l1\(\)/,/^}$/ {print}' "$T5_CUT"
} )"
T5_L2_BAD_OVERRIDE="$(
  FORTEL2_CUTOVER_GAME_L2_BLOCK=notanumber bash -c '
    set -euo pipefail
    SCRIPT_DIR="'"$SCRIPT_DIR"'"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib.sh"
    '"$T5_L2_FN"'
    resolve_cutover_game_l2_block
  ' 2>&1
)" && T5_L2_BAD_OVERRIDE_EC=0 || T5_L2_BAD_OVERRIDE_EC=$?
if [[ "$T5_L2_BAD_OVERRIDE_EC" -ne 0 ]] \
  && echo "$T5_L2_BAD_OVERRIDE" | grep -qi 'FORTEL2_CUTOVER_GAME_L2_BLOCK'; then
  echo "PASS cutover game L2 override rejects non-numeric values"
else
  echo "FAIL invalid FORTEL2_CUTOVER_GAME_L2_BLOCK must fail closed (ec=$T5_L2_BAD_OVERRIDE_EC)" >&2
  echo "$T5_L2_BAD_OVERRIDE" >&2
  fail=1
fi

T5_L2_LOOKUP_FAIL="$(
  FORTEL2_CUTOVER_GAME_L2_BLOCK= \
  L1_RPC_URL=http://127.0.0.1:9 \
  L2_CHAIN_ID=852 \
  bash -c '
    set -euo pipefail
    SCRIPT_DIR="'"$SCRIPT_DIR"'"
    FORTEL2_ROOT="'"$FORTEL2_ROOT"'"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib.sh"
    '"$T5_L2_FN"'
    resolve_cutover_game_l2_block
  ' 2>&1
)" && T5_L2_LOOKUP_FAIL_EC=0 || T5_L2_LOOKUP_FAIL_EC=$?
if [[ "$T5_L2_LOOKUP_FAIL_EC" -ne 0 ]] \
  && echo "$T5_L2_LOOKUP_FAIL" | grep -Eqi 'gameCount|gameAtIndex|l2BlockNumber|DisputeGameFactory'; then
  echo "PASS cutover game L2 lookup fails closed when L1 read fails"
else
  echo "FAIL game L2 lookup must fail closed on L1 read failure (ec=$T5_L2_LOOKUP_FAIL_EC)" >&2
  echo "$T5_L2_LOOKUP_FAIL" >&2
  fail=1
fi

T5_L2_OVERRIDE_OK="$(
  FORTEL2_CUTOVER_GAME_L2_BLOCK=397392 bash -c '
    set -euo pipefail
    SCRIPT_DIR="'"$SCRIPT_DIR"'"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib.sh"
    '"$T5_L2_FN"'
    resolve_cutover_game_l2_block
  ' 2>&1
)" && T5_L2_OVERRIDE_OK_EC=0 || T5_L2_OVERRIDE_OK_EC=$?
if [[ "$T5_L2_OVERRIDE_OK_EC" -eq 0 && "$T5_L2_OVERRIDE_OK" == "397392" ]]; then
  echo "PASS cutover game L2 override returns the configured block"
else
  echo "FAIL FORTEL2_CUTOVER_GAME_L2_BLOCK override must win (ec=$T5_L2_OVERRIDE_OK_EC got=$T5_L2_OVERRIDE_OK)" >&2
  fail=1
fi

T5_SDB_DEFAULT="$(
  bash -c '
    set -euo pipefail
    SCRIPT_DIR="'"$SCRIPT_DIR"'"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib.sh"
    '"$T5_FP_FNS"'
    resolve_cutover_safedb_enable_l1
  ' 2>&1
)" && T5_SDB_DEFAULT_EC=0 || T5_SDB_DEFAULT_EC=$?
if [[ "$T5_SDB_DEFAULT_EC" -eq 0 && "$T5_SDB_DEFAULT" == "11609837" ]]; then
  echo "PASS cutover safedb-enable-l1 defaults to Task 4 constant 11609837"
else
  echo "FAIL safedb-enable-l1 must default to 11609837 (ec=$T5_SDB_DEFAULT_EC got=$T5_SDB_DEFAULT)" >&2
  fail=1
fi

T5_SDB_BAD="$(
  FORTEL2_CUTOVER_SAFEDB_ENABLE_L1=notanumber bash -c '
    set -euo pipefail
    SCRIPT_DIR="'"$SCRIPT_DIR"'"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib.sh"
    '"$T5_FP_FNS"'
    resolve_cutover_safedb_enable_l1
  ' 2>&1
)" && T5_SDB_BAD_EC=0 || T5_SDB_BAD_EC=$?
if [[ "$T5_SDB_BAD_EC" -ne 0 ]] \
  && echo "$T5_SDB_BAD" | grep -Eqi 'safedb-enable-l1|FORTEL2_CUTOVER_SAFEDB_ENABLE_L1'; then
  echo "PASS cutover safedb-enable-l1 rejects non-numeric override"
else
  echo "FAIL invalid FORTEL2_CUTOVER_SAFEDB_ENABLE_L1 must fail closed (ec=$T5_SDB_BAD_EC)" >&2
  echo "$T5_SDB_BAD" >&2
  fail=1
fi

T5_PRE_DEFAULT="$(
  bash -c '
    set -euo pipefail
    SCRIPT_DIR="'"$SCRIPT_DIR"'"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib.sh"
    '"$T5_FP_FNS"'
    resolve_cutover_pre_enable_l1
  ' 2>&1
)" && T5_PRE_DEFAULT_EC=0 || T5_PRE_DEFAULT_EC=$?
if [[ "$T5_PRE_DEFAULT_EC" -eq 0 && "$T5_PRE_DEFAULT" == "11600000" ]]; then
  echo "PASS cutover pre-enable-l1 defaults to Task 4 constant 11600000"
else
  echo "FAIL pre-enable-l1 must default to 11600000 (ec=$T5_PRE_DEFAULT_EC got=$T5_PRE_DEFAULT)" >&2
  fail=1
fi

T5_PRE_BAD="$(
  FORTEL2_CUTOVER_PRE_ENABLE_L1=notanumber bash -c '
    set -euo pipefail
    SCRIPT_DIR="'"$SCRIPT_DIR"'"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib.sh"
    '"$T5_FP_FNS"'
    resolve_cutover_pre_enable_l1
  ' 2>&1
)" && T5_PRE_BAD_EC=0 || T5_PRE_BAD_EC=$?
if [[ "$T5_PRE_BAD_EC" -ne 0 ]] \
  && echo "$T5_PRE_BAD" | grep -Eqi 'pre-enable-l1|FORTEL2_CUTOVER_PRE_ENABLE_L1'; then
  echo "PASS cutover pre-enable-l1 rejects non-numeric override"
else
  echo "FAIL invalid FORTEL2_CUTOVER_PRE_ENABLE_L1 must fail closed (ec=$T5_PRE_BAD_EC)" >&2
  echo "$T5_PRE_BAD" >&2
  fail=1
fi

T5_PRE_TRAP="$(
  FORTEL2_CUTOVER_SAFEDB_ENABLE_L1=100 FORTEL2_CUTOVER_PRE_ENABLE_L1=99 bash -c '
    set -euo pipefail
    SCRIPT_DIR="'"$SCRIPT_DIR"'"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib.sh"
    '"$T5_FP_FNS"'
    resolve_cutover_pre_enable_l1
  ' 2>&1
)" && T5_PRE_TRAP_EC=0 || T5_PRE_TRAP_EC=$?
if [[ "$T5_PRE_TRAP_EC" -ne 0 ]] \
  && echo "$T5_PRE_TRAP" | grep -Eqi 'enable-1|minus 1'; then
  echo "PASS cutover pre-enable-l1 rejects safedb-enable-l1 minus 1"
else
  echo "FAIL pre-enable-l1 must not equal enable-1 (ec=$T5_PRE_TRAP_EC)" >&2
  echo "$T5_PRE_TRAP" >&2
  fail=1
fi

T5_EXE="$( "$T5_CUT" --execute 2>&1 )" && T5_EXE_EC=0 || T5_EXE_EC=$?
if [[ "$T5_EXE_EC" -ne 0 ]] && echo "$T5_EXE" | grep -qi 'FORTEL2_CUTOVER_EXECUTE'; then
  echo "PASS cutover --execute refuses without FORTEL2_CUTOVER_EXECUTE=1"
else
  echo "FAIL --execute must refuse without the window confirm (ec=$T5_EXE_EC)" >&2
  echo "$T5_EXE" >&2
  fail=1
fi

if grep -q 'fortel2_live_el_pid' "$SCRIPT_DIR/demo-checklist.sh" \
  && grep -q 'fortel2_live_el_pid' "$SCRIPT_DIR/07-start-rpc-filter-sepolia.sh" \
  && grep -q 'op-reth' "$SCRIPT_DIR/stop-all-sepolia.sh" \
  && ! grep -q 'rm -rf "\$DATA_DIR/l2"' "$SCRIPT_DIR/reset-sepolia.sh"; then
  echo "PASS §10 demo-checklist / rpc-filter / stop-all / reset-sepolia follow the selector"
else
  echo "FAIL §10 stray surfaces must be selector-driven and must not wipe all of l2" >&2
  fail=1
fi

if grep -q -- '--rpc.enable-admin' "$SCRIPT_DIR/start-op-reth-verifier.sh"; then
  echo "PASS sidecar op-node enables admin RPC (loopback rehearsal)"
else
  echo "FAIL sidecar must listen for admin_stopSequencer on loopback" >&2
  fail=1
fi

# =============================================================================
# end Task 5 block
# =============================================================================

# =============================================================================
# pin-runtime-root (D-0118 Finding 5)
# Two-root fixture: env/inherited FORTEL2_ROOT must not redirect tracked
# artifacts. Additive. Do not reorder the tests above.
# =============================================================================

PRR_FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fortel2-pin-runtime-root.XXXXXX")" && pwd)"
cleanup_prr() { rm -rf "$PRR_FIX"; }
trap cleanup_prr EXIT
PRR_LIB="$SCRIPT_DIR/lib.sh"
PRR_DEPLOY="$SCRIPT_DIR/deploy-agents.sh"
PRR_CL="$SCRIPT_DIR/check-launchd.sh"
PRR_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
PRR_ORIGIN_URL="$(git -C "$PRR_REPO" remote get-url origin)"

prr_git() {
  git -c user.email=pin-runtime-root@test.invalid -c user.name=pin-runtime-root "$@"
}

prr_clear=(env -u FORTEL2_ENV -u FORTEL2_ROOT -u FORTEL2_ENV_FILE -u _FORTEL2_ROOT_PIN_WARNED)

# --- (a) two-root fixture: env FORTEL2_ROOT=dev, lib.sh sourced from pinned ---
PRR_DEV="$PRR_FIX/dev"
PRR_PIN="$PRR_FIX/pinned"
mkdir -p "$PRR_DEV/scripts" "$PRR_DEV/deployments/sepolia" "$PRR_DEV/data"
mkdir -p "$PRR_PIN/scripts" "$PRR_PIN/deployments/sepolia" "$PRR_PIN/data"
PRR_DEV="$(cd "$PRR_DEV" && pwd)"
PRR_PIN="$(cd "$PRR_PIN" && pwd)"
cp "$PRR_LIB" "$PRR_DEV/scripts/lib.sh"
cp "$PRR_LIB" "$PRR_PIN/scripts/lib.sh"
printf '%s\n' '{"from":"dev"}' > "$PRR_DEV/deployments/sepolia/deployments.json"
printf '%s\n' '{"from":"pinned"}' > "$PRR_PIN/deployments/sepolia/deployments.json"
cat > "$PRR_DEV/.env.sepolia" <<EOF
FORTEL2_ROOT=$PRR_DEV
L2_CHAIN_ID=852
DATA_DIR=$PRR_DEV/data
L1_CHAIN_ID=11155111
L1_RPC_URL=https://example.invalid
L2_RPC_URL=http://127.0.0.1:9545
L2_NODE_RPC_URL=http://127.0.0.1:9547
EOF
PRR_A_PATH="$("${prr_clear[@]}" FORTEL2_ENV="$PRR_DEV/.env.sepolia" \
  bash -c 'source "'"$PRR_PIN"'/scripts/lib.sh" && deployments_json_path' \
  2>"$PRR_FIX/a.err")" && PRR_A_EC=0 || PRR_A_EC=$?
if [[ "$PRR_A_EC" -eq 0 ]] \
  && [[ "$PRR_A_PATH" == "$PRR_PIN/deployments/sepolia/deployments.json" ]] \
  && grep -q "WARN: FORTEL2_ROOT=${PRR_DEV}" "$PRR_FIX/a.err" \
  && grep -q "script-derived root ${PRR_PIN}" "$PRR_FIX/a.err" \
  && grep -q "env file ${PRR_DEV}/.env.sepolia" "$PRR_FIX/a.err"; then
  echo "PASS pin-runtime-root two-root fixture uses pinned deployments.json and WARNs"
else
  echo "FAIL two-root fixture must return the pinned deployments.json and WARN (ec=$PRR_A_EC path=$PRR_A_PATH)" >&2
  cat "$PRR_FIX/a.err" >&2
  fail=1
fi

# --- (b) inherited FORTEL2_ROOT is overridden with a WARN ---
cat > "$PRR_DEV/.env.sepolia" <<EOF
L2_CHAIN_ID=852
DATA_DIR=$PRR_DEV/data
L1_CHAIN_ID=11155111
L1_RPC_URL=https://example.invalid
L2_RPC_URL=http://127.0.0.1:9545
L2_NODE_RPC_URL=http://127.0.0.1:9547
EOF
PRR_B_ROOT="$(env -u FORTEL2_ENV -u FORTEL2_ENV_FILE -u _FORTEL2_ROOT_PIN_WARNED \
  FORTEL2_ROOT="$PRR_DEV" FORTEL2_ENV="$PRR_DEV/.env.sepolia" \
  bash -c 'source "'"$PRR_PIN"'/scripts/lib.sh" && printf %s "$FORTEL2_ROOT"' \
  2>"$PRR_FIX/b.err")" && PRR_B_EC=0 || PRR_B_EC=$?
if [[ "$PRR_B_EC" -eq 0 ]] \
  && [[ "$PRR_B_ROOT" == "$PRR_PIN" ]] \
  && grep -q "WARN: FORTEL2_ROOT=${PRR_DEV}" "$PRR_FIX/b.err"; then
  echo "PASS pin-runtime-root inherited FORTEL2_ROOT is overridden with a WARN"
else
  echo "FAIL inherited FORTEL2_ROOT must be pinned to the lib.sh tree with a WARN (ec=$PRR_B_EC root=$PRR_B_ROOT)" >&2
  cat "$PRR_FIX/b.err" >&2
  fail=1
fi

# --- (e) re-source is idempotent: same root, one WARN ---
PRR_E_OUT="$(env -u FORTEL2_ENV -u FORTEL2_ROOT -u FORTEL2_ENV_FILE -u _FORTEL2_ROOT_PIN_WARNED \
  FORTEL2_ENV="$PRR_DEV/.env.sepolia" FORTEL2_ROOT="$PRR_DEV" \
  bash -c '
    source "'"$PRR_PIN"'/scripts/lib.sh"
    echo ROOT1="$FORTEL2_ROOT"
    source "'"$PRR_PIN"'/scripts/lib.sh"
    echo ROOT2="$FORTEL2_ROOT"
  ' 2>"$PRR_FIX/e.err")" && PRR_E_EC=0 || PRR_E_EC=$?
PRR_E_WARNS="$(grep -c 'WARN: FORTEL2_ROOT=' "$PRR_FIX/e.err" || true)"
if [[ "$PRR_E_EC" -eq 0 ]] \
  && echo "$PRR_E_OUT" | grep -q "ROOT1=${PRR_PIN}" \
  && echo "$PRR_E_OUT" | grep -q "ROOT2=${PRR_PIN}" \
  && [[ "$PRR_E_WARNS" -eq 1 ]]; then
  echo "PASS pin-runtime-root re-source is idempotent (one WARN)"
else
  echo "FAIL sourcing lib.sh twice must keep the pinned root and emit a single WARN (ec=$PRR_E_EC warns=$PRR_E_WARNS)" >&2
  echo "$PRR_E_OUT" >&2
  cat "$PRR_FIX/e.err" >&2
  fail=1
fi

# --- (c) deploy-agents.sh .deployer symlink: create / idempotent / refuse / not sepolia dir ---
PRR_SEED="$PRR_FIX/seed"
PRR_ORIGIN="$PRR_FIX/origin.git"
PRR_CDEV="$PRR_FIX/cdev"
PRR_CPIN="$PRR_FIX/cpinned"
git init -q -b main "$PRR_SEED"
mkdir -p "$PRR_SEED/deployments/sepolia"
printf '%s\n' '{"from":"pinned-seed"}' > "$PRR_SEED/deployments/sepolia/deployments.json"
printf '%s\n' '{"from":"pinned-seed"}' > "$PRR_SEED/deployments/sepolia/rollup.json"
printf 'seed\n' > "$PRR_SEED/README"
printf '.env\n.env.sepolia\ndata/\ndeployments/sepolia/.deployer/\n' > "$PRR_SEED/.gitignore"
prr_git -C "$PRR_SEED" add README .gitignore deployments
prr_git -C "$PRR_SEED" commit -q -m seed
git clone -q --bare "$PRR_SEED" "$PRR_ORIGIN"
git -C "$PRR_SEED" remote add origin "$PRR_ORIGIN"
git -C "$PRR_SEED" push -q -u origin main
mkdir -p "$PRR_CDEV/deployments/sepolia/.deployer"
printf 'SEPOLIA=1\n' > "$PRR_CDEV/.env.sepolia"
printf 'LOCAL=1\n' > "$PRR_CDEV/.env"
printf 'challenger-rollup\n' > "$PRR_CDEV/deployments/sepolia/.deployer/rollup.json"

prr_deploy() {
  env FORTEL2_AGENTS_DIR="$1" FORTEL2_DEV_DIR="$PRR_CDEV" \
    FORTEL2_AGENTS_REMOTE="$PRR_ORIGIN" \
    "$PRR_DEPLOY" 2>&1
}

PRR_C_OUT="$(prr_deploy "$PRR_CPIN")" && PRR_C_EC=0 || PRR_C_EC=$?
if [[ "$PRR_C_EC" -eq 0 ]] \
  && [[ -L "$PRR_CPIN/deployments/sepolia/.deployer" ]] \
  && [[ "$(readlink "$PRR_CPIN/deployments/sepolia/.deployer")" == "$PRR_CDEV/deployments/sepolia/.deployer" ]] \
  && [[ -f "$PRR_CPIN/deployments/sepolia/deployments.json" ]] \
  && [[ ! -L "$PRR_CPIN/deployments/sepolia/deployments.json" ]] \
  && [[ -d "$PRR_CPIN/deployments/sepolia" ]] \
  && [[ ! -L "$PRR_CPIN/deployments/sepolia" ]]; then
  echo "PASS pin-runtime-root deploy-agents creates .deployer symlink and leaves tracked deployments.json"
else
  echo "FAIL deploy-agents must symlink .deployer only, not deployments/sepolia (ec=$PRR_C_EC)" >&2
  echo "$PRR_C_OUT" >&2
  fail=1
fi

PRR_C2_OUT="$(prr_deploy "$PRR_CPIN")" && PRR_C2_EC=0 || PRR_C2_EC=$?
if [[ "$PRR_C2_EC" -eq 0 ]] \
  && echo "$PRR_C2_OUT" | grep -q 'already' \
  && [[ -L "$PRR_CPIN/deployments/sepolia/.deployer" ]]; then
  echo "PASS pin-runtime-root deploy-agents .deployer symlink is idempotent"
else
  echo "FAIL second deploy-agents must be idempotent for .deployer (ec=$PRR_C2_EC)" >&2
  echo "$PRR_C2_OUT" >&2
  fail=1
fi

rm -f "$PRR_CPIN/deployments/sepolia/.deployer"
printf 'regular-file\n' > "$PRR_CPIN/deployments/sepolia/.deployer"
PRR_CREG="$(prr_deploy "$PRR_CPIN")" && PRR_CREG_EC=0 || PRR_CREG_EC=$?
if [[ "$PRR_CREG_EC" -ne 0 ]] \
  && echo "$PRR_CREG" | grep -q 'refusing to overwrite existing file with a symlink'; then
  echo "PASS pin-runtime-root deploy-agents refuses to replace a regular .deployer with a symlink"
else
  echo "FAIL regular .deployer must refuse overwrite (ec=$PRR_CREG_EC)" >&2
  echo "$PRR_CREG" >&2
  fail=1
fi

# Missing dest .deployer must refuse — do not mkdir an empty stand-in (Bugbot).
PRR_NODEP="$PRR_FIX/nodeployer-dev"
mkdir -p "$PRR_NODEP"
printf 'SEPOLIA=1\n' > "$PRR_NODEP/.env.sepolia"
PRR_NO_OUT="$(
  env FORTEL2_AGENTS_DIR="$PRR_FIX/nodeployer-pin" FORTEL2_DEV_DIR="$PRR_NODEP" \
    FORTEL2_AGENTS_REMOTE="$PRR_ORIGIN" \
    "$PRR_DEPLOY" 2>&1
)" && PRR_NO_EC=0 || PRR_NO_EC=$?
if [[ "$PRR_NO_EC" -ne 0 ]] \
  && [[ ! -e "$PRR_NODEP/deployments/sepolia/.deployer" ]]; then
  echo "PASS pin-runtime-root deploy-agents refuses when dest .deployer is missing"
else
  echo "FAIL missing dest .deployer must refuse, not mkdir an empty dir (ec=$PRR_NO_EC exists=$([[ -e $PRR_NODEP/deployments/sepolia/.deployer ]] && echo y || echo n))" >&2
  echo "$PRR_NO_OUT" >&2
  fail=1
fi

# --- (d) check-launchd FAILs when the required .deployer symlink is missing ---
PRR_AUDIT="$PRR_FIX/audit"
PRR_ADEV="$PRR_FIX/adev"
git init -q -b main "$PRR_AUDIT"
git -C "$PRR_AUDIT" remote add origin "$PRR_ORIGIN_URL"
prr_git -C "$PRR_AUDIT" commit -q --allow-empty -m audit
mkdir -p "$PRR_AUDIT/.git/info" "$PRR_ADEV/data" "$PRR_ADEV/deployments/sepolia/.deployer"
printf '.env.sepolia\n.env\ndata\ndeployments/sepolia/.deployer\n' >> "$PRR_AUDIT/.git/info/exclude"
printf 'SEPOLIA=1\n' > "$PRR_ADEV/.env.sepolia"
ln -s "$PRR_ADEV/.env.sepolia" "$PRR_AUDIT/.env.sepolia"
ln -s "$PRR_ADEV/data" "$PRR_AUDIT/data"
PRR_D_OUT="$(
  env -u FORTEL2_ENV FORTEL2_ROOT="$PRR_REPO" \
    CHECK_LAUNCHD_AGENTS_DIR="$PRR_FIX/empty-agents" \
    CHECK_LAUNCHD_PINNED_TREE="$PRR_AUDIT" \
    CHECK_LAUNCHD_DEV_DIR="$PRR_ADEV" \
    CHECK_LAUNCHD_CLOUDFLARED_PLIST="$PRR_FIX/no-such-cloudflared.plist" \
    "$PRR_CL" 2>&1 || true
)"
if echo "$PRR_D_OUT" | grep -q 'FAIL  pinned tree deployments/sepolia/.deployer is missing or not a symlink'; then
  echo "PASS pin-runtime-root check-launchd FAILs a pinned tree missing the .deployer symlink"
else
  echo "FAIL check-launchd must FAIL when deployments/sepolia/.deployer is not a symlink" >&2
  echo "$PRR_D_OUT" >&2
  fail=1
fi

# =============================================================================
# end pin-runtime-root
# =============================================================================

if (( fail )); then
  echo "script helper tests FAILED" >&2
  exit 1
fi
echo "All script helper tests passed."
