# Task 4 evidence — op-reth candidate fault-proof / historical workflows

**STATUS: complete** — closer 2 isolated judge landed (`Game info` + nonce 0). This is not a Task 5 go and not a sequencer-cutover authorization. The candidate datadir (`$DATA_DIR/l2/op-reth`) is preserved for a later Task 5; do not wipe it.

**Date opened:** 2026-08-31  
**PRD:** `tasks/prd-op-reth-migration.md` §8 Task 4 / §11 Q3  
**Decisions consumed:** D-0109 (pin), D-0110 (identifiers, wipe+re-derive), D-0114 (candidate datadir, restart env, replica prune window)  
**Verdict id:** planner-owned (not written here)  
**Branch:** `feat/op-reth-task4-faultproof`

This is the one `tasks/` write Task 4 is permitted. L1 provider URLs, JWTs, and keys are never written here.

## Candidate (inherited, not wiped)

`$DATA_DIR/l2/op-reth` from Task 3 (`sequencer_faultproof`, `--proofs-history` since first start). Restart env is the Task 3 block (`unset FORTEL2_ENV`, `FORTEL2_EL=reth`, `FORTEL2_RETH_PROFILE=sequencer_faultproof`, `SEPOLIA_L1_RPC_RATE_LIMIT=10`). The 23:45 sleep stops the sidecar; wake does not restart it. Morning closer 2 restarted it (no wipe) with the Task 3 env before the judge.

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

## Isolated challenger (non-signing) — closer 2

Binary has **no** dry-run / no-tx flag (`--private-key` / mnemonic required). Unfunded throwaways only. Did not use `09-start-challenger-sepolia.sh`. Did not share live datadir / SafeDB / pid `op-challenger`.

**2026-09-01 morning (after 03:00 wake):** sidecar restarted first (no wipe; Task 3 env). Safe-head L1-origin lag reached **0** at 07:16:56 PT (candidate safe 419383 = live safe). `0xa7a60CB10b86dAE73de3eBdB821c95f95D15e31c` key was not persisted; that address stayed unfunded (nonce 0 / 0 wei) and was not reused. Fresh throwaway `0x5c7470Df70F763Bd747c30cffa04DdB9c753103E` (also unfunded).

Game **215** is 11h old and outside `--game-window=3h`. Allowlisted game **220** (`0x52151b45fC1E4dbBd1806A89f6ccBD3229d8c9d5`, L2 418291): `rootClaim` MATCH candidate `:19547` and live `:9547`. First isolated start (pid 91730) used the L1 HTTPS provider directly and 429'd every 180s (`Failed to progress games` — allowlist does not shrink the factory fetch). Restarted at 07:34:30 PT via the existing loopback L1 batch proxy (`127.0.0.1:9549`, same provider as live; live 85931 untouched). #168 retry (grace 20s, 3 attempts, backoff 5/10) — first attempt survived. Poll 180s offset from live 300s. Logs/pids under `$DATA_DIR` Sepolia tree (`…/data-sepolia/logs/op-challenger-reth-task4.log`).

Paste (in-process honest-valid line — op-challenger has no literal `VALID`; `claims=1` + `In Progress` + no Attack/Move is AgreeWithRootClaim / no actions):

```
t=2026-09-01T07:37:43-0700 lvl=info msg="Game info" game=0x52151b45fC1E4dbBd1806A89f6ccBD3229d8c9d5 claims=1 status="In Progress"
```

Throwaway nonce after that line and after stop: **0**. Isolated pid **92547** stopped; live **85931** still up.

Earlier 2026-08-31 attempts (not this closer): `0xa7a60CB1…e31c` pid 61384 (Phase 1 DATA_DIR trap) and `0x6eaAa9F4…C418` pid 24547 (stopped 21:22:42 PT per planner — no `Game info`). Both nonce 0→0.

## Withdrawal

Prerequisite deposit (ADMIN L2 was 0 post-wipe): `FORTEL2_ENV=.env.sepolia DEPOSIT_AMOUNT=0.001ether ./scripts/deposit-eth-sepolia.sh`. L1 tx `0x1abc97e6d64f9be2b2d2d21b675f2d43d78e6c25dfd36cdd9f891d395cd9d145` (status `0x1`). ADMIN L2 after: `1000000000000000` wei.

Initiate on **live** `:9545` (not the candidate): `1000000000000wei` (0.000001 ETH) to ADMIN `0xBB3E19811B2c3423069B54BDFF3e90Dd8094bb0F`. L2 tx `0x33bcb5934dc7b9acb4126fdefa324abc1fea8ff6dab14b8c7dd4d8a27ddbd937` in L2 block **400804**. Artifact: `$DATA_DIR/bridge-task4/last-withdrawal.json` (gitignored data tree).

