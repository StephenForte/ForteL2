#!/usr/bin/env bash
# Recover type-1 dispute-game bonds from DelayedWETH on Sepolia L2 852.
#
# Automates the R-13 sequence per game, checking on-chain state before every
# send so an interrupted run (the expected case — two mandatory waits) can be
# resumed without re-sending:
#
#   resolveClaim(0,0) → resolve() → [wait disputeGameFinalityDelaySeconds]
#     → claimCredit(recipient)   # closeGame + unlock
#     → [wait DelayedWETH.delay()]
#     → claimCredit(recipient)   # withdraw
#
# Dry-run is the default. --execute is required to broadcast, same shape as
# --force-full-deploy elsewhere. Resolution is permissionless; this script
# signs with ADMIN so it never shares a nonce with the hourly proposer.
# claimCredit's recipient is always PROPOSER_ADDRESS — the 0.08 ETH lands
# there regardless of who pays gas.
#
#   FORTEL2_ENV=.env.sepolia ./scripts/resolve-games-sepolia.sh
#   FORTEL2_ENV=.env.sepolia ./scripts/resolve-games-sepolia.sh --execute --max-games 1
#   RESOLVE_GAMES_SNAPSHOT=/tmp/snap.json ./scripts/resolve-games-sepolia.sh --analyze-only
#
# Exit 0: plan computed (dry-run) or every attempted send confirmed.
# Exit 1: usage / env / I/O / a send failed or state did not advance.
#
# Offline path (--analyze-only) is pure python3 over a snapshot JSON; no
# network, cast, or Sepolia env. Wei math is in python3 (values exceed bash
# integers). macOS bash 3.2 compatible.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
Usage: resolve-games-sepolia.sh [--analyze-only] [--execute] [--max-games N]

  Default (no --execute): fetch every factory game, report what *would* be
                          sent, and send nothing. An invocation with no
                          arguments never moves funds.

  --analyze-only  Skip fetch; compute the plan from RESOLVE_GAMES_SNAPSHOT
                  only. No network, cast, or Sepolia env required.
  --execute       Broadcast the currently-ready legs. Typed deliberately.
                  Incompatible with --analyze-only.
  --max-games N   Act on (or report) at most N games that still have
                  remaining recovery work. Games already fully claimed or
                  with an unexpired clock do not count toward N.

Env:
  RESOLVE_GAMES_SNAPSHOT  Snapshot JSON path (--analyze-only requires this)
  FORTEL2_ENV             Must be .env.sepolia for the live path
EOF
}

ANALYZE_ONLY=0
EXECUTE=0
MAX_GAMES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --analyze-only) ANALYZE_ONLY=1; shift ;;
    --execute) EXECUTE=1; shift ;;
    --max-games)
      if [[ $# -lt 2 || -z "${2:-}" || "$2" == -* ]]; then
        echo "ERROR: --max-games requires a non-negative integer" >&2
        usage >&2
        exit 1
      fi
      MAX_GAMES="$2"
      shift 2
      ;;
    --max-games=*)
      MAX_GAMES="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -n "$MAX_GAMES" ]]; then
  case "$MAX_GAMES" in
    ''|*[!0-9]*)
      echo "ERROR: --max-games requires a non-negative integer (got $MAX_GAMES)" >&2
      exit 1
      ;;
  esac
fi

if [[ "$ANALYZE_ONLY" -eq 1 && "$EXECUTE" -eq 1 ]]; then
  echo "ERROR: --execute is incompatible with --analyze-only" >&2
  exit 1
fi

require_bin python3

