#!/usr/bin/env bash
# l1-provider-preflight.sh — executable D-0123 L1 provider gate.
#
# Read-only: no files, no env writes, no argv URL. urllib JSON-RPC with a
# SIGALRM deadline and body cap (alert-watch replica-probe pattern).
#
# Cost table (source of truth: AGENTS.md "L1 provider preflight (D-0123)"):
#   QuickNode  ≈40 credits / L1 block; PAYG $0.43 / million credits
#   Alchemy    ≈340 CU / L1 block; 30M CU cap ≈ 88k L1 blocks
# Unknown hosts print "unpriced — unverified". "Free tier" is never a capability.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Typical call budget (see --help). Override L1_PREFLIGHT_SAMPLES in tests only.
# 25 header samples + chainId + head + receipts + optional debug_getRawReceipts.
DEFAULT_SAMPLES=25
DEFAULT_CALL_TIMEOUT=15
DEFAULT_TOTAL_TIMEOUT=60
# 1 MiB: alert-watch's 64 KiB fits one header; this script must ingest
# eth_getBlockReceipts (D-0135: 162 receipts at 11703708 already exceeds 64 KiB).
# SIGALRM still bounds a trickle; the cap bounds memory. Read cap+1 to detect overflow.
BODY_CAP=1048576
SEPOLIA_CHAIN_ID=11155111
# Three weeks of 12 s L1 slots: 21 * 24 * 3600 / 12 = 151200.
RECEIPTS_LOOKBACK_BLOCKS=151200

usage() {
  cat <<EOF
Usage: l1-provider-preflight.sh --l1.rpckind=KIND [options]

D-0123 gate: capability calls + header integrity + cost arithmetic for an L1
RPC provider before a derivation catch-up. Paste the output into the incident
note. Exit 0 is the gate.

URL (secret):
  Never pass the URL on argv (ps exposes it). Set L1_PREFLIGHT_RPC_URL, or
  L1_RPC_URL if already exported, or paste at the prompt:
    printf 'Paste the URL: ' && read -r URL
  Printed form is scheme://host/<redacted> only.

Required:
  --l1.rpckind=KIND     intended op-node --l1.rpckind (quicknode|standard|…)
                        also reads L1_PREFLIGHT_RPC_KIND, SEPOLIA_L1_RPC_KIND,
                        L1_RPC_KIND

Options:
  --remaining-blocks=N  L1 blocks still to derive (cost input)
  --from-l1=N           remaining = head − N (alternative to --remaining-blocks)
  --purpose=NAME        catch-up (default) or tip-follow (D-0124)
  --provider=NAME       cost table row: quicknode | alchemy
                        default: infer from hostname, else unpriced
  --help

Call budget (metered endpoints):
  At most 29 JSON-RPC calls: eth_chainId, eth_blockNumber,
  eth_getBlockByNumber × 25 (genesis origin, head, 23 interiors),
  eth_getBlockReceipts once, debug_getRawReceipts once when KIND=quicknode.
  A few dozen at ~40 credits is negligible; thousands is not.

Deadlines:
  Per-call SIGALRM + urllib timeout (default ${DEFAULT_CALL_TIMEOUT}s) and a
  process total deadline (default ${DEFAULT_TOTAL_TIMEOUT}s), body cap ${BODY_CAP} bytes.
  Socket timeout alone does not bound a trickling body.
  Overrides: L1_PREFLIGHT_CALL_TIMEOUT, L1_PREFLIGHT_TOTAL_TIMEOUT.

Exit codes:
  0  all checks pass
  1  usage / missing URL / missing --l1.rpckind
  2  unreachable / no JSON
  3  wrong chain id (not ${SEPOLIA_CHAIN_ID})
  4  missing genesis header
  5  pruned receipts (null or empty)
  6  header integrity mismatch (requested vs returned number)
  7  rpckind mismatch (quicknode + debug_getRawReceipts unavailable)

This script cannot preflight the Render replica's L1 endpoint: that URL uses
the L2_Render token, which lives only in the Render dashboard. A Mac run
exercises a different token (provider-level, not endpoint-level).
EOF
}

