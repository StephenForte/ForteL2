#!/usr/bin/env bash
# T5 step 3 / D-0034: run cloudflared against the write-filter origin only.
# LaunchAgent com.steve.fortel2-cloudflared execs this in the foreground (KeepAlive).
# Independent of start-all-sepolia.sh — nightly sleep stops the sequencer; this
# process stays up (origin goes dark; documented 23:45–03:00 window).
#
# Origin MUST be http://127.0.0.1:${L2_WRITE_RPC_PORT:-9555}.
# Never :9545 (full admin/debug/miner/txpool), never op-node :9547.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

WRITE_PORT="${L2_WRITE_RPC_PORT:-9555}"
EXPECTED_ORIGIN="http://127.0.0.1:${WRITE_PORT}"
TEMPLATE="$FORTEL2_ROOT/config/cloudflared-write.yml.example"
LIVE_CONFIG="${CLOUDFLARED_WRITE_CONFIG:-$FORTEL2_ROOT/config/cloudflared-write.yml}"

usage() {
  echo "Usage: $0 [--check-config [path]]" >&2
  echo "  (no args)        validate live config and exec cloudflared (launchd)" >&2
  echo "  --check-config   validate ingress origin (default: live config path)" >&2
}

# Fail closed if WRITE_PORT is the full EL / op-node surface.
assert_write_port_not_operator_rpc() {
  case "$WRITE_PORT" in
    9545|9546|9547|9551)
      echo "ERROR: L2_WRITE_RPC_PORT=$WRITE_PORT is the full EL/op-node surface; cloudflared must dial the write filter (default 9555)" >&2
      return 1
      ;;
  esac
}

# Validate ingress service: lines. $1 = yaml path.
check_origin() {
  local cfg="$1"
  if [[ ! -f "$cfg" ]]; then
    echo "ERROR: cloudflared config not found: $cfg" >&2
    echo "Copy $TEMPLATE → $LIVE_CONFIG and fill tunnel UUID + hostname (never commit)." >&2
    return 1
  fi
  WRITE_PORT="$WRITE_PORT" EXPECTED_ORIGIN="$EXPECTED_ORIGIN" python3 - "$cfg" <<'PY'
import os, re, sys
from urllib.parse import urlparse

path = sys.argv[1]
expected = os.environ["EXPECTED_ORIGIN"]
forbidden_ports = {9545, 9546, 9547, 9551}

text = open(path, encoding="utf-8").read()
services = []
for raw in text.splitlines():
    line = raw.split("#", 1)[0].rstrip()
    m = re.match(r"^\s*service:\s*(.+?)\s*$", line)
    if not m:
        continue
    val = m.group(1).strip().strip('"').strip("'")
    services.append(val)

if not services:
    print("ERROR: no service: keys in %s" % path, file=sys.stderr)
    sys.exit(1)

found = False
for val in services:
    if val.startswith("http_status:"):
        continue
    parsed = urlparse(val)
    port = parsed.port
    host = (parsed.hostname or "").lower()
    if port in forbidden_ports:
        print(
            "ERROR: forbidden origin port %s in service %r (never :9545/:9546/:9547/:9551)"
            % (port, val),
            file=sys.stderr,
        )
        sys.exit(1)
    if val != expected:
        print("ERROR: ingress service %r is not %s" % (val, expected), file=sys.stderr)
        sys.exit(1)
    if host != "127.0.0.1":
        print("ERROR: origin host must be 127.0.0.1, got %r" % host, file=sys.stderr)
        sys.exit(1)
    found = True

if not found:
    print("ERROR: missing origin %s" % expected, file=sys.stderr)
    sys.exit(1)
PY
}

MODE="run"
CHECK_PATH=""
if [[ "${1:-}" == "--check-config" ]]; then
  MODE="check"
  CHECK_PATH="${2:-$LIVE_CONFIG}"
elif [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
elif [[ -n "${1:-}" ]]; then
  usage
  exit 1
fi

assert_write_port_not_operator_rpc

if [[ "$MODE" == "check" ]]; then
  check_origin "$CHECK_PATH"
  echo "OK origin $EXPECTED_ORIGIN in $CHECK_PATH"
  exit 0
fi

if [[ "$LIVE_CONFIG" == "$TEMPLATE" ]]; then
  echo "ERROR: refusing to run the committed template $TEMPLATE" >&2
  exit 1
fi
if [[ ! -f "$LIVE_CONFIG" ]]; then
  echo "ERROR: live config missing: $LIVE_CONFIG" >&2
  echo "Copy $TEMPLATE → $LIVE_CONFIG and fill placeholders before bootstrapping the LaunchAgent." >&2
  exit 1
fi
if grep -q 'REPLACE_WITH_' "$LIVE_CONFIG"; then
  echo "ERROR: $LIVE_CONFIG still has REPLACE_WITH_ placeholders — fill tunnel UUID + hostname (never commit secrets)" >&2
  exit 1
fi
check_origin "$LIVE_CONFIG"
require_bin cloudflared
echo "cloudflared origin $EXPECTED_ORIGIN (config $LIVE_CONFIG)"
exec cloudflared tunnel --config "$LIVE_CONFIG" run