# Embedded planner. Subcommands: analyze | fetch | fetch-one
# Never sees a private key. Live fetch uses cast call only.
resolve_games_py() {
  python3 - "$@" <<'PY'
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

WEI = 10 ** 18
GAS_UNITS = {
    "resolveClaim": 110900,
    "resolve": 37267,
    "claimCredit_unlock": 249913,
    "claimCredit_withdraw": 89233,
}
# R-13 measured costs, used when the snapshot has no gas_price_wei.
ETH_COST_WEI = {
    "resolveClaim": 119950252342500,
    "resolve": 35053356821082,
    "claimCredit_unlock": 258970920746248,
    "claimCredit_withdraw": 98103478525650,
}


def parse_uint(s):
    if s is None:
        return 0
    if isinstance(s, int):
        return s
    s = str(s).strip().split()[0]
    if not s:
        return 0
    if s.startswith("0x") or s.startswith("0X"):
        return int(s, 16)
    return int(s)


def parse_addr(s):
    s = str(s).strip().split()[0]
    return s


def fmt_eth(wei):
    wei = int(wei)
    sign = ""
    if wei < 0:
        sign = "-"
        wei = -wei
    whole = wei // WEI
    frac = wei % WEI
    return "%s%d.%018d" % (sign, whole, frac)


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def decide_game(game, now, finality_delay, weth_delay):
    """Return disposition for one game. Never infers a claimCredit leg by call count."""
    idx = int(game["index"])
    # Missing game_type (offline fixtures) defaults to 1; a live fetch always sets it.
    raw_type = game.get("game_type", 1)
    try:
        game_type = int(raw_type)
    except (TypeError, ValueError):
        game_type = 1
    if game_type != 1:
        return {
            "index": idx,
            "selected": False,
            "disposition": "skip",
            "reason": "not_type_1",
            "actions": [],
            "ready_at": None,
        }
    status = int(game["status"])
    resolved_at = parse_uint(game.get("resolved_at", 0))
    created_at = parse_uint(game.get("created_at", 0))
    max_clock = parse_uint(game.get("max_clock_duration", 0))
    credit = parse_uint(game.get("credit_wei", 0))
    claim_len = int(game.get("claim_data_len", 0))
    weth_amount = parse_uint(game.get("weth_amount_wei", 0))
    weth_ts = parse_uint(game.get("weth_unlock_ts", 0))

    finalized = status in (1, 2) and resolved_at > 0 and now >= resolved_at + finality_delay
    clock_expired = max_clock > 0 and now >= created_at + max_clock

    if claim_len != 1:
        return {
            "index": idx,
            "selected": False,
            "disposition": "skip",
            "reason": "multi_claim",
            "actions": [],
            "ready_at": None,
        }

    if status == 1:
        return {
            "index": idx,
            "selected": False,
            "disposition": "skip",
            "reason": "challenger_wins",
            "actions": [],
            "ready_at": None,
        }

    if status == 2 and credit == 0 and weth_amount == 0:
        return {
            "index": idx,
            "selected": False,
            "disposition": "skip",
            "reason": "zero_credit",
            "actions": [],
            "ready_at": None,
        }

    if status == 0 and not clock_expired:
        return {
            "index": idx,
            "selected": False,
            "disposition": "skip",
            "reason": "clock_unexpired",
            "actions": [],
            "ready_at": created_at + max_clock,
        }

    if status not in (0, 2):
        return {
            "index": idx,
            "selected": False,
            "disposition": "skip",
            "reason": "unknown_status",
            "actions": [],
            "ready_at": None,
        }

    actions = []
    reason = None
    ready_at = None
    disposition = "action"

    if status == 0:
        if credit == 0:
            actions.append("resolveClaim")
        actions.append("resolve")
        reason = "resolve"
    else:
        # status == 2: never re-resolve. Distinguish the two claimCredit legs
        # by DelayedWETH withdrawals(), not by how many times we have called.
        if not finalized:
            disposition = "wait"
            reason = "finality"
            ready_at = resolved_at + finality_delay
        elif weth_amount == 0 and weth_ts == 0 and credit > 0:
            actions.append("claimCredit_unlock")
            reason = "unlock"
        elif weth_amount > 0 and now < weth_ts + weth_delay:
            disposition = "wait"
            reason = "weth_delay"
            ready_at = weth_ts + weth_delay
        elif weth_amount > 0 and now >= weth_ts + weth_delay:
            actions.append("claimCredit_withdraw")
            reason = "withdraw"
        elif credit == 0:
            return {
                "index": idx,
                "selected": False,
                "disposition": "skip",
                "reason": "zero_credit",
                "actions": [],
                "ready_at": None,
            }
        else:
            disposition = "wait"
            reason = "unknown_claim_state"
            ready_at = None

    if disposition == "wait":
        return {
            "index": idx,
            "selected": True,
            "disposition": "wait",
            "reason": reason,
            "actions": [],
            "ready_at": ready_at,
        }

    return {
        "index": idx,
        "selected": True,
        "disposition": "action",
        "reason": reason,
        "actions": actions,
        "ready_at": None,
    }


def remaining_wei(game, init_bond):
    credit = parse_uint(game.get("credit_wei", 0))
    weth_amount = parse_uint(game.get("weth_amount_wei", 0))
    if credit > 0:
        return credit
    if weth_amount > 0:
        return weth_amount
    if int(game.get("status", 0)) == 0:
        return init_bond
    return 0


def action_cost_wei(leg, gas_price_wei):
    if gas_price_wei and gas_price_wei > 0:
        return GAS_UNITS[leg] * gas_price_wei
    return ETH_COST_WEI[leg]


def analyze(snapshot, max_games):
    now = parse_uint(snapshot["now"])
    finality_delay = parse_uint(snapshot["finality_delay"])
    weth_delay = parse_uint(snapshot["weth_delay"])
    init_bond = parse_uint(snapshot.get("init_bond_wei", 0))
    gas_price = parse_uint(snapshot.get("gas_price_wei", 0))
    games = snapshot.get("games", [])

    decisions = []
    for game in games:
        decisions.append((game, decide_game(game, now, finality_delay, weth_delay)))

    candidates = [(g, d) for (g, d) in decisions if d["selected"]]
    if max_games is not None:
        selected = candidates[:max_games]
        overflow = candidates[max_games:]
    else:
        selected = candidates
        overflow = []

    selected_idx = set(d["index"] for (_, d) in selected)
    report = []
    for game, dec in decisions:
        if dec["index"] in selected_idx:
            report.append((game, dec))
        elif dec["selected"]:
            capped = dict(dec)
            capped["selected"] = False
            capped["disposition"] = "skip"
            capped["reason"] = "max_games"
            report.append((game, capped))
        else:
            report.append((game, dec))

    actions = []
    recoverable = 0
    locked_clock = 0
    for game, dec in report:
        if dec["selected"]:
            recoverable += remaining_wei(game, init_bond)
            for leg in dec["actions"]:
                actions.append({"index": dec["index"], "address": game.get("address", ""), "leg": leg})
        elif dec["reason"] == "clock_unexpired":
            locked_clock += remaining_wei(game, init_bond)

    est = 0
    for a in actions:
        est += action_cost_wei(a["leg"], gas_price)

    mode = snapshot.get("mode", "dry-run")
    selected_indexes = [d["index"] for (_, d) in selected]
    wait_count = sum(1 for (_, d) in selected if d["disposition"] == "wait")
    action_count = sum(1 for (_, d) in selected if d["disposition"] == "action")

    print("=== ForteL2 resolve-games (%s) ===" % mode)
    print("mode=%s" % mode)
    print("now=%d finality_delay=%d weth_delay=%d" % (now, finality_delay, weth_delay))
    if max_games is None:
        print("max_games=all")
    else:
        print("max_games=%d" % max_games)
    print("game_count=%d" % len(games))
    print("selected_count=%d" % len(selected))
    print("selected_indexes=%s" % (",".join(str(i) for i in selected_indexes) if selected_indexes else ""))
    print("action_games=%d wait_games=%d" % (action_count, wait_count))
    print("actions_ready=%d" % len(actions))
    print("txs_sent=0")
    print("recoverable_eth=%s" % fmt_eth(recoverable))
    print("recoverable_wei=%d" % recoverable)
    print("locked_unexpired_eth=%s" % fmt_eth(locked_clock))
    print("estimated_gas_eth=%s" % fmt_eth(est))
    print("estimated_gas_wei=%d" % est)

    for game, dec in report:
        idx = dec["index"]
        if dec["disposition"] == "skip":
            extra = ""
            if dec["reason"] == "clock_unexpired" and dec["ready_at"] is not None:
                extra = " ready_at=%d age=%d" % (dec["ready_at"], now - parse_uint(game.get("created_at", 0)))
            print("game %d SKIP %s%s" % (idx, dec["reason"], extra))
        elif dec["disposition"] == "wait":
            extra = ""
            if dec["ready_at"] is not None:
                extra = " ready_at=%d ready_in=%d" % (dec["ready_at"], max(0, dec["ready_at"] - now))
            print("game %d WAIT %s%s" % (idx, dec["reason"], extra))
        else:
            print("game %d ACTION %s" % (idx, ",".join(dec["actions"])))

    if overflow:
        print("capped_indexes=%s" % ",".join(str(d["index"]) for (_, d) in overflow))

    plan = {
        "mode": mode,
        "selected_indexes": selected_indexes,
        "actions": actions,
        "recoverable_wei": str(recoverable),
        "estimated_gas_wei": str(est),
        "txs_sent": 0,
        "decisions": [
            {
                "index": d["index"],
                "selected": d["selected"],
                "disposition": d["disposition"],
                "reason": d["reason"],
                "actions": d["actions"],
                "ready_at": d["ready_at"],
            }
            for (_, d) in report
        ],
    }
    print("PLAN_JSON=%s" % json.dumps(plan, separators=(",", ":")))
    return 0


def cast_call(rpc, address, sig, *args):
    cmd = ["cast", "call", address, sig]
    cmd.extend(str(a) for a in args)
    cmd.extend(["--rpc-url", rpc])
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True)
    except subprocess.CalledProcessError:
        raise SystemExit("ERROR: cast call failed for %s (rpc redacted)" % sig)
    lines = []
    for raw in out.splitlines():
        raw = raw.strip()
        if not raw:
            continue
        lines.append(raw.split()[0])
    return lines


