/**
 * Pure helpers for the Phase 6 block viewer (unit-tested; no RPC I/O).
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
 * Format unix seconds for display (UTC ISO date + relative age).
 * @param {number|bigint|string|null|undefined} tsSeconds
 */
export function formatBlockTimestamp(tsSeconds, nowMs = Date.now()) {
  const n = Number(tsSeconds);
  if (!Number.isFinite(n) || n <= 0) return { iso: "—", age: "—" };
  const d = new Date(n * 1000);
  return {
    iso: d.toISOString().replace("T", " ").replace(".000Z", " UTC"),
    age: formatAge(n, nowMs),
  };
}

/** Default page size for block list pagination. */
export function blocksPageSize(l2ChainId) {
  return Number(l2ChainId) === 852 ? 15 : 25;
}

/**
 * Inclusive block-number range for the initial list page (newest-first display).
 * @param {number|bigint|string} tip latest block number
 * @param {number} pageSize
 */
export function initialBlocksRange(tip, pageSize) {
  const t = Number(tip);
  const size = Math.max(1, Number(pageSize) || 1);
  if (!Number.isFinite(t) || t < 0) return { from: 0, to: 0, count: 0 };
  const from = Math.max(0, t - size + 1);
  return { from, to: t, count: t - from + 1 };
}

/**
 * Next older page when "load more" is clicked.
 * @param {number} oldestLoaded lowest block number currently shown
 * @param {number} pageSize
 */
export function nextBlocksPageRange(oldestLoaded, pageSize) {
  const oldest = Number(oldestLoaded);
  const size = Math.max(1, Number(pageSize) || 1);
  if (!Number.isFinite(oldest) || oldest <= 0) {
    return { from: 0, to: -1, count: 0, hasMore: false };
  }
  const to = oldest - 1;
  const from = Math.max(0, to - size + 1);
  return { from, to, count: to - from + 1, hasMore: from > 0 };
}

/**
 * Sort block summaries newest-first by block number.
 * @param {Array<{number?: number|string}>} blocks
 */
export function sortBlocksNewestFirst(blocks) {
  if (!Array.isArray(blocks)) return [];
  return [...blocks].sort((a, b) => Number(b.number) - Number(a.number));
}

/**
 * Summarize a block for the list table.
 * @param {object|null|undefined} block ethers block object
 */
export function summarizeBlockListRow(block) {
  if (!block || block.number == null) {
    return { number: null, hash: null, shortHash: "—", timestamp: null, txCount: null, age: "—", timeIso: "—" };
  }
  const txLen = Array.isArray(block.transactions)
    ? block.transactions.length
    : typeof block.transactions === "number"
      ? block.transactions
      : 0;
  const ts = formatBlockTimestamp(block.timestamp);
  return {
    number: Number(block.number),
    hash: block.hash || null,
    shortHash: shortHex(block.hash, 8, 6),
    timestamp: Number(block.timestamp),
    txCount: txLen,
    age: ts.age,
    timeIso: ts.iso,
  };
}

/**
 * Summarize block header fields for the detail view.
 * @param {object|null|undefined} block
 */
export function summarizeBlockHeader(block) {
  if (!block || block.number == null) {
    return {
      number: null,
      hash: null,
      parentHash: null,
      timestamp: null,
      timeIso: "—",
      age: "—",
      gasUsed: null,
      gasLimit: null,
      txCount: null,
      miner: null,
    };
  }
  const ts = formatBlockTimestamp(block.timestamp);
  const txLen = Array.isArray(block.transactions) ? block.transactions.length : 0;
  return {
    number: Number(block.number),
    hash: block.hash || null,
    parentHash: block.parentHash || null,
    timestamp: Number(block.timestamp),
    timeIso: ts.iso,
    age: ts.age,
    gasUsed: block.gasUsed != null ? String(block.gasUsed) : null,
    gasLimit: block.gasLimit != null ? String(block.gasLimit) : null,
    txCount: txLen,
    miner: block.miner || null,
  };
}

/**
 * Format wei value for display (ETH with sensible precision).
 * @param {bigint|string|number|null|undefined} wei
 */
export function formatEthValue(wei) {
  if (wei == null) return "—";
  try {
    const w = typeof wei === "bigint" ? wei : BigInt(String(wei));
    if (w === 0n) return "0 ETH";
    const eth = Number(w) / 1e18;
    if (eth >= 0.0001) return `${eth.toFixed(4)} ETH`;
    return `${w.toString()} wei`;
  } catch {
    return "—";
  }
}

/**
 * Summarize transactions in a block for detail rows.
 * @param {Array<object|string>|null|undefined} transactions
 */
export function summarizeTxRows(transactions) {
  if (!Array.isArray(transactions)) return [];
  return transactions
    .map((tx) => {
      if (typeof tx === "string") {
        return { hash: tx, shortHash: shortHex(tx, 8, 6), from: null, to: null, value: null, type: null };
      }
      if (!tx || typeof tx !== "object") return null;
      const type = tx.type != null ? Number(tx.type) : null;
      return {
        hash: tx.hash || null,
        shortHash: shortHex(tx.hash, 8, 6),
        from: tx.from || null,
        to: tx.to || null,
        value: formatEthValue(tx.value),
        type: type != null && Number.isFinite(type) ? String(type) : "—",
      };
    })
    .filter(Boolean);
}

/**
 * Parse a block route param (decimal height or 0x hash).
 * @param {string|null|undefined} param
 * @returns {{ kind: 'number'|'hash'|'invalid', value: string|number|null }}
 */
export function parseBlockParam(param) {
  if (param == null) return { kind: "invalid", value: null };
  const s = String(param).trim();
  if (!s) return { kind: "invalid", value: null };
  if (/^0x[0-9a-fA-F]{64}$/.test(s)) {
    return { kind: "hash", value: s };
  }
  if (/^\d+$/.test(s)) {
    const n = Number(s);
    if (Number.isFinite(n) && n >= 0) return { kind: "number", value: n };
  }
  return { kind: "invalid", value: null };
}

/**
 * Parse location hash into view state.
 * Supports `#/` (list), `#/block/123`, `#/block/0x…`.
 * @param {string} hash location.hash
 */
export function parseRouteHash(hash) {
  const raw = (hash || "").replace(/^#/, "").replace(/^\//, "");
  if (!raw || raw === "") return { view: "list", blockParam: null };
  const parts = raw.split("/").filter(Boolean);
  if (parts[0] === "block" && parts[1]) {
    return { view: "detail", blockParam: parts[1] };
  }
  return { view: "list", blockParam: null };
}

/** Build a location hash for navigation. */
export function buildRouteHash(view, blockParam = null) {
  if (view === "detail" && blockParam != null) {
    return `#/block/${blockParam}`;
  }
  return "#/";
}
