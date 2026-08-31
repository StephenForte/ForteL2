# Task 3 evidence — op-reth candidate safe-head parity (chain 852)

**Date opened:** 2026-08-31  
**PRD:** `tasks/prd-op-reth-migration.md` §8 Task 3  
**Decisions consumed:** D-0109 (pin), D-0110 (identifiers, wipe+re-derive, live-path refuse)  
**D-0111:** reserved planner-side — not written here  
**Branch:** `feat/op-reth-task3-verifier`

This is the one `tasks/` write Task 3 is permitted. It records the candidate datadir derivation of chain 852 from Sepolia L1 to the live safe head, sampled parity against the live sequencer and the Render replica, and restart/resume. L1 provider URLs, JWTs, and keys are never written here.

## Versions (measured 2026-08-31 after sidecar start)

| Binary | Expected pin | Observed |
|---|---|---|
| op-node | v1.19.2 `da197e45` | `op-node version v1.19.2-da197e45-1782514747` (`check-el-pins.sh` ok) |
| op-reth | tag `op-reth/v2.3.3` reports `Reth Version: 2.3.0-dev` commit `9384bc53` | `Reth Version: 2.3.0-dev` `Commit SHA: 9384bc53d8c0c77e59cac83fdaaf3b372c6d2216` (`check-el-pins.sh` ok) |
| live EL | op-geth (untouched) | still bound on `:9545`; sidecar is `:19545` only |

`./scripts/check-el-pins.sh` exit 0 on this host after start.

## Exact env (no secrets)

```
unset FORTEL2_ENV
FORTEL2_EL=reth
FORTEL2_RETH_PROFILE=sequencer_faultproof
FORTEL2_RETH_DATADIR=$DATA_DIR/l2/op-reth   # created by this run; Tasks 4–5 inherit
SEPOLIA_L1_RPC_KIND=quicknode              # script default
SEPOLIA_L1_RPC_RATE_LIMIT=10
L1_RPC_URL=<redacted QuickNode HTTPS>
DATA_DIR=<Sepolia runtime dir from .env.sepolia>
ports 19545/19546/19551/19547/30330
```

Started 2026-08-31 08:51:24 PT. Genesis sidecar hash matched `0xe242b1a3312b509e7df1496847f0bd0b115cb66676b1e973a355296c99e2386d`. Live `:9545` was not stopped, restarted, or written.

**Additive runner edit:** `--proofs-history` ExEx panics unless the store is initialized. The pinned binary's command is `op-reth proofs init` (the panic text names a non-existent `initialize-op-proofs`). `start-op-reth-verifier.sh` now runs `op-reth proofs init --datadir --chain --proofs-history.skip-backfill` before `op-reth node` when the profile is `sequencer_faultproof`. skip-backfill is required on V1 (no backfill) and is the right genesis posture: the store is enabled from first start and fills forward as Task 3 derives. The call is idempotent (`Proofs storage already initialized`). Port/datadir/PublicNode/`.env.sepolia` refusals are unchanged.

First `op-reth node` start (08:46 PT) crashed in ~1s with that panic; the datadir was **not** wiped. `proofs init --skip-backfill` then succeeded at block 0 / genesis hash above; the second start (08:51 PT) stayed up. Live stack was up throughout.

Live sequencer `:9545/:9546/:9547/:9551` and `$DATA_DIR/l2/op-geth` are not opened for write. Rewind policy: wipe + re-derive; never `debug_setHead`.

## Checkpoint (~30–45 min after first start)

_Pending. Posted as a PR comment: L2 blocks/min, L1 origin progress, projected time to live safe head, `op-reth-node.log` error counts. Continue by default._

## Sample heights

_Pending `./scripts/verify-reth-parity.sh` after catch-up (must include 0, 5, and ≥18 spread checkpoints)._

## Parity output

_Pending. Exit 0 full-match against live `:9545` and the public replica read URL. Negative fixture (`--alter-field`) exit nonzero — see helper tests._

## Restart / resume

_Pending. One deliberate stop/start of the sidecar after catch-up; the 23:45 launchd sleep counts as a natural iteration if it occurs. Proof: timestamps + head continuity, no re-init line in `op-reth.log`._

## Safe-head catch-up

_Pending. Verifier safe head = live safe head, or lag ≤ 2 L1 epochs across 3 consecutive samples._
