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

## Checkpoint (~30–45 min after first successful start)

Posted 2026-08-31 09:26 PDT on PR #184: https://github.com/StephenForte/ForteL2/pull/184#issuecomment-5481270776

| Metric | Value |
|---|---|
| Elapsed | 34.8 min (start 08:51:24 PDT) |
| Candidate safe/unsafe | 16956 / 16956 |
| Live safe / unsafe | 380070 / 380141 |
| Candidate L1 origin | 11548321 |
| Live L1 origin | 11606828 |
| L2 rate | 487 blocks/min |
| L1 origin rate | 78.6 blocks/min |
| Projected time to live safe | ~12.4 h (ETA ~21:50 PDT if rate holds) |
| `op-reth-node.log` | 0 error-level; 1 recovered HTTP 429 (09:05:47, 50/s burst on receipts of L1 11547600); 0 `got 0 receipts`; 9 warns (startup/beacon-ignore, attach reset, that 429, 5 Sepolia L1 re-org signals) |
| `op-reth.log` (this start) | 0 panics, 0 ERROR |

Continue by default. One 429 is not a loop. Steve to read the QuickNode dashboard against these numbers.

## Mid-sync prefix (not catch-up)

Measured 2026-08-31 ~13:07 PDT while L1-origin lag was still ~29650 (cap is 2). Three-way `eth_getBlockByNumber` on candidate `:19545`, live `:9545`, and `replica.readRpcUrl` (host `fortel2-replica-rpc.onrender.com` only). Not a substitute for `./scripts/verify-reth-parity.sh`.

| Height | Result |
|---|---|
| 0 | MATCH `0xe242b1a3312b509e…` txCount=0 |
| 5 | MATCH `0xd9fd2a33ebadd2a7…` txCount=1 |
| 10000 | MATCH `0x4457f86234a6ec97…` txCount=1 |
| 100000 | MATCH `0x562ae6051eabeec6…` txCount=1 |
| 200000 | MATCH `0x1db822a237391528…` txCount=1 |

Live parity RPC path also probed: candidate op-node `:19547` and live op-node `:9547` both answer `optimism_syncStatus`; replica `eth_chainId` = 852.

Receipts at 5 and 200000 MATCH three-way (both type `0x7e` deposits). State at 200000 MATCH on candidate + live; replica returns `historical state … is not available` (diskless prune). Replica `eth_getBalance` at its own latest and latest−64 succeeds; latest−256 fails. After catch-up, `verify-reth-parity.sh` queries state at overlap `hi` (within 2 L1 origins ≈ ~12 L2), which is inside that window — not at 200000.

## Sample heights

Live `./scripts/verify-reth-parity.sh` 2026-08-31 17:15 PDT. Overlap high-water `hi=394152` (candidate safe = live safe = replica EL). Twenty heights including 0 and 5:

`[0, 5, 21897, 43795, 65692, 87589, 109487, 131384, 153281, 175179, 197076, 218973, 240871, 262768, 284665, 306563, 328460, 350357, 372255, 394152]`

## Parity output

Exit 0. `full-match: candidate = live sequencer = replica`. `verify-reth-parity: PASS (20 blocks)`.

Heads: `candidate_el=394152 live_el=394203 replica_el=394152 candidate_safe=394152 live_safe=394152 candidate_l1origin=11609112 live_l1origin=11609112`. Lag delta=0 (max 2).

Every sampled block MATCH on number, hash, parentHash, stateRoot, receiptsRoot, txCount. Anchors:

| Height | Hash (prefix) | txCount |
|---|---|---:|
| 0 | `0xe242b1a3312b509e7df1496847f0bd0b115cb66676b1e973a355296c99e2386d` | 0 |
| 5 | `0xd9fd2a33ebadd2a734924d8f76bac945709ba4a1df352a7d4fd50383dee209e9` | 1 |
| 394152 | `0x2ffa1fb0f16d9a4dde0b02eec33adee01a666f4aeaef6c987099e9b76739cae3` | 1 |

State at tag `0x603a8` (block 394152, not `latest`). `deployments/guestbook.txt` has no code at that height — script fell back to WETH (documented WARN). Four checks MATCH: WETH codehash, L2StandardBridge balance `0x0`, `L2ToL1MessagePasser.messageNonce` slot 1 `0x0…0`, WETH.balance `0x0`. Two receipts MATCH (`0xc3425ec1…` status 0x1, `0xbe5a242d…` status 0x1). Deposit type `0x7e` at block 5 MATCH.

Negative fixture (`--alter-field`) exit nonzero is covered by helper tests, not this live run.

Live `:9545` was eth_* reads only. Replica was comparison only.

## Restart / resume

Deliberate stop/start **without** `--wipe` after the PASS. Same env as first start (`unset FORTEL2_ENV`, `FORTEL2_EL=reth`, `FORTEL2_RETH_PROFILE=sequencer_faultproof`, `SEPOLIA_L1_RPC_RATE_LIMIT=10`). Live `:9545` stayed up (`eth_blockNumber` after stop still advancing; listen on 9545 throughout).

| Event | PDT |
|---|---|
| Pre-stop safe | 394152 `0x2ffa1fb0f16d9a4dde0b02eec33adee01a666f4aeaef6c987099e9b76739cae3` |
| Stop | 17:16:02–17:16:04 (pids 16626 / 17194) |
| Start | 17:16:12–17:16:18 (new pids 16725 / 16736) |
| EL immediately after start | block **394152** (same hash as pre-stop) |

`03-init-l2.sh`: `op-reth datadir already initialized … (skipping)` — **no** `Initializing op-reth with` genesis re-init. `op-reth proofs init --skip-backfill`: `Proofs storage already initialized` at genesis `0xe242b1a3…`. Genesis sidecar hash match.

After attach, `safe` briefly sat at 393558 then climbed (393708 → 394002 within ~24s) while `latest` stayed 394152 — op-node re-derived the safe label, not a wipe. Hash at height 394152 unchanged. Live sequencer untouched.

## Safe-head catch-up

Done. Three consecutive samples 2026-08-31 ~17:14 PDT, lag = 0 (cap 2):

| When (PDT) | Candidate safe | Live safe | Cand L1 origin | Live L1 origin | L1 lag |
|---|---:|---:|---:|---:|---:|
| 09:26 (T+35) | 16956 | 380070 | 11548321 | 11606828 | 58507 |
| 13:07 | 202689 | 386658 | 11578241 | 11607894 | 29653 |
| 17:14 sample 1 | 394152 | 394152 | 11609112 | 11609112 | 0 |
| 17:14 sample 2 | 394152 | 394152 | 11609112 | 11609112 | 0 |
| 17:14 sample 3 | 394152 | 394152 | 11609112 | 11609112 | 0 |

Datadir `$DATA_DIR/l2/op-reth` was not wiped. Tasks 4–5 inherit it.
