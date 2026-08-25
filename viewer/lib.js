/**
 * Pure helpers for the Phase 1c/1d pipeline viewer (unit-tested; no RPC I/O).
 */

/** @param {number|bigint|string|null|undefined} tsSeconds unix seconds */
export function formatAge(tsSeconds, nowMs = Date.now()) {
  const n = Number(tsSeconds);
  if (!Number.isFinite(n) || n <= 0) return "—";
  const ageSec = Math.max(0, Math.floor(nowMs / 1000) - n);
  if (ageSec < 60) return `${ageSec}s ago`;
  if (ageSec < 3600) return `${Math.floor(ageSec / 60)}m ${ageSec % 60}s ago`;
  const h = Math.floor(ageSec / 3600);
  const m = Math.floor((ageSec % 3600) / 60);
  return `${h}h ${m}m ago`;
}

/** Shorten a 0x hash/address for display. */
export function shortHex(value, head = 6, tail = 4) {
  if (!value || typeof value !== "string" || value.length < head + tail + 2) {
    return value || "—";
  }
  return `${value.slice(0, head + 2)}…${value.slice(-tail)}`;
}

/**
 * Summarize optimism_syncStatus JSON into panel fields.
 * @param {object|null|undefined} status
 */
export function summarizeSyncStatus(status) {
  if (!status || typeof status !== "object") {
    return {
      unsafe: null,
      safe: null,
      finalized: null,
      unsafeAge: "—",
      safeAge: "—",
      finalizedAge: "—",
      lagUnsafeSafe: null,
    };
  }
  const unsafe = status.unsafe_l2 ?? status.unsafeL2 ?? null;
  const safe = status.safe_l2 ?? status.safeL2 ?? null;
  const finalized = status.finalized_l2 ?? status.finalizedL2 ?? null;
  const unsafeNum = unsafe?.number != null ? Number(unsafe.number) : null;
  const safeNum = safe?.number != null ? Number(safe.number) : null;
  const finalizedNum = finalized?.number != null ? Number(finalized.number) : null;
  let lagUnsafeSafe = null;
  if (unsafeNum != null && safeNum != null) lagUnsafeSafe = unsafeNum - safeNum;
  return {
    unsafe: unsafeNum,
    safe: safeNum,
    finalized: finalizedNum,
    unsafeAge: formatAge(unsafe?.timestamp),
    safeAge: formatAge(safe?.timestamp),
    finalizedAge: formatAge(finalized?.timestamp),
    lagUnsafeSafe,
  };
}

/**
 * Filter L1 txs that are batcher → batch inbox.
 * @param {Array<{hash?: string, from?: string, to?: string, blockNumber?: number|string, blockTimestamp?: number}>} txs
 * @param {string} batcher
 * @param {string} inbox
 */
export function filterBatchTxs(txs, batcher, inbox) {
  const b = (batcher || "").toLowerCase();
  const i = (inbox || "").toLowerCase();
  if (!b || !i || !Array.isArray(txs)) return [];
  return txs.filter((tx) => {
    const from = (tx.from || "").toLowerCase();
    const to = (tx.to || "").toLowerCase();
    return from === b && to === i;
  });
}

/**
 * Cadence summary from batch txs ordered newest-first (or any order).
 * @param {Array<{hash?: string, blockTimestamp?: number, blockNumber?: number|string}>} batchTxs
 */
export function summarizeBatcherActivity(batchTxs, nowMs = Date.now()) {
  if (!Array.isArray(batchTxs) || batchTxs.length === 0) {
    return { count: 0, lastHash: null, lastAge: "—", cadenceSec: null };
  }
  const sorted = [...batchTxs].sort((a, b) => {
    const ta = Number(a.blockTimestamp) || 0;
    const tb = Number(b.blockTimestamp) || 0;
    if (tb !== ta) return tb - ta;
    return Number(b.blockNumber) - Number(a.blockNumber);
  });
  const last = sorted[0];
  let cadenceSec = null;
  if (sorted.length >= 2) {
    const gaps = [];
    for (let i = 0; i < sorted.length - 1; i++) {
      const newer = Number(sorted[i].blockTimestamp) || 0;
      const older = Number(sorted[i + 1].blockTimestamp) || 0;
      if (newer > older) gaps.push(newer - older);
    }
    if (gaps.length) {
      cadenceSec = Math.round(gaps.reduce((s, g) => s + g, 0) / gaps.length);
    }
  }
  return {
    count: sorted.length,
    lastHash: last.hash || null,
    lastAge: formatAge(last.blockTimestamp, nowMs),
    cadenceSec,
  };
}