def l1_timestamp(rpc):
    try:
        out = subprocess.check_output(
            ["cast", "block", "latest", "--field", "timestamp", "--rpc-url", rpc],
            stderr=subprocess.STDOUT,
            text=True,
        )
    except subprocess.CalledProcessError:
        raise SystemExit("ERROR: cast block latest --field timestamp failed (rpc redacted)")
    ts = parse_uint(out.strip().split()[0] if out.strip() else "0")
    if ts <= 0:
        raise SystemExit("ERROR: L1 latest block timestamp was empty")
    return ts


def fetch_snapshot(out_path, extra):
    rpc = extra["rpc"]
    factory = extra["factory"]
    weth = extra["weth"]
    asr = extra["asr"]
    recipient = extra["recipient"]

    count_lines = cast_call(rpc, factory, "gameCount()(uint256)")
    game_count = parse_uint(count_lines[0])
    now = l1_timestamp(rpc)
    finality = parse_uint(cast_call(rpc, asr, "disputeGameFinalityDelaySeconds()(uint256)")[0])
    weth_delay = parse_uint(cast_call(rpc, weth, "delay()(uint256)")[0])
    init_bond = parse_uint(cast_call(rpc, factory, "initBonds(uint32)(uint256)", 1)[0])
    impl8 = parse_addr(cast_call(rpc, factory, "gameImpls(uint32)(address)", 8)[0])
    impl1 = parse_addr(cast_call(rpc, factory, "gameImpls(uint32)(address)", 1)[0])
    try:
        gas_price = parse_uint(subprocess.check_output(
            ["cast", "gas-price", "--rpc-url", rpc],
            stderr=subprocess.STDOUT, text=True,
        ).strip().split()[0])
    except subprocess.CalledProcessError:
        gas_price = 0

    anchor_game = parse_addr(cast_call(rpc, asr, "anchorGame()(address)")[0])
    anchor = cast_call(rpc, asr, "anchors(uint32)(bytes32,uint256)", 1)
    anchor_root = parse_addr(anchor[0])
    anchor_block = parse_uint(anchor[1]) if len(anchor) > 1 else 0
    respected = parse_uint(cast_call(rpc, asr, "respectedGameType()(uint32)")[0])
    weth_bal = parse_uint(subprocess.check_output(
        ["cast", "balance", weth, "--rpc-url", rpc],
        stderr=subprocess.STDOUT, text=True,
    ).strip().split()[0])

    workers = min(8, max(1, game_count))
    with ThreadPoolExecutor(max_workers=workers) as pool:
        games = list(pool.map(
            lambda i: fetch_one_game(rpc, factory, weth, recipient, i),
            range(game_count),
        ))

    snap = {
        "now": now,
        "mode": extra.get("mode", "dry-run"),
        "finality_delay": finality,
        "weth_delay": weth_delay,
        "recipient": recipient,
        "init_bond_wei": str(init_bond),
        "gas_price_wei": str(gas_price),
        "factory": factory,
        "weth": weth,
        "asr": asr,
        "game_impls_1": impl1,
        "game_impls_8": impl8,
        "anchor_game": anchor_game,
        "anchor_root": anchor_root,
        "anchor_block": anchor_block,
        "respected_game_type": respected,
        "weth_balance_wei": str(weth_bal),
        "game_count": game_count,
        "games": games,
    }
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(snap, f)
        f.write("\n")
    return 0


