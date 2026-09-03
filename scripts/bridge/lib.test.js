/**
 * Unit tests for bridge pure helpers (no live RPC).
 * Run: cd scripts/bridge && npm ci && node --test lib.test.js
 */
import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  loadDeployments,
  loadEnvFromShell,
  makeChains,
  MESSAGE_PASSER,
  proxyFromGameAtIndexResult,
  readJson,
  refuseAnvilWarp,
  writeJson,
  increaseTime,
  mineBlocks,
  isRealClockL1,
  assertArtifactChainIds,
  readArtifactChainIds,
  classifyFinalizeReadiness,
  classifyProveReadiness,
  dryRunExitCode,
  finalizeReadyAt,
  realClockReached,
  waitUntilRealClockReady,
  parseBridgeArgs,
  GAME_IN_PROGRESS,
  GAME_DEFENDER_WINS,
  GAME_CHALLENGER_WINS,
} from "./lib.mjs";

describe("loadDeployments", () => {
  it("reads portal and factory proxies", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fortel2-bridge-"));
    const file = path.join(dir, "deployments.json");
    writeJson(file, {
      OptimismPortalProxy: "0x1111111111111111111111111111111111111111",
      DisputeGameFactoryProxy: "0x2222222222222222222222222222222222222222",
    });
    const d = loadDeployments(file);
    assert.equal(d.portal, "0x1111111111111111111111111111111111111111");
    assert.equal(d.factory, "0x2222222222222222222222222222222222222222");
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it("rejects missing portal/factory", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fortel2-bridge-"));
    const file = path.join(dir, "deployments.json");
    writeJson(file, { SomethingElse: "0x1111111111111111111111111111111111111111" });
    assert.throws(() => loadDeployments(file), /portal\/factory/);
    fs.rmSync(dir, { recursive: true, force: true });
  });
});

describe("readJson / writeJson", () => {
  it("round-trips nested objects", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fortel2-bridge-"));
    const file = path.join(dir, "nested", "state.json");
    const obj = { a: 1, b: { c: "x" } };
    writeJson(file, obj);
    assert.deepEqual(readJson(file), obj);
    fs.rmSync(dir, { recursive: true, force: true });
  });
});

describe("loadEnvFromShell", () => {
  const keys = [
    "L1_RPC_URL",
    "L2_RPC_URL",
    "L1_CHAIN_ID",
    "L2_CHAIN_ID",
    "ADMIN_ADDRESS",
    "ADMIN_PRIVATE_KEY",
  ];
  const saved = {};

  before(() => {
    for (const k of keys) {
      saved[k] = process.env[k];
      process.env[k] = `set-${k}`;
    }
  });

  after(() => {
    for (const k of keys) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  });

  it("passes when required keys are present", () => {
    assert.doesNotThrow(() => loadEnvFromShell());
  });

  it("throws when a required key is missing", () => {
    const prev = process.env.L2_RPC_URL;
    delete process.env.L2_RPC_URL;
    assert.throws(() => loadEnvFromShell(), /missing env L2_RPC_URL/);
    process.env.L2_RPC_URL = prev;
  });
});

describe("makeChains", () => {
  const saved = {};
  const keys = ["L1_CHAIN_ID", "L2_CHAIN_ID", "L1_RPC_URL", "L2_RPC_URL"];

  before(() => {
    for (const k of keys) saved[k] = process.env[k];
    process.env.L1_CHAIN_ID = "900";
    process.env.L2_CHAIN_ID = "901";
    process.env.L1_RPC_URL = "http://127.0.0.1:8545";
    process.env.L2_RPC_URL = "http://127.0.0.1:9545";
  });

  after(() => {
    for (const k of keys) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  });

  it("wires portal / factory / message passer onto L2 chain", () => {
    const portal = "0x1111111111111111111111111111111111111111";
    const factory = "0x2222222222222222222222222222222222222222";
    const { l1, l2 } = makeChains({ portal, factory });
    assert.equal(l1.id, 900);
    assert.equal(l2.id, 901);
    assert.equal(l2.sourceId, 900);
    assert.equal(l2.contracts.portal[900].address, portal);
    assert.equal(l2.contracts.disputeGameFactory[900].address, factory);
    assert.equal(l2.contracts.l2ToL1MessagePasser.address, MESSAGE_PASSER);
  });
});