/**
 * Aggregate L2 block window: empty vs non-empty, tx rate.
 * @param {Array<{timestamp?: number|string, transactions?: unknown[]|number}>} blocks oldest→newest or any
 */
export function aggregateTxWindow(blocks, nowMs = Date.now()) {
  if (!Array.isArray(blocks) || blocks.length === 0) {
    return {
      blockCount: 0,
      empty: 0,
      nonEmpty: 0,
      txCount: 0,
      txPerMin: null,
      windowSec: null,
      avgIntervalSec: null,
    };
  }
  let empty = 0;
  let nonEmpty = 0;
  let txCount = 0;
  const timestamps = [];
  for (const b of blocks) {
    const n =
      typeof b.transactions === "number"
        ? b.transactions
        : Array.isArray(b.transactions)
          ? b.transactions.length
          : 0;
    txCount += n;
    if (n === 0) empty += 1;
    else nonEmpty += 1;
    const ts = Number(b.timestamp);
    if (Number.isFinite(ts) && ts > 0) timestamps.push(ts);
  }
  timestamps.sort((a, b) => a - b);
  let windowSec = null;
  let avgIntervalSec = null;
  if (timestamps.length >= 2) {
    windowSec = timestamps[timestamps.length - 1] - timestamps[0];
    avgIntervalSec = windowSec / (timestamps.length - 1);
  } else if (timestamps.length === 1) {
    windowSec = Math.max(0, Math.floor(nowMs / 1000) - timestamps[0]);
  }
  let txPerMin = null;
  if (windowSec != null && windowSec > 0) {
    txPerMin = (txCount / windowSec) * 60;
  }
  return {
    blockCount: blocks.length,
    empty,
    nonEmpty,
    txCount,
    txPerMin,
    windowSec,
    avgIntervalSec,
  };
}

/** Format a number for panel display. */
export function formatRate(n, digits = 1) {
  if (n == null || !Number.isFinite(n)) return "—";
  return n.toFixed(digits);
}

/** Parse eth_ hex quantity or decimal string to a non-negative integer. */
export function parseHexQuantity(value) {
  if (value == null || value === "") return null;
  if (typeof value === "number" && Number.isFinite(value) && value >= 0) {
    return Math.floor(value);
  }
  const s = String(value).trim();
  if (!s) return null;
  try {
    const n = s.startsWith("0x") || s.startsWith("0X") ? Number.parseInt(s, 16) : Number(s);
    if (!Number.isFinite(n) || n < 0) return null;
    return Math.floor(n);
  } catch {
    return null;
  }
}

/**
 * Summarize L2 `txpool_status` for the Aggregate panel (Phase 1d).
 * @param {object|null|undefined} status e.g. `{ pending: "0x1", queued: "0x0" }`
 */
export function summarizeTxpoolStatus(status) {
  if (!status || typeof status !== "object") {
    return { pending: null, queued: null, total: null, label: "—" };
  }
  const pending = parseHexQuantity(status.pending);
  const queued = parseHexQuantity(status.queued);
  if (pending == null && queued == null) {
    return { pending: null, queued: null, total: null, label: "—" };
  }
  const p = pending ?? 0;
  const q = queued ?? 0;
  return {
    pending: p,
    queued: q,
    total: p + q,
    label: `${p} pending / ${q} queued`,
  };
}

/**
 * Inclusive start block for scanning `windowSize` blocks ending at `tip`.
 * ethers v6 `Provider.getBlockNumber()` returns a number — keep arithmetic in
 * Number space (mixing with BigInt throws TypeError).
 * @param {number|bigint|string} tip
 * @param {number} windowSize
 */
