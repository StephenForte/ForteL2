#!/usr/bin/env bash
# Recover dispute-game bonds of the on-chain respected type from DelayedWETH
# on Sepolia L2 852. The filter reads AnchorStateRegistry.respectedGameType()
# once per run (snapshot field respected_game_type); it does not hardcode 1 or 8.
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
# resolveClaim is skipped when resolvedSubgames(0) is already true — credit
# can still read 0. A ClaimAlreadyResolved revert is treated as already-done
# so the job continues to resolve() instead of exiting 1.
#
# Dry-run is the default. --execute is required to broadcast, same shape as
# --force-full-deploy elsewhere. Resolution is permissionless; this script
# signs with ADMIN so it never shares a nonce with the hourly proposer.
# claimCredit's recipient is always PROPOSER_ADDRESS — the 0.08 ETH lands
# there regardless of who pays gas.
#
#   FORTEL2_ENV=.env.sepolia ./scripts/resolve-games-sepolia.sh
#   FORTEL2_ENV=.env.sepolia ./scripts/resolve-games-sepolia.sh --execute --max-games 1
#   FORTEL2_ENV=.env.sepolia ./scripts/resolve-games-sepolia.sh --full-scan
#   RESOLVE_GAMES_SNAPSHOT=/tmp/snap.json ./scripts/resolve-games-sepolia.sh --analyze-only
#
# Live runs persist a low-water mark at $DATA_DIR/resolve-games-watermark.json
# so each invocation fetches from the lowest non-terminal game, not from 0.
# --full-scan ignores that file and starts at index 0.
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
Usage: resolve-games-sepolia.sh [--analyze-only] [--execute] [--max-games N] [--full-scan]

  Default (no --execute): fetch the in-flight working set, report what
                          *would* be sent, and send nothing. An invocation
                          with no arguments never moves funds.

  --analyze-only  Skip fetch; compute the plan from RESOLVE_GAMES_SNAPSHOT
                  only. No network, cast, or Sepolia env required.
  --execute       Broadcast the currently-ready legs. Typed deliberately.
                  Incompatible with --analyze-only.
  --max-games N   Act on (or report) at most N games that still have
                  remaining recovery work. Games already fully claimed or
                  with an unexpired clock do not count toward N.
  --full-scan     Ignore the persisted watermark and scan from index 0.
                  Use to audit the whole history or recover a corrupted
                  mark without deleting the file.

Env:
  RESOLVE_GAMES_SNAPSHOT   Snapshot JSON path (--analyze-only requires this)
  RESOLVE_GAMES_WATERMARK  Watermark JSON path. Live default:
                           $DATA_DIR/resolve-games-watermark.json.
                           Analyze-only honors this only when set; otherwise
                           it scans the snapshot from 0 and writes nothing.
  RESOLVE_GAMES_MAX_TXS_PER_RUN
                           Cap on transactions actually sent (and on planned
                           action legs in dry-run / analyze-only). Default 5.
                           The hourly launchd agent does not pass --max-games,
                           so this is the first-run money guard: a backlog is
                           drained across hours via the watermark, not in one
                           unattended burst. 0 plans/sends nothing.
  FORTEL2_ENV              Must be .env.sepolia for the live path
EOF
}

ANALYZE_ONLY=0
EXECUTE=0
FULL_SCAN=0
MAX_GAMES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --analyze-only) ANALYZE_ONLY=1; shift ;;
    --execute) EXECUTE=1; shift ;;
    --full-scan) FULL_SCAN=1; shift ;;
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

# --max-games is opt-in and unused by launchd (ProgramArguments is --execute
# only), so it is not a per-run bound. This env cap is. Default 5.
MAX_TXS_PER_RUN="${RESOLVE_GAMES_MAX_TXS_PER_RUN:-5}"
case "$MAX_TXS_PER_RUN" in
  ''|*[!0-9]*)
    echo "ERROR: RESOLVE_GAMES_MAX_TXS_PER_RUN must be a non-negative integer (got $MAX_TXS_PER_RUN)" >&2
    exit 1
    ;;
