import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  aggregateTxWindow,
  applyBatcherScanSuccess,
  assertPublicRpcMethod,
  assertPublicViewerAllowlist,
  assertPublicViewerConfigOrigins,
  contiguousScanTip,
  filterBatchTxs,
  formatAge,
  formatRate,
  httpOriginsInText,
  nextBatcherScanRange,
  parseHexQuantity,
  pruneBatchTxsToWindow,
  PUBLIC_FORBIDDEN_RPC_METHODS,
  PUBLIC_VIEWER_ALLOWED_ORIGINS,
  PUBLIC_VIEWER_CSP,
  scanFromBlock,
  shortHex,
  summarizeBatcherActivity,
  summarizePublicSequencerHeads,
  summarizeSyncStatus,
  summarizeTxpoolStatus,
  viewerL1ScanBlocks,
  viewerRefreshMs,
  viewerRpcPlan,
  cspForMeta,
  PUBLIC_VIEWER_CSP_META,
  META_IGNORED_CSP_DIRECTIVES,
  collectRecentTxs,
  explorerTxUrl,
  isL1AttributesDeposit,
  recentTxHeights,
  DEFAULT_EXPLORER_TX_PREFIX,
  L1_ATTRIBUTES_DEPOSITOR,
  RECENT_L2_TX_COUNT,
  RECENT_L2_TX_LOOKBACK,
} from "./lib.js";

const viewerDir = dirname(fileURLToPath(import.meta.url));

describe("formatAge", () => {
  const now = 1_700_000_100_000; // ms
  it("formats seconds", () => {
    assert.equal(formatAge(1_700_000_090, now), "10s ago");
  });
  it("formats minutes", () => {
    assert.equal(formatAge(1_700_000_000, now), "1m 40s ago");
  });
  it("handles missing", () => {
    assert.equal(formatAge(null, now), "—");
    assert.equal(formatAge(0, now), "—");
  });
});

describe("shortHex", () => {
  it("shortens hashes", () => {
    assert.equal(
      shortHex("0x1234567890abcdef1234567890abcdef12345678", 4, 4),
      "0x1234…5678",
    );
  });
  it("passthrough short values", () => {
    assert.equal(shortHex("0xabc"), "0xabc");
  });
});

describe("summarizeSyncStatus", () => {
  it("reads snake_case heads", () => {
    const s = summarizeSyncStatus({
      unsafe_l2: { number: 100, timestamp: 50 },
      safe_l2: { number: 90, timestamp: 40 },
      finalized_l2: { number: 80, timestamp: 30 },
    });
    assert.equal(s.unsafe, 100);
    assert.equal(s.safe, 90);
    assert.equal(s.finalized, 80);
    assert.equal(s.lagUnsafeSafe, 10);
  });
  it("handles empty", () => {
    const s = summarizeSyncStatus(null);
    assert.equal(s.unsafe, null);
    assert.equal(s.lagUnsafeSafe, null);
  });
});

describe("filterBatchTxs", () => {
  const batcher = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
  const inbox = "0x00289c189bee4e70334629f04cd5ed602b6600eb";
  it("filters batcher to inbox", () => {
    const out = filterBatchTxs(
      [
        { hash: "0xaa", from: batcher, to: inbox },
        { hash: "0xbb", from: batcher, to: "0x1111111111111111111111111111111111111111" },
        { hash: "0xcc", from: "0x2222222222222222222222222222222222222222", to: inbox },
      ],
      batcher,
      inbox,
    );
    assert.equal(out.length, 1);
    assert.equal(out[0].hash, "0xaa");
  });
  it("returns empty when addresses missing", () => {
    assert.deepEqual(filterBatchTxs([{ hash: "0xaa" }], "", inbox), []);
  });
});

describe("summarizeBatcherActivity", () => {
  const now = 1_700_000_200_000;
  it("computes cadence from newest-first timestamps", () => {
    const s = summarizeBatcherActivity(
      [
        { hash: "0x1", blockTimestamp: 1_700_000_100, blockNumber: 10 },
        { hash: "0x2", blockTimestamp: 1_700_000_180, blockNumber: 20 },
        { hash: "0x3", blockTimestamp: 1_700_000_140, blockNumber: 15 },
      ],
      now,
    );
    assert.equal(s.count, 3);
    assert.equal(s.lastHash, "0x2");
    assert.equal(s.cadenceSec, 40); // gaps 40 and 40
  });
  it("empty window", () => {
    const s = summarizeBatcherActivity([]);
    assert.equal(s.count, 0);
    assert.equal(s.lastHash, null);
  });
});

