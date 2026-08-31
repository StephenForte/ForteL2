#!/usr/bin/env bash
# Task 3: sampled safe-head parity — candidate op-reth vs live op-geth vs replica.
# Live :9545 is READ-ONLY eth_* (no admin/debug writes). Replica is a
# comparison reference only, never a derivation source.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
usage: verify-reth-parity.sh [options]

Compare ≥20 pinned SAFE blocks (number, hash, parentHash, stateRoot,
receiptsRoot, txCount) plus state/receipt/deposit spot-checks across:

  candidate  default http://127.0.0.1:19545  (op-reth sidecar)
  live       default http://127.0.0.1:9545   (sequencer; loopback eth_* only)
  replica    default rail-interface.json replica.readRpcUrl

Exit 0 only on a full three-way match. Any mismatch names block + field.

  --candidate URL     candidate EL HTTP (loopback)
  --live URL          live sequencer EL HTTP (must be loopback)
  --replica URL       replica public read URL (comparison only)
  --candidate-node URL  candidate op-node (default http://127.0.0.1:19547)
  --live-node URL       live op-node (default http://127.0.0.1:9547)
  --blocks CSV        extra pinned heights (always includes 0,5 when in range)
  --min-blocks N      minimum sample count (default 20)
  --sleep-ms N        pause between live/replica RPC calls (default 400)
  --guestbook ADDR    Guestbook address (default deployments/guestbook.txt)
  --fixture PATH      offline JSON fixture (no RPC; CI / helper tests)
  --alter-field F     mutate the candidate fixture copy of F before compare
                      (hash|parentHash|stateRoot|receiptsRoot|txCount|
                       balance|storage|receipt) — must exit nonzero
  -h, --help

Does not print private keys, JWTs, or L1 provider URLs.
EOF
}

CANDIDATE_RPC="${CANDIDATE_RPC:-http://127.0.0.1:19545}"
LIVE_RPC="${LIVE_RPC:-http://127.0.0.1:9545}"
REPLICA_RPC="${REPLICA_RPC:-}"
CANDIDATE_NODE_RPC="${CANDIDATE_NODE_RPC:-http://127.0.0.1:19547}"
LIVE_NODE_RPC="${LIVE_NODE_RPC:-http://127.0.0.1:9547}"
BLOCKS_CSV=""
MIN_BLOCKS=20
SLEEP_MS=400
GUESTBOOK_ADDR="${GUESTBOOK_ADDRESS:-}"
FIXTURE=""
ALTER_FIELD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --candidate) CANDIDATE_RPC="$2"; shift 2 ;;
    --live) LIVE_RPC="$2"; shift 2 ;;
    --replica) REPLICA_RPC="$2"; shift 2 ;;
    --candidate-node) CANDIDATE_NODE_RPC="$2"; shift 2 ;;
    --live-node) LIVE_NODE_RPC="$2"; shift 2 ;;
    --blocks) BLOCKS_CSV="$2"; shift 2 ;;
    --min-blocks) MIN_BLOCKS="$2"; shift 2 ;;
    --sleep-ms) SLEEP_MS="$2"; shift 2 ;;
    --guestbook) GUESTBOOK_ADDR="$2"; shift 2 ;;
    --fixture) FIXTURE="$2"; shift 2 ;;
    --alter-field) ALTER_FIELD="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ! [[ "$MIN_BLOCKS" =~ ^[0-9]+$ ]] || (( MIN_BLOCKS < 1 )); then
  echo "ERROR: --min-blocks must be an integer >= 1" >&2
  exit 2
