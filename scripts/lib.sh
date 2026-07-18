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