esac
# Canonical base-10: a value like 08 is digit-valid but bash [[ -ge ]]
# treats it as octal and can skip the cap (Codex P2 on #182).
MAX_TXS_PER_RUN=$((10#$MAX_TXS_PER_RUN))
export RESOLVE_GAMES_MAX_TXS_PER_RUN="$MAX_TXS_PER_RUN"

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
import time
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


def parse_bool(s):
    if isinstance(s, bool):
        return s
    if s is None:
        return False
    if isinstance(s, int):
        return s != 0
    token = str(s).strip().split()[0].lower()
    return token in ("true", "1", "0x1")


def subgame_already_resolved(game):
    """True / False / None. None = field absent (offline fixtures, pre-fetch)."""
    if "resolved_subgame" not in game:
        return None
    return parse_bool(game.get("resolved_subgame"))


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


def parse_optional_type(value):
    """Parse a game type. Return None if missing or unparseable.

    Fail closed: never treat a missing/garbage type as a match. The old
    decide_game defaulted missing game_type to 1 so offline fixtures passed
    a hardcoded type-1 filter; after respectedGameType flipped to 8, that
    same default would select the wrong games for real transactions.
    """
    if value is None:
        return None
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    s = str(value).strip()
    if not s:
        return None
    s = s.split()[0]
    try:
        if s.startswith("0x") or s.startswith("0X"):
            return int(s, 16)
        return int(s)
    except (TypeError, ValueError):
        return None


def snapshot_respected_type(snapshot):
    if not isinstance(snapshot, dict) or "respected_game_type" not in snapshot:
        return None
    return parse_optional_type(snapshot.get("respected_game_type"))


def parse_max_txs():
    raw = os.environ.get("RESOLVE_GAMES_MAX_TXS_PER_RUN")
    if raw is None or str(raw).strip() == "":
        return 5
    try:
        n = int(str(raw).strip().split()[0])
    except (TypeError, ValueError):
        raise SystemExit(
            "ERROR: RESOLVE_GAMES_MAX_TXS_PER_RUN must be a non-negative integer"
        )
    if n < 0:
        raise SystemExit(
            "ERROR: RESOLVE_GAMES_MAX_TXS_PER_RUN must be a non-negative integer"
        )
    return n


def decide_game(game, now, finality_delay, weth_delay, respected_game_type, init_bond=0):
    """Return disposition for one game. Never infers a claimCredit leg by call count.

    init_bond is the snapshot's initBonds(respected) value. Action returns
    include expected_credit_wei = remaining_wei(game, init_bond) so
    confirm_leg_advanced can distinguish a zero-bond resolveClaim (credit
    stays 0, success) from a bonded recovery that produced no credit.
    """
    idx = int(game["index"])
    # Type filter uses the snapshot's respected_game_type (one on-chain read
    # at fetch time). decide_game never calls the chain and never hardcodes
    # 1 or 8. Missing type on the game or snapshot → skip, never select.
    if "game_type" not in game:
        game_type = None
    else:
        game_type = parse_optional_type(game.get("game_type"))
    if game_type is None or respected_game_type is None:
        return {
            "index": idx,
            "selected": False,
            "disposition": "skip",
            "reason": "missing_type",
            "actions": [],
            "ready_at": None,
        }
    if game_type != respected_game_type:
        return {
            "index": idx,
            "selected": False,
            "disposition": "skip",
            "reason": "not_respected_type",
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
        already = subgame_already_resolved(game)
        # credit==0 is not enough: a resolved subgame can still read credit 0
        # (19:00 job: ClaimAlreadyResolved, then resolve() 96s later).
        if already is not True and credit == 0:
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
        "expected_credit_wei": str(remaining_wei(game, init_bond)),
    }


# Terminal for watermark advance: decide()'s skip reasons that mean
# "this game will never need another recovery look."
# zero_credit covers both return sites in decide_game (early status==2
# drain, and the later claim-state branch — they share this reason).
# challenger_wins is also advancing-terminal (a resolved loss will not
# grow proposer credit) but is recorded and reprinted every run so it
# is never walked past silently.
# not_respected_type is terminal because the agent recovers only the
# snapshot's respected type: leftover games of a previous type must
# not pin low_water at the first of them (Bugbot on #182). missing_type
# stays non-terminal so a fetch/parse glitch is retried next hour.
WATERMARK_TERMINAL_REASONS = frozenset(
    ("zero_credit", "challenger_wins", "not_respected_type")
)


def snapshot_game_count(snapshot):
    if snapshot.get("game_count") is not None and snapshot.get("game_count") != "":
        return parse_uint(snapshot["game_count"])
    games = snapshot.get("games") or []
    if not games:
        return 0
    return max(int(g["index"]) for g in games) + 1


def load_watermark(path, game_count, full_scan, factory=""):
    """Return (scan_from, status, record).

    Fail safe: missing / unreadable / malformed / out-of-range /
    factory-mismatch → scan from 0. Never treat a bad file as 'skip everything'.
    """
    empty = {"low_water": 0, "challenger_wins": [], "factory": ""}
    if full_scan:
        return 0, "full_scan", empty
    if not path:
        return 0, "missing", empty
    if not os.path.isfile(path):
        return 0, "missing", empty
    try:
        with open(path, encoding="utf-8") as f:
            raw = f.read()
        data = json.loads(raw)
    except (OSError, UnicodeDecodeError):
        return 0, "unreadable", empty
    except ValueError:
        return 0, "malformed", empty
    if not isinstance(data, dict):
        return 0, "malformed", empty
    mark = data.get("low_water")
    if isinstance(mark, bool) or not isinstance(mark, int):
        return 0, "malformed", empty
    if mark < 0 or mark > game_count:
        return 0, "out_of_range", empty
    rec_factory = str(data.get("factory") or "").strip()
    want = str(factory or "").strip()
    if rec_factory and want and rec_factory.lower() != want.lower():
        return 0, "factory_mismatch", empty
    cw = data.get("challenger_wins") or []
    if not isinstance(cw, list):
        cw = []
    cleaned = []
    for item in cw:
        if isinstance(item, int) and not isinstance(item, bool) and item >= 0:
            cleaned.append(item)
    rec = {"low_water": mark, "challenger_wins": cleaned, "factory": rec_factory}
    return mark, "ok", rec


def is_watermark_terminal(dec):
    return dec.get("disposition") == "skip" and dec.get("reason") in WATERMARK_TERMINAL_REASONS


def next_low_water(scan_from, game_count, decisions_by_idx):
    """Lowest index that is not yet terminal. May equal game_count (all done).

    Stops at the first missing index (fail safe — a hole is not skippable)
    and at any non-terminal disposition, including wait finality / weth_delay.
    """
    idx = scan_from
    while idx < game_count:
        dec = decisions_by_idx.get(idx)
        if dec is None:
            break
        if is_watermark_terminal(dec):
            idx += 1
            continue
        break
    return idx


def save_watermark(path, low_water, challenger_wins, old_mark, status, full_scan, factory=""):
    if not path:
        return True
    parent = os.path.dirname(path)
    if full_scan or status != "ok":
        write_mark = low_water
    else:
        write_mark = max(old_mark, low_water)
    rec = {
        "low_water": int(write_mark),
        "challenger_wins": sorted(set(int(i) for i in challenger_wins)),
        "updated_at": int(os.environ.get("RESOLVE_GAMES_NOW") or 0) or int(time.time()),
        "factory": str(factory or ""),
    }
    tmp = path + ".tmp"
    try:
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(rec, f)
            f.write("\n")
        os.replace(tmp, path)
    except OSError as exc:
        try:
            os.remove(tmp)
        except OSError:
            pass
        print("ERROR: failed to persist watermark (refusing to pretend it was saved): %s" % exc, file=sys.stderr)
        return False
    return True


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
    factory_count = snapshot_game_count(snapshot)
    full_scan = os.environ.get("RESOLVE_GAMES_FULL_SCAN", "") == "1"
    wm_path = os.environ.get("RESOLVE_GAMES_WATERMARK") or ""
    factory = os.environ.get("RESOLVE_GAMES_FACTORY") or snapshot.get("factory") or ""

    # Live fetch stamps scan_from onto the snapshot so analyze sees the same
    # window fetch already paid for. --full-scan and --analyze-only fixtures
    # (no stamp) load the watermark file themselves.
    if (not full_scan) and snapshot.get("scan_from") is not None and snapshot.get("scan_from") != "":
        scan_from = parse_uint(snapshot["scan_from"])
        wm_status = str(snapshot.get("watermark_status") or "ok")
        wm_record = {
            "low_water": scan_from,
            "challenger_wins": snapshot.get("watermark_challenger_wins") or [],
        }
        if not isinstance(wm_record["challenger_wins"], list):
            wm_record["challenger_wins"] = []
    else:
        scan_from, wm_status, wm_record = load_watermark(wm_path, factory_count, full_scan, factory)

    examined = [g for g in games if int(g["index"]) >= scan_from]
    games_examined = len(examined)

    respected = snapshot_respected_type(snapshot)
    max_txs = parse_max_txs()

    decisions = []
    for game in examined:
        decisions.append(
            (game, decide_game(game, now, finality_delay, weth_delay, respected, init_bond))
        )

    candidates = [(g, d) for (g, d) in decisions if d["selected"]]
    if max_games is not None:
        selected = candidates[:max_games]
        overflow = candidates[max_games:]
    else:
        selected = candidates
        overflow = []

    budget = max_txs
    capped_selected = []
    overflow_txs = []
    txs_cap_truncated = False
    remaining_ready = 0
    for g, d in selected:
        if d["disposition"] != "action":
            capped_selected.append((g, d))
            continue
        legs = list(d.get("actions") or [])
        n = len(legs)
        if budget <= 0:
            overflow_txs.append((g, d))
            txs_cap_truncated = True
            remaining_ready += n
            continue
        if n <= budget:
            capped_selected.append((g, d))
            budget -= n
            continue
        partial = dict(d)
        partial["actions"] = legs[:budget]
        remaining_ready += n - budget
        capped_selected.append((g, partial))
        budget = 0
        txs_cap_truncated = True
    selected = capped_selected
    overflow_tx_idx = set(d["index"] for (_, d) in overflow_txs)

    selected_by_idx = {d["index"]: (g, d) for (g, d) in selected}
    report = []
    for game, dec in decisions:
        if dec["index"] in selected_by_idx:
            report.append(selected_by_idx[dec["index"]])
        elif dec["selected"]:
            capped = dict(dec)
            capped["selected"] = False
            capped["disposition"] = "skip"
            if dec["index"] in overflow_tx_idx:
                capped["reason"] = "max_txs"
            else:
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

    decisions_by_idx = {d["index"]: d for (_, d) in report}
    watermark_next = next_low_water(scan_from, factory_count, decisions_by_idx)
    found_cw = [d["index"] for (_, d) in report if d.get("reason") == "challenger_wins"]
    all_cw = list(wm_record.get("challenger_wins") or []) + found_cw

    print("=== ForteL2 resolve-games (%s) ===" % mode)
    print("mode=%s" % mode)
    print("now=%d finality_delay=%d weth_delay=%d" % (now, finality_delay, weth_delay))
    if max_games is None:
        print("max_games=all")
    else:
        print("max_games=%d" % max_games)
    print("respected_game_type=%s" % ("missing" if respected is None else respected))
    print("max_txs=%d" % max_txs)
    print("game_count=%d" % factory_count)
    print("scan_from=%d" % scan_from)
    print("games_examined=%d" % games_examined)
    print("watermark_status=%s" % wm_status)
    if wm_status in ("malformed", "unreadable", "out_of_range", "factory_mismatch"):
        print("watermark_fallback=%s (scanning from 0; refusing to skip)" % wm_status)
    print("watermark_next=%d" % watermark_next)
    if all_cw:
        print("WARN challenger_wins indexes=%s" % ",".join(str(i) for i in sorted(set(int(i) for i in all_cw))))
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
    if txs_cap_truncated:
        print(
            "txs_cap_truncated=1 remaining_ready=%d (remainder next hour)"
            % remaining_ready
        )
    else:
        print("txs_cap_truncated=0")

    plan = {
        "mode": mode,
        "selected_indexes": selected_indexes,
        "actions": actions,
        "recoverable_wei": str(recoverable),
        "estimated_gas_wei": str(est),
        "txs_sent": 0,
        "respected_game_type": respected,
        "max_txs": max_txs,
        "txs_cap_truncated": 1 if txs_cap_truncated else 0,
        "game_count": factory_count,
        "scan_from": scan_from,
        "games_examined": games_examined,
        "watermark_status": wm_status,
        "watermark_next": watermark_next,
        "decisions": [
            {
                "index": d["index"],
                "selected": d["selected"],
                "disposition": d["disposition"],
                "reason": d["reason"],
                "actions": d["actions"],
                "ready_at": d["ready_at"],
                "expected_credit_wei": d.get("expected_credit_wei", "0"),
            }
            for (_, d) in report
        ],
    }
    print("PLAN_JSON=%s" % json.dumps(plan, separators=(",", ":")))
    if wm_path:
        if save_watermark(wm_path, watermark_next, all_cw, scan_from, wm_status, full_scan, factory):
            print("watermark_persist=ok")
        else:
            print("watermark_persist=failed")
            return 1
    else:
        print("watermark_persist=skipped")
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
    respected = parse_uint(cast_call(rpc, asr, "respectedGameType()(uint32)")[0])
    init_bond = parse_uint(cast_call(rpc, factory, "initBonds(uint32)(uint256)", respected)[0])
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
    weth_bal = parse_uint(subprocess.check_output(
        ["cast", "balance", weth, "--rpc-url", rpc],
        stderr=subprocess.STDOUT, text=True,
    ).strip().split()[0])

    full_scan = extra.get("full_scan", False)
    wm_path = extra.get("watermark_path") or ""
    scan_from, wm_status, wm_record = load_watermark(wm_path, game_count, full_scan, factory)
    to_fetch = max(0, game_count - scan_from)
    workers = min(8, max(1, to_fetch))
    if to_fetch == 0:
        games = []
    else:
        with ThreadPoolExecutor(max_workers=workers) as pool:
            games = list(pool.map(
                lambda i: fetch_one_game(rpc, factory, weth, recipient, i),
                range(scan_from, game_count),
            ))

    snap = {
        "now": now,
        "mode": extra.get("mode", "dry-run"),
        "scan_from": scan_from,
        "watermark_status": wm_status,
        "watermark_challenger_wins": wm_record.get("challenger_wins") or [],
        "games_examined": len(games),
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
    resolved_sub = parse_bool(cast_call(rpc, address, "resolvedSubgames(uint256)(bool)", 0)[0])
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
        "resolved_subgame": resolved_sub,
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
            "watermark_path": os.environ.get("RESOLVE_GAMES_WATERMARK") or "",
            "full_scan": os.environ.get("RESOLVE_GAMES_FULL_SCAN", "") == "1",
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
        # Snapshot type, not a per-game RPC. Empty/missing → skip missing_type.
        respected = parse_optional_type(os.environ.get("RESOLVE_GAMES_RESPECTED_TYPE"))
        init_bond = parse_uint(os.environ.get("RESOLVE_GAMES_INIT_BOND", 0))
        dec = decide_game(game, now, finality, weth_delay, respected, init_bond)
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

# Broadcast via cast send --json. Exit 0 with stdout on success; 2 if the
# revert is ClaimAlreadyResolved (idempotent); 1 otherwise (stderr printed).
cast_send_json() {
  local err_file out
  err_file="$(mktemp "${TMPDIR:-/tmp}/fortel2-resolve-send.XXXXXX")"
  if out="$(cast send "$@" --json 2>"$err_file")"; then
    printf '%s' "$out"
    rm -f "$err_file"
    return 0
  fi
  if grep -qE 'ClaimAlreadyResolved|0xf1a94581' "$err_file"; then
    rm -f "$err_file"
    return 2
  fi
  cat "$err_file" >&2
  rm -f "$err_file"
  return 1
}

send_leg() {
  # Broadcast one permissionless recovery call. Caller must have just
  # re-read state and confirmed this leg is the next ready action.
  local game_addr="$1"
  local leg="$2"
  local recipient="$3"
  local tx_json tx_hash receipt status gas_used gas_price cost
  # Offline fixture path (test-helpers). Never used by the hourly agent.
  if [[ -n "${RESOLVE_GAMES_MOCK_DIR:-}" ]]; then
    echo "SENT leg=$leg tx=0xmock gasUsed=1 effectiveGasPrice=1 cost_wei=1"
    return 0
  fi
  local send_rc=0

  case "$leg" in
    resolveClaim)
      tx_json="$(
        cast_send_json "$game_addr" 'resolveClaim(uint256,uint256)' 0 0 \
          --private-key "$ADMIN_PRIVATE_KEY" \
          --rpc-url "$L1_RPC_URL"
      )" || send_rc=$?
      if [[ "$send_rc" -eq 2 ]]; then
        echo "ALREADY leg=$leg"
        return 0
      fi
      if [[ "$send_rc" -ne 0 ]]; then
        echo "ERROR: send produced no transaction hash for $leg" >&2
        exit 1
      fi
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
  # Plan-time remaining_wei for this game (decide_game.expected_credit_wei).
  # Empty/unparseable → fail closed: same fatal as a bonded recovery with
  # credit still 0. Only expected == 0 makes credit == 0 a success.
  local expected="${3:-}"
  python3 - "$game_file" "$leg" "$expected" <<'PY'
import json, sys
g = json.load(open(sys.argv[1], encoding="utf-8"))
leg = sys.argv[2]
expected_raw = sys.argv[3] if len(sys.argv) > 3 else ""
status = int(g.get("status", 0))
credit = int(g.get("credit_wei", 0))
weth_amount = int(g.get("weth_amount_wei", 0))
if leg == "resolveClaim" and credit == 0:
    try:
        expected = int(str(expected_raw).strip()) if str(expected_raw).strip() != "" else None
    except (TypeError, ValueError):
        expected = None
    if expected != 0:
        raise SystemExit("ERROR: resolveClaim confirmed but credit is still 0")
    print("OK resolveClaim confirmed with credit 0 (expected 0; zero-bond)")
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
  local finality weth_delay respected_type max_txs
  finality="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("finality_delay",0))' "$snapshot_file")"
  weth_delay="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("weth_delay",0))' "$snapshot_file")"
  respected_type="$(python3 -c '
import json,sys
s=json.load(open(sys.argv[1], encoding="utf-8"))
v=s.get("respected_game_type", "")
print("" if v is None else v)
' "$snapshot_file")"
  max_txs="${RESOLVE_GAMES_MAX_TXS_PER_RUN:-5}"
  max_txs=$((10#$max_txs))

  if [[ -z "$selected_csv" ]]; then
    echo "EXECUTE: no games selected; sending nothing"
    echo "txs_sent=0"
    return 0
  fi

  local idx game_json dec_json disposition actions_csv leg sent_n cost_sum game_file
  local claim_already init_bond expected_credit
  sent_n=0
  cost_sum=0
  init_bond="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("init_bond_wei",0))' "$snapshot_file")"
  export RESOLVE_GAMES_FINALITY="$finality"
  export RESOLVE_GAMES_WETH_DELAY="$weth_delay"
  export RESOLVE_GAMES_RESPECTED_TYPE="$respected_type"
  export RESOLVE_GAMES_INIT_BOND="$init_bond"
  game_file="$(mktemp "${TMPDIR:-/tmp}/fortel2-resolve-one.XXXXXX")"

  # Split selected_indexes without assigning IFS (Semgrep bash.lang.security.ifs-tampering).
  # awk emits one index per line; the while-read keeps counters in this shell.
  while IFS= read -r idx; do
    [[ -z "$idx" ]] && continue
    echo "--- game $idx ---"
    claim_already=0
    while true; do
      RESOLVE_GAMES_NOW="$(resolve_games_now)"
      if [[ -z "$RESOLVE_GAMES_NOW" || "$RESOLVE_GAMES_NOW" == "0" ]]; then
        echo "ERROR: L1 latest block timestamp was empty" >&2
        exit 1
      fi
      export RESOLVE_GAMES_NOW
      game_json="$(resolve_games_fetch_one "$idx")"
      if [[ "$claim_already" -eq 1 ]]; then
        # Stale RPC can still report resolved_subgame=false after the revert.
        game_json="$(printf '%s' "$game_json" | python3 -c 'import json,sys; g=json.load(sys.stdin); g["resolved_subgame"]=True; json.dump(g,sys.stdout)')"
      fi
      printf '%s\n' "$game_json" > "$game_file"
      dec_json="$(resolve_games_py decide "$game_file")"
      disposition="$(printf '%s' "$dec_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("disposition",""))')"
      actions_csv="$(printf '%s' "$dec_json" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin).get("actions") or []))')"
      if [[ "$disposition" != "action" || -z "$actions_csv" ]]; then
        echo "game $idx $disposition $(printf '%s' "$dec_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("reason",""))')"
        break
      fi
      if [[ "$sent_n" -ge "$max_txs" ]]; then
        echo "txs_cap_truncated=1 max_txs=$max_txs remainder deferred to next hour"
        break 2
      fi
      leg="${actions_csv%%,*}"
      if [[ "$leg" == "resolveClaim" && "$claim_already" -eq 1 ]]; then
        if [[ "$actions_csv" != *","* ]]; then
          echo "game $idx skip resolveClaim already on-chain"
          break
        fi
        actions_csv="${actions_csv#*,}"
        leg="${actions_csv%%,*}"
      fi
      local game_addr send_out tx_hash cost_wei
      expected_credit="$(printf '%s' "$dec_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("expected_credit_wei",""))')"
      game_addr="$(printf '%s' "$game_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("address",""))')"
      echo "sending game=$idx leg=$leg to=$game_addr expected_credit_wei=${expected_credit:-<missing>}"
      send_out="$(send_leg "$game_addr" "$leg" "$recipient")"
      echo "$send_out"
      if [[ "$send_out" == "ALREADY leg=resolveClaim" ]]; then
        claim_already=1
        continue
      fi
      tx_hash="$(printf '%s' "$send_out" | awk '{for(i=1;i<=NF;i++) if($i ~ /^tx=/){sub(/^tx=/,"",$i); print $i}}')"
      cost_wei="$(printf '%s' "$send_out" | awk '{for(i=1;i<=NF;i++) if($i ~ /^cost_wei=/){sub(/^cost_wei=/,"",$i); print $i}}')"
      sent_n=$((sent_n + 1))
      cost_sum="$(python3 -c 'import sys; print(int(sys.argv[1])+int(sys.argv[2]))' "$cost_sum" "${cost_wei:-0}")"
      game_json="$(resolve_games_fetch_one "$idx")"
      printf '%s\n' "$game_json" > "$game_file"
      confirm_leg_advanced "$game_file" "$leg" "$expected_credit"
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