for _arg in "$@"; do
  case "$_arg" in
    *://*)
      echo "ERROR: URL-like argument refused (ps -ww -o command= exposes argv)." >&2
      echo "Set L1_PREFLIGHT_RPC_URL or paste at the prompt; never pass the URL on argv." >&2
      exit 1
      ;;
  esac
done

RPC_KIND="${L1_PREFLIGHT_RPC_KIND:-${SEPOLIA_L1_RPC_KIND:-${L1_RPC_KIND:-}}}"
REMAINING=""
FROM_L1=""
PURPOSE="catch-up"
COST_PROVIDER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --l1.rpckind=*)
      RPC_KIND="${1#--l1.rpckind=}"
      ;;
    --l1.rpckind)
      shift
      RPC_KIND="${1:-}"
      ;;
    --remaining-blocks=*)
      REMAINING="${1#--remaining-blocks=}"
      ;;
    --remaining-blocks)
      shift
      REMAINING="${1:-}"
      ;;
    --from-l1=*)
      FROM_L1="${1#--from-l1=}"
      ;;
    --from-l1)
      shift
      FROM_L1="${1:-}"
      ;;
    --purpose=*)
      PURPOSE="${1#--purpose=}"
      ;;
    --purpose)
      shift
      PURPOSE="${1:-}"
      ;;
    --provider=*)
      COST_PROVIDER="${1#--provider=}"
      ;;
    --provider)
      shift
      COST_PROVIDER="${1:-}"
      ;;
    --*)
      echo "ERROR: unknown option $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      echo "ERROR: refuse non-flag argument (URL must not be on argv): $1" >&2
      echo "Set L1_PREFLIGHT_RPC_URL or paste at the prompt." >&2
      exit 1
      ;;
  esac
  shift
done

if [ -z "$RPC_KIND" ]; then
  echo "ERROR: --l1.rpckind is required (D-0124: URL and kind are a pair)." >&2
  exit 1
fi

URL="${L1_PREFLIGHT_RPC_URL:-${L1_RPC_URL:-}}"
if [ -z "$URL" ]; then
  if [ -t 0 ]; then
    printf 'Paste the URL: '
    read -r URL
  else
    echo "ERROR: set L1_PREFLIGHT_RPC_URL (or L1_RPC_URL); never pass the URL on argv." >&2
    exit 1
  fi
fi
if [ -z "$URL" ]; then
  echo "ERROR: empty URL" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: required binary not found on PATH: python3" >&2
  exit 1
fi

export L1_PREFLIGHT_RPC_URL="$URL"
export L1_PREFLIGHT_RPC_KIND="$RPC_KIND"
export L1_PREFLIGHT_REMAINING="${REMAINING}"
export L1_PREFLIGHT_FROM_L1="${FROM_L1}"
export L1_PREFLIGHT_PURPOSE="$PURPOSE"
export L1_PREFLIGHT_COST_PROVIDER="$COST_PROVIDER"
export L1_PREFLIGHT_SAMPLES="${L1_PREFLIGHT_SAMPLES:-$DEFAULT_SAMPLES}"
export L1_PREFLIGHT_CALL_TIMEOUT="${L1_PREFLIGHT_CALL_TIMEOUT:-$DEFAULT_CALL_TIMEOUT}"
export L1_PREFLIGHT_TOTAL_TIMEOUT="${L1_PREFLIGHT_TOTAL_TIMEOUT:-$DEFAULT_TOTAL_TIMEOUT}"
export L1_PREFLIGHT_BODY_CAP="${L1_PREFLIGHT_BODY_CAP:-$BODY_CAP}"
export L1_PREFLIGHT_RECEIPTS_LOOKBACK="${L1_PREFLIGHT_RECEIPTS_LOOKBACK:-$RECEIPTS_LOOKBACK_BLOCKS}"
export L1_PREFLIGHT_SEPOLIA_CHAIN_ID="$SEPOLIA_CHAIN_ID"

