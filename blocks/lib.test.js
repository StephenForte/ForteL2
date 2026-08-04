import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  blocksPageSize,
  buildRouteHash,
  formatAge,
  formatBlockTimestamp,
  formatEthValue,
  initialBlocksRange,
  nextBlocksPageRange,
  parseBlockParam,
  parseRouteHash,
  shortHex,
  sortBlocksNewestFirst,
  summarizeBlockHeader,
  summarizeBlockListRow,
  summarizeTxRows,
} from "./lib.js";

describe("formatAge", () => {
  const now = 1_700_000_100_000;
  it("formats seconds", () => {
    assert.equal(formatAge(1_700_000_090, now), "10s ago");
  });
  it("handles missing", () => {
    assert.equal(formatAge(null, now), "—");
  });
});

describe("shortHex", () => {
  it("shortens hashes", () => {
    assert.equal(
      shortHex("0x1234567890abcdef1234567890abcdef12345678", 4, 4),
      "0x1234…5678",
    );
  });
});

describe("formatBlockTimestamp", () => {
  it("returns ISO and age", () => {
    const ts = formatBlockTimestamp(1_700_000_000, 1_700_000_100_000);
    assert.match(ts.iso, /UTC$/);
    assert.equal(ts.age, "1m 40s ago");
  });
});

describe("blocksPageSize", () => {
  it("uses smaller pages on Sepolia", () => {
    assert.equal(blocksPageSize(852), 15);
    assert.equal(blocksPageSize(901), 25);
  });
});

describe("initialBlocksRange", () => {
  it("returns inclusive range ending at tip", () => {
    const r = initialBlocksRange(100, 25);
    assert.equal(r.from, 76);
    assert.equal(r.to, 100);
    assert.equal(r.count, 25);
  });
  it("clamps at genesis", () => {
    const r = initialBlocksRange(10, 25);
    assert.equal(r.from, 0);
    assert.equal(r.to, 10);
    assert.equal(r.count, 11);
  });
});

describe("nextBlocksPageRange", () => {
  it("fetches older blocks", () => {
    const r = nextBlocksPageRange(76, 25);
    assert.equal(r.to, 75);
    assert.equal(r.from, 51);
    assert.equal(r.hasMore, true);
  });
  it("stops at genesis", () => {
    const r = nextBlocksPageRange(5, 25);
    assert.equal(r.from, 0);
    assert.equal(r.to, 4);
    assert.equal(r.hasMore, false);
  });
  it("returns empty when oldest is zero", () => {
    const r = nextBlocksPageRange(0, 25);
    assert.equal(r.count, 0);
    assert.equal(r.hasMore, false);
  });
});

describe("sortBlocksNewestFirst", () => {
  it("orders by descending number", () => {
    const sorted = sortBlocksNewestFirst([{ number: 1 }, { number: 5 }, { number: 3 }]);
    assert.deepEqual(sorted.map((b) => b.number), [5, 3, 1]);
  });
});

describe("summarizeBlockListRow", () => {
  it("extracts list fields", () => {
    const row = summarizeBlockListRow({
      number: 42,
      hash: "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
      timestamp: 1_700_000_000,
      transactions: [{ hash: "0x1" }, { hash: "0x2" }],
    });
    assert.equal(row.number, 42);
    assert.equal(row.txCount, 2);
    assert.match(row.shortHash, /^0x/);
    assert.match(row.timeIso, /UTC$/);
  });
  it("handles null block", () => {
    const row = summarizeBlockListRow(null);
    assert.equal(row.number, null);
    assert.equal(row.shortHash, "—");
  });
});

describe("summarizeBlockHeader", () => {
  it("extracts header fields", () => {
    const h = summarizeBlockHeader({
      number: 10,
      hash: "0xabc",
      parentHash: "0xdef",
      timestamp: 100,
      gasUsed: 21000n,
      gasLimit: 30000000n,
      miner: "0xminer",
      transactions: [],
    });
    assert.equal(h.number, 10);
    assert.equal(h.gasUsed, "21000");
    assert.equal(h.txCount, 0);
  });
});

describe("formatEthValue", () => {
  it("formats ETH", () => {
    assert.equal(formatEthValue(1000000000000000000n), "1.0000 ETH");
    assert.equal(formatEthValue(0n), "0 ETH");
  });
  it("shows wei for tiny values", () => {
    assert.equal(formatEthValue(100n), "100 wei");
  });
});

describe("summarizeTxRows", () => {
  it("summarizes full tx objects", () => {
    const rows = summarizeTxRows([
      {
        hash: "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
        from: "0xfrom",
        to: "0xto",
        value: 1000000000000000000n,
        type: 2,
      },
    ]);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].from, "0xfrom");
    assert.equal(rows[0].value, "1.0000 ETH");
    assert.equal(rows[0].type, "2");
  });
  it("handles hash-only entries", () => {
    const rows = summarizeTxRows(["0xabc"]);
    assert.equal(rows[0].hash, "0xabc");
    assert.equal(rows[0].from, null);
  });
});

describe("parseBlockParam", () => {
  it("accepts decimal height", () => {
    assert.deepEqual(parseBlockParam("42"), { kind: "number", value: 42 });
  });
  it("accepts 32-byte hash", () => {
    const h = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";
    assert.deepEqual(parseBlockParam(h), { kind: "hash", value: h });
  });
  it("rejects invalid", () => {
    assert.equal(parseBlockParam("not-a-block").kind, "invalid");
    assert.equal(parseBlockParam("0xshort").kind, "invalid");
  });
});

describe("parseRouteHash", () => {
  it("defaults to list", () => {
    assert.deepEqual(parseRouteHash(""), { view: "list", blockParam: null });
    assert.deepEqual(parseRouteHash("#/"), { view: "list", blockParam: null });
  });
  it("parses block detail", () => {
    assert.deepEqual(parseRouteHash("#/block/123"), {
      view: "detail",
      blockParam: "123",
    });
  });
});

describe("buildRouteHash", () => {
  it("builds list and detail hashes", () => {
    assert.equal(buildRouteHash("list"), "#/");
    assert.equal(buildRouteHash("detail", 99), "#/block/99");
  });
});