# Offline fixture fetch/clock for test-helpers. Live path never sets MOCK_DIR.
resolve_games_now() {
  if [[ -n "${RESOLVE_GAMES_MOCK_DIR:-}" ]]; then
    local ts
    ts="$(cat "${RESOLVE_GAMES_MOCK_DIR}/now" 2>/dev/null || true)"
    if [[ -z "$ts" ]]; then
      ts=1000000
    fi
    printf '%s\n' "$ts"
    return 0
  fi
  cast block latest --field timestamp --rpc-url "$L1_RPC_URL" | awk '{print $1}'
}

resolve_games_fetch_one() {
  local idx="$1"
  if [[ -n "${RESOLVE_GAMES_MOCK_DIR:-}" ]]; then
    local nfile n src
    nfile="${RESOLVE_GAMES_MOCK_DIR}/count.${idx}"
    n=0
    if [[ -f "$nfile" ]]; then
      n="$(cat "$nfile")"
    fi
    n=$((n + 1))
    printf '%s\n' "$n" > "$nfile"
    src="${RESOLVE_GAMES_MOCK_DIR}/fetch/${idx}.${n}.json"
    if [[ ! -f "$src" ]]; then
      echo "ERROR: mock fetch missing $src" >&2
      exit 1
    fi
    cat "$src"
    return 0
  fi
  resolve_games_py fetch-one "$idx"
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
  export RESOLVE_GAMES_FULL_SCAN="$FULL_SCAN"
  resolve_games_py analyze "$SNAP" "$MAX_GAMES"
  exit 0
fi

# --- mock-execute (offline fixtures; test-helpers only) -------------------
# The hourly launchd job never sets RESOLVE_GAMES_MOCK_DIR. This path
# skips Sepolia env, keys, and cast so confirmation can be exercised
# against sequential fetch fixtures.
if [[ -n "${RESOLVE_GAMES_MOCK_DIR:-}" ]]; then
  if [[ ! -d "$RESOLVE_GAMES_MOCK_DIR" ]]; then
    echo "ERROR: RESOLVE_GAMES_MOCK_DIR is not a directory" >&2
    exit 1
  fi
  SNAP="${RESOLVE_GAMES_SNAPSHOT:-}"
  if [[ -z "$SNAP" || ! -f "$SNAP" ]]; then
    echo "ERROR: mock execute requires RESOLVE_GAMES_SNAPSHOT" >&2
    exit 1
  fi
  echo "=== ForteL2 resolve-games (mock-execute) ==="
  echo "snapshot: $SNAP"
  echo "mock_dir: $RESOLVE_GAMES_MOCK_DIR"
  export RESOLVE_GAMES_FULL_SCAN="$FULL_SCAN"
  ANALYZE_EC=0
  ANALYZE_OUT="$(resolve_games_py analyze "$SNAP" "$MAX_GAMES")" || ANALYZE_EC=$?
  printf '%s\n' "$ANALYZE_OUT"
  if [[ "$ANALYZE_EC" -ne 0 ]]; then
    echo "ERROR: analyze/watermark persist failed (ec=$ANALYZE_EC)" >&2
    exit "$ANALYZE_EC"
  fi
  SELECTED="$(printf '%s\n' "$ANALYZE_OUT" | awk -F= '/^selected_indexes=/{print $2}')"
  echo "EXECUTE: processing selected_indexes=${SELECTED:-<none>}"
  execute_selected "$SNAP" "$SELECTED" "${RESOLVE_GAMES_RECIPIENT:-0x0000000000000000000000000000000000000001}"
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
export RESOLVE_GAMES_FULL_SCAN="$FULL_SCAN"
export RESOLVE_GAMES_WATERMARK="${RESOLVE_GAMES_WATERMARK:-$DATA_DIR/resolve-games-watermark.json}"
if [[ "$EXECUTE" -eq 1 ]]; then
  export RESOLVE_GAMES_MODE="execute"
else
  export RESOLVE_GAMES_MODE="dry-run"
fi

echo "=== ForteL2 resolve-games (live) ==="
print_live_header
echo "PROPOSER_GAME_TYPE=${PROPOSER_GAME_TYPE:-<unset>}"
echo "watermark: $RESOLVE_GAMES_WATERMARK"
if [[ "$FULL_SCAN" -eq 1 ]]; then
  echo "scan: full (ignoring watermark)"
fi

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
print("scan_from=%s" % s.get("scan_from"))
print("games_examined=%s" % s.get("games_examined"))
print("watermark_status=%s" % s.get("watermark_status"))
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

ANALYZE_EC=0
ANALYZE_OUT="$(resolve_games_py analyze "$SNAP" "$MAX_GAMES")" || ANALYZE_EC=$?
printf '%s\n' "$ANALYZE_OUT"
if [[ "$ANALYZE_EC" -ne 0 ]]; then
  echo "ERROR: analyze/watermark persist failed (ec=$ANALYZE_EC)" >&2
  exit "$ANALYZE_EC"
fi

if [[ "$EXECUTE" -eq 0 ]]; then
  echo "dry-run: sending nothing (pass --execute to broadcast)"
  exit 0
fi

SELECTED="$(printf '%s\n' "$ANALYZE_OUT" | awk -F= '/^selected_indexes=/{print $2}')"
echo "EXECUTE: processing selected_indexes=${SELECTED:-<none>}"
execute_selected "$SNAP" "$SELECTED" "$PROPOSER_ADDRESS"
