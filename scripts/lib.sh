#!/usr/bin/env bash
# Shared helpers for ForteL2 scripts (Phase 1 local + Phase 2 Sepolia).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FORTEL2_ROOT="${FORTEL2_ROOT:-$ROOT}"

# Resolve env file: FORTEL2_ENV (basename or absolute) → .env → .env.example
_fortel2_resolve_env_file() {
  local candidate=""
  if [[ -n "${FORTEL2_ENV:-}" ]]; then
    if [[ "$FORTEL2_ENV" == /* ]]; then
      candidate="$FORTEL2_ENV"
    else
      candidate="$FORTEL2_ROOT/$FORTEL2_ENV"
    fi
    if [[ ! -f "$candidate" ]]; then
      echo "ERROR: FORTEL2_ENV=$FORTEL2_ENV not found at $candidate" >&2
      echo "Copy .env.sepolia.example → .env.sepolia (keys offline) or unset FORTEL2_ENV for Phase 1." >&2
      exit 1
    fi
  elif [[ -f "$FORTEL2_ROOT/.env" ]]; then
    candidate="$FORTEL2_ROOT/.env"
  elif [[ -f "$FORTEL2_ROOT/.env.example" ]]; then
    echo "WARN: no .env found; loading .env.example (copy to .env for local overrides)" >&2
    candidate="$FORTEL2_ROOT/.env.example"
  else
    echo "ERROR: no env file under $FORTEL2_ROOT (.env / .env.example / FORTEL2_ENV)" >&2
    exit 1
  fi
  printf '%s' "$candidate"
}

FORTEL2_ENV_FILE="$(_fortel2_resolve_env_file)"
export FORTEL2_ENV_FILE
# shellcheck disable=SC1090
set -a
source "$FORTEL2_ENV_FILE"
set +a

BIN_DIR="${BIN_DIR:-$FORTEL2_ROOT/bin}"
DATA_DIR="${DATA_DIR:-$FORTEL2_ROOT/data}"
DEPLOY_DIR="${DEPLOY_DIR:-$FORTEL2_ROOT/deployments/.deployer}"
LOG_DIR="${LOG_DIR:-$DATA_DIR/logs}"
PID_DIR="${PID_DIR:-$DATA_DIR/pids}"

mkdir -p "$DATA_DIR" "$LOG_DIR" "$PID_DIR" "$DEPLOY_DIR"

export PATH="/opt/homebrew/bin:$HOME/.foundry/bin:$BIN_DIR:$PATH"

require_bin() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "ERROR: required binary not found on PATH: $name" >&2
    exit 1
  fi
}

# Redact userinfo / query / fragment and long path tokens (QuickNode-style API keys).
# Safe for terminal logs; still pass the raw URL to cast/--rpc-url.
redact_rpc_url() {
  python3 - <<'PY' "${1:-}"
import sys, urllib.parse
u = sys.argv[1]
if not u:
    print("<empty>")
    raise SystemExit
p = urllib.parse.urlparse(u)
# Drop userinfo + query + fragment (common API-key locations)
netloc = p.hostname or ""
if p.port:
    netloc = f"{netloc}:{p.port}"
path = p.path if p.path and p.path != "/" else ""
# If path looks like /abc123token, show only /…
if path and len(path) > 8:
    path = "/…"
print(f"{p.scheme}://{netloc}{path}")
PY
}

wait_for_rpc() {
  local url="$1"
  local label="${2:-RPC}"
  local tries="${3:-60}"
  local i=0
  local display
  display="$(redact_rpc_url "$url")"
  echo "Waiting for $label at $display ..."
  while (( i < tries )); do
    if cast block-number --rpc-url "$url" >/dev/null 2>&1; then
      echo "$label is up (block $(cast block-number --rpc-url "$url"))"
      return 0
    fi
    sleep 1
    ((i++)) || true
  done
  echo "ERROR: timed out waiting for $label at $display" >&2
  return 1
}

start_bg() {
  local name="$1"
  shift
  local pidfile="$PID_DIR/$name.pid"
  local logfile="$LOG_DIR/$name.log"
  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "$name already running (pid $(cat "$pidfile"))"
    return 0
  fi
  echo "Starting $name → $logfile"
  # Double-fork daemonize so Cursor/agent shell teardown cannot reap the stack.
  # Writes the grandchild PID to pidfile.
  python3 - "$pidfile" "$logfile" "$@" <<'PY'
import os, sys, time
pidfile, logfile, *cmd = sys.argv[1:]
if os.fork() > 0:
    # parent of first fork — exit immediately
    sys.exit(0)
os.setsid()
if os.fork() > 0:
    sys.exit(0)
# grandchild
os.chdir("/")
os.umask(0)
devnull = open(os.devnull, "rb")
log = open(logfile, "ab", buffering=0)
os.dup2(devnull.fileno(), 0)
os.dup2(log.fileno(), 1)
os.dup2(log.fileno(), 2)
with open(pidfile, "w") as f:
    f.write(str(os.getpid()))
os.execvp(cmd[0], cmd)
PY
  # Wait for pidfile from grandchild
  local i=0
  while [[ ! -f "$pidfile" && $i -lt 50 ]]; do
    sleep 0.1
    ((i++)) || true
  done
  if [[ ! -f "$pidfile" ]]; then
    echo "ERROR: $name failed to write pidfile" >&2
    return 1
  fi
  local pid
  pid="$(cat "$pidfile")"
  sleep 0.3
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "ERROR: $name exited immediately — see $logfile" >&2
    return 1
  fi
  echo "$name pid $pid"
}

stop_bg() {
  local name="$1"
  local pidfile="$PID_DIR/$name.pid"
  if [[ ! -f "$pidfile" ]]; then
    echo "$name not running (no pidfile)"
    return 0
  fi
  local pid
  pid="$(cat "$pidfile")"
  if kill -0 "$pid" 2>/dev/null; then
    echo "Stopping $name (pid $pid)"
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$pidfile"
}

is_running() {
  local name="$1"
  local pidfile="$PID_DIR/$name.pid"
  [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null
}

# Unsigned decimal integer comparison (wei-safe; bash (( )) overflows).
# Returns 0 if $1 > $2.
uint_gt() {
  python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) > int(sys.argv[2]) else 1)' "${1:-}" "${2:-}"
}

# Accepts 0x-prefixed 40-hex-char addresses (case-insensitive).
is_eth_address() {
  [[ "${1:-}" =~ ^0x[0-9a-fA-F]{40}$ ]]
}

require_eth_address() {
  local label="$1"
  local addr="$2"
  if ! is_eth_address "$addr"; then
    echo "ERROR: invalid $label address: ${addr:-<empty>}" >&2
    exit 1
  fi
}

# Refuse binding/serving to non-loopback hosts for local learning stack.
assert_loopback_url() {
  local url="$1"
  local label="${2:-URL}"
  case "$url" in
    http://127.0.0.1:*|http://localhost:*|https://127.0.0.1:*|https://localhost:*)
      return 0
      ;;
    *)
      echo "ERROR: $label must be loopback (127.0.0.1/localhost), got: $url" >&2
      exit 1
      ;;
  esac
}

# Fjord sequencer drift: L1 must not outpace L2 (see README).
assert_block_times() {
  local l1="${L1_BLOCK_TIME:-}"
  local l2="${L2_BLOCK_TIME:-}"
  if [[ -z "$l1" || -z "$l2" ]]; then
    echo "ERROR: L1_BLOCK_TIME and L2_BLOCK_TIME must be set" >&2
    exit 1
  fi
  if ! [[ "$l1" =~ ^[0-9]+$ && "$l2" =~ ^[0-9]+$ ]]; then
    echo "ERROR: L1_BLOCK_TIME/L2_BLOCK_TIME must be integers (got L1=$l1 L2=$l2)" >&2
    exit 1
  fi
  if (( l1 < l2 )); then
    echo "ERROR: L1_BLOCK_TIME ($l1) must be >= L2_BLOCK_TIME ($l2) or sequencer hits NoTxPool" >&2
    exit 1
  fi
}

# Canonical Anvil/Foundry test-mnemonic keys (accounts 0–9).
# Safe on local L2 chain 901 only — never fund these on public nets.
is_foundry_default_private_key() {
  local key
  key="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$key" in
    0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80|\
    0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d|\
    0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a|\
    0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6|\
    0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a|\
    0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba|\
    0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e|\
    0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356|\
    0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97|\
    0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6)
      return 0
      ;;
  esac
  return 1
}

# Phase 2 tripwire: Foundry defaults are allowed only on local learning L2 (901).
refuse_foundry_defaults_unless_local_l2() {
  local key="${1:-}"
  local label="${2:-private key}"
  local chain="${L2_CHAIN_ID:-}"
  if [[ -z "$key" ]]; then
    return 0
  fi
  if ! is_foundry_default_private_key "$key"; then
    return 0
  fi
  if [[ "$chain" == "901" ]]; then
    return 0
  fi
  echo "ERROR: refusing $label — Foundry/Anvil default key on L2_CHAIN_ID=${chain:-<unset>} (allowed only on 901)" >&2
  echo "Generate fresh keys before any non-local / Phase 2 work (see PRD US-012)." >&2
  exit 1
}

# Warn when running against committed example defaults (Phase 1 or missing local file).
warn_if_missing_env_file() {
  local base
  base="$(basename "${FORTEL2_ENV_FILE:-}")"
  case "$base" in
    .env.example|.env.sepolia.example)
      echo "WARN: using $base defaults — copy to a local env file before any non-local work" >&2
      ;;
  esac
  if [[ -n "${FORTEL2_ENV:-}" && "$base" == ".env.example" ]]; then
    echo "WARN: FORTEL2_ENV set but resolved to .env.example — unexpected" >&2
  fi
}

# L2 + op-node must stay loopback (Phase 1 and Phase 2 until US-012 non-loopback review flips).
assert_l2_loopback_urls() {
  assert_loopback_url "${L2_RPC_URL:-}" "L2_RPC_URL"
  if [[ -n "${L2_NODE_RPC_URL:-}" ]]; then
    assert_loopback_url "$L2_NODE_RPC_URL" "L2_NODE_RPC_URL"
  fi
}

# Accept http(s) L1 URLs for Sepolia (public RPC / QuickNode). Reject empty / nonsense.
assert_remote_l1_rpc_url() {
  local url label
  if (( $# >= 1 )); then
    url="$1"
  else
    url="${L1_RPC_URL:-}"
  fi
  label="${2:-L1_RPC_URL}"
  case "$url" in
    http://*|https://*)
      return 0
      ;;
    *)
      echo "ERROR: $label must be an http(s) URL, got: ${url:-<empty>}" >&2
      exit 1
      ;;
  esac
}

# Local Phase 1 RPC surface: both L1 and L2 must stay on loopback.
assert_local_rpc_urls() {
  assert_loopback_url "${L1_RPC_URL:-}" "L1_RPC_URL"
  assert_l2_loopback_urls
}

# Phase 2 Sepolia: remote L1 OK; L2 / op-node remain loopback.
assert_sepolia_rpc_urls() {
  assert_remote_l1_rpc_url "${L1_RPC_URL:-}" "L1_RPC_URL"
  assert_l2_loopback_urls
  local chain="${L2_CHAIN_ID:-}"
  if [[ "$chain" == "901" ]]; then
    echo "ERROR: assert_sepolia_rpc_urls requires a non-local L2_CHAIN_ID (got 901 — use Phase 1 .env)" >&2
    exit 1
  fi
  if [[ "$chain" != "852" ]]; then
    echo "WARN: L2_CHAIN_ID=$chain (expected 852 for ForteL2 Sepolia learning chain)" >&2
  fi
}

# Fail closed unless this process loaded a Sepolia env (chain 852 + sepolia deploy tree).
require_sepolia_env() {
  assert_sepolia_rpc_urls
  if [[ "${L1_CHAIN_ID:-}" != "11155111" ]]; then
    echo "ERROR: require_sepolia_env expects L1_CHAIN_ID=11155111 (got ${L1_CHAIN_ID:-<unset>})" >&2
    exit 1
  fi
  if [[ "${L2_CHAIN_ID:-}" != "852" ]]; then
    echo "ERROR: require_sepolia_env expects L2_CHAIN_ID=852 (got ${L2_CHAIN_ID:-<unset>})" >&2
    exit 1
  fi
  case "${DEPLOY_DIR:-}" in
    */deployments/sepolia/.deployer|*/deployments/sepolia/.deployer/)
      ;;
    *)
      echo "ERROR: DEPLOY_DIR must be deployments/sepolia/.deployer (got ${DEPLOY_DIR:-<unset>})" >&2
      echo "Use FORTEL2_ENV=.env.sepolia — do not reuse Phase 1 deployments/.deployer" >&2
      exit 1
      ;;
  esac
}

