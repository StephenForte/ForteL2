# P:0 spike — op-reth sidecar on ForteL2 Sepolia 852

**Date:** 2026-08-29  
**Script:** `scripts/spike-op-reth.sh` (throwaway; do not replace `04-start-sequencer*.sh`)  
**PRD (output, later):** migration PRD — this note is the evidence it must cite  
**This is a shell script, not a chat prompt.** From the ForteL2 repo root: `./scripts/spike-op-reth.sh --blocks 5`

## Goal

Prove that a **source-built** `op-reth` (v2.3.3+) can init ForteL2 chain **852** genesis, attach the pinned `op-node` v1.19.2 with `--l2.enginekind=reth`, derive the first **N** L2 blocks from Sepolia L1, and **hash-match** the public replica. No sequencer cutover. No Docker. No Karst.

## Non-goals

- No Docker / OrbStack / Kurtosis (including pulling the official op-reth image)
- No `FORTEL2_ENV=.env.sepolia` (do not load role keys)
- No edits to live start/stop/`start_bg`
- No local chain 901 path
- No sync-to-tip, no friend image, no `karst_time`

## Mini copy-paste (do this)

Your live optimism clone is a **shallow** `op-node/v1.19.2` tree. Do **not** `git checkout` that folder — it can break the running sequencer build tree. Use a **second** clone. No Docker. Do **not** `export FORTEL2_ENV=.env.sepolia`.

Paths below match `.env.example`. If your Mini `.env` differs, use those values for `ForteL2` and `BIN_DIR`.

### 0. Get the receipt-kind fix