describe("aggregateTxWindow", () => {
  it("counts empty vs non-empty and rate", () => {
    const agg = aggregateTxWindow([
      { timestamp: 1000, transactions: 0 },
      { timestamp: 1002, transactions: 3 },
      { timestamp: 1004, transactions: [] },
      { timestamp: 1006, transactions: 2 },
    ]);
    assert.equal(agg.blockCount, 4);
    assert.equal(agg.empty, 2);
    assert.equal(agg.nonEmpty, 2);
    assert.equal(agg.txCount, 5);
    assert.equal(agg.windowSec, 6);
    assert.equal(agg.avgIntervalSec, 2);
    assert.ok(Math.abs(agg.txPerMin - 50) < 0.01);
  });
});

describe("formatRate", () => {
  it("formats finite numbers", () => {
    assert.equal(formatRate(1.234, 1), "1.2");
    assert.equal(formatRate(null), "—");
  });
});

describe("summarizeTxpoolStatus", () => {
  it("parses hex pending/queued", () => {
    const s = summarizeTxpoolStatus({ pending: "0x2", queued: "0x1" });
    assert.equal(s.pending, 2);
    assert.equal(s.queued, 1);
    assert.equal(s.total, 3);
    assert.equal(s.label, "2 pending / 1 queued");
  });
  it("handles empty", () => {
    assert.equal(summarizeTxpoolStatus(null).label, "—");
  });
});

describe("parseHexQuantity", () => {
  it("parses hex and decimal", () => {
    assert.equal(parseHexQuantity("0xa"), 10);
    assert.equal(parseHexQuantity("3"), 3);
    assert.equal(parseHexQuantity(null), null);
  });
});

describe("scanFromBlock", () => {
  it("uses Number arithmetic for ethers v6 tip values", () => {
    assert.equal(scanFromBlock(100, 5), 96);
    assert.equal(scanFromBlock(100, 40), 61);
    assert.equal(scanFromBlock(3, 5), 0);
    assert.equal(scanFromBlock(0, 40), 0);
  });
  it("accepts bigint tip without mixing types in callers", () => {
    assert.equal(scanFromBlock(100n, 30), 71);
  });
});

describe("nextBatcherScanRange", () => {
  it("full window on first scan", () => {
    const r = nextBatcherScanRange(null, 100, 12);
    assert.equal(r.from, 89);
    assert.equal(r.tip, 100);
    assert.equal(r.reset, true);
    assert.equal(r.skip, false);
  });
  it("skips when tip unchanged", () => {
    const r = nextBatcherScanRange(100, 100, 12);
    assert.equal(r.skip, true);
    assert.equal(r.reset, false);
  });
  it("fetches only new blocks when tip advances", () => {
    const r = nextBatcherScanRange(100, 103, 12);
    assert.equal(r.from, 101);
    assert.equal(r.tip, 103);
    assert.equal(r.skip, false);
  });
  it("clamps catch-up to window", () => {
    const r = nextBatcherScanRange(50, 100, 12);
    assert.equal(r.from, 89);
    assert.equal(r.reset, false);
  });
});

describe("pruneBatchTxsToWindow", () => {
  it("drops txs outside the tip window", () => {
    const out = pruneBatchTxsToWindow(
      [
        { blockNumber: 88 },
        { blockNumber: 89 },
        { blockNumber: 100 },
      ],
      100,
      12,
    );
    assert.deepEqual(
      out.map((t) => t.blockNumber),
      [89, 100],
    );
  });
});

describe("contiguousScanTip", () => {
  it("returns last contiguous success from the starting block", () => {
    const blocks = [
      { number: 10 },
      { number: 11 },
      null,
      { number: 13 },
    ];
    assert.equal(contiguousScanTip(10, blocks), 11);
  });
  it("returns null when the first block is missing", () => {
    assert.equal(contiguousScanTip(10, [null, { number: 11 }]), null);
  });
  it("returns full tip when all present", () => {
    assert.equal(
      contiguousScanTip(5, [{ number: 5 }, { number: 6 }, { number: 7 }]),
      7,
    );
  });
});

