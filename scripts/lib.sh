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

# >>> env-dup
# Active assignments only: uncommented lines, optional leading whitespace,
# optional `export ` prefix. Name is the identifier before the first `=`.
# Never prints values — a value containing `=` is still one assignment of the
# name. Commented lines (`# KEY=`) are ignored. Lines inside an unclosed
# quoted value are not assignments. D-0066 Finding 5: duplicates belong in
# the loader; absence does not (F7-11 stays deploy-path-only).

# Quote state after scanning s. $1 is the current state (empty, ' or ").
# Toggles on the matching quote character. Unquoted `#` preceded by whitespace
# (or at column 0) starts a comment and is not quote context. Inside double
# quotes, `\` skips the next character so `\"` does not close the string.
# Not a full shell parser.
_scan_quote_state_after() {
  local state="${1-}" s="$2" i=0 c prev prevc
  while [[ $i -lt ${#s} ]]; do
    c="${s:i:1}"
    if [[ -z "$state" ]]; then
      if [[ "$c" == "#" ]]; then
        if [[ $i -eq 0 ]]; then
          break
        fi
        prev=$((i - 1))
        prevc="${s:prev:1}"
        if [[ "$prevc" == [[:blank:]] ]]; then
          break
        fi
      fi
      case "$c" in
        \'|\") state="$c" ;;
      esac
    elif [[ "$state" == '"' && "$c" == "\\" ]]; then
      i=$((i + 1))
    elif [[ "$c" == "$state" ]]; then
      state=""
    fi
    i=$((i + 1))
  done
  printf '%s' "$state"
}

_scan_env_assignments() {
  local file="${1:-${FORTEL2_ENV_FILE:-}}"
  local lineno=0 line trimmed name in_quote=""
  [[ -n "$file" && -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    if [[ -n "$in_quote" ]]; then
      in_quote="$(_scan_quote_state_after "$in_quote" "$line")"
      continue
    fi
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$trimmed" ]] && continue
    [[ "$trimmed" == \#* ]] && continue
    if [[ "$trimmed" == export[[:space:]]* ]]; then
      trimmed="${trimmed#export}"
      trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
    fi
    [[ "$trimmed" == *=* ]] || continue
    name="${trimmed%%=*}"
    [[ "$name" =~ ^[A-Za-z_][A-Za-z_0-9]*$ ]] || continue
    printf '%s %s\n' "$lineno" "$name"
    in_quote="$(_scan_quote_state_after "" "$trimmed")"
  done < "$file"
}

# Refuse a duplicate active assignment of any variable. Error text names
# variables and line numbers only — never a value. Fail closed: missing file
# is an error, not a pass (every consumer sources this).
refuse_duplicate_env_assignments() {
  local file="${1:-${FORTEL2_ENV_FILE:-}}"
  local name lines dups
  if [[ -z "$file" ]]; then
    echo "ERROR: FORTEL2_ENV_FILE is unset; cannot check for duplicate assignments" >&2
    exit 1
  fi
  if [[ ! -f "$file" || ! -r "$file" ]]; then
    echo "ERROR: env file is missing or unreadable; cannot check for duplicate assignments" >&2
    exit 1
  fi
  dups="$(_scan_env_assignments "$file" | awk '
    { lines[$2] = lines[$2] $1 ", "; count[$2]++ }
    END {
      for (n in count) if (count[n] > 1) {
        gsub(/, $/, "", lines[n])
        print n, lines[n]
      }
    }')"
  if [[ -n "$dups" ]]; then
    while read -r name lines; do
      [[ -z "$name" ]] && continue
      echo "ERROR: $name is assigned more than once in the env file (lines $lines)." >&2
      echo "  The last assignment wins when the file is sourced; remove the extra assignment(s) (D-0066)." >&2
    done <<< "$dups"
    exit 1
  fi
}
# <<< env-dup

FORTEL2_ENV_FILE="$(_fortel2_resolve_env_file)"
export FORTEL2_ENV_FILE
refuse_duplicate_env_assignments
# shellcheck disable=SC1090
set -a
source "$FORTEL2_ENV_FILE"
set +a

BIN_DIR="${BIN_DIR:-$FORTEL2_ROOT/bin}"
DATA_DIR="${DATA_DIR:-$FORTEL2_ROOT/data}"
DEPLOY_DIR="${DEPLOY_DIR:-$FORTEL2_ROOT/deployments/.deployer}"
LOG_DIR="${LOG_DIR:-$DATA_DIR/logs}"
PID_DIR="${PID_DIR:-$DATA_DIR/pids}"
# Admin RPC ports for op-batcher / op-proposer (shared by Phase 1 + 2c; must stay free together).
BATCHER_RPC_PORT="${BATCHER_RPC_PORT:-8548}"
PROPOSER_RPC_PORT="${PROPOSER_RPC_PORT:-8560}"

mkdir -p "$DATA_DIR" "$LOG_DIR" "$PID_DIR" "$DEPLOY_DIR"

export PATH="/opt/homebrew/bin:$HOME/.foundry/bin:$BIN_DIR:$PATH"

require_bin() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "ERROR: required binary not found on PATH: $name" >&2
    exit 1
  fi
}

# Redact userinfo / query / fragment and all non-root paths (which may be API keys).
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
path = "/…" if p.path and p.path != "/" else ""
print(f"{p.scheme}://{netloc}{path}")
PY
}

# scheme://host[:port] for CSP connect-src (never includes path tokens).
rpc_origin() {
  python3 - <<'PY' "${1:-}"
import sys, urllib.parse
u = sys.argv[1]
if not u:
    raise SystemExit("empty URL")
p = urllib.parse.urlparse(u)
if p.scheme not in ("http", "https") or not p.hostname:
    raise SystemExit(f"not an http(s) URL: {u!r}")
netloc = p.hostname
if p.port:
    netloc = f"{netloc}:{p.port}"
print(f"{p.scheme}://{netloc}")
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

# Parse a successful optimism_syncStatus JSON-RPC result.
# Prints the current L1 number, or "-" when the result is present but has no number.
# Exit 1 when the payload is not a JSON-RPC result (null, error envelope, non-JSON).
_opnode_syncstatus_l1() {
  python3 -c '
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
if data is None:
    sys.exit(1)
if isinstance(data, dict) and "jsonrpc" in data:
    if "result" not in data:
        sys.exit(1)
    data = data["result"]
    if data is None:
        sys.exit(1)
n = None
if isinstance(data, dict):
    cur = data.get("current_l1")
    if isinstance(cur, dict) and cur.get("number") is not None:
        n = cur["number"]
print("-" if n is None else n)
' "${1:-}"
}

# op-node serves the optimism namespace, not eth_*. Probing with eth_blockNumber
# (wait_for_rpc) times out against a healthy node — D-0055/D-0057 shape.
# Succeeds only on a JSON-RPC *result* from optimism_syncStatus, not TCP/HTTP 200.
wait_for_opnode_rpc() {
  local url="$1"
  local label="${2:-op-node}"
  local tries="${3:-60}"
  local i=0
  local display
  local sync_json
  local l1
  display="$(redact_rpc_url "$url")"
  echo "Waiting for $label at $display ..."
  while (( i < tries )); do
    if sync_json="$(cast rpc optimism_syncStatus --rpc-url "$url" 2>/dev/null)" \
      && l1="$(_opnode_syncstatus_l1 "$sync_json")"; then
      if [[ "$l1" != "-" ]]; then
        echo "$label is up (L1 block $l1)"
      else
        echo "$label is up (optimism_syncStatus ok)"
      fi
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

# Pair a private-key env var to its address env var before any spend or wipe
# (F7-10). Args are the *names* of the variables, not the values.
# `cast wallet address` has no env-var form (ETH_PRIVATE_KEY is not accepted);
# the key touches argv for one short-lived process. That bounded exposure is
# the accepted class — do not invent a new mechanism. Error text names the
# derived and configured addresses and the variable names; never any part of
# the key. Optional 3rd arg is an extra stderr line on mismatch (challenger).
require_key_matches_address() {
  local key_var="$1"
  local addr_var="$2"
  local extra="${3:-}"
  local key addr derived derived_lc configured_lc
  key="${!key_var:-}"
  addr="${!addr_var:-}"
  if [[ -z "$key" ]]; then
    echo "ERROR: $key_var is required (must derive $addr_var)" >&2
    exit 1
  fi
  derived="$(cast wallet address --private-key "$key")"
  derived_lc="$(printf '%s' "$derived" | tr '[:upper:]' '[:lower:]')"
  configured_lc="$(printf '%s' "$addr" | tr '[:upper:]' '[:lower:]')"
  if [[ "$derived_lc" != "$configured_lc" ]]; then
    echo "ERROR: $key_var does not match $addr_var" >&2
    echo "  derived:    $derived" >&2
    echo "  configured: $addr" >&2
    if [[ -n "$extra" ]]; then
      echo "  $extra" >&2
    fi
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
# Includes batcher/proposer admin RPC ports (BATCHER_RPC_PORT / PROPOSER_RPC_PORT).
assert_l2_ports_free() {
  if ! command -v lsof >/dev/null 2>&1; then
    echo "ERROR: lsof is required to verify L2 ports are free (install lsof)" >&2
    exit 1
  fi
  local port
  for port in \
    "${L2_EL_HTTP_PORT}" \
    "${L2_EL_WS_PORT}" \
    "${L2_EL_AUTH_PORT}" \
    "${L2_NODE_RPC_PORT}" \
    "${BATCHER_RPC_PORT}" \
    "${PROPOSER_RPC_PORT}"
  do
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "ERROR: port $port already in use — stop Phase 1 (./scripts/stop-all.sh) or free the port" >&2
      exit 1
    fi
  done
}

# Pin this many L1 blocks behind the observed head. Too recent (head itself)
# fails honest nodes that are 1–2 slots behind a load-balanced tip; too old
# reports a historical balance. Three Sepolia slots ≈ 36s: recent enough that
# funding is current, settled enough that an honest node a block or two behind
# still has the header. A lagging backend that cannot serve that height must
# error rather than answer eth_getBalance(..., "latest") from an older view.
_BALANCE_PIN_LAG=3

# One-shot second-opinion L1 (D-0106). Not serving traffic. Default is the
# endpoint that served the historical pin; if that origin is also L1_RPC_URL
# (the committed example uses PublicNode as L1), fall back rather than
# fail-closing — an unset default colliding with serving L1 is not an
# operator misconfig. An *explicit* same-origin URL is still refused.
_SEPOLIA_L1_CORROBORATION_RPC_DEFAULT="https://ethereum-sepolia-rpc.publicnode.com"
_SEPOLIA_L1_CORROBORATION_RPC_FALLBACK="https://rpc.sepolia.org"

# Outcome (c): balance could not be established. Quotes no figure.
_balance_unread() {
  local label="$1"
  local addr="$2"
  echo "ERROR: $label $addr: could not establish L1 balance at $(redact_rpc_url "${L1_RPC_URL:-}")" >&2
  echo "Balance is unknown — refusing to start. Underfunding has not been established." >&2
  exit 1
}

# Below-floor primary, but the independent second opinion could not be read.
# Distinct from underfunded (quotes no confirmed figure) and from (c) (names
# the corroboration URL). Fail-closed: we cannot establish funds.
_balance_second_opinion_unread() {
  local label="$1"
  local addr="$2"
  local corr_url="$3"
  local pin_block="$4"
  echo "ERROR: $label $addr: second-opinion L1 balance unavailable at $(redact_rpc_url "$corr_url") (pinned block ${pin_block})" >&2
  echo "Cannot corroborate a below-floor primary read — refusing to start. Underfunding has not been established (D-0106)." >&2
  exit 1
}

# Two head samples, take the max so a mixed load balancer prefers a current
# backend. Each sample retries on failure. Prints the pin block; return 1 if
# no verified head. Status captured in `if` — a failed cast must not abort
# the caller under set -e (plain assignment would). Regex unquoted: bash 3.2
# treats a quoted =~ operand as a literal.
_l1_balance_pin_block() {
  local attempt=0
  local max_attempts=3
  local raw="" head="" sample=""
  while [[ "$attempt" -lt "$max_attempts" ]]; do
    attempt=$((attempt + 1))
    raw=""
    if raw="$(cast block-number --rpc-url "$L1_RPC_URL" 2>/dev/null)" \
      && [[ -n "$raw" && "$raw" =~ ^[0-9]+$ ]]; then
      head="$raw"
      break
    fi
    if [[ "$attempt" -lt "$max_attempts" ]]; then
      sleep 1
    fi
  done
  if [[ -z "$head" ]]; then
    return 1
  fi
  if sample="$(cast block-number --rpc-url "$L1_RPC_URL" 2>/dev/null)" \
    && [[ -n "$sample" && "$sample" =~ ^[0-9]+$ ]] \
    && [[ "$sample" -gt "$head" ]]; then
    head="$sample"
  fi
  if [[ "$head" -gt "$_BALANCE_PIN_LAG" ]]; then
    printf '%s\n' "$((head - _BALANCE_PIN_LAG))"
  else
    printf '%s\n' "0"
  fi
  return 0
}

# Balance in wei at an explicit block on rpc_url (defaults to $L1_RPC_URL).
# Retries; prints a decimal integer or returns 1. Never uses the implicit
# "latest" tag. Third arg is the independent corroboration URL (D-0106).
_l1_balance_wei_at() {
  local addr="$1"
  local block="$2"
  local rpc_url="${3:-${L1_RPC_URL:-}}"
  local attempt=0
  local max_attempts=3
  local raw=""
  while [[ "$attempt" -lt "$max_attempts" ]]; do
    attempt=$((attempt + 1))
    raw=""
    if raw="$(cast balance "$addr" --rpc-url "$rpc_url" --block "$block" 2>/dev/null)" \
      && [[ -n "$raw" && "$raw" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$raw"
      return 0
    fi
    if [[ "$attempt" -lt "$max_attempts" ]]; then
      sleep 1
    fi
  done
  return 1
}

# Require address balance >= min_ether (ether units as decimal string). Uses cast.
# Outcomes — an unpinned or unconfirmed read must never tear the stack down:
#   (a) verified wei integer >= floor → return (no secondary call)
#   (b) two agreeing same-provider reads < floor, then a second provider at
#       the same pin:
#         secondary >= floor → WARN (D-0106), proceed
#         secondary < floor  → exit 1, existing underfunded message + both readings
#         secondary unread   → exit 1, distinct cannot-corroborate message
#   (c) primary balance could not be established → exit 1, no figure
# Status captured in `if` — a failed cast must not abort the caller under
# set -e (plain assignment would). Regex unquoted: bash 3.2 treats a quoted
# =~ operand as a literal.
require_min_balance_eth() {
  local addr="$1"
  local min_eth="$2"
  local label="${3:-account}"
  require_eth_address "$label" "$addr"
  require_bin cast
  local min_wei pin_block bal_wei bal_wei2 corr_url corr_wei corr_eth bal_eth
  local primary_origin corr_origin corr_explicit=0

  min_wei="$(cast to-wei "$min_eth" ether)"
  if ! [[ -n "$min_wei" && "$min_wei" =~ ^[0-9]+$ ]]; then
    echo "ERROR: $label $addr: could not convert minimum ETH floor to wei" >&2
    exit 1
  fi

  if ! pin_block="$(_l1_balance_pin_block)"; then
    _balance_unread "$label" "$addr"
  fi
  if ! [[ -n "$pin_block" && "$pin_block" =~ ^[0-9]+$ ]]; then
    _balance_unread "$label" "$addr"
  fi

  if ! bal_wei="$(_l1_balance_wei_at "$addr" "$pin_block")"; then
    _balance_unread "$label" "$addr"
  fi

  if python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) >= int(sys.argv[2]) else 1)' "$bal_wei" "$min_wei"; then
    return 0
  fi

  # Below floor: corroborate at the same pin after a short delay (same provider).
  sleep 1
  if ! bal_wei2="$(_l1_balance_wei_at "$addr" "$pin_block")"; then
    _balance_unread "$label" "$addr"
  fi
  if [[ "$bal_wei" != "$bal_wei2" ]]; then
    _balance_unread "$label" "$addr"
  fi

  # Same-provider reads agree below floor. Ask a second independent provider
  # at the same pin (D-0106): same-provider corroboration cannot detect
  # provider-level staleness. One-shot read only — not serving L1.
  if [[ -n "${SEPOLIA_L1_CORROBORATION_RPC_URL:-}" ]]; then
    corr_explicit=1
    corr_url="$SEPOLIA_L1_CORROBORATION_RPC_URL"
  else
    corr_url="$_SEPOLIA_L1_CORROBORATION_RPC_DEFAULT"
  fi
  # Compare origins, not raw strings: a token in the path, a query, or a
  # trailing slash must not count as an independent provider (D-0106).
  if ! primary_origin="$(rpc_origin "${L1_RPC_URL:-}" 2>/dev/null)"; then
    echo "ERROR: $label $addr: cannot parse L1_RPC_URL origin for second-opinion comparison" >&2
    echo "Cannot corroborate — refusing to start. Underfunding has not been established (D-0106)." >&2
    exit 1
  fi
  if ! corr_origin="$(rpc_origin "$corr_url" 2>/dev/null)"; then
    _balance_second_opinion_unread "$label" "$addr" "$corr_url" "$pin_block"
  fi
  if [[ "$corr_origin" == "$primary_origin" ]]; then
    if [[ "$corr_explicit" -eq 1 ]]; then
      echo "ERROR: $label $addr: SEPOLIA_L1_CORROBORATION_RPC_URL shares origin with L1_RPC_URL ($(redact_rpc_url "${L1_RPC_URL:-}")) — a same-provider second opinion cannot detect provider staleness (D-0106)" >&2
      echo "Cannot corroborate — refusing to start. Underfunding has not been established." >&2
      exit 1
    fi
    # Unset default collided with serving L1 (example PublicNode). Fall back.
    corr_url="$_SEPOLIA_L1_CORROBORATION_RPC_FALLBACK"
    if ! corr_origin="$(rpc_origin "$corr_url" 2>/dev/null)"; then
      _balance_second_opinion_unread "$label" "$addr" "$corr_url" "$pin_block"
    fi
    if [[ "$corr_origin" == "$primary_origin" ]]; then
      echo "ERROR: $label $addr: SEPOLIA_L1_CORROBORATION_RPC_URL shares origin with L1_RPC_URL ($(redact_rpc_url "${L1_RPC_URL:-}")) — a same-provider second opinion cannot detect provider staleness (D-0106)" >&2
      echo "Cannot corroborate — refusing to start. Underfunding has not been established." >&2
      exit 1
    fi
    echo "WARN: default corroboration URL shares origin with L1_RPC_URL; using $(redact_rpc_url "$corr_url") for the second opinion (D-0106)" >&2
  fi

  if ! corr_wei="$(_l1_balance_wei_at "$addr" "$pin_block" "$corr_url")"; then
    _balance_second_opinion_unread "$label" "$addr" "$corr_url" "$pin_block"
  fi

  bal_eth="$(cast --to-unit "$bal_wei" ether)"
  corr_eth="$(cast --to-unit "$corr_wei" ether)"

  if python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) >= int(sys.argv[2]) else 1)' "$corr_wei" "$min_wei"; then
    echo "WARN: $label $addr: L1 providers disagree at pinned block ${pin_block} (D-0106)" >&2
    echo "  primary $(redact_rpc_url "${L1_RPC_URL:-}"): ${bal_eth} ETH" >&2
    echo "  secondary $(redact_rpc_url "$corr_url"): ${corr_eth} ETH" >&2
    echo "  Proceeding with start — provider disagreement; a false abort takes the stack down overnight." >&2
    return 0
  fi

  echo "ERROR: $label $addr has ${bal_eth} ETH; need >= ${min_eth} ETH on Sepolia" >&2
  echo "  primary $(redact_rpc_url "${L1_RPC_URL:-}"): ${bal_eth} ETH; secondary $(redact_rpc_url "$corr_url"): ${corr_eth} ETH (pinned block ${pin_block})" >&2
  echo "Fund from harvest ($HARVEST_ADDRESS) then re-run. See scripts/sepolia-fund-check.sh" >&2
  exit 1
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
# Optional 4th arg: path to a file whose contents are sent as Content-Security-Policy
# (used by the pipeline viewer so Sepolia L1 HTTPS origins need not patch index.html).
# Not privileged process control — does not use start_bg / stop_bg.
serve_static_loopback() {
  local dir="$1"
  local port="$2"
  local label="${3:-static HTTP}"
  local csp_file="${4:-}"
  if [[ -z "$dir" || ! -d "$dir" ]]; then
    echo "ERROR: $label directory missing: ${dir:-<empty>}" >&2
    exit 1
  fi
  require_http_port "$port" "$label"
  assert_loopback_url "http://127.0.0.1:${port}" "$label"
  echo "Serving $label at http://127.0.0.1:${port}/ (loopback only)"
  cd "$dir"
  if [[ -n "$csp_file" ]]; then
    if [[ ! -f "$csp_file" ]]; then
      echo "ERROR: CSP file missing: $csp_file" >&2
      exit 1
    fi
    exec python3 - "$port" "$csp_file" <<'PY'
import http.server, pathlib, sys

port = int(sys.argv[1])
csp = pathlib.Path(sys.argv[2]).read_text().strip()
if not csp:
    raise SystemExit("empty CSP file")

class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Content-Security-Policy", csp)
        super().end_headers()

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
  fi
  exec python3 -m http.server "${port}" --bind 127.0.0.1
}

# --- op-reth migration Task 2 (additive; start_bg/stop_bg bodies unchanged) ---
# Selector: FORTEL2_EL=geth|reth, default geth until Task 5. Live sequencer
# scripts refuse reth rather than hijacking :9545. Sidecar: start-op-reth-verifier.sh.
# Mid-chain rewind without debug_setHead (PRD §11 Q6): wipe the reth datadir and
# re-derive from 852 genesis. Never debug_setHead on a keeper (live or candidate).

FORTEL2_L2_GENESIS_HASH_852='0xe242b1a3312b509e7df1496847f0bd0b115cb66676b1e973a355296c99e2386d'
FORTEL2_LIVE_EL_PORTS='9545 9546 9547 9551'

fortel2_el() {
  printf '%s' "${FORTEL2_EL:-geth}"
}

require_fortel2_el() {
  local el
  el="$(fortel2_el)"
  case "$el" in
    geth|reth) ;;
    *)
      echo "ERROR: FORTEL2_EL must be geth or reth (got $el)" >&2
      exit 1
      ;;
  esac
}

# Live sequencer start paths stay op-geth until Task 5. FORTEL2_EL=reth here
# would otherwise start (or skip) geth with --l2.enginekind=geth — the silent
# overnight class. Sidecar is scripts/start-op-reth-verifier.sh.
refuse_reth_on_live_sequencer() {
  local which="${1:-this live sequencer script}"
  require_fortel2_el
  if [[ "$(fortel2_el)" == "reth" ]]; then
    echo "ERROR: FORTEL2_EL=reth — $which stays op-geth until Task 5" >&2
    echo "Start the isolated 852 verifier: ./scripts/start-op-reth-verifier.sh" >&2
    echo "Live ports :9545/:9546/:9547/:9551 stay on op-geth; this task never restarts the live stack." >&2
    exit 1
  fi
}

# Scripts that need a caller-exported L1_RPC_URL (QuickNode) snapshot it BEFORE
# sourcing lib.sh — Phase 1 .env clobbers it to Anvil. Call this after source.
restore_caller_l1_rpc_url() {
  local saved="${1:-}"
  if [[ -n "$saved" ]]; then
    L1_RPC_URL="$saved"
    export L1_RPC_URL
  fi
}

# Caller DATA_DIR (e.g. Sepolia runtime without loading .env.sepolia). Phase 1
# .env always assigns DATA_DIR; restore then re-bind LOG_DIR/PID_DIR so pids
# and logs land in the caller's tree, not the env-file tree.
restore_caller_data_dir() {
  local saved="${1:-}"
  if [[ -n "$saved" ]]; then
    DATA_DIR="$saved"
    export DATA_DIR
    LOG_DIR="$DATA_DIR/logs"
    PID_DIR="$DATA_DIR/pids"
    mkdir -p "$DATA_DIR" "$LOG_DIR" "$PID_DIR"
  fi
}

require_reth_enginekind() {
  local kind="${1:-}"
  if [[ "$(fortel2_el)" != "reth" ]]; then
    return 0
  fi
  if [[ "$kind" != "reth" ]]; then
    echo "ERROR: FORTEL2_EL=reth requires --l2.enginekind=reth (got ${kind:-<empty>})" >&2
    exit 1
  fi
}

require_reth_profile() {
  local profile="${1:-${FORTEL2_RETH_PROFILE:-}}"
  case "$profile" in
    sequencer_faultproof|verifier) ;;
    "")
      echo "ERROR: FORTEL2_RETH_PROFILE is required when starting op-reth (sequencer_faultproof | verifier); no silent default" >&2
      exit 1
      ;;
    *)
      echo "ERROR: FORTEL2_RETH_PROFILE must be sequencer_faultproof or verifier (got $profile)" >&2
      exit 1
      ;;
  esac
}

# Prints one flag per line (bash 3.2 — no mapfile). Archive is op-reth default
# (no --full). Task 4 proves historical-proof sufficiency; we enable the flag.
reth_profile_flags() {
  local profile="${1:-${FORTEL2_RETH_PROFILE:-}}"
  require_reth_profile "$profile"
  case "$profile" in
    sequencer_faultproof)
      printf '%s\n' --proofs-history
      ;;
    verifier)
      printf '%s\n' --full --rollup.disable-tx-pool-gossip
      ;;
  esac
}

