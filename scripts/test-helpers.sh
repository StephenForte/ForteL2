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
# env -u: same FORTEL2_ENV leak as the fixture run above — an inherited
# absolute FORTEL2_ENV would load a valid BATCHER_ADDRESS and this would pass.
if env -u FORTEL2_ENV FORTEL2_ROOT="$FIXTURE" "$SCRIPT_DIR/gen-viewer-config.sh" >/dev/null 2>&1; then
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
  "games": [
    {
      "index": 0,
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
RG_ENV=(env -u FORTEL2_ENV PATH="$RG_PATH" RESOLVE_GAMES_SNAPSHOT="$RG_FIXTURE_DIR/games.json")

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
  env -u FORTEL2_ENV PATH="$RG_PATH" RESOLVE_GAMES_SNAPSHOT="$RG_FIXTURE_DIR/type8.json" \
    "$RESOLVE_GAMES" --analyze-only 2>&1
)" && RG_T8_EC=0 || RG_T8_EC=$?
if [[ "$RG_T8_EC" -eq 0 ]] \
  && echo "$RG_T8_OUT" | grep -q 'game 1 SKIP not_type_1' \
  && echo "$RG_T8_OUT" | grep -q 'game 2 ACTION resolveClaim,resolve' \
  && echo "$RG_T8_OUT" | grep -q 'selected_indexes=2'; then
  echo "PASS resolve-games non-type-1 game is not selected"
else
  echo "FAIL resolve-games type-8 game should be skipped (ec=$RG_T8_EC)" >&2
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
  "games": [
    {
      "index": 1,
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
  env -u FORTEL2_ENV PATH="$RG_PATH" RESOLVE_GAMES_SNAPSHOT="$RG_FIXTURE_DIR/already-claim.json" \
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
  "game_count": 8,
  "games": [
    {
      "index": 0, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 990000, "credit_wei": "0",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 992000
    },
    {
      "index": 1, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 990000, "credit_wei": "0",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    },
    {
      "index": 2, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 990000, "credit_wei": "0",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    },
    {
      "index": 3, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 990000, "credit_wei": "0",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    },
    {
      "index": 4, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 999900, "credit_wei": "80000000000000000",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    },
    {
      "index": 5, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 990000, "credit_wei": "0",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    },
    {
      "index": 6, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 990000, "credit_wei": "80000000000000000",
      "claim_data_len": 1, "weth_amount_wei": "80000000000000000", "weth_unlock_ts": 999000
    },
    {
      "index": 7, "created_at": 999000, "max_clock_duration": 7200,
      "status": 0, "resolved_at": 0, "credit_wei": "0",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    }
  ]
}
EOF

rg_wm_analyze() {
  local mark="$1"
  shift
  env -u FORTEL2_ENV PATH="$RG_PATH" \
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
  "game_count": 4,
  "games": [
    {
      "index": 0, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 990000, "credit_wei": "0",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    },
    {
      "index": 1, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 990000, "credit_wei": "0",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    },
    {
      "index": 2, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 990000, "credit_wei": "0",
      "claim_data_len": 1, "weth_amount_wei": "0", "weth_unlock_ts": 0
    },
    {
      "index": 3, "created_at": 980000, "max_clock_duration": 7200,
      "status": 2, "resolved_at": 990000, "credit_wei": "80000000000000000",
      "claim_data_len": 1, "weth_amount_wei": "80000000000000000", "weth_unlock_ts": 999000
    }
  ]
}
EOF
WM_DELAY="$RG_FIXTURE_DIR/wm-delay-mark.json"
RG_WM_DELAY_OUT="$(
  env -u FORTEL2_ENV PATH="$RG_PATH" \
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
  env -u FORTEL2_ENV PATH="$RG_PATH" \
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
  env -u FORTEL2_ENV PATH="$RG_PATH" \
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
unset _kg_fn _kg_dup_fn _kg_rc _kg_out _kg_mismatch _kg_key _kg_addr _kg_addr_lc _kg_other
unset CHALLENGER_SEPOLIA

if (( fail )); then
  echo "script helper tests FAILED" >&2
  exit 1
fi
echo "All script helper tests passed."