fi
if ! [[ "$SLEEP_MS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --sleep-ms must be an integer >= 0" >&2
  exit 2
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin python3
require_bin jq

RAIL="$FORTEL2_ROOT/deployments/rail-interface.json"
if [[ -z "$REPLICA_RPC" ]]; then
  REPLICA_RPC="$(jq -r '.networks["fortel2-sepolia"].replica.readRpcUrl // empty' "$RAIL")"
fi
if [[ -z "$REPLICA_RPC" ]]; then
  echo "ERROR: replica URL missing (pass --replica or fix rail-interface.json)" >&2
  exit 2
fi

if [[ -z "$GUESTBOOK_ADDR" && -f "$FORTEL2_ROOT/deployments/guestbook.txt" ]]; then
  GUESTBOOK_ADDR="$(tr -d '[:space:]' < "$FORTEL2_ROOT/deployments/guestbook.txt")"
fi

if [[ -z "$FIXTURE" ]]; then
  assert_loopback_url "$CANDIDATE_RPC" "candidate EL"
  assert_loopback_url "$LIVE_RPC" "live sequencer EL"
  assert_loopback_url "$CANDIDATE_NODE_RPC" "candidate op-node"
  assert_loopback_url "$LIVE_NODE_RPC" "live op-node"
  if [[ -n "$ALTER_FIELD" ]]; then
    echo "ERROR: --alter-field is fixture-only (do not mutate a live compare)" >&2
    exit 2
  fi
else
  if [[ ! -f "$FIXTURE" ]]; then
    echo "ERROR: fixture not found: $FIXTURE" >&2
    exit 2
  fi
fi

export PARITY_CANDIDATE_RPC="$CANDIDATE_RPC"
export PARITY_LIVE_RPC="$LIVE_RPC"
export PARITY_REPLICA_RPC="$REPLICA_RPC"
export PARITY_CANDIDATE_NODE_RPC="$CANDIDATE_NODE_RPC"
export PARITY_LIVE_NODE_RPC="$LIVE_NODE_RPC"
export PARITY_BLOCKS_CSV="$BLOCKS_CSV"
export PARITY_MIN_BLOCKS="$MIN_BLOCKS"
export PARITY_SLEEP_MS="$SLEEP_MS"
export PARITY_GUESTBOOK="${GUESTBOOK_ADDR:-}"
export PARITY_FIXTURE="$FIXTURE"
export PARITY_ALTER_FIELD="$ALTER_FIELD"

python3 - <<'PY'
import json, os, sys, time, urllib.error, urllib.request, hashlib

CAND = os.environ["PARITY_CANDIDATE_RPC"].rstrip("/")
LIVE = os.environ["PARITY_LIVE_RPC"].rstrip("/")
REPL = os.environ["PARITY_REPLICA_RPC"].rstrip("/")
CNODE = os.environ["PARITY_CANDIDATE_NODE_RPC"].rstrip("/")
LNODE = os.environ["PARITY_LIVE_NODE_RPC"].rstrip("/")
MIN_BLOCKS = int(os.environ["PARITY_MIN_BLOCKS"])
SLEEP_MS = int(os.environ["PARITY_SLEEP_MS"])
GUESTBOOK = (os.environ.get("PARITY_GUESTBOOK") or "").strip()
FIXTURE = os.environ.get("PARITY_FIXTURE") or ""
ALTER = (os.environ.get("PARITY_ALTER_FIELD") or "").strip()
BLOCKS_CSV = (os.environ.get("PARITY_BLOCKS_CSV") or "").strip()

L2_BRIDGE = "0x4200000000000000000000000000000000000010"
L2_WETH = "0x4200000000000000000000000000000000000006"
L2_PASSER = "0x4200000000000000000000000000000000000016"
PASSER_NONCE_SLOT = "0x1"
EL_ETH_METHODS = {
    "eth_chainId",
    "eth_blockNumber",
    "eth_getBlockByNumber",
    "eth_getTransactionReceipt",
    "eth_getTransactionByHash",
    "eth_getBalance",
    "eth_getStorageAt",
    "eth_getCode",
}
NODE_METHODS = {"optimism_syncStatus"}
ALLOWED = EL_ETH_METHODS | NODE_METHODS

_rpc_id = 0


def fail(msg, code=1):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def hex_int(v):
    if v is None:
        return None
    if isinstance(v, int):
        return v
    s = str(v).strip().lower()
    if s in ("", "none", "null"):
        return None
    return int(s, 16) if s.startswith("0x") else int(s)


def norm_hex(v):
    if v is None:
        return None
    s = str(v).strip().lower()
    if not s.startswith("0x"):
        s = "0x" + s
    if s == "0x":
        return "0x0"
    body = s[2:].lstrip("0")
    return "0x" + (body if body else "0")


def norm_hash(v):
    if v is None:
        return None
    s = str(v).strip().lower()
    if not s.startswith("0x"):
        s = "0x" + s
    return "0x" + s[2:].zfill(64)


def norm_addr(v):
    if not v:
        return ""
    return str(v).strip().lower()


def tx_list(block):
    txs = block.get("transactions") or []
    return txs if isinstance(txs, list) else []


def tx_count(block):
    return len(tx_list(block))


def tx_hash_of(tx):
    if isinstance(tx, str):
        return norm_hash(tx)
    if isinstance(tx, dict):
        return norm_hash(tx.get("hash") or tx.get("transactionHash"))
    return None


def tx_type_of(tx):
    if not isinstance(tx, dict):
        return None
    t = tx.get("type")
    if t is None:
        return None
    return hex_int(t)


def sleep_rpc():
    if SLEEP_MS > 0:
        time.sleep(SLEEP_MS / 1000.0)


def rpc(url, method, params, label):
    if method not in ALLOWED:
        fail(f"refusing RPC method {method} (eth_* on EL / optimism_syncStatus on op-node only)")
    if url.rstrip("/") in (LIVE,) and method not in EL_ETH_METHODS:
        fail(f"refusing non-eth_* method {method} against live sequencer EL")
    global _rpc_id
    _rpc_id += 1
    payload = json.dumps({
        "jsonrpc": "2.0",
        "id": _rpc_id,
        "method": method,
        "params": params,
    }).encode()
    req = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    sleep_rpc()
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = json.loads(resp.read().decode())
    except urllib.error.URLError as e:
        fail(f"{label} RPC {method} failed: {e}")
    if body.get("error"):
        err = body["error"]
        fail(f"{label} RPC {method} error: {err}")
    return body.get("result")


def chain_id(url, label):
    return hex_int(rpc(url, "eth_chainId", [], label))


def el_head(url, label):
    return hex_int(rpc(url, "eth_blockNumber", [], label))


def get_block(url, label, n, full_txs=True):
    return rpc(url, "eth_getBlockByNumber", [hex(n), full_txs], label)


def get_receipt(url, label, txh):
    return rpc(url, "eth_getTransactionReceipt", [txh], label)


def get_balance(url, label, addr):
    return norm_hex(rpc(url, "eth_getBalance", [addr, "latest"], label))


def get_storage(url, label, addr, slot):
    return norm_hash(rpc(url, "eth_getStorageAt", [addr, slot, "latest"], label))


def get_codehash(url, label, addr):
    code = rpc(url, "eth_getCode", [addr, "latest"], label) or "0x"
    raw = code[2:] if isinstance(code, str) and code.startswith("0x") else ""
    try:
        blob = bytes.fromhex(raw) if raw else b""
    except ValueError:
        fail(f"{label} eth_getCode for {addr} is not hex")
    return "0x" + hashlib.sha256(blob).hexdigest()


def safe_head(node_url, label):
    st = rpc(node_url, "optimism_syncStatus", [], label)
    if not isinstance(st, dict):
        fail(f"{label} optimism_syncStatus did not return an object")
    safe = st.get("safe_l2") or {}
    if isinstance(safe, dict):
        n = hex_int(safe.get("number"))
        h = safe.get("hash")
        origin = safe.get("l1origin") or safe.get("l1_origin") or {}
        origin_n = hex_int(origin.get("number") if isinstance(origin, dict) else None)
        return n, h, origin_n
    n = hex_int(safe)
    return n, None, None


def sample_heights(hi, extra, minimum):
    pins = [0, 5]
    for raw in extra:
        raw = raw.strip()
        if not raw:
            continue
        pins.append(int(raw, 0) if raw.lower().startswith("0x") else int(raw))
    chosen = [p for p in pins if 0 <= p <= hi]
    # Spread remaining slots from genesis to hi, always include hi.
    need = max(minimum, len(chosen))
    if hi not in chosen:
        chosen.append(hi)
    remaining = need - len(set(chosen))
    if remaining > 0 and hi > 0:
        for i in range(1, remaining + 1):
            chosen.append(round(i * hi / (remaining + 1)))
    out = sorted({n for n in chosen if 0 <= n <= hi})
    n = 0
    while len(out) < minimum and n <= hi:
        if n not in out:
            out.append(n)
        n += 1
    return sorted(out)


def block_fields(block):
    if not block:
        return None
    return {
        "number": hex_int(block.get("number")),
        "hash": norm_hash(block.get("hash")),
        "parentHash": norm_hash(block.get("parentHash") or block.get("parent_hash")),
        "stateRoot": norm_hash(block.get("stateRoot") or block.get("state_root")),
        "receiptsRoot": norm_hash(block.get("receiptsRoot") or block.get("receipts_root")),
        "txCount": tx_count(block),
    }


def receipt_fields(rcpt):
    if not rcpt:
        return None
    return {
        "txHash": norm_hash(rcpt.get("transactionHash") or rcpt.get("txHash")),
        "status": norm_hex(rcpt.get("status")),
        "logsBloom": (rcpt.get("logsBloom") or "").lower(),
        "cumulativeGasUsed": norm_hex(rcpt.get("cumulativeGasUsed")),
        "blockNumber": hex_int(rcpt.get("blockNumber")),
    }


def alter_fixture(doc, field):
    allowed = {
        "hash", "parentHash", "stateRoot", "receiptsRoot", "txCount",
        "balance", "storage", "receipt",
    }
    if field not in allowed:
        fail(f"unknown --alter-field {field} (want {'|'.join(sorted(allowed))})", 2)
    cand = json.loads(json.dumps(doc))
    if field in ("hash", "parentHash", "stateRoot", "receiptsRoot"):
        if not cand.get("blocks"):
            fail("fixture has no blocks to alter")
        dead = "0x" + "dd" * 32
        cand["blocks"][0][field] = dead
    elif field == "txCount":
        txs = cand["blocks"][0].setdefault("transactions", [])
        txs.append({"hash": "0x" + "ee" * 32, "type": "0x0"})
    elif field == "balance":
        st = [s for s in cand.get("state", []) if s.get("kind") == "balance"]
        if not st:
            fail("fixture has no balance state to alter")
        st[0]["value"] = "0xdead"
    elif field == "storage":
        st = [s for s in cand.get("state", []) if s.get("kind") == "storage"]
        if not st:
            fail("fixture has no storage state to alter")
        st[0]["value"] = "0x" + "ab" * 32
    elif field == "receipt":
        if not cand.get("receipts"):
            fail("fixture has no receipts to alter")
        cand["receipts"][0]["status"] = "0x0"
    return cand


def mismatch(kind, ident, field, a, b, c=None):
    extra = f" replica={c}" if c is not None else ""
    print(
        f"MISMATCH {kind}={ident} field={field} candidate={a} live={b}{extra}",
        file=sys.stderr,
    )
    sys.exit(1)


def compare_maps(kind, ident, ca, lv, rp, fields):
    for f in fields:
        a, b, c = ca.get(f), lv.get(f), rp.get(f)
        if a != b or a != c:
            mismatch(kind, ident, f, a, b, c)


def load_sources_from_fixture(path):
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
    live = json.loads(json.dumps(doc))
    replica = json.loads(json.dumps(doc))
    candidate = alter_fixture(doc, ALTER) if ALTER else json.loads(json.dumps(doc))
    return candidate, live, replica


def pick_receipt_txs(blocks, want=2):
    found = []
    deposits = []
    for b in blocks:
        n = hex_int(b.get("number"))
        for tx in tx_list(b):
            h = tx_hash_of(tx)
            t = tx_type_of(tx)
            if t == 0x7E:
                deposits.append({"txHash": h, "type": t, "blockNumber": n})
            if h and len(found) < want:
                found.append(h)
        if len(found) >= want and deposits:
            break
    return found, deposits


def fixture_codehash_ok(addr):
    return bool(addr)


def run_fixture():
    cand, live, replica = load_sources_from_fixture(FIXTURE)
    blocks_c = cand.get("blocks") or []
    blocks_l = live.get("blocks") or []
    blocks_r = replica.get("blocks") or []
    if min(len(blocks_c), len(blocks_l), len(blocks_r)) < MIN_BLOCKS:
        fail(
            f"fixture has {len(blocks_c)}/{len(blocks_l)}/{len(blocks_r)} "
            f"blocks; need >= {MIN_BLOCKS}"
        )
    numbers = [hex_int(b.get("number")) for b in blocks_l[:MIN_BLOCKS]]
    if 0 not in numbers or 5 not in numbers:
        fail("fixture must include blocks 0 and 5")
    print(f"fixture samples={len(numbers)} heights={numbers}")
    for i, n in enumerate(numbers):
        fc = block_fields(blocks_c[i])
        fl = block_fields(blocks_l[i])
        fr = block_fields(blocks_r[i])
        if fc is None or fl is None or fr is None:
            fail(f"missing block {n} in fixture")
        compare_maps("block", n, fc, fl, fr,
                     ["number", "hash", "parentHash", "stateRoot", "receiptsRoot", "txCount"])
        print(
            f"  block {n} hash={fc['hash'][:18]}… parent={fc['parentHash'][:18]}… "
            f"state={fc['stateRoot'][:18]}… receipts={fc['receiptsRoot'][:18]}… "
            f"txCount={fc['txCount']} MATCH"
        )

    state_c = cand.get("state") or []
    state_l = live.get("state") or []
    state_r = replica.get("state") or []
    if len(state_c) < 3 or len(state_l) < 3 or len(state_r) < 3:
        fail("fixture must include >=3 state checks (Guestbook + bridge contracts)")
    labels = []
    for i, (sc, sl, sr) in enumerate(zip(state_c, state_l, state_r)):
        kind = sc.get("kind")
        ident = sc.get("label") or sc.get("address") or str(i)
        labels.append(f"{kind}:{ident}")
        if sc.get("kind") != sl.get("kind") or sc.get("kind") != sr.get("kind"):
            mismatch("state", ident, "kind", sc.get("kind"), sl.get("kind"), sr.get("kind"))
        if sc.get("value") != sl.get("value") or sc.get("value") != sr.get("value"):
            mismatch("state", ident, kind or "value", sc.get("value"), sl.get("value"), sr.get("value"))
        print(f"  state {ident} {kind}={sc.get('value')} MATCH")
    if not any("guestbook" in x.lower() for x in labels):
        fail("fixture state checks must include Guestbook")
    if not any("bridge" in x.lower() for x in labels):
        fail("fixture state checks must include a bridge contract")

    rc_c = [receipt_fields(x) for x in (cand.get("receipts") or [])]
    rc_l = [receipt_fields(x) for x in (live.get("receipts") or [])]
    rc_r = [receipt_fields(x) for x in (replica.get("receipts") or [])]
    if min(len(rc_c), len(rc_l), len(rc_r)) < 2:
        fail("fixture must include >=2 receipts")
    for i in range(2):
        compare_maps("receipt", rc_l[i]["txHash"], rc_c[i], rc_l[i], rc_r[i],
                     ["txHash", "status", "logsBloom", "cumulativeGasUsed", "blockNumber"])
        print(f"  receipt {rc_l[i]['txHash'][:18]}… status={rc_l[i]['status']} MATCH")

    dep_c = cand.get("deposits") or []
    dep_l = live.get("deposits") or []
    dep_r = replica.get("deposits") or []
    if min(len(dep_c), len(dep_l), len(dep_r)) < 1:
        fail("fixture must include >=1 deposit tx (type 0x7e)")
    if (dep_c[0].get("txHash") != dep_l[0].get("txHash")
            or dep_c[0].get("txHash") != dep_r[0].get("txHash")):
        mismatch("deposit", 0, "txHash",
                 dep_c[0].get("txHash"), dep_l[0].get("txHash"), dep_r[0].get("txHash"))
    print(f"  deposit {dep_l[0].get('txHash')} type=0x7e MATCH")

    print("full-match: candidate = live sequencer = replica")
    print("verify-reth-parity: PASS")


def run_live():
    extra = [x for x in BLOCKS_CSV.split(",") if x.strip()] if BLOCKS_CSV else []
    cid_c = chain_id(CAND, "candidate")
    cid_l = chain_id(LIVE, "live")
    cid_r = chain_id(REPL, "replica")
    if cid_c != 852 or cid_l != 852 or cid_r != 852:
        fail(f"chain id mismatch candidate={cid_c} live={cid_l} replica={cid_r} (want 852)")

    safe_c, safe_c_hash, origin_c = safe_head(CNODE, "candidate-node")
    safe_l, safe_l_hash, origin_l = safe_head(LNODE, "live-node")
    head_r = el_head(REPL, "replica")
    head_c = el_head(CAND, "candidate")
    head_l = el_head(LIVE, "live")
    print(
        f"heads candidate_el={head_c} live_el={head_l} replica_el={head_r} "
        f"candidate_safe={safe_c} live_safe={safe_l} "
        f"candidate_l1origin={origin_c} live_l1origin={origin_l}"
    )
    if safe_c is None or safe_l is None:
        fail("could not read safe heads from op-node")
    # Replica is L1-derived; its EL tip is the highest block we can compare there.
    hi = min(safe_c, safe_l, head_r)
    if hi < 5:
        fail(f"overlap high-water {hi} is below block 5; sidecar has not derived far enough")
    heights = sample_heights(hi, extra, MIN_BLOCKS)
    if len(heights) < MIN_BLOCKS:
        fail(
            f"overlap high-water {hi} yields {len(heights)} samples; need >= {MIN_BLOCKS} "
            "(sidecar still catching up)"
        )
    if 0 not in heights or 5 not in heights:
        fail(f"sample list must include 0 and 5 (got {heights})")
    print(f"samples={len(heights)} heights={heights}")

    blocks = {"candidate": [], "live": [], "replica": []}
    for n in heights:
        bc = get_block(CAND, "candidate", n, True)
        bl = get_block(LIVE, "live", n, True)
        br = get_block(REPL, "replica", n, True)
        fc, fl, fr = block_fields(bc), block_fields(bl), block_fields(br)
        if fc is None or fl is None or fr is None:
            fail(f"missing block {n} on one source (candidate/live/replica)")
        compare_maps("block", n, fc, fl, fr,
                     ["number", "hash", "parentHash", "stateRoot", "receiptsRoot", "txCount"])
        print(
            f"  block {n} hash={fc['hash']} parent={fc['parentHash']} "
            f"state={fc['stateRoot']} receipts={fc['receiptsRoot']} "
            f"txCount={fc['txCount']} MATCH"
        )
        blocks["candidate"].append(bc)
        blocks["live"].append(bl)
        blocks["replica"].append(br)

    # State spot-checks: Guestbook (if code present) + bridge + withdrawal passer nonce.
    gb = norm_addr(GUESTBOOK)
    gb_code_live = rpc(LIVE, "eth_getCode", [gb, "latest"], "live") if gb else "0x"
    have_gb = bool(gb) and gb_code_live not in (None, "", "0x")

    checks = [
        ("balance", L2_BRIDGE, None, "L2StandardBridge"),
        ("storage", L2_PASSER, PASSER_NONCE_SLOT, "L2ToL1MessagePasser.messageNonce"),
    ]
    if have_gb:
        checks.insert(0, ("codehash", gb, None, "Guestbook"))
        checks.append(("storage", gb, "0x0", "Guestbook._entries.length"))
    else:
        print("WARN: no Guestbook code at configured address; using WETH codehash instead")
        checks.insert(0, ("codehash", L2_WETH, None, "WETH"))
        checks.append(("balance", L2_WETH, None, "WETH.balance"))
    # Keep a dedicated withdrawal-related check even if Guestbook filled the quota.
    if not any(c[3].startswith("L2ToL1MessagePasser") for c in checks):
        checks.append(("storage", L2_PASSER, PASSER_NONCE_SLOT, "L2ToL1MessagePasser.messageNonce"))

    seen = set()
    uniq = []
    for c in checks:
        if c[3] in seen:
            continue
        seen.add(c[3])
        uniq.append(c)
    if len(uniq) < 3:
        fail("need >=3 state checks")
    print(f"state checks={len(uniq)}")
    for kind, addr, slot, label in uniq:
        if kind == "balance":
            a, b, c = get_balance(CAND, "candidate", addr), get_balance(LIVE, "live", addr), get_balance(REPL, "replica", addr)
        elif kind == "storage":
            a, b, c = get_storage(CAND, "candidate", addr, slot), get_storage(LIVE, "live", addr, slot), get_storage(REPL, "replica", addr, slot)
        elif kind == "codehash":
            a, b, c = get_codehash(CAND, "candidate", addr), get_codehash(LIVE, "live", addr), get_codehash(REPL, "replica", addr)
        else:
            fail(f"unknown state kind {kind}")
        if a != b or a != c:
            mismatch("state", label, kind, a, b, c)
        print(f"  state {label} {kind}={a} MATCH")

    receipt_hashes, deposits = pick_receipt_txs(blocks["live"], want=2)
    if len(receipt_hashes) < 2:
        fail("could not find >=2 transactions for receipt compare")
    if not deposits:
        fail("could not find a deposit tx (type 0x7e) in sampled blocks")
    for txh in receipt_hashes[:2]:
        rc = receipt_fields(get_receipt(CAND, "candidate", txh))
        rl = receipt_fields(get_receipt(LIVE, "live", txh))
        rr = receipt_fields(get_receipt(REPL, "replica", txh))
        compare_maps("receipt", txh, rc, rl, rr,
                     ["txHash", "status", "logsBloom", "cumulativeGasUsed", "blockNumber"])
        print(f"  receipt {txh} status={rl['status']} MATCH")

    dep = deposits[0]
    # Confirm the same deposit tx hash exists in candidate + replica sampled blocks.
    dep_hash = dep["txHash"]
    def has_tx(block_list, h):
        for b in block_list:
            for tx in tx_list(b):
                if tx_hash_of(tx) == h:
                    return True
        return False
    if not has_tx(blocks["candidate"], dep_hash) or not has_tx(blocks["replica"], dep_hash):
        mismatch("deposit", dep.get("blockNumber"), "txHash",
                 dep_hash if has_tx(blocks["candidate"], dep_hash) else None,
                 dep_hash,
                 dep_hash if has_tx(blocks["replica"], dep_hash) else None)
    print(f"  deposit {dep_hash} type=0x7e block={dep['blockNumber']} MATCH")
    print(
        f"  withdrawal-related L2ToL1MessagePasser.messageNonce compared above"
    )

    print("full-match: candidate = live sequencer = replica")
    print(f"verify-reth-parity: PASS ({len(heights)} blocks)")


if FIXTURE:
    run_fixture()
else:
    run_live()
PY
