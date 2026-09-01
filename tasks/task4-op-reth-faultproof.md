# Task 4 evidence — op-reth candidate fault-proof / historical workflows

**STATUS: blocked** — Task 4 workflows are not closed. This is not a Task 5 go and not a sequencer-cutover authorization. The candidate datadir (`$DATA_DIR/l2/op-reth`) is preserved for a later Task 5; do not wipe it. RPC spot checks below (output-root / SafeDB / `eth_getProof`) do not substitute for a judged valid claim or a withdrawal that succeeded or had its named blocker resolved.

**Date opened:** 2026-08-31  
**PRD:** `tasks/prd-op-reth-migration.md` §8 Task 4 / §11 Q3  
**Decisions consumed:** D-0109 (pin), D-0110 (identifiers, wipe+re-derive), D-0114 (candidate datadir, restart env, replica prune window)  
**Verdict id:** planner-owned (not written here)  
**Branch:** `feat/op-reth-task4-faultproof`

This is the one `tasks/` write Task 4 is permitted. L1 provider URLs, JWTs, and keys are never written here.

## Candidate (inherited, not wiped)

`$DATA_DIR/l2/op-reth` from Task 3 (`sequencer_faultproof`, `--proofs-history` since first start). Restart env is the Task 3 block (`unset FORTEL2_ENV`, `FORTEL2_EL=reth`, `FORTEL2_RETH_PROFILE=sequencer_faultproof`, `SEPOLIA_L1_RPC_RATE_LIMIT=10`). The 23:45 sleep stops the sidecar; wake does not restart it.

**Do not:** `--wipe`, `reset-sepolia.sh`, `debug_setHead`, stop/reconfigure the live challenger, share its SafeDB/dirs, bind the sidecar off loopback, or query the replica for deep historical state (latest−256 fails; D-0114 Finding 4).

## Versions / pins (measured 2026-08-31 after SafeDB restart)

| Binary | Expected pin | Observed |
|---|---|---|
| op-node | v1.19.2 `da197e45` | `check-el-pins.sh` ok |
| op-reth | tag `op-reth/v2.3.3` reports `2.3.0-dev` `9384bc53` | `web3_clientVersion` `reth/v2.3.0-9384bc5/aarch64-apple-darwin` |
| live EL | op-geth (untouched) | `Geth/v1.101702.2-stable-…` on `:9545` |

`./scripts/check-el-pins.sh` exit 0. Live EL selector remains `FORTEL2_EL=geth`.

## Restart + SafeDB enable (no wipe)

Pre-stop (Task 3 pids 16725 / 16736, **no** `--safedb.path`): candidate EL 398916 hash `0xe0ff27979361ed8d2d5a29d4a2858baeaf21535dab3f4884579736f9ef0d69bd`. Live `:9545` 399054.

Stop via `stop-op-reth-verifier.sh` (no `--wipe`). Live `:9545` kept advancing (399056). Candidate datadir and live `$DATA_DIR/safedb` intact. Live challenger pid 45520 stayed up.

Start with the Task 3 env. `03-init-l2.sh`: datadir already initialized (skip). `op-reth proofs init --skip-backfill`: `Proofs storage already initialized` at genesis `0xe242b1a3…`. New pids 58830 / 58867. Sidecar op-node argv includes `--safedb.path=$DATA_DIR/l2/op-reth-safedb` and `--l2.enginekind=reth`. Live op-node argv unchanged (no sidecar SafeDB path).

| Event | Value |
|---|---|
| Wall-clock L1 tip at enable | **11609909** |
| First SafeDB **answer** (floor) | recorded `l1Block` **11609838** (query 11609850) |
| Post-restart EL | 398916 same hash as pre-stop |
| Genesis | `0xe242b1a3312b509e7df1496847f0bd0b115cb66676b1e973a355296c99e2386d` |