Prove artifacts from **candidate only** (`L2_RPC_URL=http://127.0.0.1:19545`, output root from `:19547`; never live-geth fallback, never replica):

| Artifact | Endpoint | Result |
|---|---|---|
| `optimism_outputAtBlock` 400804 | `:19547` | MATCH live `:9547` |
| `eth_getProof` passer + nonce slot | `:19545` | MATCH live (storageHash / balance / nonce / codeHash / accountProof / storageProof) |
| L2 receipt | `:19545` | block 400804 status `0x1` |

`scripts/bridge/prove.mjs` against candidate: covering game **216** proxy `0xbD43A40dED613aabf89e14d2a91CE6E194A3e2Ed`. L1 prove tx `0xf33adedc4dd6f7cf62938d80e9f25f47e0d13efeee95d5b7e822f6c1f3949091`. `provenAt` **1788235512** = 2026-08-31T21:05:12 PT. Portal clocks (on-chain): `proofMaturityDelaySeconds=1800`, `disputeGameFinalityDelaySeconds=1800`. Withdrawal hash `0x06de34692e590ce003bddfa4dcbe9fe78c7360d753773b9804d6f3f9074a8abd`.

Game 216 is **IN_PROGRESS** (`status=0`), `maxClockDuration=7200`, `createdAt=1788235464` (21:04:24 PT). Portal finalize requires DEFENDER_WINS + finality delay — not just `provenAt+3600`. `withdraw-finalize.sh` / `finalize.mjs` are Anvil-only (`evm_increaseTime`) and must not be used on Sepolia.

Closer 1 remainder (no judge): wait for L1 timestamp ≥ `createdAt+maxClock` (23:04:24 PT), `resolveClaim(0,0)` + `resolve()` (permissionless; ADMIN gas; live hourly `resolve-games` at :00 is too late for a 23:45 sleep), then wait `disputeGameFinalityDelaySeconds` (~23:34:24 PT), then `finalizeWithdrawal` with **no** time-warp. Hard stop 23:42 PT. Hourly `com.steve.fortel2-resolve-games` at 00:00 would also resolve, but that is after sleep.

**Closer 1 named blocker (2026-08-31 23:04 PT):** L1 timestamp reached `createdAt+maxClock`. The waiter then failed `ERR_MODULE_NOT_FOUND: viem` because `node --input-type=module` ran from the repo root, not `scripts/bridge`. No `resolve` / `finalize` was sent. Game 216 was still `IN_PROGRESS` on the morning of 2026-09-01. Hourly `resolve-games` did not resolve it overnight. `withdraw-finalize.sh` / `finalize.mjs` remain Anvil-only. PRD Task 4 allows succeed-or-named-blocker; this is the named clock/script blocker.

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

**After SafeDB enable:** same live pids; L2 399489; sidecar 58830 / 58867 with SafeDB. Challenger 45520 still running.

**Closer session (21:22 PT):** live still 44832 / 44849 / 45087 / 45203 / 44964 / 45520. Sidecar restarted earlier without wipe: op-reth **21151**, op-reth-node **21207**. Isolated judge **24547** stopped at 21:22:42 PT (planner: do not run tonight).

**2026-09-01 morning:** 03:00 wake brought live pids 85333 / 85340 / 85563 / 85662 / 85931. Sidecar restarted 06:54 PT (no wipe): op-reth **88387**, op-reth-node **88446**. Isolated judge **92547** stopped after `Game info`. Live 85931 untouched.

## Residual

- Closer 1 finalize did not send: named blocker is the 23:04 `viem` cwd miss (game 216 still `IN_PROGRESS` as of 2026-09-01 morning). Initiate + candidate prove remain on-chain.
- Isolated L1 must use the loopback batch proxy (`127.0.0.1:9549`). Direct provider HTTPS 429s the factory fetch even with `--game-allowlist` + 3h window.
- Q3 profile shape (observed, not a Task 5 authorization): `sequencer_faultproof` = archive + `--proofs-history` (init `--skip-backfill` from genesis) + sidecar `--safedb.path` (`$DATA_DIR/l2/op-reth-safedb`). Replica prune window unchanged.

The candidate datadir is preserved so Task 5 can start from it later. Never `reset-sepolia` / `--wipe` / `debug_setHead` on the datadir. This STATUS complete is not a cutover.

Codex-tightened `verify-reth-faultproof.sh` re-ran live (game L2 397392, `--safedb-enable-l1` 11609837, `--pre-enable-l1` 11600000): PASS on three distinct recorded SafeDB L1s and full `eth_getProof` payloads (storageHash / balance / nonce / codeHash / accountProof / storageProof) vs the Mac archive geth. That does not lift the block.