def fetch_one_game(rpc, factory, weth, recipient, index):
    meta = cast_call(rpc, factory, "gameAtIndex(uint256)(uint32,uint64,address)", index)
    game_type = parse_uint(meta[0])
    created_at = parse_uint(meta[1])
    address = parse_addr(meta[2])
    status = parse_uint(cast_call(rpc, address, "status()(uint8)")[0])
    resolved_at = parse_uint(cast_call(rpc, address, "resolvedAt()(uint64)")[0])
    credit = parse_uint(cast_call(rpc, address, "credit(address)(uint256)", recipient)[0])
    claim_len = parse_uint(cast_call(rpc, address, "claimDataLen()(uint256)")[0])
    max_clock = parse_uint(cast_call(rpc, address, "maxClockDuration()(uint64)")[0])
    wd = cast_call(rpc, weth, "withdrawals(address,address)(uint256,uint256)", address, recipient)
    weth_amount = parse_uint(wd[0])
    weth_ts = parse_uint(wd[1]) if len(wd) > 1 else 0
    return {
        "index": index,
        "address": address,
        "game_type": game_type,
        "created_at": created_at,
        "max_clock_duration": max_clock,
        "status": status,
        "resolved_at": resolved_at,
        "credit_wei": str(credit),
        "claim_data_len": claim_len,
        "weth_amount_wei": str(weth_amount),
        "weth_unlock_ts": weth_ts,
    }