describe("applyBatcherScanSuccess", () => {
  it("on reset replaces txs and advances tip only via returned state", () => {
    const cache = {
      tip: 50,
      txs: [{ blockNumber: 50, hash: "0xold" }],
    };
    const next = applyBatcherScanSuccess(
      cache,
      { tip: 100, reset: true },
      [{ blockNumber: 100, hash: "0xnew" }],
      12,
    );
    assert.equal(next.tip, 100);
    assert.deepEqual(
      next.txs.map((t) => t.hash),
      ["0xnew"],
    );
    // Caller must assign — original cache untouched until then.
    assert.equal(cache.tip, 50);
    assert.equal(cache.txs.length, 1);
  });

  it("on incremental append keeps prior txs in window", () => {
    const cache = {
      tip: 99,
      txs: [{ blockNumber: 95, hash: "0xa" }],
    };
    const next = applyBatcherScanSuccess(
      cache,
      { tip: 100, reset: false },
      [{ blockNumber: 100, hash: "0xb" }],
      12,
    );
    assert.equal(next.tip, 100);
    assert.equal(next.txs.length, 2);
  });
});

describe("viewer Sepolia defaults", () => {
  it("uses a smaller L1 window and slower refresh on 852", () => {
    assert.equal(viewerL1ScanBlocks(852), 12);
    assert.equal(viewerL1ScanBlocks(901), 40);
    assert.equal(viewerRefreshMs(852, undefined), 15_000);
    assert.equal(viewerRefreshMs(901, undefined), 5_000);
    assert.equal(viewerRefreshMs(852, 20_000), 20_000);
  });
});

describe("viewer public-mode refresh floor", () => {
  it("clamps public mode to at least 30s even when configured lower", () => {
    assert.equal(viewerRefreshMs(852, 15_000, true), 30_000);
    assert.equal(viewerRefreshMs(901, 5_000, true), 30_000);
    assert.equal(viewerRefreshMs(852, 45_000, true), 45_000);
  });
});

describe("viewer L1 scan window is mode-split on 852", () => {
  it("keeps 12 blocks in local mode (QuickNode budget)", () => {
    assert.equal(viewerL1ScanBlocks(852), 12);
    assert.equal(viewerL1ScanBlocks(852, false), 12);
  });

  it("widens to 36 blocks in public mode (one ~25-block interval plus slack)", () => {
    assert.equal(viewerL1ScanBlocks(852, true), 36);
  });

  it("does not widen chain 901 when publicMode is true", () => {
    assert.equal(viewerL1ScanBlocks(901, true), 40);
    assert.equal(viewerL1ScanBlocks(901, false), 40);
  });

  it("app.js passes PUBLIC_MODE into viewerL1ScanBlocks", () => {
    const src = readFileSync(join(viewerDir, "app.js"), "utf8");
    assert.match(src, /viewerL1ScanBlocks\(\s*L2_CHAIN_ID\s*,\s*PUBLIC_MODE\s*\)/);
  });
});

describe("public origin allowlist", () => {
  it("fails a config that contains a QuickNode-shaped URL", () => {
    const leaked = `
      export const L1_RPC_URL = "https://some-name.quiknode.pro/abcdef0123456789token/";
      export const L2_RPC_URL = "https://fortel2-replica-rpc.onrender.com";
    `;
    const result = assertPublicViewerAllowlist(leaked);
    assert.equal(result.ok, false);
    assert.ok(result.unexpected.includes("https://some-name.quiknode.pro"));
  });

  it("accepts only the three D-0047 / publicnode origins in committed public config", () => {
    const text = readFileSync(join(viewerDir, "config.public.js"), "utf8");
    const result = assertPublicViewerConfigOrigins(text);
    assert.deepEqual(result.found, [...PUBLIC_VIEWER_ALLOWED_ORIGINS].sort());
    assert.equal(result.ok, true);
    assert.deepEqual(result.unexpected, []);
    assert.deepEqual(result.missing, []);
  });

  it("matches public.csp connect-src to PUBLIC_VIEWER_CSP", () => {
    const csp = readFileSync(join(viewerDir, "public.csp"), "utf8").trim();
    assert.equal(csp, PUBLIC_VIEWER_CSP);
    const fromCsp = httpOriginsInText(csp);
    assert.deepEqual(fromCsp, [...PUBLIC_VIEWER_ALLOWED_ORIGINS].sort());
  });
});