describe("proxyFromGameAtIndexResult", () => {
  const proxy = "0x3333333333333333333333333333333333333333";

  it("reads named proxy_ field", () => {
    assert.equal(
      proxyFromGameAtIndexResult({ proxy_: proxy, gameType_: 0, timestamp_: 1n }),
      proxy,
    );
  });

  it("reads positional tuple index 2", () => {
    assert.equal(proxyFromGameAtIndexResult([0, 1n, proxy]), proxy);
  });

  it("rejects missing proxy", () => {
    assert.throws(() => proxyFromGameAtIndexResult(null, 7), /gameAtIndex\(7\)/);
    assert.throws(() => proxyFromGameAtIndexResult({}), /empty proxy/);
  });

  it("rejects zero address", () => {
    assert.throws(
      () => proxyFromGameAtIndexResult({ proxy_: "0x0000000000000000000000000000000000000000" }),
      /empty proxy/,
    );
  });
});

describe("refuseAnvilWarp", () => {
  const prevSkip = process.env.SKIP_ANVIL_WARP;
  const prevL1 = process.env.L1_CHAIN_ID;
  after(() => {
    if (prevSkip === undefined) delete process.env.SKIP_ANVIL_WARP;
    else process.env.SKIP_ANVIL_WARP = prevSkip;
    if (prevL1 === undefined) delete process.env.L1_CHAIN_ID;
    else process.env.L1_CHAIN_ID = prevL1;
  });

  it("is false on local Anvil ids without the skip flag", () => {
    delete process.env.SKIP_ANVIL_WARP;
    process.env.L1_CHAIN_ID = "31337";
    assert.equal(refuseAnvilWarp(), false);
  });

  it("is true on Sepolia L1", () => {
    delete process.env.SKIP_ANVIL_WARP;
    process.env.L1_CHAIN_ID = "11155111";
    assert.equal(refuseAnvilWarp(), true);
  });

  it("is true when SKIP_ANVIL_WARP=1", () => {
    process.env.SKIP_ANVIL_WARP = "1";
    process.env.L1_CHAIN_ID = "31337";
    assert.equal(refuseAnvilWarp(), true);
  });

  it("increaseTime throws on Sepolia before any RPC", async () => {
    delete process.env.SKIP_ANVIL_WARP;
    process.env.L1_CHAIN_ID = "11155111";
    await assert.rejects(
      () =>
        increaseTime(
          {
            request: async () => {
              throw new Error("should not RPC");
            },
          },
          1,
        ),
      /refusing evm_increaseTime/,
    );
  });

  it("mineBlocks throws on Sepolia before any RPC", async () => {
    delete process.env.SKIP_ANVIL_WARP;
    process.env.L1_CHAIN_ID = "11155111";
    await assert.rejects(
      () =>
        mineBlocks(
          {
            request: async () => {
              throw new Error("should not RPC");
            },
          },
          3,
        ),
      /refusing evm_mine/,
    );
  });
});

describe("isRealClockL1", () => {
  it("is true only for Ethereum Sepolia", () => {
    assert.equal(isRealClockL1("11155111"), true);
    assert.equal(isRealClockL1("31337"), false);
    assert.equal(isRealClockL1("900"), false);
  });
});

describe("parseBridgeArgs", () => {
  it("reads artifact and --dry-run in either order", () => {
    assert.deepEqual(parseBridgeArgs(["node", "finalize.mjs", "wd.json", "--dry-run"]), {
      dryRun: true,
      artifactPath: "wd.json",
    });
    assert.deepEqual(parseBridgeArgs(["node", "finalize.mjs", "--dry-run", "wd.json"]), {
      dryRun: true,
      artifactPath: "wd.json",
    });
    assert.deepEqual(parseBridgeArgs(["node", "finalize.mjs", "wd.json"]), {
      dryRun: false,
      artifactPath: "wd.json",
    });
  });
});

