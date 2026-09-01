#!/usr/bin/env bash
# Task 4: output-root compare + SafeDB + historical eth_getProof against the
# op-reth candidate (sequencer_faultproof). Live :9545 is READ-ONLY eth_*.
# Replica is never queried (diskless prune cannot serve deep history).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
usage: verify-reth-faultproof.sh [options]

Compare proposer output roots, SafeDB safe-heads, and historical eth_getProof
across:

  candidate EL    default http://127.0.0.1:19545  (op-reth sidecar)
  live EL         default http://127.0.0.1:9545   (archive op-geth; loopback)
  candidate node  default http://127.0.0.1:19547
  live node       default http://127.0.0.1:9547

Exit 0 only when every required probe matches. Any mismatch names the field.

  --candidate URL       candidate EL HTTP (loopback)
  --live URL            live sequencer EL HTTP (must be loopback)
  --candidate-node URL  candidate op-node (loopback)
  --live-node URL       live op-node (loopback)
  --game-l2-block N     latest proposed game's L2 block (required live)
  --safedb-enable-l1 N  L1 head when sidecar SafeDB was enabled (required live)
  --pre-enable-l1 N     pre-enable L1 block for the required negative
                        (default: enable-1)
  --min-output-roots N  default 3
  --min-safedb N        default 3
  --min-proofs N        default 3
  --sleep-ms N          pause between live RPC calls (default 400)
  --fixture PATH        offline JSON fixture (no RPC; CI / helper tests)
  --alter-field F       mutate the candidate fixture copy of F before compare
                        (outputRoot|safeHead|proof|preEnable) — must exit nonzero
  -h, --help

Does not print private keys, JWTs, or L1 provider URLs.
Does not query the replica. Does not invoke debug_setHead or admin_*.
EOF
}

CANDIDATE_RPC="${CANDIDATE_RPC:-http://127.0.0.1:19545}"
LIVE_RPC="${LIVE_RPC:-http://127.0.0.1:9545}"
CANDIDATE_NODE_RPC="${CANDIDATE_NODE_RPC:-http://127.0.0.1:19547}"
LIVE_NODE_RPC="${LIVE_NODE_RPC:-http://127.0.0.1:9547}"
GAME_L2_BLOCK=""
SAFEDB_ENABLE_L1=""
PRE_ENABLE_L1=""
MIN_OUTPUT_ROOTS=3
MIN_SAFEDB=3
MIN_PROOFS=3
SLEEP_MS=400
FIXTURE=""
ALTER_FIELD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --candidate) CANDIDATE_RPC="$2"; shift 2 ;;
    --live) LIVE_RPC="$2"; shift 2 ;;
    --candidate-node) CANDIDATE_NODE_RPC="$2"; shift 2 ;;
    --live-node) LIVE_NODE_RPC="$2"; shift 2 ;;
    --game-l2-block) GAME_L2_BLOCK="$2"; shift 2 ;;
    --safedb-enable-l1) SAFEDB_ENABLE_L1="$2"; shift 2 ;;
    --pre-enable-l1) PRE_ENABLE_L1="$2"; shift 2 ;;
    --min-output-roots) MIN_OUTPUT_ROOTS="$2"; shift 2 ;;
    --min-safedb) MIN_SAFEDB="$2"; shift 2 ;;
    --min-proofs) MIN_PROOFS="$2"; shift 2 ;;
    --sleep-ms) SLEEP_MS="$2"; shift 2 ;;
    --fixture) FIXTURE="$2"; shift 2 ;;
    --alter-field) ALTER_FIELD="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for name in MIN_OUTPUT_ROOTS MIN_SAFEDB MIN_PROOFS SLEEP_MS; do
  val="${!name}"
  if ! [[ "$val" =~ ^[0-9]+$ ]]; then
    echo "ERROR: $name must be an integer >= 0" >&2
    exit 2
  fi
done
if (( MIN_OUTPUT_ROOTS < 1 || MIN_SAFEDB < 1 || MIN_PROOFS < 1 )); then
  echo "ERROR: --min-output-roots / --min-safedb / --min-proofs must be >= 1" >&2
  exit 2
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_bin python3
require_bin jq