def main(argv):
    if len(argv) < 2:
        raise SystemExit("ERROR: python helper requires a subcommand")
    cmd = argv[1]
    if cmd == "analyze":
        if len(argv) < 3:
            raise SystemExit("ERROR: analyze requires a snapshot path")
        snapshot = load_json(argv[2])
        max_games = None
        if len(argv) >= 4 and argv[3] != "":
            max_games = int(argv[3])
        raise SystemExit(analyze(snapshot, max_games))
    if cmd == "fetch":
        if len(argv) < 3:
            raise SystemExit("ERROR: fetch requires an output path")
        extra = {
            "rpc": os.environ["RESOLVE_GAMES_RPC"],
            "factory": os.environ["RESOLVE_GAMES_FACTORY"],
            "weth": os.environ["RESOLVE_GAMES_WETH"],
            "asr": os.environ["RESOLVE_GAMES_ASR"],
            "recipient": os.environ["RESOLVE_GAMES_RECIPIENT"],
            "mode": os.environ.get("RESOLVE_GAMES_MODE", "dry-run"),
        }
        raise SystemExit(fetch_snapshot(argv[2], extra))
    if cmd == "fetch-one":
        if len(argv) < 3:
            raise SystemExit("ERROR: fetch-one requires an index")
        rpc = os.environ["RESOLVE_GAMES_RPC"]
        factory = os.environ["RESOLVE_GAMES_FACTORY"]
        weth = os.environ["RESOLVE_GAMES_WETH"]
        recipient = os.environ["RESOLVE_GAMES_RECIPIENT"]
        game = fetch_one_game(rpc, factory, weth, recipient, int(argv[2]))
        json.dump(game, sys.stdout)
        sys.stdout.write("\n")
        raise SystemExit(0)
    if cmd == "decide":
        if len(argv) < 3:
            raise SystemExit("ERROR: decide requires a game JSON path")
        game = load_json(argv[2])
        now = parse_uint(os.environ["RESOLVE_GAMES_NOW"])
        finality = parse_uint(os.environ["RESOLVE_GAMES_FINALITY"])
        weth_delay = parse_uint(os.environ["RESOLVE_GAMES_WETH_DELAY"])
        dec = decide_game(game, now, finality, weth_delay)
        json.dump(dec, sys.stdout)
        sys.stdout.write("\n")
        raise SystemExit(0)
    raise SystemExit("ERROR: unknown python subcommand: %s" % cmd)


if __name__ == "__main__":
    main(sys.argv)
PY
}

print_live_header() {
  echo "RPC: $(redact_rpc_url "$L1_RPC_URL")"
  echo "factory: $RESOLVE_GAMES_FACTORY"
  echo "weth: $RESOLVE_GAMES_WETH"
  echo "asr: $RESOLVE_GAMES_ASR"
  echo "recipient: $RESOLVE_GAMES_RECIPIENT (PROPOSER)"
  if [[ "$EXECUTE" -eq 1 ]]; then
    echo "sender: $ADMIN_ADDRESS (ADMIN)"
  fi
}