describe("cspForMeta strips only meta-ignored directives", () => {
  it("drops frame-ancestors and preserves every other PUBLIC_VIEWER_CSP directive", () => {
    assert.equal(META_IGNORED_CSP_DIRECTIVES.includes("frame-ancestors"), true);
    assert.match(PUBLIC_VIEWER_CSP, /frame-ancestors 'none'/);
    assert.equal(PUBLIC_VIEWER_CSP_META.includes("frame-ancestors"), false);
    assert.equal(cspForMeta(PUBLIC_VIEWER_CSP), PUBLIC_VIEWER_CSP_META);

    const parse = (policy) => {
      const out = {};
      for (const raw of policy.split(";")) {
        const d = raw.trim();
        if (!d) continue;
        const name = d.split(/\s+/)[0].toLowerCase();
        out[name] = d.slice(name.length).trim();
      }
      return out;
    };
    const full = parse(PUBLIC_VIEWER_CSP);
    const meta = parse(PUBLIC_VIEWER_CSP_META);
    assert.equal("frame-ancestors" in full, true);
    assert.equal("frame-ancestors" in meta, false);
    for (const [name, value] of Object.entries(full)) {
      if (name === "frame-ancestors") continue;
      assert.equal(meta[name], value, name);
    }
  });
});

describe("public RPC plan never calls forbidden methods", () => {
  it("omits txpool_status and optimism_syncStatus in public mode", () => {
    const plan = viewerRpcPlan(true);
    const methods = Object.values(plan).flat();
    for (const forbidden of PUBLIC_FORBIDDEN_RPC_METHODS) {
      assert.equal(methods.includes(forbidden), false, forbidden);
    }
  });

  it("keeps those methods in local mode", () => {
    const plan = viewerRpcPlan(false);
    const methods = Object.values(plan).flat();
    assert.ok(methods.includes("txpool_status"));
    assert.ok(methods.includes("optimism_syncStatus"));
  });

  it("throws if public mode attempts a forbidden RPC method", () => {
    assert.throws(
      () => assertPublicRpcMethod("txpool_status", true),
      /must not call txpool_status/,
    );
    assert.throws(
      () => assertPublicRpcMethod("optimism_syncStatus", true),
      /must not call optimism_syncStatus/,
    );
    assert.doesNotThrow(() => assertPublicRpcMethod("eth_getBlockByNumber", true));
    assert.doesNotThrow(() => assertPublicRpcMethod("txpool_status", false));
  });

  it("public sequencer helper in app.js does not name the forbidden methods", () => {
    const src = readFileSync(join(viewerDir, "app.js"), "utf8");
    const start = src.indexOf("async function refreshSequencerPublic");
    const end = src.indexOf("async function refreshSequencer(");
    assert.ok(start >= 0 && end > start);
    const publicFn = src.slice(start, end);
    assert.equal(publicFn.includes("optimism_syncStatus"), false);
    assert.equal(publicFn.includes("txpool_status"), false);
  });
});

describe("summarizePublicSequencerHeads", () => {
  const now = 1_700_000_200_000;

  it("derives heads from block tags including hex quantities", () => {
    const s = summarizePublicSequencerHeads(
      {
        unsafe: { number: "0x17d25", timestamp: "0x6565d0a8" },
        safe: { number: "0x17d25", timestamp: "0x6565d0a8" },
        finalized: { number: "0x17b84", timestamp: "0x6565c000" },
      },
      now,
    );
    assert.equal(s.unsafe, 97573);
    assert.equal(s.safe, 97573);
    assert.equal(s.finalized, 97156);
    assert.equal(s.lagUnsafeSafe, 0);
    assert.equal(s.degraded, false);
    assert.equal(s.degradeLabel, null);
  });

  it("degrades when the sequencer gateway latest head is missing", () => {
    const s = summarizePublicSequencerHeads(
      {
        unsafe: { error: "HTTP 502" },
        safe: { number: 97606, timestamp: 1_700_000_100 },
        finalized: { number: 97132, timestamp: 1_700_000_000 },
      },
      now,
    );
    assert.equal(s.unsafe, null);
    assert.equal(s.safe, 97606);
    assert.equal(s.finalized, 97132);
    assert.equal(s.unsafeAge, "unavailable");
    assert.equal(s.degraded, true);
    assert.match(s.degradeLabel, /nightly 23:45–03:00/);
    assert.equal(s.lagUnsafeSafe, null);
  });

  it("degrades when latest is null without discarding replica tags", () => {
    const s = summarizePublicSequencerHeads(
      {
        unsafe: null,
        safe: { number: "0x10", timestamp: 50 },
        finalized: { number: "0x8", timestamp: 40 },
      },
      now,
    );
    assert.equal(s.degraded, true);
    assert.equal(s.safe, 16);
    assert.equal(s.finalized, 8);
  });

  it("degrades when replica safe/finalized tags fail while unsafe is live", () => {
    const s = summarizePublicSequencerHeads(
      {
        unsafe: { number: 100, timestamp: 1_700_000_180 },
        safe: { error: "method not allowed" },
        finalized: null,
      },
      now,
    );
    assert.equal(s.unsafe, 100);
    assert.equal(s.safe, null);
    assert.equal(s.finalized, null);
    assert.equal(s.safeAge, "unavailable");
    assert.equal(s.finalizedAge, "unavailable");
    assert.equal(s.degraded, true);
    assert.match(s.degradeLabel, /Replica safe\/finalized/);
  });
});