describe("assertArtifactChainIds", () => {
  it("allows legacy artifacts with no chain ids", () => {
    assert.doesNotThrow(() => assertArtifactChainIds({}, 11155111, 852));
  });

  it("refuses a 901 artifact on 852", () => {
    assert.throws(
      () => assertArtifactChainIds({ l1ChainId: 900, l2ChainId: 901 }, 11155111, 852),
      /artifact chain mismatch/,
    );
  });

  it("refuses a 852 artifact on 901", () => {
    assert.throws(
      () => assertArtifactChainIds({ l1ChainId: 11155111, l2ChainId: 852 }, 900, 901),
      /artifact chain mismatch/,
    );
  });

  it("accepts a matching 852 artifact", () => {
    assert.doesNotThrow(() =>
      assertArtifactChainIds({ l1ChainId: 11155111, l2ChainId: 852 }, 11155111, 852),
    );
  });

  it("refuses incomplete chain ids", () => {
    assert.throws(
      () => assertArtifactChainIds({ l2ChainId: 852 }, 11155111, 852),
      /incomplete chain ids/,
    );
  });

  it("readArtifactChainIds prefers camelCase", () => {
    assert.deepEqual(readArtifactChainIds({ l1ChainId: 11155111, l2ChainId: 852 }), {
      l1: 11155111,
      l2: 852,
    });
  });
});

describe("classifyFinalizeReadiness / dry-run states", () => {
  const base = {
    finalityDelaySeconds: 1800,
    l1HeadTimestamp: 1_000_000,
  };

  it("already-finalized", () => {
    const c = classifyFinalizeReadiness({
      ...base,
      finalized: true,
      proven: true,
      gameStatus: GAME_DEFENDER_WINS,
      resolvedAt: 1,
    });
    assert.equal(c.verdict, "already-finalized");
    assert.equal(dryRunExitCode(c.verdict, "finalizable"), 1);
  });

  it("not-proven", () => {
    const c = classifyFinalizeReadiness({
      ...base,
      finalized: false,
      proven: false,
      gameStatus: GAME_IN_PROGRESS,
      resolvedAt: 0,
    });
    assert.equal(c.verdict, "not-proven");
    assert.equal(dryRunExitCode(c.verdict, "finalizable"), 1);
    assert.equal(dryRunExitCode(c.verdict, "not-proven"), 0);
  });

  it("proven-waiting-until-<ts> when DEFENDER_WINS but delay remains", () => {
    const resolvedAt = 1_000_000 - 100;
    const c = classifyFinalizeReadiness({
      ...base,
      finalized: false,
      proven: true,
      gameStatus: GAME_DEFENDER_WINS,
      resolvedAt,
    });
    const readyAt = finalizeReadyAt(resolvedAt, 1800);
    assert.equal(c.verdict, `proven-waiting-until-${readyAt}`);
    assert.equal(c.readyAt, readyAt);
    assert.equal(dryRunExitCode(c.verdict, "finalizable"), 1);
  });

  it("waits for the later of proof maturity and finality delay", () => {
    const waiting = classifyFinalizeReadiness({
      finalized: false,
      proven: true,
      gameStatus: GAME_DEFENDER_WINS,
      resolvedAt: 1000,
      finalityDelaySeconds: 1800,
      l1HeadTimestamp: 3000,
      proofTimestamp: 1500,
      proofMaturityDelaySeconds: 1800,
    });
    assert.equal(waiting.verdict, "proven-waiting-until-3300");
    const ready = classifyFinalizeReadiness({
      finalized: false,
      proven: true,
      gameStatus: GAME_DEFENDER_WINS,
      resolvedAt: 1000,
      finalityDelaySeconds: 1800,
      l1HeadTimestamp: 3300,
      proofTimestamp: 1500,
      proofMaturityDelaySeconds: 1800,
    });
    assert.equal(ready.verdict, "finalizable");
  });

  it("finalizable when DEFENDER_WINS and delay has passed", () => {
    const resolvedAt = 1_000_000 - 1800;
    const c = classifyFinalizeReadiness({
      ...base,
      finalized: false,
      proven: true,
      gameStatus: GAME_DEFENDER_WINS,
      resolvedAt,
      l1HeadTimestamp: 1_000_000,
    });
    assert.equal(c.verdict, "finalizable");
    assert.equal(dryRunExitCode(c.verdict, "finalizable"), 0);
  });

  it("proven-waiting while game still IN_PROGRESS", () => {
    const c = classifyFinalizeReadiness({
      ...base,
      finalized: false,
      proven: true,
      gameStatus: GAME_IN_PROGRESS,
      resolvedAt: 0,
      createdAt: 990_000,
      maxClockDuration: 7200,
    });
    assert.match(c.verdict, /^proven-waiting-until-/);
    assert.equal(dryRunExitCode(c.verdict, "finalizable"), 1);
  });

  it("CHALLENGER_WINS is not finalizable", () => {
    const c = classifyFinalizeReadiness({
      ...base,
      finalized: false,
      proven: true,
      gameStatus: GAME_CHALLENGER_WINS,
      resolvedAt: 1,
    });
    assert.equal(c.verdict, "not-proven");
    assert.equal(c.error, "CHALLENGER_WINS");
    assert.equal(dryRunExitCode(c.verdict, "finalizable"), 1);
  });
});