# URL stays in the environment, never on python argv.
exec python3 - "$REPO_ROOT" <<'PY'
from __future__ import print_function

import json
import os
import signal
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# Per-block prices: AGENTS.md "L1 provider preflight (D-0123)" is the source of truth.
COST_TABLE = {
    "quicknode": {
        "per_block": 40,
        "unit": "credits",
        "usd_per_million": 0.43,
        "cap": None,
        "cap_unit": None,
        "cap_blocks": None,
    },
    "alchemy": {
        "per_block": 340,
        "unit": "CU",
        "usd_per_million": None,
        "cap": 30000000,
        "cap_unit": "CU",
        "cap_blocks": 88000,
    },
}

EC_OK = 0
EC_UNREACHABLE = 2
EC_CHAIN_ID = 3
EC_GENESIS = 4
EC_RECEIPTS = 5
EC_INTEGRITY = 6
EC_RPCKIND = 7

REPO_ROOT = sys.argv[1]
URL = os.environ.get("L1_PREFLIGHT_RPC_URL") or ""
RPC_KIND = (os.environ.get("L1_PREFLIGHT_RPC_KIND") or "").strip()
PURPOSE = (os.environ.get("L1_PREFLIGHT_PURPOSE") or "catch-up").strip()
COST_PROVIDER_OPT = (os.environ.get("L1_PREFLIGHT_COST_PROVIDER") or "").strip().lower()
SAMPLES = int(os.environ.get("L1_PREFLIGHT_SAMPLES") or "25")
CALL_TIMEOUT = float(os.environ.get("L1_PREFLIGHT_CALL_TIMEOUT") or "15")
TOTAL_TIMEOUT = float(os.environ.get("L1_PREFLIGHT_TOTAL_TIMEOUT") or "60")
BODY_CAP = int(os.environ.get("L1_PREFLIGHT_BODY_CAP") or "1048576")
LOOKBACK = int(os.environ.get("L1_PREFLIGHT_RECEIPTS_LOOKBACK") or "151200")
SEPOLIA_CHAIN_ID = int(os.environ.get("L1_PREFLIGHT_SEPOLIA_CHAIN_ID") or "11155111")
REMAINING_IN = (os.environ.get("L1_PREFLIGHT_REMAINING") or "").strip()
FROM_L1_IN = (os.environ.get("L1_PREFLIGHT_FROM_L1") or "").strip()

STARTED = time.time()
CALLS = [0]


class PreflightError(Exception):
    def __init__(self, code, message):
        self.code = code
        Exception.__init__(self, message)


def redact_url(u):
    """scheme://host[:port]/<redacted> — path and query never printed."""
    if not u:
        return "<empty>"
    p = urllib.parse.urlparse(u)
    host = p.hostname or ""
    if p.port:
        host = "%s:%d" % (host, p.port)
    path = "/<redacted>" if p.path and p.path != "/" else ""
    query = "?<redacted>" if p.query else ""
    return "%s://%s%s%s" % (p.scheme, host, path, query)


def token_fragments(u):
    """Secret-looking URL pieces that must never appear in output."""
    parts = []
    try:
        p = urllib.parse.urlparse(u)
    except Exception:
        return parts
    if p.password:
        parts.append(p.password)
    if p.query:
        parts.append(p.query)
        for piece in p.query.split("&"):
            if "=" in piece:
                parts.append(piece.split("=", 1)[1])
    path = (p.path or "").strip("/")
    if path:
        parts.append(path)
        for seg in path.split("/"):
            if seg:
                parts.append(seg)
    return [x for x in parts if x]


def scrub(text):
    if not text:
        return text
    out = str(text)
    if URL:
        out = out.replace(URL, redact_url(URL))
        for frag in token_fragments(URL):
            if frag:
                out = out.replace(frag, "<redacted>")
    return out


def emit(line, stream=None):
    stream = stream or sys.stdout
    stream.write(scrub(line) + "\n")
    stream.flush()