export function scanFromBlock(tip, windowSize) {
  const t = Number(tip);
  const w = Number(windowSize);
  if (!Number.isFinite(t) || t < 0) return 0;
  if (!Number.isFinite(w) || w <= 0) return t;
  return Math.max(0, t - w + 1);
}

/**
 * Next inclusive [from, tip] range for incremental L1 batcher scans.
 * @param {number|null|undefined} prevTip last successfully scanned tip (or null)
 * @param {number|bigint|string} tip current L1 tip
 * @param {number} windowBlocks rolling window size
 * @returns {{ from: number, tip: number, reset: boolean, skip: boolean }}
 */
export function nextBatcherScanRange(prevTip, tip, windowBlocks) {
  const t = Number(tip);
  const w = Math.max(1, Number(windowBlocks) || 1);
  if (!Number.isFinite(t) || t < 0) {
    return { from: 0, tip: 0, reset: true, skip: true };
  }
  if (prevTip == null || !Number.isFinite(Number(prevTip)) || t < Number(prevTip)) {
    return { from: scanFromBlock(t, w), tip: t, reset: true, skip: false };
  }
  const prev = Number(prevTip);
  if (t === prev) {
    return { from: t, tip: t, reset: false, skip: true };
  }
  let from = prev + 1;
  const minFrom = scanFromBlock(t, w);
  if (from < minFrom) from = minFrom;
  return { from, tip: t, reset: false, skip: false };
}

/**
 * Keep batch txs whose blockNumber is within the rolling window ending at tip.
 * @param {Array<{blockNumber?: number|string}>} txs
 * @param {number} tip
 * @param {number} windowBlocks
 */
export function pruneBatchTxsToWindow(txs, tip, windowBlocks) {
  if (!Array.isArray(txs)) return [];
  const minBlock = scanFromBlock(tip, windowBlocks);
  return txs.filter((tx) => {
    const n = Number(tx?.blockNumber);
    return Number.isFinite(n) && n >= minBlock && n <= Number(tip);
  });
}

/**
 * Highest L1 block scanned contiguously from `from` given parallel getBlock results.
 * Null entries (or gaps) stop the run so tip does not advance past missing heights.
 * @param {number} from first requested block number
 * @param {Array<object|null|undefined>} blockResults aligned with from, from+1, …
 * @returns {number|null} last contiguous success, or null if `from` itself missing
 */
export function contiguousScanTip(from, blockResults) {
  const start = Number(from);
  if (!Number.isFinite(start) || start < 0 || !Array.isArray(blockResults)) {
    return null;
  }
  let last = null;
  for (let i = 0; i < blockResults.length; i++) {
    const block = blockResults[i];
    if (!block) break;
    const n = Number(block.number);
    if (!Number.isFinite(n) || n !== start + i) break;
    last = n;
  }
  return last;
}

/**
 * Apply a successful L1 batcher scan to cache state.
 * Call only after blocks were fetched — never clear/advance tip before I/O succeeds,
 * or a failed fetch + unchanged tip yields skip:true with an empty cache forever.
 * @param {{ tip: number|null, txs: Array<{blockNumber?: number|string}> }} cache
 * @param {{ tip: number, reset: boolean }} range
 * @param {Array<{blockNumber?: number|string}>} collected
 * @param {number} windowBlocks
 */
export function applyBatcherScanSuccess(cache, range, collected, windowBlocks) {
  const base = range.reset ? [] : cache.txs || [];
  const tip = range.tip;
  return {
    tip,
    txs: pruneBatchTxsToWindow([...base, ...(collected || [])], tip, windowBlocks),
  };
}

/**
 * Inclusive L1 block window for the batcher panel scan.
 *
 * Chain 901 (local Anvil): 40 blocks — L1 is free and fast.
 * Chain 852 local (:8081): 12 blocks. That path hits the operator's metered
 * QuickNode L1; widening it multiplies getBlock calls per refresh.
 * Chain 852 public: 36 blocks. Measured 2026-08-25, inbox posts at L1
 * 11565828 / 11565852 / 11565877 (~25-block / ~5 min spacing). 12 blocks
 * (~2.4 min) miss a healthy batcher about half the time. 36 = one 25-block
 * interval plus 11-block slack (~2 min) so the latest post still shows when
 * a batch is slightly late. Public mode hits free publicnode, not QuickNode.
 *
 * @param {number|string} l2ChainId
 * @param {boolean} [publicMode=false]
 */