require_sender_ready() {
  require_eth_address "ADMIN_ADDRESS" "${ADMIN_ADDRESS:-}"
  require_eth_address "PROPOSER_ADDRESS" "${PROPOSER_ADDRESS:-}"
  if [[ -z "${ADMIN_PRIVATE_KEY:-}" || ! "$ADMIN_PRIVATE_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    echo "ERROR: ADMIN_PRIVATE_KEY missing or malformed" >&2
    exit 1
  fi
  refuse_foundry_defaults_unless_local_l2 "$ADMIN_PRIVATE_KEY" "ADMIN_PRIVATE_KEY"

  local derived admin_lc proposer_lc
  derived="$(cast wallet address --private-key "$ADMIN_PRIVATE_KEY")"
  admin_lc="$(printf '%s' "$ADMIN_ADDRESS" | tr '[:upper:]' '[:lower:]')"
  proposer_lc="$(printf '%s' "$PROPOSER_ADDRESS" | tr '[:upper:]' '[:lower:]')"
  derived_lc="$(printf '%s' "$derived" | tr '[:upper:]' '[:lower:]')"
  if [[ "$derived_lc" != "$admin_lc" ]]; then
    echo "ERROR: ADMIN_PRIVATE_KEY does not match ADMIN_ADDRESS" >&2
    echo "  derived:    $derived" >&2
    echo "  configured: $ADMIN_ADDRESS" >&2
    exit 1
  fi
  if [[ "$admin_lc" == "$proposer_lc" ]]; then
    echo "ERROR: ADMIN_ADDRESS equals PROPOSER_ADDRESS; refusing to share the proposer nonce" >&2
    exit 1
  fi
}

send_leg() {
  # Broadcast one permissionless recovery call. Caller must have just
  # re-read state and confirmed this leg is the next ready action.
  local game_addr="$1"
  local leg="$2"
  local recipient="$3"
  local tx_json tx_hash receipt status gas_used gas_price cost

  case "$leg" in
    resolveClaim)
      tx_json="$(
        cast send "$game_addr" 'resolveClaim(uint256,uint256)' 0 0 \
          --private-key "$ADMIN_PRIVATE_KEY" \
          --rpc-url "$L1_RPC_URL" \
          --json
      )"
      ;;
    resolve)
      tx_json="$(
        cast send "$game_addr" 'resolve()' \
          --private-key "$ADMIN_PRIVATE_KEY" \
          --rpc-url "$L1_RPC_URL" \
          --json
      )"
      ;;
    claimCredit_unlock|claimCredit_withdraw)
      tx_json="$(
        cast send "$game_addr" 'claimCredit(address)' "$recipient" \
          --private-key "$ADMIN_PRIVATE_KEY" \
          --rpc-url "$L1_RPC_URL" \
          --json
      )"
      ;;
    *)
      echo "ERROR: unknown leg: $leg" >&2
      exit 1
      ;;
  esac

  tx_hash="$(printf '%s' "$tx_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("transactionHash") or d.get("hash") or "")')"
  if [[ -z "$tx_hash" || "$tx_hash" == "null" ]]; then
    echo "ERROR: send produced no transaction hash for $leg" >&2
    printf '%s\n' "$tx_json" >&2
    exit 1
  fi

  receipt="$(cast receipt "$tx_hash" --rpc-url "$L1_RPC_URL" --json)"
  cost="$(printf '%s' "$receipt" | python3 -c '
import json, sys
r = json.load(sys.stdin)
status = str(r.get("status", ""))
used_raw, price_raw = r.get("gasUsed", 0), r.get("effectiveGasPrice", 0)
used = int(used_raw, 16) if isinstance(used_raw, str) else int(used_raw or 0)
price = int(price_raw, 16) if isinstance(price_raw, str) else int(price_raw or 0)
print("%s %d %d %d" % (status, used, price, used * price))
')"
  status="$(printf '%s' "$cost" | awk '{print $1}')"
  gas_used="$(printf '%s' "$cost" | awk '{print $2}')"
  gas_price="$(printf '%s' "$cost" | awk '{print $3}')"
  local cost_wei
  cost_wei="$(printf '%s' "$cost" | awk '{print $4}')"

  if [[ "$status" != "0x1" && "$status" != "1" ]]; then
    echo "ERROR: $leg reverted tx=$tx_hash status=$status" >&2
    exit 1
  fi

  echo "SENT leg=$leg tx=$tx_hash gasUsed=$gas_used effectiveGasPrice=$gas_price cost_wei=$cost_wei"
}