# Absolute path even when the leaf does not exist yet. Physical (`pwd -P`) so a
# symlink $DATA_DIR/l2/op-reth → op-geth cannot bypass the geth-datadir guard.
fortel2_canon_path() {
  local p="$1" parent base
  parent="$(dirname "$p")"
  base="$(basename "$p")"
  if [[ -d "$p" ]]; then
    (cd "$p" && pwd -P)
  elif [[ -d "$parent" ]]; then
    printf '%s/%s\n' "$(cd "$parent" && pwd -P)" "$base"
  else
    printf '%s\n' "$p"
  fi
}

# Production candidate $DATA_DIR/l2/op-reth; throwaway $DATA_DIR/l2/spike-op-reth.
# Refuse $DATA_DIR/l2/op-geth and any path whose leaf is op-geth.
require_reth_datadir() {
  local datadir="${1:-${FORTEL2_RETH_DATADIR:-$DATA_DIR/l2/op-reth}}"
  local got leaf allowed_prod allowed_spike
  mkdir -p "$DATA_DIR/l2"
  got="$(fortel2_canon_path "$datadir")"
  leaf="$(basename "$got")"
  allowed_prod="$(fortel2_canon_path "$DATA_DIR/l2/op-reth")"
  allowed_spike="$(fortel2_canon_path "$DATA_DIR/l2/spike-op-reth")"
  if [[ "$leaf" == "op-geth" ]] || [[ "$got" == "$(fortel2_canon_path "$DATA_DIR/l2/op-geth")" ]]; then
    echo "ERROR: refusing op-geth datadir $got — op-reth never opens \$DATA_DIR/l2/op-geth" >&2
    exit 1
  fi
  if [[ "$got" != "$allowed_prod" && "$got" != "$allowed_spike" ]]; then
    echo "ERROR: reth datadir must be $allowed_prod or $allowed_spike (got $got)" >&2
    exit 1
  fi
  printf '%s\n' "$got"
}