# Checked-in L1 proxy JSON for the active env (Phase 1 vs Sepolia).
deployments_json_path() {
  if [[ "${L2_CHAIN_ID:-}" == "852" ]]; then
    printf '%s' "${SEPOLIA_DEPLOYMENTS_JSON:-$FORTEL2_ROOT/deployments/sepolia/deployments.json}"
  else
    printf '%s' "${DEPLOYMENTS_JSON:-$FORTEL2_ROOT/deployments/deployments.json}"
  fi
}

# Refuse starting Sepolia L2 if something already listens on the configured loopback ports
# (Phase 1 and Phase 2c share default ports and cannot run together).
# Includes batcher/proposer admin RPC ports (hardcoded 8548/8560 in Phase 1 + 2c start scripts).
assert_l2_ports_free() {
  local port
  for port in \
    "${L2_EL_HTTP_PORT}" \
    "${L2_EL_WS_PORT}" \
    "${L2_EL_AUTH_PORT}" \
    "${L2_NODE_RPC_PORT}" \
    8548 \
    8560
  do
    if command -v lsof >/dev/null 2>&1; then
      if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "ERROR: port $port already in use — stop Phase 1 (./scripts/stop-all.sh) or free the port" >&2
        exit 1
      fi
    fi
  done
}

# Require address balance >= min_ether (ether units as decimal string). Uses cast.
require_min_balance_eth() {
  local addr="$1"
  local min_eth="$2"
  local label="${3:-account}"
  require_eth_address "$label" "$addr"
  require_bin cast
  local bal_wei min_wei
  bal_wei="$(cast balance "$addr" --rpc-url "$L1_RPC_URL")"
  min_wei="$(cast to-wei "$min_eth" ether)"
  if ! python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) >= int(sys.argv[2]) else 1)' "$bal_wei" "$min_wei"; then
    local bal_eth
    bal_eth="$(cast --to-unit "$bal_wei" ether)"
    echo "ERROR: $label $addr has ${bal_eth} ETH; need >= ${min_eth} ETH on Sepolia" >&2
    echo "Fund from harvest ($HARVEST_ADDRESS) then re-run. See scripts/sepolia-fund-check.sh" >&2
    exit 1
  fi
}

# Validate a TCP port number (1–65535).
require_http_port() {
  local port="$1"
  local label="${2:-PORT}"
  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    echo "ERROR: invalid $label: $port" >&2
    exit 1
  fi
}

# Serve a static directory on loopback only (guestbook / pipeline viewer).
# Not privileged process control — does not use start_bg / stop_bg.
serve_static_loopback() {
  local dir="$1"
  local port="$2"
  local label="${3:-static HTTP}"
  if [[ -z "$dir" || ! -d "$dir" ]]; then
    echo "ERROR: $label directory missing: ${dir:-<empty>}" >&2
    exit 1
  fi
  require_http_port "$port" "$label"
  assert_loopback_url "http://127.0.0.1:${port}" "$label"
  echo "Serving $label at http://127.0.0.1:${port}/ (loopback only)"
  cd "$dir"
  exec python3 -m http.server "${port}" --bind 127.0.0.1
}
