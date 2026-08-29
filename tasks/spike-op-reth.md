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

`--blocks` needs the same receipts-capable L1 the live sequencer uses. Export **only** the URL **before** invoking the script — the script snapshots `L1_RPC_URL` so Phase 1 `.env` (Anvil loopback) cannot clobber it into PublicNode. Do not print the URL, and do **not** `export FORTEL2_ENV=.env.sepolia`:

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

Filled below from the Mini retry. Optional flags: `--genesis PATH`, `--no-wipe`. Sidecar ports: HTTP **19845**, auth **19851**, op-node **19847**.

## Checks (must be able to go red)

| Check | Cloud Linux | Mini darwin/arm64 |
|---|---|---|
| `op-reth --version` is v2.3.3+ (native path, not Docker) | not a Mini substitute | `Reth Version: 2.3.0-dev` SHA `9384bc53` (upstream reth pin in `op-reth/v2.3.3`); Mach-O arm64 |
| Genesis block 0 hash matches replica | | PASS `0xe242b1a3312b509e7df1496847f0bd0b115cb66676b1e973a355296c99e2386d` |
| `op-node --l2.enginekind=reth` attaches | | PASS — `--l2.enginekind=reth` + `--l1.rpckind=quicknode` |
| Block N hash matches replica | | PASS block 5 `0xd9fd2a33ebadd2a734924d8f76bac945709ba4a1df352a7d4fd50383dee209e9` (first run FAIL was L1 receipts) |
| Sequencer-tip door (optional; may be down 23:45–03:00 PT) | | PASS — same hash at block 5 |
| RPC probe: `eth` / `net` / `web3`; `debug` / `txpool` / `eth_getProof` / `debug_setHead` recorded | | see flag table |
| Live `op-geth` datadir and ports 9545/9546/9547/9551 untouched | | PASS (sidecar :19845/:19846/:19851/:19847/:30329) |

Replica oracle: `https://fortel2-replica-rpc.onrender.com` (read only).

## Flag table (fill after a run)

| Need (today on op-geth) | op-reth flag that worked | Notes |
|---|---|---|
| HTTP loopback + JWT auth | `--http.addr=127.0.0.1 --http.port=19845 --authrpc.addr=127.0.0.1 --authrpc.port=19851 --authrpc.jwtsecret` | WS `:19846`; P2P `--port=30329 --disable-discovery` |
| `eth,net,web3` | `--http.api=eth,net,web3,debug,txpool` | `net_version` PASS; `web3_clientVersion` PASS |
| `debug` | same `--http.api` | PASS (`debug_getRawHeader` or `debug_traceBlockByNumber` answered) |
| `txpool` | same `--http.api` | `txpool_status` PASS |
| archive / `eth_getProof` | default archive prune (no extra flag) | `cast proof` PASS |
| genesis init | `op-reth init --datadir --chain` then `op-reth node --chain` | Local `$DEPLOY_DIR/genesis.json` was chain 901 — fetched replica genesis |
| `debug_setHead` (probe) | **answered** | UNEXPECTED. Do **not** use on a keeper datadir. Derivation mid-chain needs another path |

## Results

**Mini retry (2026-08-29, after L1 receipt-kind fix) — PASS `--blocks 5` on darwin/arm64.**

- `--preflight` PASS: `l2=852`, `l1.rpckind=quicknode`, no PublicNode WARN. Caller `L1_RPC_URL` kept (QuickNode; script printed a redacted `quiknode.pro` host). Do not paste that URL.
- `op-reth --version`: `Reth Version: 2.3.0-dev` commit `9384bc53d8c0c77e59cac83fdaaf3b372c6d2216` (upstream reth pin inside `op-reth/v2.3.3`).
- Ignored `$DEPLOY_DIR/genesis.json` (chainId 901). Fetched 852 genesis from fortel2-replica.
- Genesis replica = sidecar = `0xe242b1a3312b509e7df1496847f0bd0b115cb66676b1e973a355296c99e2386d`.
- Block 5 replica = sidecar = `0xd9fd2a33ebadd2a734924d8f76bac945709ba4a1df352a7d4fd50383dee209e9`. Sequencer-tip door matched the same hash.
- RPC: `net_version`, `web3_clientVersion`, debug (some method), `txpool_status`, `eth_getProof` PASS. `debug_setHead` **answered** — do not use on a keeper datadir.
- Sidecar only (`:19845/:19851/:19847`). Live `op-geth` untouched. EXIT trap stopped the sidecar.
- `zsh: command not found: #` was the paste of a comment line. Harmless.

**Mini first run (2026-08-28 19:19–19:26 PT) — FAIL `--blocks 5`. Not an op-reth failure.**

- Same binary. Genesis matched. Head stayed **0**.
- op-node reset Holocene at L1 origin `0xaf5518e27683473d8bcc776fadc48c2af9ef1d9881ed0f62c5e3a9ffd25c0800:11545587` (correct), then looped `got 0 receipts but expected 105`.
- L1 was PublicNode + hardcoded `--l1.rpckind=standard`. Live sequencer uses QuickNode + `quicknode`. Fixed in this follow-up (`SPIKE_L1_RPC_KIND` / `SEPOLIA_L1_RPC_KIND`, default `quicknode`; PublicNode refused on `--blocks`; caller `L1_RPC_URL` snapshotted across `.env` load).

A Cloud PASS is not a Mini PASS. This Mini PASS is.

## Go / no-go for the migration PRD

**GO to write the migration PRD**, citing this Mini `--blocks 5` PASS (hashes and flag table above).

Still **NO-GO** for: sequencer cutover, replacing `04-start-sequencer*.sh`, friend-replica image swap, `karst_time`, Phase 7 wipe, or sync-to-tip. P:0 proved genesis + first 5 L2 blocks hash-match on a sidecar. That is not a cutover. `debug_setHead` answering is a derivation risk — the PRD must not treat it as a keeper rewind tool.