# JWT lives under the verifier datadir — never $DATA_DIR/jwt/jwt.txt (live).
reth_jwt_path() {
  local datadir="${1:-}"
  [[ -n "$datadir" ]] || { echo "ERROR: reth_jwt_path requires a datadir" >&2; exit 1; }
  printf '%s/jwt.txt\n' "$datadir"
}

write_reth_jwt() {
  local jwt="$1"
  mkdir -p "$(dirname "$jwt")"
  if [[ ! -f "$jwt" ]]; then
    openssl rand -hex 32 > "$jwt"
    chmod 600 "$jwt"
    echo "Wrote verifier JWT $jwt (not the live sequencer JWT)"
  fi
}

# Known ForteL2 852 genesis block hash from deployments/sepolia/rollup.json.
require_sepolia_genesis_hash() {
  local rollup="${1:-$FORTEL2_ROOT/deployments/sepolia/rollup.json}"
  local got
  if [[ ! -f "$rollup" ]]; then
    echo "ERROR: missing rollup $rollup (need deployments/sepolia/rollup.json)" >&2
    exit 1
  fi
  got="$(jq -r '.genesis.l2.hash // empty' "$rollup")"
  if [[ "$got" != "$FORTEL2_L2_GENESIS_HASH_852" ]]; then
    echo "ERROR: refusing genesis hash ${got:-<missing>} (want $FORTEL2_L2_GENESIS_HASH_852)" >&2
    exit 1
  fi
  local id
  id="$(jq -r '.l2_chain_id // empty' "$rollup")"
  if [[ "$id" != "852" ]]; then
    echo "ERROR: refusing rollup l2_chain_id ${id:-<missing>} — op-reth init is ForteL2 852 only (not 901)" >&2
    exit 1
  fi
}