def load_genesis():
    candidates = [
        os.path.join(REPO_ROOT, "deployments", "sepolia", ".deployer", "rollup.json"),
        os.path.join(REPO_ROOT, "deployments", "sepolia", "rollup.json"),
    ]
    last_err = "no rollup.json found"
    for path in candidates:
        if not os.path.isfile(path):
            continue
        try:
            with open(path, "r") as fh:
                doc = json.load(fh)
        except (OSError, ValueError) as exc:
            last_err = "%s: %s" % (path, exc)
            continue
        try:
            number = int(doc["genesis"]["l1"]["number"])
        except (KeyError, TypeError, ValueError):
            last_err = "%s: missing genesis.l1.number" % path
            continue
        rel = os.path.relpath(path, REPO_ROOT)
        return number, rel
    raise PreflightError(1, "ERROR: cannot read L1 genesis origin (%s)" % last_err)


def parse_int(value):
    if value is None:
        return None
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    text = str(value).strip()
    if not text:
        return None
    try:
        if text.startswith("0x") or text.startswith("0X"):
            return int(text, 16)
        return int(text, 10)
    except ValueError:
        return None


def hex_qty(n):
    return "0x%x" % int(n)


def infer_provider(host, override):
    if override:
        return override
    h = (host or "").lower()
    if "quiknode.pro" in h or "quicknode" in h:
        return "quicknode"
    if "alchemy" in h:
        return "alchemy"
    return ""


def cost_block(provider, remaining):
    lines = []
    lines.append("COST (catch-up arithmetic — AGENTS.md D-0123 measured facts)")
    lines.append("  purpose:      %s" % PURPOSE)
    if remaining is None:
        lines.append("  remaining:    (not given; pass --remaining-blocks or --from-l1)")
        lines.append("  per-block:    unpriced — unverified")
        return lines
    lines.append("  remaining:    %d L1 blocks" % remaining)
    if provider not in COST_TABLE:
        name = provider if provider else "unknown"
        lines.append("  provider:     %s" % name)
        lines.append("  per-block:    unpriced — unverified")
        lines.append("  total:        unpriced — unverified")
        lines.append("  note:         \"free tier\" is not a capability claim")
        return lines
    row = COST_TABLE[provider]
    total = remaining * row["per_block"]
    lines.append("  provider:     %s" % provider)
    lines.append("  per-block:    ≈%s %s" % (row["per_block"], row["unit"]))
    lines.append("  total:        %s %s" % (total, row["unit"]))
    if row["usd_per_million"] is not None:
        dollars = (float(total) / 1000000.0) * row["usd_per_million"]
        lines.append("  dollars:      $%.4f  (QuickNode PAYG $%.2f/M)" % (
            dollars, row["usd_per_million"]))
    if row["cap"] is not None:
        frac = (float(total) / float(row["cap"])) * 100.0 if row["cap"] else 0.0
        extra = ""
        if row["cap_blocks"] is not None:
            extra = " ≈ %sk L1 blocks" % (row["cap_blocks"] // 1000)
        lines.append("  cap:          %s %s%s" % (row["cap"], row["cap_unit"], extra))
        lines.append("  fraction:     %.2f%% of cap" % frac)
    else:
        lines.append("  cap:          (none stated in table)")
    return lines


def remaining_blocks(head):
    if REMAINING_IN:
        n = parse_int(REMAINING_IN)
        if n is None or n < 0:
            raise PreflightError(1, "ERROR: --remaining-blocks must be a non-negative integer")
        return n
    if FROM_L1_IN:
        start = parse_int(FROM_L1_IN)
        if start is None:
            raise PreflightError(1, "ERROR: --from-l1 must be an integer")
        if head is None:
            return None
        return max(0, int(head) - int(start))
    return None


def sample_heights(genesis, head, n):
    if n < 3:
        n = 3
    genesis = int(genesis)
    head = int(head)
    if head < genesis:
        return [genesis, head]
    if head == genesis:
        return [genesis]
    heights = [genesis]
    interior = n - 2
    span = head - genesis
    for i in range(1, interior + 1):
        h = genesis + (span * i) // (interior + 1)
        if h != genesis and h != head and h not in heights:
            heights.append(h)
    heights.append(head)
    return heights


def _deadline(_signum, _frame):
    raise TimeoutError("preflight JSON-RPC deadline")


def rpc(method, params):
    elapsed = time.time() - STARTED
    if elapsed >= TOTAL_TIMEOUT:
        raise PreflightError(EC_UNREACHABLE, "FAIL reachability: total deadline (%.1fs) exceeded" % TOTAL_TIMEOUT)
    remaining = TOTAL_TIMEOUT - elapsed
    budget = CALL_TIMEOUT if CALL_TIMEOUT < remaining else remaining
    if budget <= 0:
        raise PreflightError(EC_UNREACHABLE, "FAIL reachability: total deadline (%.1fs) exceeded" % TOTAL_TIMEOUT)
    payload = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params,
    }).encode("utf-8")
    req = urllib.request.Request(
        URL,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="POST",
    )
    prev = signal.signal(signal.SIGALRM, _deadline)
    signal.setitimer(signal.ITIMER_REAL, budget)
    raw = b""
    try:
        try:
            with urllib.request.urlopen(req, timeout=budget) as resp:
                raw = resp.read(BODY_CAP + 1)
        except TimeoutError:
            raise PreflightError(EC_UNREACHABLE, "FAIL reachability: call deadline (%.1fs) exceeded" % budget)
        except urllib.error.HTTPError as exc:
            try:
                raw = exc.read(BODY_CAP + 1)
            except Exception:
                raw = b""
            if not raw:
                raise PreflightError(EC_UNREACHABLE, "FAIL reachability: HTTP %s / no JSON" % exc.code)
        except (urllib.error.URLError, OSError, ValueError):
            raise PreflightError(EC_UNREACHABLE, "FAIL reachability: unreachable / no JSON")
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, prev)
    if len(raw) > BODY_CAP:
        raise PreflightError(EC_UNREACHABLE, "FAIL reachability: response exceeded body cap (%d bytes)" % BODY_CAP)
    CALLS[0] += 1
    try:
        doc = json.loads(raw.decode("utf-8"))
    except (ValueError, TypeError, UnicodeDecodeError):
        raise PreflightError(EC_UNREACHABLE, "FAIL reachability: non-JSON body")
    if not isinstance(doc, dict):
        raise PreflightError(EC_UNREACHABLE, "FAIL reachability: non-JSON-RPC body")
    return doc