const TX = (byte) => `0x${byte.repeat(32)}`;
const EXPLORER = "https://settlementos-explorer-ihgo.onrender.com/fortel2-sepolia/tx/";

describe("collectRecentTxs", () => {
  it("walks newest blocks first and skips empty blocks", () => {
    const txs = collectRecentTxs([
      { number: 10, timestamp: 1000, transactions: [] },
      { number: 12, timestamp: 1004, transactions: [TX("aa")] },
      {
        number: 11,
        timestamp: 1002,
        transactions: [TX("bb"), TX("cc")],
      },
      { number: 9, timestamp: 998, transactions: [TX("dd")] },
    ]);
    assert.deepEqual(
      txs.map((t) => t.hash),
      [TX("aa"), TX("cc"), TX("bb"), TX("dd")],
    );
    assert.equal(txs[0].blockNumber, 12);
    assert.equal(txs[0].timestamp, 1004);
    assert.equal(txs[1].blockNumber, 11);
    assert.equal(txs[2].hash, TX("bb"));
  });

  it("stops at the requested count", () => {
    const txs = collectRecentTxs(
      [
        { number: "0xc", timestamp: "0x3e8", transactions: [TX("11"), TX("22")] },
        { number: 11, timestamp: 1000, transactions: [TX("33")] },
      ],
      2,
    );
    assert.equal(txs.length, 2);
    assert.deepEqual(
      txs.map((t) => t.hash),
      [TX("22"), TX("11")],
    );
  });

  it("returns a short list when fewer than N exist", () => {
    const txs = collectRecentTxs(
      [
        { number: 4, timestamp: 50, transactions: [] },
        { number: 5, timestamp: 60, transactions: [TX("ee")] },
      ],
      RECENT_L2_TX_COUNT,
    );
    assert.equal(txs.length, 1);
    assert.equal(txs[0].hash, TX("ee"));
    assert.equal(txs[0].blockNumber, 5);
  });

  it("returns empty when no blocks or no txs", () => {
    assert.deepEqual(collectRecentTxs([]), []);
    assert.deepEqual(collectRecentTxs(null), []);
    assert.deepEqual(
      collectRecentTxs([{ number: 1, timestamp: 10, transactions: [] }], 10),
      [],
    );
    assert.deepEqual(collectRecentTxs([{ number: 1, transactions: [TX("ff")] }], 0), []);
  });

  it("drops malformed hashes and count-only blocks", () => {
    const txs = collectRecentTxs([
      { number: 3, timestamp: 30, transactions: 4 },
      {
        number: 2,
        timestamp: 20,
        transactions: ["0xshort", { hash: TX("ab") }, { hash: "nope" }],
      },
    ]);
    assert.equal(txs.length, 1);
    assert.equal(txs[0].hash, TX("ab"));
  });

  it("does not fill the list with L1 attributes deposits", () => {
    const l1Attr = (id) => ({
      hash: TX(id),
      from: "0xDeaDdeadDeaDdeadDeaDdeadDeaDdeadDeaD0001",
      to: "0x4200000000000000000000000000000000000015",
      type: "0x7e",
    });
    const guestbook = {
      hash: TX("ab"),
      from: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
      to: "0x5FbDB2315678afecb367f032d93F642f64180aa3",
      type: "0x2",
    };
    const userDeposit = {
      hash: TX("cd"),
      from: "0x1111111111111111111111111111111111111111",
      to: "0x2222222222222222222222222222222222222222",
      type: "0x7e",
    };
    const blocks = [];
    for (let n = 30; n >= 11; n--) {
      const id = n.toString(16).padStart(2, "0");
      blocks.push({ number: n, timestamp: 1000 + n, transactions: [l1Attr(id)] });
    }
    blocks.push({
      number: 10,
      timestamp: 1010,
      transactions: [l1Attr("ee"), userDeposit, guestbook],
    });
    const txs = collectRecentTxs(blocks, RECENT_L2_TX_COUNT);
    assert.equal(txs.length, 2);
    assert.deepEqual(
      txs.map((t) => t.hash),
      [guestbook.hash, userDeposit.hash],
    );
    assert.equal(txs[0].blockNumber, 10);
    assert.equal(isL1AttributesDeposit(l1Attr("ee")), true);
    assert.equal(L1_ATTRIBUTES_DEPOSITOR.length, 42);
    assert.equal(isL1AttributesDeposit(userDeposit), false);
    assert.equal(isL1AttributesDeposit(guestbook), false);
    assert.equal(isL1AttributesDeposit(TX("ab")), false);
  });

  it("defaults to the latest 10", () => {
    const transactions = [];
    for (let i = 0; i < 12; i++) transactions.push(TX(i.toString(16).padStart(2, "0")));
    const txs = collectRecentTxs([{ number: 8, timestamp: 80, transactions }]);
    assert.equal(RECENT_L2_TX_COUNT, 10);
    assert.equal(txs.length, 10);
    assert.equal(txs[0].hash, transactions[11]);
    assert.equal(txs[9].hash, transactions[2]);
  });
});