require_genesis_852() {
  local genesis="$1"
  local rollup="${2:-$FORTEL2_ROOT/deployments/sepolia/rollup.json}"
  local id
  if [[ -z "$genesis" || ! -f "$genesis" ]]; then
    echo "ERROR: missing 852 genesis.json: ${genesis:-<empty>}" >&2
    exit 1
  fi
  id="$(jq -r '.config.chainId // empty' "$genesis")"
  if [[ "$id" != "852" ]]; then
    echo "ERROR: refusing chain ${id:-<missing>} genesis — op-reth init is ForteL2 852 only (not 901)" >&2
    exit 1
  fi
  require_sepolia_genesis_hash "$rollup"
}

# Resolve 852 genesis. Never returns the Phase 1 901 $DEPLOY_DIR/genesis.json.
resolve_reth_genesis() {
  local explicit="${1:-${FORTEL2_RETH_GENESIS:-}}"
  local sepolia="$FORTEL2_ROOT/deployments/sepolia/.deployer/genesis.json"
  local packed="$FORTEL2_ROOT/replica/config/genesis.json"
  local id
  if [[ -n "$explicit" ]]; then
    [[ -f "$explicit" ]] || { echo "ERROR: FORTEL2_RETH_GENESIS not a file: $explicit" >&2; exit 1; }
    printf '%s\n' "$explicit"
    return 0
  fi
  if [[ -f "$sepolia" ]]; then
    id="$(jq -r '.config.chainId // empty' "$sepolia")"
    if [[ "$id" == "852" ]]; then
      printf '%s\n' "$sepolia"
      return 0
    fi
    echo "WARN: $sepolia chainId=$id — ignoring (not 852)" >&2
  fi
  if [[ -f "$packed" ]]; then
    id="$(jq -r '.config.chainId // empty' "$packed")"
    if [[ "$id" == "852" ]]; then
      printf '%s\n' "$packed"
      return 0
    fi
  fi
  if [[ -f "$DEPLOY_DIR/genesis.json" ]]; then
    id="$(jq -r '.config.chainId // empty' "$DEPLOY_DIR/genesis.json")"
    if [[ "$id" == "852" ]]; then
      printf '%s\n' "$DEPLOY_DIR/genesis.json"
      return 0
    fi
    echo "ERROR: $DEPLOY_DIR/genesis.json chainId=$id — refusing 901 (pass FORTEL2_RETH_GENESIS or use deployments/sepolia/.deployer/genesis.json)" >&2
    exit 1
  fi
  echo "ERROR: no 852 genesis.json found (set FORTEL2_RETH_GENESIS or run with Sepolia deploy artifacts)" >&2
  exit 1
}