export function viewerL1ScanBlocks(l2ChainId, publicMode = false) {
  if (Number(l2ChainId) === 852) {
    return publicMode ? 36 : 12;
  }
  return 40;
}

export function viewerRefreshMs(l2ChainId, configuredMs, publicMode = false) {
  const configured = Number(configuredMs);
  let ms;
  if (Number.isFinite(configured) && configured > 0) {
    ms = configured;
  } else {
    ms = Number(l2ChainId) === 852 ? 15_000 : 5_000;
  }
  if (publicMode) return Math.max(ms, 30_000);
  return ms;
}

/** D-0047 public read origins — the only hosts a hosted viewer may contact. */
export const PUBLIC_VIEWER_ALLOWED_ORIGINS = Object.freeze([
  "https://fortel2-replica-rpc.onrender.com",
  "https://fortel2-sequencer-rpc.onrender.com",
  "https://ethereum-sepolia-rpc.publicnode.com",
]);

export const PUBLIC_FORBIDDEN_RPC_METHODS = Object.freeze([
  "txpool_status",
  "optimism_syncStatus",
]);

export const PUBLIC_VIEWER_CSP =
  "default-src 'self'; base-uri 'self'; frame-ancestors 'none'; script-src 'self'; " +
  "style-src 'self' 'unsafe-inline'; font-src 'self'; connect-src " +
  `${PUBLIC_VIEWER_ALLOWED_ORIGINS.join(" ")}; img-src 'self' data:;`;

/**
 * Directives browsers ignore (and warn on) when CSP is delivered via <meta>.
 * `frame-ancestors` still belongs in the HTTP / dashboard-header copy
 * (`public.csp` / Content-Security-Policy.txt).
 */
export const META_IGNORED_CSP_DIRECTIVES = Object.freeze(["frame-ancestors"]);

/**
 * Strip meta-ignored directives without changing any other directive's value.
 * @param {string} policy
 * @param {readonly string[]} [ignored]
 */
export function cspForMeta(policy, ignored = META_IGNORED_CSP_DIRECTIVES) {
  if (typeof policy !== "string" || !policy) return "";
  const skip = new Set([...ignored].map((d) => d.toLowerCase()));
  const parts = [];
  for (const raw of policy.split(";")) {
    const d = raw.trim();
    if (!d) continue;
    const name = d.split(/\s+/)[0].toLowerCase();
    if (skip.has(name)) continue;
    parts.push(d);
  }
  return parts.length ? `${parts.join("; ")};` : "";
}

export const PUBLIC_VIEWER_CSP_META = cspForMeta(PUBLIC_VIEWER_CSP);

/** JSON-RPC methods each panel issues. Public mode must never list the forbidden pair. */
export function viewerRpcPlan(publicMode) {
  if (publicMode) {
    return {
      sequencer: ["eth_getBlockByNumber"],
      batcher: ["eth_getBlockByNumber"],
      proposer: ["eth_call"],
      aggregate: ["eth_getBlockByNumber"],
    };
  }
  return {
    sequencer: ["optimism_syncStatus", "eth_getBlockByNumber"],
    batcher: ["eth_getBlockByNumber"],
    proposer: ["eth_call"],
    aggregate: ["eth_getBlockByNumber", "txpool_status"],
  };
}

export function assertPublicRpcMethod(method, publicMode) {
  if (publicMode && PUBLIC_FORBIDDEN_RPC_METHODS.includes(method)) {
    throw new Error(`public viewer must not call ${method}`);
  }
}

/**
 * Collect http(s) origins from arbitrary text (config, HTML, first-party JS).
 * Trailing punctuation from prose is stripped so a URL in a sentence still parses.
 */