if [[ -z "$FIXTURE" ]]; then
  assert_loopback_url "$CANDIDATE_RPC" "candidate EL"
  assert_loopback_url "$LIVE_RPC" "live sequencer EL"
  assert_loopback_url "$CANDIDATE_NODE_RPC" "candidate op-node"
  assert_loopback_url "$LIVE_NODE_RPC" "live op-node"
  if [[ -n "$ALTER_FIELD" ]]; then
    echo "ERROR: --alter-field is fixture-only (do not mutate a live compare)" >&2
    exit 2
  fi
  if ! [[ "${GAME_L2_BLOCK:-}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --game-l2-block N is required in live mode (latest proposed game L2 block)" >&2
    exit 2
  fi
  if ! [[ "${SAFEDB_ENABLE_L1:-}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --safedb-enable-l1 N is required in live mode (L1 head at SafeDB enable)" >&2
    exit 2
  fi
  if [[ -n "$PRE_ENABLE_L1" ]] && ! [[ "$PRE_ENABLE_L1" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --pre-enable-l1 must be an integer" >&2
    exit 2
  fi
else
  if [[ ! -f "$FIXTURE" ]]; then
    echo "ERROR: fixture not found: $FIXTURE" >&2
    exit 2
  fi
fi

export FP_CANDIDATE_RPC="$CANDIDATE_RPC"
export FP_LIVE_RPC="$LIVE_RPC"
export FP_CANDIDATE_NODE_RPC="$CANDIDATE_NODE_RPC"
export FP_LIVE_NODE_RPC="$LIVE_NODE_RPC"
export FP_GAME_L2_BLOCK="$GAME_L2_BLOCK"
export FP_SAFEDB_ENABLE_L1="$SAFEDB_ENABLE_L1"
export FP_PRE_ENABLE_L1="$PRE_ENABLE_L1"
export FP_MIN_OUTPUT_ROOTS="$MIN_OUTPUT_ROOTS"
export FP_MIN_SAFEDB="$MIN_SAFEDB"
export FP_MIN_PROOFS="$MIN_PROOFS"
export FP_SLEEP_MS="$SLEEP_MS"
export FP_FIXTURE="$FIXTURE"
export FP_ALTER_FIELD="$ALTER_FIELD"

python3 - <<'PY'
import json, os, sys, time, urllib.error, urllib.request

CAND = os.environ["FP_CANDIDATE_RPC"].rstrip("/")
LIVE = os.environ["FP_LIVE_RPC"].rstrip("/")
CNODE = os.environ["FP_CANDIDATE_NODE_RPC"].rstrip("/")
LNODE = os.environ["FP_LIVE_NODE_RPC"].rstrip("/")
GAME_L2 = (os.environ.get("FP_GAME_L2_BLOCK") or "").strip()
ENABLE_L1 = (os.environ.get("FP_SAFEDB_ENABLE_L1") or "").strip()
PRE_L1 = (os.environ.get("FP_PRE_ENABLE_L1") or "").strip()
MIN_ROOTS = int(os.environ["FP_MIN_OUTPUT_ROOTS"])
MIN_SAFEDB = int(os.environ["FP_MIN_SAFEDB"])
MIN_PROOFS = int(os.environ["FP_MIN_PROOFS"])
SLEEP_MS = int(os.environ["FP_SLEEP_MS"])
FIXTURE = os.environ.get("FP_FIXTURE") or ""
ALTER = (os.environ.get("FP_ALTER_FIELD") or "").strip()

L2_BRIDGE = "0x4200000000000000000000000000000000000010"
L2_PASSER = "0x4200000000000000000000000000000000000016"
PASSER_NONCE_SLOT = "0x0000000000000000000000000000000000000000000000000000000000000001"

EL_ETH_METHODS = {
    "eth_chainId",
    "eth_blockNumber",
    "eth_getBlockByNumber",
    "eth_getProof",
}
NODE_METHODS = {
    "optimism_syncStatus",
    "optimism_outputAtBlock",
    "optimism_safeHeadAtL1Block",
}
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


def norm_hash(v):
    if v is None:
        return None
    s = str(v).strip().lower()
    if not s.startswith("0x"):
        s = "0x" + s
    return "0x" + s[2:].zfill(64)


def sleep_rpc():
    if SLEEP_MS > 0:
        time.sleep(SLEEP_MS / 1000.0)


class RpcError(Exception):
    def __init__(self, label, method, err):
        self.label = label
        self.method = method
        self.err = err
        super().__init__(f"{label} RPC {method} error: {err}")


def rpc(url, method, params, label, allow_error=False):
    if method not in ALLOWED:
        fail(f"refusing RPC method {method}")
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
        with urllib.request.urlopen(req, timeout=90) as resp:
            body = json.loads(resp.read().decode())
    except urllib.error.URLError as e:
        fail(f"{label} RPC {method} failed: {e}")
    if body.get("error"):
        if allow_error:
            raise RpcError(label, method, body["error"])
        fail(f"{label} RPC {method} error: {body['error']}")
    return body.get("result")


def mismatch(kind, ident, field, a, b):
    print(
        f"MISMATCH {kind}={ident} field={field} candidate={a} live={b}",
        file=sys.stderr,
    )
    sys.exit(1)


def output_root_of(res):
    if not isinstance(res, dict):
        return None
    return norm_hash(res.get("outputRoot") or res.get("output_root"))


def safe_head_fields(res):
    if not isinstance(res, dict):
        return None
    safe = res.get("safeHead") or res.get("safe_head") or res.get("l2") or res
    if not isinstance(safe, dict):
        return None
    return {
        "number": hex_int(safe.get("number")),
        "hash": norm_hash(safe.get("hash")),
    }


def proof_fields(res):
    if not isinstance(res, dict):
        return None
    keys = res.get("storageProof") or res.get("storage_proof") or []
    return {
        "storageHash": norm_hash(res.get("storageHash") or res.get("storage_hash")),
        "accountProofLen": len(res.get("accountProof") or res.get("account_proof") or []),
        "storageProofLen": len(keys),
        "nonce": str(res.get("nonce") or ""),
    }


def alter_fixture(doc, field):
    allowed = {"outputRoot", "safeHead", "proof", "preEnable"}
    if field not in allowed:
        fail(f"unknown --alter-field {field} (want {'|'.join(sorted(allowed))})", 2)
    cand = json.loads(json.dumps(doc))
    if field == "outputRoot":
        roots = cand.get("outputRoots") or []
        if not roots:
            fail("fixture has no outputRoots to alter")
        roots[0]["outputRoot"] = "0x" + "dd" * 32
    elif field == "safeHead":
        heads = cand.get("safeHeads") or []
        if not heads:
            fail("fixture has no safeHeads to alter")
        heads[0]["l2Hash"] = "0x" + "ee" * 32
    elif field == "proof":
        proofs = cand.get("proofs") or []
        if not proofs:
            fail("fixture has no proofs to alter")
        proofs[0]["storageHash"] = "0x" + "ab" * 32
    elif field == "preEnable":
        # Make the required negative succeed — script must then fail closed.
        cand["preEnableError"] = ""
        cand["preEnableOk"] = True
    return cand


def run_fixture():
    with open(FIXTURE, encoding="utf-8") as f:
        doc = json.load(f)
    live = json.loads(json.dumps(doc))
    cand = alter_fixture(doc, ALTER) if ALTER else json.loads(json.dumps(doc))

    roots_c = cand.get("outputRoots") or []
    roots_l = live.get("outputRoots") or []
    if min(len(roots_c), len(roots_l)) < MIN_ROOTS:
        fail(
            f"fixture has {len(roots_c)}/{len(roots_l)} outputRoots; need >= {MIN_ROOTS}"
        )
    game = hex_int(live.get("gameL2Block"))
    if game is None:
        fail("fixture must include gameL2Block (latest proposed game)")
    game_seen = False
    for i in range(MIN_ROOTS):
        rc, rl = roots_c[i], roots_l[i]
        n = hex_int(rl.get("l2Block"))
        a, b = norm_hash(rc.get("outputRoot")), norm_hash(rl.get("outputRoot"))
        if a != b:
            mismatch("outputRoot", n, "outputRoot", a, b)
        if n == game:
            game_seen = True
        print(f"  outputRoot l2={n} {a} MATCH")
    if not game_seen:
        fail(f"fixture outputRoots must include game L2 block {game}")
    print(f"output-root compare: PASS ({MIN_ROOTS} blocks incl game {game})")

    heads_c = cand.get("safeHeads") or []
    heads_l = live.get("safeHeads") or []
    if min(len(heads_c), len(heads_l)) < MIN_SAFEDB:
        fail(
            f"fixture has {len(heads_c)}/{len(heads_l)} safeHeads; need >= {MIN_SAFEDB}"
        )
    enable = hex_int(live.get("safedbEnableL1"))
    if enable is None:
        fail("fixture must include safedbEnableL1")
    for i in range(MIN_SAFEDB):
        hc, hl = heads_c[i], heads_l[i]
        l1 = hex_int(hl.get("l1Block"))
        if l1 is None or l1 <= enable:
            fail(f"fixture safeHead L1 {l1} must be > safedbEnableL1 {enable}")
        a_n, b_n = hex_int(hc.get("l2Number")), hex_int(hl.get("l2Number"))
        a_h, b_h = norm_hash(hc.get("l2Hash")), norm_hash(hl.get("l2Hash"))
        if a_n != b_n:
            mismatch("safeHead", l1, "l2Number", a_n, b_n)
        if a_h != b_h:
            mismatch("safeHead", l1, "l2Hash", a_h, b_h)
        print(f"  safeHead l1={l1} l2={a_n} {a_h} MATCH")
    print(f"SafeDB post-enable: PASS ({MIN_SAFEDB} L1 blocks after {enable})")

    pre = hex_int(live.get("preEnableL1"))
    if pre is None or pre >= enable:
        fail("fixture preEnableL1 must be < safedbEnableL1")
    pre_err = (cand.get("preEnableError") or "").strip()
    pre_ok = bool(cand.get("preEnableOk"))
    if pre_ok or not pre_err:
        fail(
            f"required SafeDB pre-enable negative did not fail "
            f"(l1={pre} enable={enable})"
        )
    print(f"SafeDB pre-enable negative: l1={pre} error={pre_err}")

    proofs_c = cand.get("proofs") or []
    proofs_l = live.get("proofs") or []
    if min(len(proofs_c), len(proofs_l)) < MIN_PROOFS:
        fail(f"fixture has {len(proofs_c)}/{len(proofs_l)} proofs; need >= {MIN_PROOFS}")
    for i in range(MIN_PROOFS):
        pc, pl = proofs_c[i], proofs_l[i]
        ident = f"{pl.get('block')}:{pl.get('address')}"
        a, b = norm_hash(pc.get("storageHash")), norm_hash(pl.get("storageHash"))
        if a != b:
            mismatch("proof", ident, "storageHash", a, b)
        print(f"  proof {ident} storageHash={a} MATCH")
    print(f"historical eth_getProof: PASS ({MIN_PROOFS} depths)")
    print("verify-reth-faultproof: PASS")


def chain_id(url, label):
    return hex_int(rpc(url, "eth_chainId", [], label))


def el_head(url, label):
    return hex_int(rpc(url, "eth_blockNumber", [], label))


def sync_safe(node_url, label):
    st = rpc(node_url, "optimism_syncStatus", [], label)
    if not isinstance(st, dict):
        fail(f"{label} optimism_syncStatus did not return an object")
    safe = st.get("safe_l2") or {}
    n = hex_int(safe.get("number") if isinstance(safe, dict) else safe)
    origin = safe.get("l1origin") or safe.get("l1_origin") or {}
    origin_n = hex_int(origin.get("number") if isinstance(origin, dict) else None)
    return n, origin_n


def pick_output_blocks(hi, game):
    blocks = [game]
    if hi > 0 and hi != game:
        blocks.append(hi)
    mid = hi // 2
    if mid not in blocks and mid > 0:
        blocks.append(mid)
    # Fill with earlier unique heights if still short.
    n = max(hi - 1, 0)
    while len(blocks) < MIN_ROOTS and n >= 0:
        if n not in blocks:
            blocks.append(n)
        n -= max(hi // (MIN_ROOTS + 1), 1)
        if n < 0:
            break
    out = sorted({b for b in blocks if 0 <= b <= hi})
    if game not in out:
        fail(f"game L2 block {game} is above overlap high-water {hi}")
    if len(out) < MIN_ROOTS:
        fail(f"only {len(out)} output-root heights available (need >= {MIN_ROOTS})")
    return out[: max(MIN_ROOTS, len(out))]


def pick_safedb_l1(enable, origin_c, origin_l):
    hi = min(x for x in (origin_c, origin_l) if x is not None) if origin_c or origin_l else None
    if hi is None:
        fail("could not read L1 origins from op-node sync status")
    if hi <= enable:
        fail(
            f"SafeDB enable L1 {enable} is not behind current origin {hi}; "
            "no post-enable L1 heads to query yet"
        )
    span = hi - enable
    picks = []
    for i in range(1, MIN_SAFEDB + 1):
        n = enable + max(1, round(i * span / (MIN_SAFEDB + 1)))
        if n > hi:
            n = hi - (MIN_SAFEDB - i)
        if n > enable:
            picks.append(n)
    if hi not in picks:
        picks.append(hi)
    out = sorted({n for n in picks if enable < n <= hi})
    if len(out) < MIN_SAFEDB:
        fail(
            f"only {len(out)} L1 blocks after SafeDB enable {enable} "
            f"(origin {hi}); need >= {MIN_SAFEDB}"
        )
    return out[:MIN_SAFEDB] if len(out) > MIN_SAFEDB else out


def pick_proof_heights(hi):
    # Depths the replica cannot serve (latest−256 fails). Near-genesis + deep.
    wanted = [5, max(hi - 1000, 5), max(hi - 100000, 5)]
    if hi >= 1 and 1 not in wanted:
        # Prefer a true near-genesis probe when 5 is also in the deep set.
        if wanted.count(5) > 1:
            wanted[wanted.index(5)] = 1
    out = []
    for n in wanted:
        if 0 < n <= hi and n not in out:
            out.append(n)
    if len(out) < MIN_PROOFS:
        # Spread additional distinct heights downward from hi.
        n = max(hi - 256, 1)
        while len(out) < MIN_PROOFS and n >= 1:
            if n not in out:
                out.append(n)
            n = max(n // 2, 1)
            if n == 1 and 1 in out:
                break
    if len(out) < MIN_PROOFS:
        fail(f"only {len(out)} proof heights available (need >= {MIN_PROOFS})")
    return out[:MIN_PROOFS]


def run_live():
    game = int(GAME_L2)
    enable = int(ENABLE_L1)
    pre = int(PRE_L1) if PRE_L1 else enable - 1
    if pre < 0 or pre >= enable:
        fail(f"pre-enable L1 {pre} must be >= 0 and < enable {enable}")

    cid_c = chain_id(CAND, "candidate")
    cid_l = chain_id(LIVE, "live")
    if cid_c != 852 or cid_l != 852:
        fail(f"chain id mismatch candidate={cid_c} live={cid_l} (want 852)")

    safe_c, origin_c = sync_safe(CNODE, "candidate-node")
    safe_l, origin_l = sync_safe(LNODE, "live-node")
    head_c = el_head(CAND, "candidate")
    head_l = el_head(LIVE, "live")
    print(
        f"heads candidate_el={head_c} live_el={head_l} "
        f"candidate_safe={safe_c} live_safe={safe_l} "
        f"candidate_l1origin={origin_c} live_l1origin={origin_l} "
        f"game_l2={game} safedb_enable_l1={enable}"
    )
    if safe_c is None or safe_l is None:
        fail("could not read safe heads from op-node")
    hi = min(safe_c, safe_l, head_c, head_l)
    if hi < 5:
        fail(f"overlap high-water {hi} is below block 5")

    # --- output roots (op-node; never live EL) ---
    blocks = pick_output_blocks(hi, game)
    print(f"output-root blocks={blocks}")
    for n in blocks:
        tag = hex(n)
        rc = rpc(CNODE, "optimism_outputAtBlock", [tag], "candidate-node")
        rl = rpc(LNODE, "optimism_outputAtBlock", [tag], "live-node")
        a, b = output_root_of(rc), output_root_of(rl)
        if a is None or b is None:
            fail(f"missing outputRoot at L2 {n}")
        if a != b:
            mismatch("outputRoot", n, "outputRoot", a, b)
        print(f"  outputRoot l2={n} {a} MATCH")
    print(f"output-root compare: PASS ({len(blocks)} blocks incl game {game})")

    # --- SafeDB post-enable ---
    l1s = pick_safedb_l1(enable, origin_c, origin_l)
    print(f"SafeDB post-enable l1={l1s}")
    for l1 in l1s:
        tag = hex(l1)
        try:
            rc = rpc(CNODE, "optimism_safeHeadAtL1Block", [tag], "candidate-node")
        except Exception as e:
            fail(f"SafeDB post-enable query failed at L1 {l1}: {e}")
        # Live op-node SafeDB is not in scope for this compare (Task 5).
        # Candidate must answer; cross-check the returned L2 hash against the
        # live archive geth block at that height.
        fields = safe_head_fields(rc)
        if not fields or fields["number"] is None or not fields["hash"]:
            fail(f"SafeDB returned empty safe head at L1 {l1}: {rc}")
        blk = rpc(LIVE, "eth_getBlockByNumber", [hex(fields["number"]), False], "live")
        live_hash = norm_hash((blk or {}).get("hash"))
        if live_hash != fields["hash"]:
            mismatch("safeHead", l1, "l2Hash", fields["hash"], live_hash)
        print(
            f"  safeHead l1={l1} l2={fields['number']} {fields['hash']} "
            f"matches live archive block MATCH"
        )
    print(f"SafeDB post-enable: PASS ({len(l1s)} L1 blocks after {enable})")

    # --- required pre-enable negative ---
    print(f"SafeDB pre-enable negative query l1={pre} (enable={enable})")
    try:
        unexpected = rpc(
            CNODE,
            "optimism_safeHeadAtL1Block",
            [hex(pre)],
            "candidate-node",
            allow_error=True,
        )
        fail(
            f"required SafeDB pre-enable negative did not fail "
            f"(l1={pre} enable={enable} result={unexpected})"
        )
    except RpcError as e:
        print(f"SafeDB pre-enable negative: l1={pre} error={e.err}")

    # --- historical proofs vs live archive geth ---
    heights = pick_proof_heights(hi)
    addrs = [L2_PASSER, L2_BRIDGE]
    print(f"historical eth_getProof heights={heights} accounts={addrs}")
    compared = 0
    for n in heights:
        tag = hex(n)
        addr = addrs[compared % len(addrs)]
        keys = [PASSER_NONCE_SLOT] if addr == L2_PASSER else []
        pc = rpc(CAND, "eth_getProof", [addr, keys, tag], "candidate")
        pl = rpc(LIVE, "eth_getProof", [addr, keys, tag], "live")
        fc, fl = proof_fields(pc), proof_fields(pl)
        if fc is None or fl is None:
            fail(f"missing eth_getProof at block {n} addr {addr}")
        if fc["storageHash"] != fl["storageHash"]:
            mismatch("proof", f"{n}:{addr}", "storageHash", fc["storageHash"], fl["storageHash"])
        if fc["accountProofLen"] < 1 or fl["accountProofLen"] < 1:
            fail(f"eth_getProof at {n}:{addr} returned empty accountProof")
        print(
            f"  proof block={n} addr={addr} storageHash={fc['storageHash']} "
            f"accountProofLen={fc['accountProofLen']} MATCH"
        )
        compared += 1
    if compared < MIN_PROOFS:
        fail(f"compared {compared} proofs; need >= {MIN_PROOFS}")
    print(f"historical eth_getProof: PASS ({compared} depths vs live archive geth)")
    print("verify-reth-faultproof: PASS")


if FIXTURE:
    run_fixture()
else:
    run_live()
PY
