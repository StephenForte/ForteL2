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
  writeJson,
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
