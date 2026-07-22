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

/** Sepolia viewer defaults: fewer L1 blocks, slower poll (QuickNode credit budget). */
export function viewerL1ScanBlocks(l2ChainId) {
  return Number(l2ChainId) === 852 ? 12 : 40;
}

export function viewerRefreshMs(l2ChainId, configuredMs) {
  const configured = Number(configuredMs);
  if (Number.isFinite(configured) && configured > 0) return configured;
  return Number(l2ChainId) === 852 ? 15_000 : 5_000;
}