def rpc_result(method, params):
    doc = rpc(method, params)
    if "error" in doc and doc["error"] is not None:
        return None, doc["error"]
    return doc.get("result"), None


def error_code(err):
    if isinstance(err, dict):
        return parse_int(err.get("code"))
    return None


def main():
    failures = []
    genesis, genesis_src = load_genesis()
    host = urllib.parse.urlparse(URL).hostname or ""
    provider = infer_provider(host, COST_PROVIDER_OPT)

    emit("=== ForteL2 L1 provider preflight (D-0123) ===")
    emit("endpoint:     %s" % redact_url(URL))
    emit("purpose:      %s" % PURPOSE)
    emit("l1.rpckind:   %s" % RPC_KIND)
    emit("genesis L1:   %d  (from %s)" % (genesis, genesis_src))
    emit("samples:      %d header heights (genesis, head, evenly spaced interiors)" % SAMPLES)
    emit("deadlines:    per-call %.1fs, total %.1fs, body cap %d" % (
        CALL_TIMEOUT, TOTAL_TIMEOUT, BODY_CAP))
    emit("")

    chain_id = None
    head = None
    try:
        result, err = rpc_result("eth_chainId", [])
        if err is not None:
            raise PreflightError(EC_UNREACHABLE, "FAIL reachability: eth_chainId JSON-RPC error")
        chain_id = parse_int(result)
        if chain_id is None:
            raise PreflightError(EC_UNREACHABLE, "FAIL reachability: eth_chainId missing")
    except PreflightError as exc:
        if exc.code == EC_UNREACHABLE:
            emit(str(exc), sys.stderr)
            rem = remaining_blocks(None)
            for line in cost_block(provider, rem):
                emit(line)
            emit("json-rpc calls: %d" % CALLS[0])
            return exc.code
        raise

    if chain_id != SEPOLIA_CHAIN_ID:
        emit("CHECK reachability+chainId  FAIL chain_id=%s (expected %d)" % (
            chain_id, SEPOLIA_CHAIN_ID), sys.stderr)
        emit("wrong chain id is an immediate hard fail (mainnet URL pasted by mistake).")
        rem = remaining_blocks(None)
        for line in cost_block(provider, rem):
            emit(line)
        emit("json-rpc calls: %d" % CALLS[0])
        return EC_CHAIN_ID
    emit("CHECK reachability+chainId  PASS chain_id=%d" % chain_id)

    try:
        result, err = rpc_result("eth_blockNumber", [])
        if err is not None:
            raise PreflightError(EC_UNREACHABLE, "FAIL reachability: eth_blockNumber JSON-RPC error")
        head = parse_int(result)
        if head is None:
            raise PreflightError(EC_UNREACHABLE, "FAIL reachability: eth_blockNumber missing")
    except PreflightError as exc:
        emit(str(exc), sys.stderr)
        rem = remaining_blocks(None)
        for line in cost_block(provider, rem):
            emit(line)
        emit("json-rpc calls: %d" % CALLS[0])
        return exc.code
    emit("head:         %d" % head)

    # --- genesis header (also the first integrity sample; do not double-fetch) ---
    genesis_block = None
    try:
        result, err = rpc_result("eth_getBlockByNumber", [hex_qty(genesis), False])
        if err is not None or result is None:
            raise PreflightError(
                EC_GENESIS,
                "CHECK genesis header       FAIL missing header at %d (null or RPC error)" % genesis,
            )
        if not isinstance(result, dict):
            raise PreflightError(
                EC_GENESIS,
                "CHECK genesis header       FAIL missing header at %d (not an object)" % genesis,
            )
        genesis_block = result
        emit("CHECK genesis header       PASS block=%d" % genesis)
    except PreflightError as exc:
        if exc.code == EC_UNREACHABLE:
            emit(str(exc), sys.stderr)
            rem = remaining_blocks(head)
            for line in cost_block(provider, rem):
                emit(line)
            emit("json-rpc calls: %d" % CALLS[0])
            return exc.code
        emit(str(exc), sys.stderr)
        failures.append(exc.code)

    # --- historical receipts (D-0124 cause 1) ---
    receipts_block = head - LOOKBACK
    if receipts_block < 0:
        receipts_block = 0
    try:
        result, err = rpc_result("eth_getBlockReceipts", [hex_qty(receipts_block)])
        n_receipts = None
        if err is not None:
            fail_receipts = True
        elif result is None:
            fail_receipts = True
        elif isinstance(result, list):
            n_receipts = len(result)
            fail_receipts = n_receipts == 0
        else:
            fail_receipts = True
        if fail_receipts:
            emit(
                "CHECK historical receipts  FAIL pruned at %d "
                "(head %d − %d slots / 12s = 3 weeks); null or empty (D-0124 cause 1)" % (
                    receipts_block, head, LOOKBACK),
                sys.stderr,
            )
            failures.append(EC_RECEIPTS)
        else:
            emit(
                "CHECK historical receipts  PASS block=%d n=%d "
                "(head %d − %d = 3 weeks of 12s slots)" % (
                    receipts_block, n_receipts, head, LOOKBACK)
            )
    except PreflightError as exc:
        if exc.code == EC_UNREACHABLE:
            emit(str(exc), sys.stderr)
            rem = remaining_blocks(head)
            for line in cost_block(provider, rem):
                emit(line)
            emit("json-rpc calls: %d" % CALLS[0])
            return exc.code
        emit(str(exc), sys.stderr)
        failures.append(exc.code)

    # --- header integrity (PublicNode 11703708 class) ---
    heights = sample_heights(genesis, head, SAMPLES)
    mismatch = None
    try:
        for height in heights:
            if height == genesis and genesis_block is not None:
                result, err = genesis_block, None
            else:
                result, err = rpc_result("eth_getBlockByNumber", [hex_qty(height), False])
            if err is not None or not isinstance(result, dict):
                mismatch = (height, None)
                break
            got = parse_int(result.get("number"))
            if got != height:
                mismatch = (height, got)
                break
        if mismatch is not None:
            requested, returned = mismatch
            ret_s = "null" if returned is None else str(returned)
            emit(
                "CHECK header integrity     FAIL requested %s, returned %s" % (
                    requested, ret_s),
                sys.stderr,
            )
            failures.append(EC_INTEGRITY)
        else:
            emit("CHECK header integrity     PASS samples=%d (requested number == returned number)" % len(heights))
    except PreflightError as exc:
        if exc.code == EC_UNREACHABLE:
            emit(str(exc), sys.stderr)
            rem = remaining_blocks(head)
            for line in cost_block(provider, rem):
                emit(line)
            emit("json-rpc calls: %d" % CALLS[0])
            return exc.code
        emit(str(exc), sys.stderr)
        failures.append(exc.code)

    # --- rpckind pairing (D-0124 cause 2) ---
    # op-node --l1.rpckind valid options (D-0105 Finding 3 / binary help):
    # alchemy, quicknode, infura, parity, nethermind, debug_geth, erigon, basic, any, standard
    known_kinds = (
        "alchemy", "quicknode", "infura", "parity", "nethermind",
        "debug_geth", "erigon", "basic", "any", "standard",
    )
    kind_l = RPC_KIND.lower()
    try:
        if kind_l not in known_kinds:
            emit(
                "CHECK rpckind pairing      FAIL kind=%s is not a known --l1.rpckind "
                "(unverified; valid: %s)" % (RPC_KIND, ", ".join(known_kinds)),
                sys.stderr,
            )
            failures.append(EC_RPCKIND)
        elif kind_l == "quicknode":
            result, err = rpc_result("debug_getRawReceipts", [hex_qty(receipts_block)])
            code = error_code(err) if err is not None else None
            if err is not None or result is None:
                emit(
                    "CHECK rpckind pairing      FAIL kind=quicknode incompatible "
                    "with this URL: debug_getRawReceipts → %s (D-0124 cause 2)" % (
                        code if code is not None else "error/null"),
                    sys.stderr,
                )
                failures.append(EC_RPCKIND)
            else:
                emit("CHECK rpckind pairing      PASS kind=quicknode + debug_getRawReceipts compatible")
        else:
            emit("CHECK rpckind pairing      PASS kind=%s (debug_getRawReceipts not required)" % RPC_KIND)
    except PreflightError as exc:
        if exc.code == EC_UNREACHABLE:
            emit(str(exc), sys.stderr)
            rem = remaining_blocks(head)
            for line in cost_block(provider, rem):
                emit(line)
            emit("json-rpc calls: %d" % CALLS[0])
            return exc.code
        emit(str(exc), sys.stderr)
        failures.append(exc.code)

    rem = remaining_blocks(head)
    emit("")
    for line in cost_block(provider, rem):
        emit(line)
    emit("json-rpc calls: %d (budget ≤29)" % CALLS[0])

    if failures:
        # Distinct codes, first in table order.
        order = (EC_GENESIS, EC_RECEIPTS, EC_INTEGRITY, EC_RPCKIND)
        for code in order:
            if code in failures:
                emit("RESULT FAIL exit=%d" % code, sys.stderr)
                return code
        return failures[0]

    emit("RESULT PASS")
    return EC_OK


if __name__ == "__main__":
    try:
        rc = main()
    except PreflightError as exc:
        emit(str(exc), sys.stderr)
        rc = exc.code
    except Exception as exc:
        emit("FAIL reachability: unreachable / no JSON (%s)" % type(exc).__name__, sys.stderr)
        rc = EC_UNREACHABLE
    sys.exit(rc)
PY
