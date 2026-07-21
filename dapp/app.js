/**
 * ForteL2 Guestbook — local learning dApp (chain 901).
 * Uses vendored ethers v6; wallet + RPC stay on loopback.
 */
import { BrowserProvider, Contract, JsonRpcProvider, isAddress } from "./vendor/ethers-6.13.5.min.js";
import { GUESTBOOK_ADDRESS, GUESTBOOK_ABI, L2_CHAIN_ID, L2_RPC_URL } from "./config.js";
import { trimToUtf8Bytes, utf8ByteLength } from "./lib.js";

const L2_CHAIN_HEX = `0x${Number(L2_CHAIN_ID).toString(16)}`;
const FEE = { maxFeePerGas: 1_000_000_000n, maxPriorityFeePerGas: 1_000_000_000n };
const PAGE = 50;
const MAX_TEXT_BYTES = 280;

/**
 * Trim to MAX_TEXT_BYTES and refresh the counter/color.
 * Skip while IME is composing unless force=true (post-sign reset / recovery).
 */
function syncMessageByteBudget(ev, { force = false } = {}) {
  if (!force && (ev?.isComposing || imeComposing)) return;
  const value = trimToUtf8Bytes(els.text.value, MAX_TEXT_BYTES);
  if (value !== els.text.value) els.text.value = value;
  const bytes = utf8ByteLength(els.text.value);
  els.charCount.textContent = String(bytes);
  els.charCount.style.color = bytes >= MAX_TEXT_BYTES ? "var(--warn)" : "";
}

const els = {
  connect: document.getElementById("connect"),
  refresh: document.getElementById("refresh"),
  sign: document.getElementById("sign"),
  text: document.getElementById("text"),
  status: document.getElementById("status"),
  list: document.getElementById("messages"),
  empty: document.getElementById("empty"),
  charCount: document.getElementById("char-count"),
};

let provider = null;
let signer = null;
let writeContract = null;
let busy = false;
let imeComposing = false;

function setStatus(msg, isError = false) {
  els.status.textContent = msg;
  els.status.classList.toggle("is-error", Boolean(isError));
}

function shortAddr(addr) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

function formatTime(ts) {
  const n = Number(ts);
  if (!n) return "";
  try {
    return new Date(n * 1000).toLocaleString();
  } catch {
    return "";
  }
}

function assertGuestbookConfig() {
  if (!GUESTBOOK_ADDRESS || !isAddress(GUESTBOOK_ADDRESS)) {
    throw new Error("Deploy Guestbook first: ./scripts/deploy-guestbook.sh");
  }
}

function readContract() {
  assertGuestbookConfig();
  if (writeContract) return writeContract;
  return new Contract(GUESTBOOK_ADDRESS, GUESTBOOK_ABI, new JsonRpcProvider(L2_RPC_URL));
}

async function ensureNetwork() {
  const eth = window.ethereum;
  if (!eth) throw new Error("No injected wallet — install MetaMask");
  const chainId = await eth.request({ method: "eth_chainId" });
  if (parseInt(chainId, 16) === Number(L2_CHAIN_ID)) return;
  try {
    await eth.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: L2_CHAIN_HEX }],
    });
  } catch (err) {
    if (err?.code === 4902) {
      await eth.request({
        method: "wallet_addEthereumChain",
        params: [{
          chainId: L2_CHAIN_HEX,
          chainName: "ForteL2",
          nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
          rpcUrls: [L2_RPC_URL],
        }],
      });
    } else {
      throw err;
    }
  }
}

function setConnectedUi(connected) {
  els.sign.disabled = !connected || busy;
  els.text.disabled = !connected || busy;
  els.connect.textContent = connected ? "Reconnect" : "Connect wallet";
}

async function connect() {
  if (busy) return;
  busy = true;
  try {
    await ensureNetwork();
    provider = new BrowserProvider(window.ethereum);
    await provider.send("eth_requestAccounts", []);
    signer = await provider.getSigner();
    assertGuestbookConfig();
    writeContract = new Contract(GUESTBOOK_ADDRESS, GUESTBOOK_ABI, signer);
    const addr = await signer.getAddress();
    setConnectedUi(true);
    setStatus(`Connected ${shortAddr(addr)} on ForteL2`);
    await refresh();
  } catch (e) {
    setStatus(e?.shortMessage || e?.message || String(e), true);
  } finally {
    busy = false;
    setConnectedUi(Boolean(writeContract));
  }
}

