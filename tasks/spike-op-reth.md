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

### 0. Get the script

```bash
cd /Users/steveforte/ForteL2
git fetch origin cursor/spike-op-reth-p0-7710
git checkout cursor/spike-op-reth-p0-7710
```

Leave the sequencer running. This spike does not stop it.

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

Want: `preflight ok` and `l2=852`. If it errors about `.env.sepolia`, you exported the wrong env — `unset FORTEL2_ENV` and retry.

Optional QuickNode (otherwise the script uses the public Sepolia URL):

```bash
export L1_RPC_URL='https://your-quicknode-sepolia-host'   # HTTPS only; do not paste keys into chat
```

### 3. Run the spike

```bash
cd /Users/steveforte/ForteL2
./scripts/spike-op-reth.sh --blocks 5
```

Want a last line `spike-op-reth: PASS`. Failures are real — read `$DATA_DIR/logs/spike-op-reth.log` and `spike-op-reth-node.log`. Ctrl-C stops only the sidecar.

### 4. Write down the result

Edit `tasks/spike-op-reth.md` Results + flag table (Mini column). Paste `op-reth --version`, the two hashes, PASS/FAIL. That is what the migration PRD cites.

Optional flags: `--genesis PATH`, `--no-wipe`. Sidecar ports: HTTP **19845**, auth **19851**, op-node **19847**.

## Checks (must be able to go red)

| Check | Cloud Linux | Mini darwin/arm64 |
|---|---|---|
| `op-reth --version` is v2.3.3+ (native path, not Docker) | | |
| Genesis block 0 hash matches replica | | |
| `op-node --l2.enginekind=reth` attaches | | |
| Block N hash matches replica | | |
| Sequencer-tip door (optional; may be down 23:45–03:00 PT) | | |
| RPC probe: `eth` / `net` / `web3`; `debug` / `txpool` / `eth_getProof` / `debug_setHead` recorded | | |
| Live `op-geth` datadir and ports 9545/9546/9547/9551 untouched | | |

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

_Unrun._ A Cloud PASS is not a Mini PASS.

## Go / no-go for the migration PRD

_Pending a Mini run._