reth_http_port() { printf '%s' "${FORTEL2_RETH_HTTP_PORT:-19545}"; }
reth_ws_port() { printf '%s' "${FORTEL2_RETH_WS_PORT:-19546}"; }
reth_auth_port() { printf '%s' "${FORTEL2_RETH_AUTH_PORT:-19551}"; }
reth_node_rpc_port() { printf '%s' "${FORTEL2_RETH_NODE_RPC_PORT:-19547}"; }
reth_p2p_port() { printf '%s' "${FORTEL2_RETH_P2P_PORT:-30330}"; }

refuse_live_port_for_reth() {
  local name="$1" port="$2" p
  for p in $FORTEL2_LIVE_EL_PORTS; do
    if [[ "$port" == "$p" ]]; then
      echo "ERROR: refusing $name=$port — live sequencer ports :9545/:9546/:9547/:9551 stay on op-geth" >&2
      exit 1
    fi
  done
}

require_reth_verifier_ports() {
  local http ws auth node p2p
  http="$(reth_http_port)"
  ws="$(reth_ws_port)"
  auth="$(reth_auth_port)"
  node="$(reth_node_rpc_port)"
  p2p="$(reth_p2p_port)"
  require_http_port "$http" "FORTEL2_RETH_HTTP_PORT"
  require_http_port "$ws" "FORTEL2_RETH_WS_PORT"
  require_http_port "$auth" "FORTEL2_RETH_AUTH_PORT"
  require_http_port "$node" "FORTEL2_RETH_NODE_RPC_PORT"
  require_http_port "$p2p" "FORTEL2_RETH_P2P_PORT"
  refuse_live_port_for_reth FORTEL2_RETH_HTTP_PORT "$http"
  refuse_live_port_for_reth FORTEL2_RETH_WS_PORT "$ws"
  refuse_live_port_for_reth FORTEL2_RETH_AUTH_PORT "$auth"
  refuse_live_port_for_reth FORTEL2_RETH_NODE_RPC_PORT "$node"
  refuse_live_port_for_reth FORTEL2_RETH_P2P_PORT "$p2p"
}