confirm_leg_advanced() {
  local game_file="$1"
  local leg="$2"
  python3 - "$game_file" "$leg" <<'PY'
import json, sys
g = json.load(open(sys.argv[1], encoding="utf-8"))
leg = sys.argv[2]
status = int(g.get("status", 0))
credit = int(g.get("credit_wei", 0))
weth_amount = int(g.get("weth_amount_wei", 0))
if leg == "resolveClaim" and credit == 0:
    raise SystemExit("ERROR: resolveClaim confirmed but credit is still 0")
if leg == "resolve" and status == 0:
    raise SystemExit("ERROR: resolve confirmed but status is still 0")
if leg == "claimCredit_unlock" and weth_amount == 0:
    raise SystemExit("ERROR: claimCredit unlock confirmed but DelayedWETH amount is still 0")
if leg == "claimCredit_withdraw" and credit != 0:
    raise SystemExit("ERROR: claimCredit withdraw confirmed but credit is still %d" % credit)
PY
}

execute_selected() {
  local snapshot_file="$1"
  local selected_csv="$2"
  local recipient="$3"
  local finality weth_delay
  finality="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("finality_delay",0))' "$snapshot_file")"
  weth_delay="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("weth_delay",0))' "$snapshot_file")"

  if [[ -z "$selected_csv" ]]; then
    echo "EXECUTE: no games selected; sending nothing"
    echo "txs_sent=0"
    return 0
  fi

  local idx game_json dec_json disposition actions_csv leg sent_n cost_sum game_file
  sent_n=0
  cost_sum=0
  export RESOLVE_GAMES_FINALITY="$finality"
  export RESOLVE_GAMES_WETH_DELAY="$weth_delay"
  game_file="$(mktemp "${TMPDIR:-/tmp}/fortel2-resolve-one.XXXXXX")"

  # Split selected_indexes without assigning IFS (Semgrep bash.lang.security.ifs-tampering).
  # awk emits one index per line; the while-read keeps counters in this shell.
  while IFS= read -r idx; do
    [[ -z "$idx" ]] && continue
    echo "--- game $idx ---"
    while true; do
      RESOLVE_GAMES_NOW="$(cast block latest --field timestamp --rpc-url "$L1_RPC_URL" | awk '{print $1}')"
      if [[ -z "$RESOLVE_GAMES_NOW" || "$RESOLVE_GAMES_NOW" == "0" ]]; then
        echo "ERROR: L1 latest block timestamp was empty" >&2
        exit 1
      fi
      export RESOLVE_GAMES_NOW
      game_json="$(resolve_games_py fetch-one "$idx")"
      printf '%s\n' "$game_json" > "$game_file"
      dec_json="$(resolve_games_py decide "$game_file")"
      disposition="$(printf '%s' "$dec_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("disposition",""))')"
      actions_csv="$(printf '%s' "$dec_json" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin).get("actions") or []))')"
      if [[ "$disposition" != "action" || -z "$actions_csv" ]]; then
        echo "game $idx $disposition $(printf '%s' "$dec_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("reason",""))')"
        break
      fi
      leg="${actions_csv%%,*}"
      local game_addr send_out tx_hash cost_wei
      game_addr="$(printf '%s' "$game_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("address",""))')"
      echo "sending game=$idx leg=$leg to=$game_addr"
      send_out="$(send_leg "$game_addr" "$leg" "$recipient")"
      echo "$send_out"
      tx_hash="$(printf '%s' "$send_out" | awk '{for(i=1;i<=NF;i++) if($i ~ /^tx=/){sub(/^tx=/,"",$i); print $i}}')"
      cost_wei="$(printf '%s' "$send_out" | awk '{for(i=1;i<=NF;i++) if($i ~ /^cost_wei=/){sub(/^cost_wei=/,"",$i); print $i}}')"
      sent_n=$((sent_n + 1))
      cost_sum="$(python3 -c 'import sys; print(int(sys.argv[1])+int(sys.argv[2]))' "$cost_sum" "${cost_wei:-0}")"
      game_json="$(resolve_games_py fetch-one "$idx")"
      printf '%s\n' "$game_json" > "$game_file"
      confirm_leg_advanced "$game_file" "$leg"
    done
  done <<EOF
$(printf '%s' "$selected_csv" | awk -F, '{for (i = 1; i <= NF; i++) print $i}')
EOF
  rm -f "$game_file"

  echo "EXECUTE done"
  echo "txs_sent=$sent_n"
  echo "gas_spent_wei=$cost_sum"
  echo "gas_spent_eth=$(python3 -c 'import sys; w=int(sys.argv[1]); print("%d.%018d" % (w//10**18, w%10**18))' "$cost_sum")"
}

