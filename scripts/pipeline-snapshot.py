#!/usr/bin/env python3
"""One-shot ForteL2 pipeline health snapshot → JSON (stdlib only).

Mirrors the pipeline viewer panels (sequencer / batcher / proposer / aggregate)
as a single static capture — no browser, no polling loop.

Usage:
  python3 scripts/pipeline-snapshot.py
  python3 scripts/pipeline-snapshot.py -o /tmp/fortel2-health.json
  FORTEL2_ENV=.env.sepolia python3 scripts/pipeline-snapshot.py -o snapshot.json

Reads FORTEL2_ENV (basename or path) → .env → .env.example under the repo root.
Does not print private keys. L1 RPC URLs are redacted in the JSON output.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]

# Sepolia-friendly: few full L1 blocks (viewer uses 12 incremental; one-shot is smaller).
L1_SCAN_BLOCKS = 8
L2_WINDOW_BLOCKS = 15


def load_env_file(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        val = val.strip().strip("'").strip('"')
        if key:
            out[key] = val
    return out


def resolve_env_path() -> Path:
    fortel2_env = os.environ.get("FORTEL2_ENV", "").strip()
    if fortel2_env:
        p = Path(fortel2_env)
        if not p.is_absolute():
            p = ROOT / fortel2_env
        if not p.is_file():
            raise SystemExit(f"ERROR: FORTEL2_ENV not found: {p}")
        return p
    for name in (".env", ".env.example"):
        p = ROOT / name
        if p.is_file():
            return p
    raise SystemExit(f"ERROR: no .env / .env.example under {ROOT}")


def env_get(env: dict[str, str], key: str, default: str = "") -> str:
    return os.environ.get(key) or env.get(key) or default


def redact_rpc_url(url: str) -> str:
    if not url:
        return "<empty>"
    p = urllib.parse.urlparse(url)
    netloc = p.hostname or ""
    if p.port:
        netloc = f"{netloc}:{p.port}"
    path = "/…" if p.path and p.path != "/" else ""
    return f"{p.scheme}://{netloc}{path}"


def rpc(url: str, method: str, params: list[Any] | None = None, timeout: float = 30.0) -> Any:
    body = json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}
    ).encode()
    req = urllib.request.Request(
        url,
        data=body,
        headers={"content-type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        payload = json.loads(resp.read().decode())
    if "error" in payload and payload["error"]:
        err = payload["error"]
        msg = err.get("message") if isinstance(err, dict) else str(err)
        raise RuntimeError(msg or json.dumps(err))
    return payload.get("result")


def hex_to_int(value: Any) -> int | None:
    if value is None or value == "":
        return None
    if isinstance(value, int):
        return value
    s = str(value).strip()
    try:
        return int(s, 0)
    except ValueError:
        return None


def is_eth_address(addr: str) -> bool:
    return bool(re.fullmatch(r"0x[0-9a-fA-F]{40}", addr or ""))


def deployments_json_path(root: Path, l2_chain_id: str) -> Path:
    if l2_chain_id == "852":
        return root / "deployments" / "sepolia" / "deployments.json"
    return root / "deployments" / "deployments.json"


def load_rollup_inbox(deploy_dir: Path) -> str:
    rollup = deploy_dir / "rollup.json"
    if not rollup.is_file():
        return ""
    data = json.loads(rollup.read_text())
    return str(data.get("batch_inbox_address") or data.get("batch_inbox") or "")


def load_factory(deployments: Path) -> str:
    if not deployments.is_file():
        return ""
    data = json.loads(deployments.read_text())
    return str(data.get("DisputeGameFactoryProxy") or data.get("disputeGameFactoryProxy") or "")


def age_seconds(ts: Any, now: float | None = None) -> int | None:
    n = hex_to_int(ts) if not isinstance(ts, (int, float)) else int(ts)
    if n is None or n <= 0:
        return None
    now = now or time.time()
    return max(0, int(now) - n)


def scan_from(tip: int, window: int) -> int:
    if tip < 0:
        return 0
    if window <= 0:
        return tip
    return max(0, tip - window + 1)


def snapshot_sequencer(l2_url: str, node_url: str) -> dict[str, Any]:
    status = rpc(node_url, "optimism_syncStatus")
    unsafe = status.get("unsafe_l2") or status.get("unsafeL2") or {}
    safe = status.get("safe_l2") or status.get("safeL2") or {}
    finalized = status.get("finalized_l2") or status.get("finalizedL2") or {}
    unsafe_n = hex_to_int(unsafe.get("number"))
    safe_n = hex_to_int(safe.get("number"))
    finalized_n = hex_to_int(finalized.get("number"))
    lag = None
    if unsafe_n is not None and safe_n is not None:
        lag = unsafe_n - safe_n

    tip = hex_to_int(rpc(l2_url, "eth_blockNumber"))
    intervals: list[int] = []
    if tip is not None:
        start = scan_from(tip, 5)
        prev_ts = None
        for n in range(start, tip + 1):
            block = rpc(l2_url, "eth_getBlockByNumber", [hex(n), False])
            if not block:
                continue
            ts = hex_to_int(block.get("timestamp"))
            if prev_ts is not None and ts is not None and ts > prev_ts:
                intervals.append(ts - prev_ts)
            prev_ts = ts

    avg_interval = None
    if intervals:
        avg_interval = round(sum(intervals) / len(intervals), 2)

    return {
        "unsafe": unsafe_n,
        "safe": safe_n,
        "finalized": finalized_n,
        "lag_unsafe_safe": lag,
        "unsafe_age_sec": age_seconds(unsafe.get("timestamp")),
        "safe_age_sec": age_seconds(safe.get("timestamp")),
        "finalized_age_sec": age_seconds(finalized.get("timestamp")),
        "recent_block_interval_sec": avg_interval,
        "l2_tip": tip,
    }


def snapshot_batcher(
    l1_url: str, batcher: str, inbox: str, window: int = L1_SCAN_BLOCKS
) -> dict[str, Any]:
    tip = hex_to_int(rpc(l1_url, "eth_blockNumber"))
    if tip is None:
        raise RuntimeError("eth_blockNumber failed on L1")
    start = scan_from(tip, window)
    batcher_l = batcher.lower()
    inbox_l = inbox.lower()
    posts: list[dict[str, Any]] = []
    for n in range(start, tip + 1):
        block = rpc(l1_url, "eth_getBlockByNumber", [hex(n), True])
        if not block:
            continue
        ts = hex_to_int(block.get("timestamp"))
        for tx in block.get("transactions") or []:
            if not isinstance(tx, dict):
                continue
            frm = (tx.get("from") or "").lower()
            to = (tx.get("to") or "").lower()
            if frm == batcher_l and to == inbox_l:
                posts.append(
                    {
                        "hash": tx.get("hash"),
                        "block_number": n,
                        "block_timestamp": ts,
                        "age_sec": age_seconds(ts),
                    }
                )
    posts.sort(key=lambda p: (p.get("block_number") or 0), reverse=True)
    last = posts[0] if posts else None
    cadence = None
    if len(posts) >= 2:
        gaps = []
        for i in range(len(posts) - 1):
            newer = posts[i].get("block_timestamp") or 0
            older = posts[i + 1].get("block_timestamp") or 0
            if newer > older:
                gaps.append(newer - older)
        if gaps:
            cadence = round(sum(gaps) / len(gaps))
    return {
        "scan_from": start,
        "scan_to": tip,
        "post_count": len(posts),
        "last_hash": last.get("hash") if last else None,
        "last_age_sec": last.get("age_sec") if last else None,
        "cadence_sec": cadence,
        "batcher": batcher,
        "inbox": inbox,
    }


def snapshot_proposer(l1_url: str, factory: str) -> dict[str, Any]:
    # gameCount()
    raw = rpc(l1_url, "eth_call", [{"to": factory, "data": "0x4d1975b4"}, "latest"])
    count = hex_to_int(raw) or 0
    out: dict[str, Any] = {
        "factory": factory,
        "game_count": count,
        "latest": None,
    }
    if count == 0:
        return out
    # gameAtIndex(uint256) — selector 0xbb8aa1fc
    idx = count - 1
    data = "0xbb8aa1fc" + f"{idx:064x}"
    raw_game = rpc(l1_url, "eth_call", [{"to": factory, "data": data}, "latest"])
    if not raw_game or raw_game == "0x" or len(raw_game) < 2 + 64 * 3:
        return out
    # ABI: uint32 gameType, uint64 timestamp, address proxy (each 32-byte word)
    h = raw_game[2:]
    game_type = int(h[0:64], 16)
    ts = int(h[64:128], 16)
    proxy = "0x" + h[128 + 24 : 128 + 64]
    out["latest"] = {
        "index": idx,
        "game_type": game_type,
        "timestamp": ts,
        "age_sec": age_seconds(ts),
        "proxy": proxy,
    }
    return out


def snapshot_aggregate(l2_url: str, window: int = L2_WINDOW_BLOCKS) -> dict[str, Any]:
    tip = hex_to_int(rpc(l2_url, "eth_blockNumber"))
    if tip is None:
        raise RuntimeError("eth_blockNumber failed on L2")
    start = scan_from(tip, window)
    empty = non_empty = tx_count = 0
    timestamps: list[int] = []
    for n in range(start, tip + 1):
        block = rpc(l2_url, "eth_getBlockByNumber", [hex(n), False])
        if not block:
            continue
        txs = block.get("transactions") or []
        n_tx = len(txs) if isinstance(txs, list) else 0
        tx_count += n_tx
        if n_tx == 0:
            empty += 1
        else:
            non_empty += 1
        ts = hex_to_int(block.get("timestamp"))
        if ts is not None:
            timestamps.append(ts)
    timestamps.sort()
    window_sec = None
    tx_per_min = None
    if len(timestamps) >= 2:
        window_sec = timestamps[-1] - timestamps[0]
        if window_sec > 0:
            tx_per_min = round((tx_count / window_sec) * 60, 2)

    mempool: dict[str, Any] = {"ok": False}
    try:
        pool = rpc(l2_url, "txpool_status")
        pending = hex_to_int(pool.get("pending"))
        queued = hex_to_int(pool.get("queued"))
        mempool = {
            "ok": True,
            "pending": pending,
            "queued": queued,
            "label": f"{pending or 0} pending / {queued or 0} queued",
        }
    except Exception as exc:  # noqa: BLE001 — best-effort panel
        mempool = {"ok": False, "error": str(exc)}

    return {
        "scan_from": start,
        "scan_to": tip,
        "block_count": empty + non_empty,
        "empty_blocks": empty,
        "non_empty_blocks": non_empty,
        "tx_count": tx_count,
        "window_sec": window_sec,
        "tx_per_min": tx_per_min,
        "mempool": mempool,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="ForteL2 one-shot pipeline health → JSON")
    parser.add_argument(
        "-o",
        "--output",
        help="Write JSON to this path (default: stdout)",
    )
    parser.add_argument(
        "--l1-blocks",
        type=int,
        default=L1_SCAN_BLOCKS,
        help=f"L1 blocks to scan for batcher posts (default {L1_SCAN_BLOCKS})",
    )
    parser.add_argument(
        "--pretty",
        action="store_true",
        default=True,
        help="Pretty-print JSON (default on)",
    )
    parser.add_argument(
        "--compact",
        action="store_true",
        help="Compact JSON (no indent)",
    )
    args = parser.parse_args()

    env_path = resolve_env_path()
    file_env = load_env_file(env_path)
    # Repo root override from env file (Cloud / custom layouts)
    root = Path(env_get(file_env, "FORTEL2_ROOT", str(ROOT))).resolve()

    l1_chain = env_get(file_env, "L1_CHAIN_ID", "900")
    l2_chain = env_get(file_env, "L2_CHAIN_ID", "901")
    l1_url = env_get(file_env, "L1_RPC_URL")
    l2_url = env_get(file_env, "L2_RPC_URL", "http://127.0.0.1:9545")
    node_url = env_get(file_env, "L2_NODE_RPC_URL", "http://127.0.0.1:9547")
    batcher = env_get(file_env, "BATCHER_ADDRESS")
    deploy_dir = Path(env_get(file_env, "DEPLOY_DIR", str(root / "deployments" / ".deployer")))

    if not l1_url:
        raise SystemExit("ERROR: L1_RPC_URL unset")

    deployments = deployments_json_path(root, l2_chain)
    inbox = load_rollup_inbox(deploy_dir)
    factory = load_factory(deployments)

    mode = "sepolia" if l2_chain == "852" else "local"
    result: dict[str, Any] = {
        "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "mode": mode,
        "env_file": str(env_path),
        "chain": {"l1": int(l1_chain) if l1_chain.isdigit() else l1_chain, "l2": int(l2_chain) if l2_chain.isdigit() else l2_chain},
        "rpc": {
            "l1": redact_rpc_url(l1_url),
            "l2": l2_url,
            "l2_node": node_url,
        },
        "sequencer": None,
        "batcher": None,
        "proposer": None,
        "aggregate": None,
        "errors": [],
    }

    try:
        result["sequencer"] = snapshot_sequencer(l2_url, node_url)
    except Exception as exc:  # noqa: BLE001
        result["errors"].append({"panel": "sequencer", "error": str(exc)})

    if is_eth_address(batcher) and is_eth_address(inbox):
        try:
            result["batcher"] = snapshot_batcher(l1_url, batcher, inbox, args.l1_blocks)
        except Exception as exc:  # noqa: BLE001
            result["errors"].append({"panel": "batcher", "error": str(exc)})
    else:
        result["errors"].append(
            {
                "panel": "batcher",
                "error": "BATCHER_ADDRESS or batch inbox missing/invalid "
                f"(batcher={batcher!r} inbox={inbox!r} rollup={deploy_dir / 'rollup.json'})",
            }
        )

    if is_eth_address(factory):
        try:
            result["proposer"] = snapshot_proposer(l1_url, factory)
        except Exception as exc:  # noqa: BLE001
            result["errors"].append({"panel": "proposer", "error": str(exc)})
    else:
        result["errors"].append(
            {
                "panel": "proposer",
                "error": f"DisputeGameFactoryProxy missing in {deployments}",
            }
        )

    try:
        result["aggregate"] = snapshot_aggregate(l2_url)
    except Exception as exc:  # noqa: BLE001
        result["errors"].append({"panel": "aggregate", "error": str(exc)})

    indent = None if args.compact else 2
    text = json.dumps(result, indent=indent) + "\n"
    if args.output:
        out = Path(args.output)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text)
        print(f"Wrote {out}", file=sys.stderr)
    else:
        sys.stdout.write(text)

    # Exit 0 if at least sequencer or aggregate worked; 1 if everything failed.
    if result["sequencer"] is None and result["aggregate"] is None:
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except urllib.error.URLError as exc:
        print(f"ERROR: RPC network failure: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
