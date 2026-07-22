import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  aggregateTxWindow,
  applyBatcherScanSuccess,
  filterBatchTxs,
  formatAge,
  formatRate,
  nextBatcherScanRange,
  parseHexQuantity,
  pruneBatchTxsToWindow,
  scanFromBlock,
  shortHex,
  summarizeBatcherActivity,
  summarizeSyncStatus,
  summarizeTxpoolStatus,
  viewerL1ScanBlocks,
  viewerRefreshMs,
} from "./lib.js";

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