export function httpOriginsInText(text) {
  if (typeof text !== "string" || !text) return [];
  const re = /https?:\/\/[^\s"'\\<>]+/gi;
  const origins = new Set();
  for (const raw of text.matchAll(re)) {
    const cleaned = raw[0].replace(/[),.;]+$/g, "");
    try {
      const u = new URL(cleaned);
      if (u.protocol === "http:" || u.protocol === "https:") {
        origins.add(`${u.protocol}//${u.host}`);
      }
    } catch {
      // ignore unparseable matches
    }
  }
  return [...origins].sort();
}

/**
 * Origin allowlist guard for the public viewer artifact.
 * `ok` is false when any origin is outside PUBLIC_VIEWER_ALLOWED_ORIGINS
 * (QuickNode-shaped hosts fail here). Missing allowlisted origins are reported
 * but do not fail — first-party JS need not repeat the three URLs.
 */
export function assertPublicViewerAllowlist(text, allowed = PUBLIC_VIEWER_ALLOWED_ORIGINS) {
  const found = httpOriginsInText(text);
  const allowedSet = new Set(allowed);
  const unexpected = found.filter((o) => !allowedSet.has(o));
  const missing = [...allowedSet].filter((o) => !found.includes(o)).sort();
  return {
    ok: unexpected.length === 0,
    found,
    unexpected,
    missing,
  };
}

/** Stricter: public config must name exactly the allowlisted origins, no extras. */
export function assertPublicViewerConfigOrigins(text, allowed = PUBLIC_VIEWER_ALLOWED_ORIGINS) {
  const result = assertPublicViewerAllowlist(text, allowed);
  const extraMissing = result.missing.length > 0;
  return {
    ...result,
    ok: result.ok && !extraMissing,
  };
}

function headFromTaggedBlock(block) {
  if (block == null || typeof block !== "object" || block.error) return null;
  const number = parseHexQuantity(block.number);
  if (number == null) return null;
  return {
    number,
    timestamp: parseHexQuantity(block.timestamp),
  };
}

function taggedHeadFailed(block) {
  return headFromTaggedBlock(block) == null;
}

/**
 * Sequencer panel from eth_getBlockByNumber tags (public mode; no optimism_syncStatus).
 * `unsafe` is sequencer-gateway `latest`; `safe` / `finalized` are replica tags.
 * A failed unsafe fetch degrades the panel without discarding replica heads.
 * Missing safe/finalized is also a visible partial degradation.
 *
 * @param {{ unsafe?: object|null, safe?: object|null, finalized?: object|null }} heads
 */
export function summarizePublicSequencerHeads(heads, nowMs = Date.now()) {
  const src = heads && typeof heads === "object" ? heads : {};
  const unsafeFailed = taggedHeadFailed(src.unsafe);
  const safeFailed = taggedHeadFailed(src.safe);
  const finalizedFailed = taggedHeadFailed(src.finalized);
  const unsafe = headFromTaggedBlock(src.unsafe);
  const safe = headFromTaggedBlock(src.safe);
  const finalized = headFromTaggedBlock(src.finalized);
  let lagUnsafeSafe = null;
  if (unsafe && safe) lagUnsafeSafe = unsafe.number - safe.number;
  const replicaFailed = safeFailed || finalizedFailed;
  let degradeLabel = null;
  if (unsafeFailed) {
    degradeLabel =
      "Sequencer tip unavailable (gateway down or nightly 23:45–03:00 window)";
  } else if (replicaFailed) {
    degradeLabel = "Replica safe/finalized tags unavailable";
  }
  return {
    unsafe: unsafe?.number ?? null,
    safe: safe?.number ?? null,
    finalized: finalized?.number ?? null,
    unsafeAge: unsafeFailed ? "unavailable" : formatAge(unsafe?.timestamp, nowMs),
    safeAge: safeFailed ? "unavailable" : formatAge(safe?.timestamp, nowMs),
    finalizedAge: finalizedFailed ? "unavailable" : formatAge(finalized?.timestamp, nowMs),
    lagUnsafeSafe,
    degraded: unsafeFailed || replicaFailed,
    degradeLabel,
  };
}
