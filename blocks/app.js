/**
 * ForteL2 block viewer — Phase 6 (chain 901 local or 852 Sepolia).
 * Client-side L2 RPC polls only; ethers vendored under ./vendor/.
 */
import { JsonRpcProvider } from "./vendor/ethers-6.13.5.min.js";
import { L1_CHAIN_ID, L2_CHAIN_ID, L2_RPC_URL } from "./config.js";
import {
  blocksPageSize,
  buildRouteHash,
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

const PAGE_SIZE = blocksPageSize(L2_CHAIN_ID);

const els = {
  lede: document.getElementById("lede"),
  status: document.getElementById("status"),
  livePill: document.getElementById("live-pill"),
  liveLabel: document.getElementById("live-label"),
  viewList: document.getElementById("view-list"),
  viewDetail: document.getElementById("view-detail"),
  blocksTbody: document.getElementById("blocks-tbody"),
  loadMore: document.getElementById("load-more"),
  navSep: document.getElementById("nav-sep"),
  navDetail: document.getElementById("nav-detail"),
  detailTitle: document.getElementById("detail-title"),
  detailErr: document.getElementById("detail-err"),
  detailHeader: document.getElementById("detail-header"),
  txTbody: document.getElementById("tx-tbody"),
  txEmpty: document.getElementById("tx-empty"),
};

/** @type {JsonRpcProvider|null} */
let provider = null;
/** @type {Array<{number: number}>} */
let listBlocks = [];
let listOldest = null;
let listHasMore = false;
let listLoading = false;
/** @type {number} Monotonic token; latest navigation wins over in-flight detail loads. */
let detailLoadSeq = 0;

function getProvider() {
  if (!provider) provider = new JsonRpcProvider(L2_RPC_URL);
  return provider;
}

function setStatus(msg, isError = false) {
  els.status.textContent = msg;
  els.status.classList.toggle("is-error", Boolean(isError));
  if (els.livePill && els.liveLabel) {
    if (isError) {
      els.livePill.dataset.state = "error";
      els.liveLabel.textContent = "Error";
    } else if (msg) {
      els.livePill.dataset.state = "live";
      els.liveLabel.textContent = "Live";
    } else {
      els.livePill.dataset.state = "idle";
      els.liveLabel.textContent = "Idle";
    }
  }
}

function clearChildren(el) {
  while (el.firstChild) el.removeChild(el.firstChild);
}

function appendMetric(dl, label, value) {
  const wrap = document.createElement("div");
  const dt = document.createElement("dt");
  dt.textContent = label;
  const dd = document.createElement("dd");
  dd.textContent = value ?? "—";
  wrap.appendChild(dt);
  wrap.appendChild(dd);
  dl.appendChild(wrap);
}

function renderListRows(blocks) {
  clearChildren(els.blocksTbody);
  for (const block of blocks) {
    const row = summarizeBlockListRow(block);
    const tr = document.createElement("tr");
    const tdHeight = document.createElement("td");
    const link = document.createElement("a");
    link.href = buildRouteHash("detail", row.number);
    link.className = "row-link mono";
    link.textContent = String(row.number ?? "—");
    tdHeight.appendChild(link);

    const tdHash = document.createElement("td");
    tdHash.className = "mono";
    tdHash.textContent = row.shortHash;

    const tdTime = document.createElement("td");
    tdTime.textContent = `${row.timeIso} (${row.age})`;

    const tdTxs = document.createElement("td");
    tdTxs.textContent = row.txCount == null ? "—" : String(row.txCount);

    tr.appendChild(tdHeight);
    tr.appendChild(tdHash);
    tr.appendChild(tdTime);
    tr.appendChild(tdTxs);
    els.blocksTbody.appendChild(tr);
  }
}

async function fetchBlockRange(from, to) {
  const l2 = getProvider();
  const nums = [];
  for (let n = from; n <= to; n++) nums.push(n);
  const blocks = await Promise.all(nums.map((n) => l2.getBlock(n)));
  return blocks.filter(Boolean);
}

async function loadInitialList() {
  if (listLoading) return;
  listLoading = true;
  els.loadMore.disabled = true;
  setStatus("Loading recent blocks…");
  try {
    const l2 = getProvider();
    const tip = await l2.getBlockNumber();
    const range = initialBlocksRange(tip, PAGE_SIZE);
    const blocks = await fetchBlockRange(range.from, range.to);
    listBlocks = sortBlocksNewestFirst(blocks);
    listOldest = listBlocks.length ? Number(listBlocks[listBlocks.length - 1].number) : null;
    listHasMore = listOldest != null && listOldest > 0;
    renderListRows(listBlocks);
    setStatus(`Showing ${listBlocks.length} blocks · tip #${tip}`);
  } catch (err) {
    clearChildren(els.blocksTbody);
    setStatus(err?.message || String(err), true);
    listHasMore = false;
  } finally {
    els.loadMore.disabled = !listHasMore;
    els.loadMore.hidden = !listHasMore && listBlocks.length > 0;
    listLoading = false;
  }
}

async function loadMoreBlocks() {
  if (listLoading || !listHasMore || listOldest == null) return;
  listLoading = true;
  els.loadMore.disabled = true;
  setStatus("Loading older blocks…");
  try {
    const range = nextBlocksPageRange(listOldest, PAGE_SIZE);
    if (range.count <= 0) {
      listHasMore = false;
      return;
    }
    const blocks = await fetchBlockRange(range.from, range.to);
    const merged = sortBlocksNewestFirst([...listBlocks, ...blocks]);
    listBlocks = merged;
    listOldest = range.from;
    listHasMore = range.hasMore;
    renderListRows(listBlocks);
    setStatus(`Showing ${listBlocks.length} blocks`);
  } catch (err) {
    setStatus(err?.message || String(err), true);
  } finally {
    els.loadMore.disabled = !listHasMore;
    els.loadMore.hidden = !listHasMore;
    listLoading = false;
  }
}

function renderDetailHeader(header) {
  clearChildren(els.detailHeader);
  appendMetric(els.detailHeader, "Height", header.number != null ? `#${header.number}` : "—");
  appendMetric(els.detailHeader, "Hash", header.hash || "—");
  appendMetric(els.detailHeader, "Parent hash", header.parentHash || "—");
  appendMetric(els.detailHeader, "Timestamp", `${header.timeIso} (${header.age})`);
  appendMetric(els.detailHeader, "Gas used", header.gasUsed || "—");
  appendMetric(els.detailHeader, "Gas limit", header.gasLimit || "—");
  appendMetric(els.detailHeader, "Tx count", header.txCount != null ? String(header.txCount) : "—");
  appendMetric(els.detailHeader, "Miner", header.miner ? shortHex(header.miner, 8, 6) : "—");
}

function renderTxRows(txs) {
  clearChildren(els.txTbody);
  if (!txs.length) {
    els.txEmpty.hidden = false;
    return;
  }
  els.txEmpty.hidden = true;
  for (const tx of txs) {
    const tr = document.createElement("tr");
    for (const [key, cls] of [
      ["shortHash", "mono"],
      ["from", "mono"],
      ["to", "mono"],
      ["value", ""],
      ["type", ""],
    ]) {
      const td = document.createElement("td");
      if (cls) td.className = cls;
      const val = tx[key];
      td.textContent =
        key === "from" || key === "to"
          ? val
            ? shortHex(val, 6, 4)
            : "—"
          : val ?? "—";
      tr.appendChild(td);
    }
    els.txTbody.appendChild(tr);
  }
}

function blockDetailTransactions(block) {
  if (block?.prefetchedTransactions != null) {
    return block.prefetchedTransactions;
  }
  return block?.transactions ?? [];
}

async function loadBlockDetail(blockParam) {
  const loadToken = ++detailLoadSeq;
  els.detailErr.hidden = true;
  els.detailErr.textContent = "";
  els.viewDetail.classList.remove("is-stale");
  setStatus("Loading block…");
  try {
    const parsed = parseBlockParam(blockParam);
    if (parsed.kind === "invalid") {
      throw new Error(`Invalid block param: ${blockParam}`);
    }
    const l2 = getProvider();
    const block = await l2.getBlock(parsed.value, true);
    if (loadToken !== detailLoadSeq) return;
    if (!block) {
      throw new Error(`Block not found: ${blockParam}`);
    }
    const header = summarizeBlockHeader(block);
    els.detailTitle.textContent = `Block #${header.number}`;
    els.navDetail.hidden = false;
    els.navSep.hidden = false;
    els.navDetail.textContent = `#${header.number}`;
    renderDetailHeader(header);
    renderTxRows(summarizeTxRows(blockDetailTransactions(block)));
    setStatus(`Block #${header.number} · ${header.txCount} tx(s)`);
  } catch (err) {
    if (loadToken !== detailLoadSeq) return;
    els.detailErr.hidden = false;
    els.detailErr.textContent = err?.message || String(err);
    els.viewDetail.classList.add("is-stale");
    clearChildren(els.detailHeader);
    clearChildren(els.txTbody);
    els.txEmpty.hidden = true;
    setStatus(err?.message || String(err), true);
  }
}

function showView(route) {
  const isList = route.view === "list";
  els.viewList.hidden = !isList;
  els.viewDetail.hidden = isList;
  els.navDetail.hidden = isList;
  els.navSep.hidden = isList;
  if (isList) {
    els.navDetail.textContent = "";
    if (listBlocks.length === 0 && !listLoading) {
      loadInitialList();
    }
  } else {
    loadBlockDetail(route.blockParam);
  }
}

function applyModeCopy() {
  if (!els.lede) return;
  if (Number(L2_CHAIN_ID) === 852) {
    els.lede.textContent =
      `Sepolia mode (L2 ${L2_CHAIN_ID} / L1 ${L1_CHAIN_ID}): browse recent L2 blocks ` +
      "newest-first and open one block for header fields and tx rows. " +
      "Not a block explorer — no search, no address pages.";
  } else {
    els.lede.textContent =
      `Local Anvil mode (L2 ${L2_CHAIN_ID} / L1 ${L1_CHAIN_ID}): browse recent L2 blocks ` +
      "newest-first and open one block for header fields and tx rows. " +
      "Not a block explorer — no search, no address pages.";
  }
}

function onRouteChange() {
  showView(parseRouteHash(window.location.hash));
}

applyModeCopy();
els.loadMore.addEventListener("click", () => loadMoreBlocks());
window.addEventListener("hashchange", onRouteChange);
onRouteChange();