# --- analyze-only (offline) ------------------------------------------------
if [[ "$ANALYZE_ONLY" -eq 1 ]]; then
  SNAP="${RESOLVE_GAMES_SNAPSHOT:-}"
  if [[ -z "$SNAP" || ! -f "$SNAP" ]]; then
    echo "ERROR: --analyze-only requires RESOLVE_GAMES_SNAPSHOT pointing at a snapshot JSON" >&2
    exit 1
  fi
  echo "=== ForteL2 resolve-games (analyze-only) ==="
  echo "snapshot: $SNAP"
  resolve_games_py analyze "$SNAP" "$MAX_GAMES"
  exit 0
fi

# --- live path -------------------------------------------------------------
require_bin cast
require_bin jq
require_sepolia_env
warn_if_missing_env_file
require_eth_address "PROPOSER_ADDRESS" "${PROPOSER_ADDRESS:-}"

if [[ "$EXECUTE" -eq 1 ]]; then
  require_sender_ready
fi

DEPLOYMENTS="$(deployments_json_path)"
if [[ ! -f "$DEPLOYMENTS" ]]; then
  echo "ERROR: missing $DEPLOYMENTS — run Phase 2b / post-wipe deploy first" >&2
  exit 1
fi

FACTORY="$(jq -r '.DisputeGameFactoryProxy // .disputeGameFactoryProxy // empty' "$DEPLOYMENTS")"
WETH="$(jq -r '.DelayedWethPermissionedGameProxy // empty' "$DEPLOYMENTS")"
ASR="$(jq -r '.AnchorStateRegistryProxy // empty' "$DEPLOYMENTS")"
require_eth_address "DisputeGameFactoryProxy" "$FACTORY"
require_eth_address "DelayedWethPermissionedGameProxy" "$WETH"
require_eth_address "AnchorStateRegistryProxy" "$ASR"

export RESOLVE_GAMES_RPC="$L1_RPC_URL"
export RESOLVE_GAMES_FACTORY="$FACTORY"
export RESOLVE_GAMES_WETH="$WETH"
export RESOLVE_GAMES_ASR="$ASR"
export RESOLVE_GAMES_RECIPIENT="$PROPOSER_ADDRESS"
if [[ "$EXECUTE" -eq 1 ]]; then
  export RESOLVE_GAMES_MODE="execute"
else
  export RESOLVE_GAMES_MODE="dry-run"
fi

echo "=== ForteL2 resolve-games (live) ==="
print_live_header
echo "PROPOSER_GAME_TYPE=${PROPOSER_GAME_TYPE:-<unset>}"

SNAP="$(mktemp "${TMPDIR:-/tmp}/fortel2-resolve-games.XXXXXX")"
cleanup_snap() { rm -f "$SNAP"; }
trap cleanup_snap EXIT

resolve_games_py fetch "$SNAP"

# Surface the chain facts the operator must record around a run.
python3 - "$SNAP" <<'PY'
import json, sys
WEI = 10 ** 18
s = json.load(open(sys.argv[1]))
weth_wei = int(s.get("weth_balance_wei", 0))
print("gameCount=%s" % s.get("game_count"))
print("weth_balance_eth=%d.%018d" % (weth_wei // WEI, weth_wei % WEI))
print("finality_delay=%s" % s.get("finality_delay"))
print("weth_delay=%s" % s.get("weth_delay"))
print("init_bond_wei=%s" % s.get("init_bond_wei"))
print("gameImpls(1)=%s" % s.get("game_impls_1"))
print("gameImpls(8)=%s" % s.get("game_impls_8"))
print("respectedGameType=%s" % s.get("respected_game_type"))
print("anchorGame=%s" % s.get("anchor_game"))
print("anchor_root=%s" % s.get("anchor_root"))
print("anchor_block=%s" % s.get("anchor_block"))
PY

ANALYZE_OUT="$(resolve_games_py analyze "$SNAP" "$MAX_GAMES")"
printf '%s\n' "$ANALYZE_OUT"

if [[ "$EXECUTE" -eq 0 ]]; then
  echo "dry-run: sending nothing (pass --execute to broadcast)"
  exit 0
fi

SELECTED="$(printf '%s\n' "$ANALYZE_OUT" | awk -F= '/^selected_indexes=/{print $2}')"
echo "EXECUTE: processing selected_indexes=${SELECTED:-<none>}"
execute_selected "$SNAP" "$SELECTED" "$PROPOSER_ADDRESS"