SafeDB records L1 blocks the new op-node walks after start, including catch-up origins numerically below the wall-clock tip. That is why answers exist for L1 11609838–11609887 before origin passed 11609909. Pre-enable = L1s **never recorded**, not “any number &lt; wall-clock tip.”

## SafeDB probes

**Required negative** (pre-record L1; paste):

```
$ cast rpc optimism_safeHeadAtL1Block 0xb10c00 --rpc-url http://127.0.0.1:19547
# 0xb10c00 = L1 11600000
Error: server returned an error response: error code -32000: not found
```

Same `not found` at L1 11609000, 11609649 (game 214 `l1Head`), 11609780, 11609800. Live op-node SafeDB **does** answer 11600000 (Phase 7 store; read-only compare).

**Post-enable (≥3), hashes match live archive geth:**

| Query L1 | Recorded L1 | Safe L2 | Hash vs live `:9545` |
|---:|---:|---:|---|
| 11609850 | 11609838 | 398616 | MATCH `0x8354560a9168c285…` |
| 11609880 | 11609862 | 398766 | MATCH `0x523faaa07e75893f…` |
| 11609900 | 11609887 | 398916 | MATCH `0xe0ff27979361ed8d…` (pre-stop hash) |

op-node returns the latest recorded L1 ≤ the query (floor), not an exact key. `verify-reth-faultproof.sh --safedb-enable-l1 11609837 --pre-enable-l1 11600000` exit 0.

## Historical `eth_getProof` (candidate vs Mac archive geth; never replica)

Replica `eth_getProof` at latest−256 (398660 vs tip 398916): `historical state … is not available` (D-0114 window confirmed).

| Depth | Account | Result |
|---|---|---|
| block 1 (near-genesis) | L2ToL1MessagePasser | MATCH storageHash + accountProofLen=4 |
| block 5 | L2ToL1MessagePasser | MATCH |
| tip−1000 (397916) | L2ToL1MessagePasser | MATCH |
| tip−100000 (298916) | L2StandardBridge | MATCH storageHash + accountProofLen=5 |

Proofs store served history from block 1. This is the Q3 input: `--proofs-history` + `proofs init --skip-backfill` from first start is sufficient for cannon-kona / shortened-window historical reads on this datadir. Replica `--full`/diskless is not.

## Proposer output root

`optimism_outputAtBlock` candidate `:19547` == live `:9547`:

| L2 | outputRoot | Result |
|---:|---|---|
| 5 | `0x8d085f67152c6dab…` | MATCH |
| 200000 | `0xd8222477d03b0c69…` | MATCH |
| 397392 (game 214) | `0x03b75f35de647d5a…` | MATCH |
| 398916 | `0x84b9124f8d007052…` | MATCH |
| 399222 (game 215) | `0x567d049d87eebfcd…` = on-chain `rootClaim` | MATCH |

`./scripts/verify-reth-faultproof.sh --game-l2-block 397392 --safedb-enable-l1 11609837 --pre-enable-l1 11600000` → `verify-reth-faultproof: PASS`. Fixture `--alter-field outputRoot` → MISMATCH + nonzero.

## Isolated challenger (non-signing)

Binary has **no** dry-run / no-tx flag (`--private-key` / mnemonic required). Ran with an **unfunded** throwaway only. Did not use `09-start-challenger-sepolia.sh`. Did not share live datadir / SafeDB / pid `op-challenger`.

| Field | Value |
|---|---|
| Address | `0xa7a60CB10b86dAE73de3eBdB821c95f95D15e31c` |
| L1 balance | 0 wei |
| Nonce before | **0** |
| Nonce after stop | **0** |
| Pid | 61384 (`op-challenger-reth-task4`); live 45520 untouched |
| Profile | http-poll 300s, min-update 300s, concurrency 1, game-window binary default |
| Endpoints | rollup `127.0.0.1:19547`, L2 `127.0.0.1:19545` |
| Window | 20:03:09–20:08:10 PT, then stopped |

