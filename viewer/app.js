/**
 * ForteL2 pipeline viewer — Phase 1c ops UI (chain 901).
 * Client-side RPC polls only; ethers vendored under ./vendor/.
 */
import { Contract, JsonRpcProvider, isAddress } from "./vendor/ethers-6.13.5.min.js";
import {
  L1_RPC_URL,
  L2_RPC_URL,
  L2_NODE_RPC_URL,
  BATCHER_ADDRESS,
  BATCH_INBOX_ADDRESS,
  DISPUTE_GAME_FACTORY,
  DISPUTE_GAME_FACTORY_ABI,
  REFRESH_MS,
} from "./config.js";
import {
  aggregateTxWindow,
  filterBatchTxs,
  formatAge,
  formatRate,
  scanFromBlock,
  shortHex,
  summarizeBatcherActivity,
  summarizeSyncStatus,
} from "./lib.js";

const L1_SCAN_BLOCKS = 40;
const L2_WINDOW_BLOCKS = 30;

const els = {
  status: document.getElementById("status"),
  refreshMeta: document.getElementById("refresh-meta"),
  seqErr: document.getElementById("seq-err"),
  batErr: document.getElementById("bat-err"),
  propErr: document.getElementById("prop-err"),
  aggErr: document.getElementById("agg-err"),
  seqUnsafe: document.getElementById("seq-unsafe"),
  seqSafe: document.getElementById("seq-safe"),
  seqFinalized: document.getElementById("seq-finalized"),
  seqLag: document.getElementById("seq-lag"),
  seqInterval: document.getElementById("seq-interval"),
  batCount: document.getElementById("bat-count"),
  batHash: document.getElementById("bat-hash"),
  batAge: document.getElementById("bat-age"),
  batCadence: document.getElementById("bat-cadence"),
  propCount: document.getElementById("prop-count"),
  propProxy: document.getElementById("prop-proxy"),
  propAge: document.getElementById("prop-age"),
  propType: document.getElementById("prop-type"),
  aggWindow: document.getElementById("agg-window"),
  aggFill: document.getElementById("agg-fill"),
  aggTxs: document.getElementById("agg-txs"),
  aggRate: document.getElementById("agg-rate"),
  panelSequencer: document.getElementById("panel-sequencer"),
  panelBatcher: document.getElementById("panel-batcher"),
  panelProposer: document.getElementById("panel-proposer"),
  panelAggregate: document.getElementById("panel-aggregate"),
};

const refreshMs = Number(REFRESH_MS) > 0 ? Number(REFRESH_MS) : 5000;
let pollTimer = null;
let inFlight = false;

function setStatus(msg, isError = false) {
  els.status.textContent = msg;
  els.status.classList.toggle("is-error", Boolean(isError));
}

function setPanelError(errEl, panelEl, message) {
  if (message) {
    errEl.hidden = false;
    errEl.textContent = message;
    panelEl.classList.add("is-stale");
  } else {
    errEl.hidden = true;
    errEl.textContent = "";
    panelEl.classList.remove("is-stale");
  }
}

function assertViewerConfig() {
  const missing = [];
  if (!isAddress(BATCHER_ADDRESS)) missing.push("BATCHER_ADDRESS");
  if (!isAddress(BATCH_INBOX_ADDRESS)) missing.push("BATCH_INBOX_ADDRESS");
  if (!isAddress(DISPUTE_GAME_FACTORY)) missing.push("DISPUTE_GAME_FACTORY");
  if (missing.length) {
    throw new Error(
      `Missing config (${missing.join(", ")}). Run: ./scripts/gen-viewer-config.sh`,
    );
  }
}

async function rpcJson(url, method, params = []) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status} from ${url}`);
  const body = await res.json();
  if (body.error) {
    throw new Error(body.error.message || JSON.stringify(body.error));
  }
  return body.result;
}

function headLine(num, age) {
  if (num == null) return "—";
  return `#${num} (${age})`;
}

async function refreshSequencer(l2, nodeUrl) {
  const status = await rpcJson(nodeUrl, "optimism_syncStatus", []);
  const summary = summarizeSyncStatus(status);
  els.seqUnsafe.textContent = headLine(summary.unsafe, summary.unsafeAge);
  els.seqSafe.textContent = headLine(summary.safe, summary.safeAge);
  els.seqFinalized.textContent = headLine(summary.finalized, summary.finalizedAge);
  els.seqLag.textContent =
    summary.lagUnsafeSafe == null ? "—" : String(summary.lagUnsafeSafe);

  const tip = await l2.getBlockNumber();
  const from = scanFromBlock(tip, 5);
  const blocks = [];
  for (let n = from; n <= tip; n++) {
    const b = await l2.getBlock(n);
    if (b) blocks.push(b);
  }
  const agg = aggregateTxWindow(blocks);
  els.seqInterval.textContent =
    agg.avgIntervalSec == null ? "—" : `${formatRate(agg.avgIntervalSec, 1)}s`;
}