# Wipe only an allowed reth datadir. Never $DATA_DIR/l2/op-geth.
wipe_reth_datadir() {
  local datadir
  datadir="$(require_reth_datadir "${1:-}")"
  echo "Wiping reth datadir $datadir (op-geth untouched)"
  rm -rf "$datadir"
  mkdir -p "$datadir"
}

stop_reth_sidecar() {
  stop_bg op-reth-node
  stop_bg op-reth
}

# Sidecar SafeDB (Task 4). Default $DATA_DIR/l2/op-reth-safedb. Never the live
# op-node store ($DATA_DIR/safedb) and never anything under op-geth.
# Enabled only when FORTEL2_RETH_PROFILE=sequencer_faultproof.
reth_safedb_path() {
  printf '%s' "${FORTEL2_RETH_SAFEDB_PATH:-$DATA_DIR/l2/op-reth-safedb}"
}

require_reth_safedb_path() {
  local raw got live_safedb live_geth parent leaf
  raw="$(reth_safedb_path)"
  if [[ -z "$raw" ]]; then
    echo "ERROR: FORTEL2_RETH_SAFEDB_PATH is empty" >&2
    exit 1
  fi
  mkdir -p "$DATA_DIR/l2"
  got="$(fortel2_canon_path "$raw")"
  live_safedb="$(fortel2_canon_path "$DATA_DIR/safedb")"
  live_geth="$(fortel2_canon_path "$DATA_DIR/l2/op-geth")"
  leaf="$(basename "$got")"
  parent="$(dirname "$got")"
  if [[ "$got" == "$live_safedb" ]]; then
    echo "ERROR: refusing live SafeDB $got — sidecar SafeDB is \$DATA_DIR/l2/op-reth-safedb (live op-node untouched)" >&2
    exit 1
  fi
  if [[ "$leaf" == "op-geth" || "$got" == "$live_geth" || "$got" == "$live_geth"/* ]]; then
    echo "ERROR: refusing SafeDB under op-geth datadir $got" >&2
    exit 1
  fi
  if [[ "$parent" == "$live_geth" ]]; then
    echo "ERROR: refusing SafeDB under op-geth datadir $got" >&2
    exit 1
  fi
  printf '%s\n' "$got"
}
