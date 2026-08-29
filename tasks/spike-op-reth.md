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

## How to run

```bash
cd "$FORTEL2_ROOT"   # Mini: ForteL2 clone; Cloud: /workspace
# Build once (no Docker), then symlink into $BIN_DIR:
#   cd ~/src/fortel2/optimism   # or the Cloud optimism tree
#   git fetch && git checkout op-reth/v2.3.3
#   cd rust && cargo build --release --bin op-reth
#   ln -sf "$(pwd)/target/release/op-reth" "$BIN_DIR/op-reth"
./scripts/spike-op-reth.sh --blocks 5
```

Optional: `--genesis PATH`, `--no-wipe`, `--preflight` (refusals only; no `op-reth` required).  
L1: `L1_RPC_URL` if set to a Sepolia HTTPS URL; otherwise the script uses the public smoke URL. Sidecar ports: HTTP **19845**, auth **19851**, op-node **19847**.

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