async function refreshBatcher(l1) {
  const tip = await l1.getBlockNumber();
  const from = scanFromBlock(tip, L1_SCAN_BLOCKS);
  const collected = [];
  for (let n = from; n <= tip; n++) {
    const block = await l1.getBlock(n, true);
    if (!block) continue;
    const txs = (block.prefetchedTransactions || block.transactions || []).map((tx) => {
      if (typeof tx === "string") return null;
      return {
        hash: tx.hash,
        from: tx.from,
        to: tx.to,
        blockNumber: Number(block.number),
        blockTimestamp: Number(block.timestamp),
      };
    }).filter(Boolean);
    collected.push(...filterBatchTxs(txs, BATCHER_ADDRESS, BATCH_INBOX_ADDRESS));
  }
  const summary = summarizeBatcherActivity(collected);
  els.batCount.textContent = `${summary.count} in last ${L1_SCAN_BLOCKS} L1 blocks`;
  els.batHash.textContent = summary.lastHash ? shortHex(summary.lastHash, 8, 6) : "none yet";
  els.batAge.textContent = summary.lastAge;
  els.batCadence.textContent =
    summary.cadenceSec == null ? "—" : `~${summary.cadenceSec}s`;
}

async function refreshProposer(l1) {
  const factory = new Contract(DISPUTE_GAME_FACTORY, DISPUTE_GAME_FACTORY_ABI, l1);
  const count = await factory.gameCount();
  els.propCount.textContent = count.toString();
  if (count === 0n) {
    els.propProxy.textContent = "none yet";
    els.propAge.textContent = "—";
    els.propType.textContent = "—";
    return;
  }
  const idx = count - 1n;
  const game = await factory.gameAtIndex(idx);
  const gameType = game.gameType_ ?? game[0];
  const timestamp = game.timestamp_ ?? game[1];
  const proxy = game.proxy_ ?? game[2];
  els.propProxy.textContent = shortHex(String(proxy), 6, 4);
  els.propAge.textContent = formatAge(timestamp);
  els.propType.textContent = String(gameType);
}

async function refreshAggregate(l2) {
  const tip = await l2.getBlockNumber();
  const from = scanFromBlock(tip, L2_WINDOW_BLOCKS);
  const blocks = [];
  for (let n = from; n <= tip; n++) {
    const b = await l2.getBlock(n, false);
    if (!b) continue;
    const txLen = Array.isArray(b.transactions) ? b.transactions.length : 0;
    blocks.push({ timestamp: Number(b.timestamp), transactions: txLen });
  }
  const agg = aggregateTxWindow(blocks);
  els.aggWindow.textContent =
    agg.windowSec == null
      ? `${agg.blockCount} blocks`
      : `${agg.blockCount} blocks / ${agg.windowSec}s`;
  els.aggFill.textContent = `${agg.nonEmpty} / ${agg.empty}`;
  els.aggTxs.textContent = String(agg.txCount);
  els.aggRate.textContent =
    agg.txPerMin == null ? "—" : formatRate(agg.txPerMin, 1);
}

async function tick() {
  if (inFlight) return;
  inFlight = true;
  const started = Date.now();
  try {
    assertViewerConfig();
    const l1 = new JsonRpcProvider(L1_RPC_URL);
    const l2 = new JsonRpcProvider(L2_RPC_URL);

    const results = await Promise.allSettled([
      refreshSequencer(l2, L2_NODE_RPC_URL).then(() =>
        setPanelError(els.seqErr, els.panelSequencer, null),
      ),
      refreshBatcher(l1).then(() => setPanelError(els.batErr, els.panelBatcher, null)),
      refreshProposer(l1).then(() => setPanelError(els.propErr, els.panelProposer, null)),
      refreshAggregate(l2).then(() =>
        setPanelError(els.aggErr, els.panelAggregate, null),
      ),
    ]);

    const labels = ["Sequencer", "Batcher", "Proposer", "Aggregate"];
    const panels = [
      [els.seqErr, els.panelSequencer],
      [els.batErr, els.panelBatcher],
      [els.propErr, els.panelProposer],
      [els.aggErr, els.panelAggregate],
    ];
    let failures = 0;
    results.forEach((r, i) => {
      if (r.status === "rejected") {
        failures += 1;
        const msg = r.reason?.message || String(r.reason);
        setPanelError(panels[i][0], panels[i][1], `${labels[i]} RPC failed: ${msg}`);
      }
    });

    if (failures === 4) {
      setStatus("All panels failed — is the stack up? ./scripts/status.sh", true);
    } else if (failures > 0) {
      setStatus(`${failures} panel(s) failed; others updated.`, true);
    } else {
      setStatus("Live — polling L1, L2, and op-node.");
    }
  } catch (err) {
    setStatus(err?.message || String(err), true);
  } finally {
    const elapsed = Date.now() - started;
    els.refreshMeta.textContent = `Refresh every ${Math.round(refreshMs / 1000)}s · last ${elapsed}ms · ${new Date().toLocaleTimeString()}`;
    els.refreshMeta.classList.remove("is-pulse");
    void els.refreshMeta.offsetWidth;
    els.refreshMeta.classList.add("is-pulse");
    inFlight = false;
  }
}

tick();
pollTimer = setInterval(tick, refreshMs);

window.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") tick();
});

// Avoid unused lint noise if bundlers ever look; keep timer reachable.
void pollTimer;