Game **214** L1 head 11609649: candidate SafeDB `not found` (pre-record; expected asymmetry). Game **215** (created during the window): L2 399222, L1 head 11609944, candidate SafeDB answers, `rootClaim` == candidate `outputRoot`. Isolated process sent **zero** L1 txs (nonce unchanged). First 300s scan hit the same QuickNode 50/s 429 class as the live challenger (`Failed to progress games` / `Failed to verify large preimages`) — no attack, no Move, no txmgr send. Unfunded key cannot post a bond even if a later scan wanted to.

## Withdrawal

Live `initiateWithdrawal` was **not** broadcast from this session: the host auto-review gate blocked the `cast send` that would spend ADMIN on chain 852, and the approval retry lost its tool-call bubble. That is an operator-approval residual, not a missing-candidate-data blocker.

Prove inputs the withdrawal path needs **were** served from the candidate (same RPCs `buildProveWithdrawal` would use):

- output root: candidate op-node `:19547` (`optimism_outputAtBlock`)
- storage / account proof: candidate EL `:19545` (`eth_getProof` on messenger/bridge, including near-genesis and tip−100k)

If an operator later initiates a minimal withdrawal on live `:9545` and points `L2_RPC_URL=http://127.0.0.1:19545` at `scripts/bridge/prove.mjs`, those two artifact classes are already green. Replica must not be used for the proof.

## RPC namespace differences (no public surface widened)

| Surface | Candidate op-reth `:19545` | Live op-geth `:9545` |
|---|---|---|
| `web3_clientVersion` | `reth/v2.3.0-9384bc5/…` | `Geth/v1.101702.2-stable/…` |
| HTTP APIs | `eth,net,web3,debug,txpool` (sidecar script) | plus `admin,miner` (live start) |
| `admin_nodeInfo` | method not found | answers |
| `eth_getProof` | answers (params required) | answers |
| `txpool_status` | answers | answers |
| `optimism_*` | not on EL | not used on EL |

`optimism_outputAtBlock` / `optimism_safeHeadAtL1Block` / `optimism_syncStatus` live on the **op-node** ports (`:19547` / `:9547`). Sidecar HTTP is still loopback. Public read gateways unchanged.

## Live stack (before / after)

**Before:** op-geth 44832, op-node 44849, batcher 45087, proposer 45203, filter 44964, challenger 45520; L2 ~399049. Sidecar was the Task 3 pair without SafeDB.

**After:** same live pids; L2 399489; sidecar 58830 / 58867 with SafeDB. Challenger 45520 still running. Isolated judge stopped.

## Residual

- Withdrawal initiate/prove/finalize on L1 was not executed (approval gate). Candidate can serve the prove artifacts; clocks were not exercised.
- Isolated challenger's single scan 429'd on L1 (shared QuickNode budget with the live challenger). Judgment of game 215 is from candidate RPC equality + SafeDB answer + zero nonce, not from a completed in-process “valid” log line.
- Isolated judge logs/pids landed under the Phase 1 `$DATA_DIR` because `lib.sh` was sourced without snapshotting Sepolia `DATA_DIR` first. Live challenger dirs were not used.
- Q3 profile shape (observed, not a Task 5 authorization): `sequencer_faultproof` = archive + `--proofs-history` (init `--skip-backfill` from genesis) + sidecar `--safedb.path` (`$DATA_DIR/l2/op-reth-safedb`). Replica prune window unchanged.

The candidate datadir is preserved so Task 5 can start from it later. Task 4 itself is **blocked**: no judged valid claim, no withdrawal succeed-or-named-blocker-resolved. Never `reset-sepolia` / `--wipe` / `debug_setHead` on the datadir.

Codex-tightened `verify-reth-faultproof.sh` re-ran live (game L2 397392, `--safedb-enable-l1` 11609837, `--pre-enable-l1` 11600000): PASS on three distinct recorded SafeDB L1s and full `eth_getProof` payloads (storageHash / balance / nonce / codeHash / accountProof / storageProof) vs the Mac archive geth. That does not lift the block.
