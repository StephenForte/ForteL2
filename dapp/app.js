/**
 * ForteL2 Guestbook — local learning dApp (chain 901).
 * Uses ethers v6 from jsDelivr; wallet + RPC stay on loopback.
 */
import { BrowserProvider, Contract, JsonRpcProvider, isAddress } from "https://cdn.jsdelivr.net/npm/ethers@6.13.5/+esm";
import { GUESTBOOK_ADDRESS, GUESTBOOK_ABI, L2_CHAIN_ID, L2_RPC_URL } from "./config.js";

const L2_CHAIN_HEX = `0x${Number(L2_CHAIN_ID).toString(16)}`;
const FEE = { maxFeePerGas: 1_000_000_000n, maxPriorityFeePerGas: 1_000_000_000n };
const PAGE = 50;

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
  if (new TextEncoder().encode(text).length > 280) {
    setStatus("Message too long (max 280 bytes)", true);
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
    els.charCount.textContent = "0";
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
els.text.addEventListener("input", () => {
  const bytes = new TextEncoder().encode(els.text.value).length;
  els.charCount.textContent = String(bytes);
  if (bytes > 280) {
    els.charCount.style.color = "var(--warn)";
  } else {
    els.charCount.style.color = "";
  }
});
els.text.addEventListener("keydown", (ev) => {
  if (ev.key === "Enter" && !els.sign.disabled) {
    ev.preventDefault();
    signMessage();
  }
});

wireWalletEvents();
refresh();