describe("explorerTxUrl", () => {
  it("builds the SettlementOS tx link from the default prefix", () => {
    assert.equal(DEFAULT_EXPLORER_TX_PREFIX, EXPLORER);
    const hash = TX("ab");
    assert.equal(explorerTxUrl(hash), `${EXPLORER}${hash}`);
  });

  it("accepts a prefix with or without a trailing slash", () => {
    const hash = TX("cd");
    assert.equal(
      explorerTxUrl(hash, "https://example.test/fortel2-sepolia/tx"),
      `https://example.test/fortel2-sepolia/tx/${hash}`,
    );
    assert.equal(
      explorerTxUrl(hash, "https://example.test/fortel2-sepolia/tx/"),
      `https://example.test/fortel2-sepolia/tx/${hash}`,
    );
  });

  it("rejects malformed hashes and non-http prefixes", () => {
    assert.equal(explorerTxUrl("0xabc"), null);
    assert.equal(explorerTxUrl(""), null);
    assert.equal(explorerTxUrl(TX("aa"), "javascript:alert(1)"), null);
    assert.equal(explorerTxUrl(TX("aa"), ""), `${EXPLORER}${TX("aa")}`);
  });
});

describe("recentTxHeights", () => {
  it("walks backward from the tip and stops at genesis", () => {
    assert.deepEqual(recentTxHeights(5, 10), [5, 4, 3, 2, 1, 0]);
    assert.deepEqual(recentTxHeights(100, 3), [100, 99, 98]);
    assert.equal(recentTxHeights(10, RECENT_L2_TX_LOOKBACK).length, 11);
    assert.deepEqual(recentTxHeights(-1), []);
  });
});

describe("recent tx links stay navigation-only", () => {
  it("does not embed the explorer origin in files the public bundle copies", () => {
    const files = ["app.js", "lib.js", "index.html", "styles.css", "config.public.js", "public.csp"];
    for (const name of files) {
      const text = readFileSync(join(viewerDir, name), "utf8");
      const origins = httpOriginsInText(text);
      assert.equal(
        origins.includes("https://settlementos-explorer-ihgo.onrender.com"),
        false,
        name,
      );
    }
  });

  it("renders rows with textContent and a new-tab explorer link", () => {
    const src = readFileSync(join(viewerDir, "app.js"), "utf8");
    const start = src.indexOf("function renderRecentTxs");
    const end = src.indexOf("async function loadRecentL2Txs");
    assert.ok(start >= 0 && end > start);
    const fn = src.slice(start, end);
    assert.equal(fn.includes("innerHTML"), false);
    assert.match(fn, /textContent/);
    assert.match(fn, /target = "_blank"/);
    assert.match(fn, /rel = "noopener noreferrer"/);
    assert.match(fn, /explorerTxUrl\(/);
  });

  it("prefetches L2 tx metadata when collecting recent txs", () => {
    const src = readFileSync(join(viewerDir, "app.js"), "utf8");
    const start = src.indexOf("async function loadRecentL2Txs");
    const end = src.indexOf("async function refreshRecentTxs");
    assert.ok(start >= 0 && end > start);
    assert.match(src.slice(start, end), /getBlock\(\s*n\s*,\s*true\s*\)/);
  });
});