function renderEntries(entries, total) {
  els.list.replaceChildren();
  if (!entries.length) {
    els.empty.classList.remove("hidden");
    return;
  }
  els.empty.classList.add("hidden");
  const startIndex = Math.max(0, total - entries.length);
  entries.forEach((entry, i) => {
    const index = startIndex + i;
    const li = document.createElement("li");
    li.style.animationDelay = `${Math.min(i, 12) * 0.03}s`;

    const body = document.createElement("p");
    body.className = "body";
    body.textContent = entry.text;

    const meta = document.createElement("p");
    meta.className = "meta";
    const parts = [`#${index}`, shortAddr(entry.author)];
    const when = formatTime(entry.timestamp);
    if (when) parts.push(when);
    meta.textContent = parts.join(" · ");

    li.append(body, meta);
    // Newest first visually
    els.list.prepend(li);
  });
}

async function refresh() {
  try {
    const c = readContract();
    const total = Number(await c.count());
    if (total === 0) {
      renderEntries([], 0);
      if (!writeContract) setStatus("0 messages on-chain");
      return;
    }
    const offset = Math.max(0, total - PAGE);
    const limit = Math.min(PAGE, total - offset);
    const entries = await c.getEntries(offset, limit);
    renderEntries(entries, total);
    if (!writeContract) setStatus(`${total} message(s) on-chain`);
  } catch (e) {
    const msg = e?.shortMessage || e?.message || String(e);
    if (/Deploy Guestbook|could not detect|Failed to fetch|NETWORK_ERROR/i.test(msg)) {
      setStatus(msg.includes("Deploy") ? msg : "L2 RPC not reachable — start the stack first", true);
    } else {
      setStatus(msg, true);
    }
  }
}

async function signMessage() {
  if (busy || !writeContract) return;
  const text = els.text.value.trim();
  if (!text) {
    setStatus("Enter a message first", true);
    return;
  }
  if (utf8ByteLength(text) > MAX_TEXT_BYTES) {
    setStatus(`Message too long (max ${MAX_TEXT_BYTES} bytes)`, true);
    return;
  }
  busy = true;
  setConnectedUi(true);
  try {
    setStatus("Sending…");
    const tx = await writeContract.sign(text, FEE);
    setStatus(`Tx ${tx.hash} — waiting…`);
    await tx.wait();
    els.text.value = "";
    // Force-reset counter even if compositionend never fired (stuck imeComposing).
    imeComposing = false;
    syncMessageByteBudget(undefined, { force: true });
    setStatus(`Confirmed ${tx.hash}`);
    await refresh();
  } catch (e) {
    setStatus(e?.shortMessage || e?.reason || e?.message || String(e), true);
  } finally {
    busy = false;
    setConnectedUi(true);
  }
}

function wireWalletEvents() {
  const eth = window.ethereum;
  if (!eth?.on) return;
  eth.on("accountsChanged", () => {
    writeContract = null;
    signer = null;
    setConnectedUi(false);
    setStatus("Account changed — connect again");
  });
  eth.on("chainChanged", () => {
    writeContract = null;
    signer = null;
    setConnectedUi(false);
    setStatus("Network changed — connect again");
  });
}

els.connect.addEventListener("click", () => connect());
els.refresh.addEventListener("click", () => refresh());
els.sign.addEventListener("click", () => signMessage());
// Enforce UTF-8 byte budget (contract MAX_TEXT_BYTES), not JS string length /
// HTML maxlength characters — multibyte glyphs must not slip past the UI.
// Skip while IME is composing so CJK composition is not corrupted mid-input.
els.text.addEventListener("compositionstart", () => {
  imeComposing = true;
});
els.text.addEventListener("compositionend", () => {
  imeComposing = false;
  syncMessageByteBudget();
});
els.text.addEventListener("input", (ev) => {
  // Recover if compositionend was dropped (dead-key layouts / some browsers).
  if (imeComposing && !ev.isComposing) {
    imeComposing = false;
  }
  syncMessageByteBudget(ev);
});
els.text.addEventListener("keydown", (ev) => {
  // keyCode 229 = IME processing (Safari/Chrome during composition).
  if (ev.isComposing || ev.keyCode === 229) return;
  if (ev.key === "Enter" && !els.sign.disabled) {
    ev.preventDefault();
    signMessage();
  }
});
els.text.addEventListener("paste", () => {
  // Re-run byte trim after paste populates the input.
  queueMicrotask(() => syncMessageByteBudget());
});

wireWalletEvents();
refresh();