describe("classifyProveReadiness", () => {
  it("not-proven is the expected prove next step", () => {
    const c = classifyProveReadiness({ finalized: false, proven: false });
    assert.equal(c.verdict, "not-proven");
    assert.equal(dryRunExitCode(c.verdict, "not-proven"), 0);
  });

  it("already-finalized is not the prove next step", () => {
    const c = classifyProveReadiness({ finalized: true, proven: true });
    assert.equal(c.verdict, "already-finalized");
    assert.equal(dryRunExitCode(c.verdict, "not-proven"), 1);
  });
});

describe("real-clock wait logic", () => {
  it("finalizeReadyAt is resolvedAt + delay", () => {
    assert.equal(finalizeReadyAt(100, 1800), 1900);
    assert.equal(realClockReached(1899, 1900), false);
    assert.equal(realClockReached(1900, 1900), true);
  });

  it("waitUntilRealClockReady returns finalizable when a later snapshot is ready", async () => {
    let n = 0;
    const classification = await waitUntilRealClockReady({
      getSnapshot: async () => {
        n += 1;
        if (n === 1) {
          return {
            finalized: false,
            proven: true,
            gameStatus: GAME_DEFENDER_WINS,
            resolvedAt: 100,
            finalityDelaySeconds: 50,
            l1HeadTimestamp: 140,
          };
        }
        return {
          finalized: false,
          proven: true,
          gameStatus: GAME_DEFENDER_WINS,
          resolvedAt: 100,
          finalityDelaySeconds: 50,
          l1HeadTimestamp: 150,
        };
      },
      maxWaitMs: 10_000,
      pollMs: 1,
      sleepFn: async () => {},
      nowFn: () => 0,
    });
    assert.equal(classification.verdict, "finalizable");
    assert.equal(n, 2);
  });

  it("waitUntilRealClockReady throws when max wait is exceeded (can go red)", async () => {
    let now = 0;
    await assert.rejects(
      () =>
        waitUntilRealClockReady({
          getSnapshot: async () => ({
            finalized: false,
            proven: true,
            gameStatus: GAME_DEFENDER_WINS,
            resolvedAt: 100,
            finalityDelaySeconds: 50,
            l1HeadTimestamp: 120,
          }),
          maxWaitMs: 5,
          pollMs: 1,
          sleepFn: async () => {
            now += 10;
          },
          nowFn: () => now,
        }),
      /real-clock wait exceeded/,
    );
  });
});
