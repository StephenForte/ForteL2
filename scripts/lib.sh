#!/usr/bin/env bash
# Shared helpers for ForteL2 Phase 1 scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FORTEL2_ROOT="${FORTEL2_ROOT:-$ROOT}"

if [[ -f "$FORTEL2_ROOT/.env" ]]; then
  # shellcheck disable=SC1091
  set -a
  source "$FORTEL2_ROOT/.env"
  set +a
elif [[ -f "$FORTEL2_ROOT/.env.example" ]]; then
  echo "WARN: no .env found; loading .env.example (copy to .env for local overrides)" >&2
  # shellcheck disable=SC1091
  set -a
  source "$FORTEL2_ROOT/.env.example"
  set +a
fi

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

wait_for_rpc() {
  local url="$1"
  local label="${2:-RPC}"
  local tries="${3:-60}"
  local i=0
  echo "Waiting for $label at $url ..."
  while (( i < tries )); do
    if cast block-number --rpc-url "$url" >/dev/null 2>&1; then
      echo "$label is up (block $(cast block-number --rpc-url "$url"))"
      return 0
    fi
    sleep 1
    ((i++)) || true
  done
  echo "ERROR: timed out waiting for $label at $url" >&2
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

# Reject accidental use of non-Foundry throwaway keys in scripts that broadcast.
warn_if_missing_env_file() {
  if [[ ! -f "$FORTEL2_ROOT/.env" ]]; then
    echo "WARN: using .env.example defaults — copy to .env before any non-local work" >&2
  fi
}

# Local Phase 1 RPC surface: both L1 and L2 must stay on loopback.
assert_local_rpc_urls() {
  assert_loopback_url "${L1_RPC_URL:-}" "L1_RPC_URL"
  assert_loopback_url "${L2_RPC_URL:-}" "L2_RPC_URL"
  if [[ -n "${L2_NODE_RPC_URL:-}" ]]; then
    assert_loopback_url "$L2_NODE_RPC_URL" "L2_NODE_RPC_URL"
  fi
}