The spike script is already on `main` (PR #170). Pull this follow-up before retrying `--blocks` — the first Mini run used PublicNode + `--l1.rpckind=standard` and could not fetch L1 receipts.

```bash
cd /Users/steveforte/ForteL2
git fetch origin cursor/spike-op-reth-l1-receipts-7710
git checkout cursor/spike-op-reth-l1-receipts-7710
```

Leave the sequencer running. This spike does not stop it. Do **not** stay on `cursor/spike-op-reth-p0-7710`.

### 1. Build op-reth (once, 20–60 min)

```bash
source "$HOME/.cargo/env"
cd ~/src/fortel2
git clone --depth 1 --branch op-reth/v2.3.3 https://github.com/ethereum-optimism/optimism.git optimism-op-reth
cd optimism-op-reth
git submodule update --init --recursive
just update-superchain-registry-submodule || true
cd rust
cargo build --release --bin op-reth
```

Binary lands at `~/src/fortel2/optimism-op-reth/rust/target/release/op-reth` (or `…/optimism-op-reth/rust/../target/release/op-reth` if cargo puts `target/` at the rust workspace root — check with `ls`).

```bash
# pick the path that exists:
ls ~/src/fortel2/optimism-op-reth/rust/target/release/op-reth \
   ~/src/fortel2/optimism-op-reth/target/release/op-reth

# symlink into the same BIN_DIR your .env already uses
source /Users/steveforte/ForteL2/.env
ln -sfn "$HOME/src/fortel2/optimism-op-reth/rust/target/release/op-reth" "$BIN_DIR/op-reth"
# if ls showed the other path, use that instead of rust/target/...

export PATH="$BIN_DIR:$PATH"
op-reth --version
# expect something with 2.3.3
file "$(command -v op-reth)"
# must say Mach-O arm64 (not Docker)
```

### 2. Preflight (no chain start)

```bash
cd /Users/steveforte/ForteL2
# do NOT: export FORTEL2_ENV=.env.sepolia
./scripts/spike-op-reth.sh --preflight
```

Want: `preflight ok`, `l2=852`, and `l1.rpckind=quicknode`. If it errors about `.env.sepolia`, you exported the wrong env — `unset FORTEL2_ENV` and retry. PublicNode is a **WARN** on `--preflight` and a **refuse** on `--blocks`.

`--blocks` needs the same receipts-capable L1 the live sequencer uses. Export **only** the URL — do not print it, and do **not** `export FORTEL2_ENV=.env.sepolia`:

```bash
unset FORTEL2_ENV
export L1_RPC_URL="$(grep '^L1_RPC_URL=' .env.sepolia | cut -d= -f2-)"
# confirm without leaking the token:
python3 -c "import os; u=os.environ.get('L1_RPC_URL',''); print('L1 set' if u.startswith('http') else 'L1 missing')"
```

Override receipt kind only if needed: `export SPIKE_L1_RPC_KIND=quicknode` (this is already the default).

### 3. Run the spike

```bash
cd /Users/steveforte/ForteL2
unset FORTEL2_ENV
# L1_RPC_URL must already be set from step 2
./scripts/spike-op-reth.sh --blocks 5
```

Want a last line `spike-op-reth: PASS`. Failures are real — read `$DATA_DIR/logs/spike-op-reth.log` and `spike-op-reth-node.log`. Ctrl-C stops only the sidecar.

### 4. Write down the result

Edit `tasks/spike-op-reth.md` Results + flag table (Mini column). Paste `op-reth --version`, the two hashes, PASS/FAIL. That is what the migration PRD cites.

Optional flags: `--genesis PATH`, `--no-wipe`. Sidecar ports: HTTP **19845**, auth **19851**, op-node **19847**.

## Checks (must be able to go red)

| Check | Cloud Linux | Mini darwin/arm64 |
|---|---|---|
| `op-reth --version` is v2.3.3+ (native path, not Docker) | | 2.3.0-dev (9384bc5) Mach-O arm64 (upstream reth pin in op-reth/v2.3.3) |
| Genesis block 0 hash matches replica | | PASS `0xe242b1a3312b509e7df1496847f0bd0b115cb66676b1e973a355296c99e2386d` |
| `op-node --l2.enginekind=reth` attaches | | PASS — FCU genesis + reset at L1 `0xaf5518e2…:11545587` |
| Block N hash matches replica | | FAIL first run — head stayed 0 (L1 receipts, not EL) |
| Sequencer-tip door (optional; may be down 23:45–03:00 PT) | | not reached |
| RPC probe: `eth` / `net` / `web3`; `debug` / `txpool` / `eth_getProof` / `debug_setHead` recorded | | not reached |
| Live `op-geth` datadir and ports 9545/9546/9547/9551 untouched | | PASS (sidecar :19845/:19846/:19851/:19847/:30329) |

Replica oracle: `https://fortel2-replica-rpc.onrender.com` (read only).

## Flag table (fill after a run)

| Need (today on op-geth) | op-reth flag that worked | Notes |
|---|---|---|
| HTTP loopback + JWT auth | | |
| `eth,net,web3` | | |
| `debug` | | |
| `txpool` | | |
| archive / `eth_getProof` | | |
| genesis init | | |
| `debug_setHead` (probe) | | |

## Results

**Mini first run (2026-08-28 19:19–19:26 PT) — FAIL `--blocks 5`. Not an op-reth failure.**

- Build: `~/src/fortel2/optimism-op-reth` @ `op-reth/v2.3.3`; binary `Reth 2.3.0-dev (9384bc5)`; Mach-O arm64; `--preflight` PASS.
- Genesis hash matched replica. op-reth Engine API accepted FCU to genesis. `latest_block` stayed **0**.
- op-node reset Holocene at L1 origin `0xaf5518e27683473d8bcc776fadc48c2af9ef1d9881ed0f62c5e3a9ffd25c0800:11545587` (correct), then looped:

  `failed to fetch receipts of L1 block … got 0 receipts but expected 105` (then 104, 137, …).

- L1 was PublicNode (`https://ethereum-sepolia-rpc.publicnode.com`) with the script hardcoded `--l1.rpckind=standard`. Live Sepolia sequencer uses QuickNode + `--l1.rpckind=quicknode` (`04-start-sequencer-sepolia.sh`). PublicNode serves headers, not receipts.
- EL `Beacon client online, but no consensus updates` is a consequence: CL never sent payloads. SIGTERM at 02:26:06 UTC stopped the sidecar only.
- Script fix (this note’s follow-up): default `l1.rpckind` to `quicknode`; refuse PublicNode on `--blocks`; warn on `--preflight`. Retry is required before any migration PRD.

A Cloud PASS is not a Mini PASS. Do not fill the flag table from this receipts FAIL.

## Go / no-go for the migration PRD

_Pending a Mini `--blocks 5` PASS with QuickNode L1._ First-run FAIL is L1 receipts, not a reason to abandon op-reth.
