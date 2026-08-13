# Spike P7-0 — Cut L1 cost and user transaction fees (blobs, span batches, cadence, scalars)

**Date:** 2026-08-13
**Status:** scoping only — **no code, no flags, no SystemConfig writes in this spike**
**Origin:** D-0025 found the batcher burn is a tuning artifact (calldata + 30-block channels + 5-minute proposals) and that blobs + span batches + relaxed cadence cut L1 cost to single-digit $/day. Operator goal restated 2026-08-11: **low user transaction fees**, not only low operator spend. Both share one lever.

---

## 0. The headline finding

**Phase 7 re-genesis is NOT required for any of this.** `deployments/sepolia/.deployer/rollup.json` has every fork active from genesis — `delta_time`, `ecotone_time`, `fjord_time`, `granite_time`, `holocene_time`, `isthmus_time`, `jovian_time` all `0`. Consequences:

- **Delta active** → span batches are available now.
- **Ecotone active** → blob DA is available now.
- **Holocene active** → the EIP-1559 parameters are **SystemConfig-settable at runtime**, not genesis-locked.

An earlier note in this thread said fee tuning was partly a re-genesis item. With Holocene at genesis it is not. P7-0 is fully decoupled from the Phase 7 wipe and can proceed on its own schedule.

---

## 1. Dependency map

### P1 — Beacon endpoint (HARD BLOCKER for blobs, and it is two places)

**Grounding (verified 2026-08-13):**

| Where | Line | Value |
|---|---|---|
| `scripts/04-start-sequencer-sepolia.sh` | 73 | `--l1.beacon.ignore=true` |
| `fortel2-replica/entrypoint.sh` | 322 | `--l1.beacon.ignore=true` |
| `.env.sepolia.example` | 31–32 | `L1_BEACON_URL=` commented out, "Optional until blob DA" |

op-node needs a beacon API to fetch blob sidecars during derivation. **Both nodes currently ignore the beacon.** Setting `BATCHER_DA_TYPE=blobs` before fixing this would not degrade performance — it would **stop the safe head advancing on both the sequencer and the replica**, because neither could read back what the batcher posted. This is a chain-halting change, not a knob.

It is also a **new external dependency**: a Sepolia beacon API (QuickNode offers one; public endpoints exist and are unreliable). Same secret-hygiene rules as the L1 RPC — `.env.sepolia`, gitignored, never in the example file, redacted in logs, and **never shared with Render** (see the existing QuickNode warning in `rail-interface.json`).

### P2 — Blob expiry vs the verifier story (**operator decision, not a task**)

Blobs are pruned by consensus clients after roughly **18 days** (4096 epochs). Calldata is permanent.

ForteL2's differentiator per D-0025 is that the `derivation/` verifier is "the institutional audit tool" and replicas are "one per counterparty" — a counterparty re-derives the chain from L1 and checks it independently. **Under blob DA, re-deriving history older than ~18 days is impossible without an archive.** A counterparty who wants to audit a settlement from two months ago cannot get the data from L1 alone.

This is a real tension between "single-digit $/day" and "auditable settlement rail", and it is the operator's call, not a worker's. Options, none pre-selected:

1. **Accept it** — treat recent-window verifiability as sufficient for staging, revisit before mainnet.
2. **Archive blobs** — run or subscribe to a blob archive (e.g. a blob-archiver service writing to object storage) so derivation can be replayed indefinitely. Adds a component and a storage cost.
3. **Stay on calldata for settlement-bearing batches**, blobs for the rest — not supported by op-batcher as a per-batch choice; would need custom work. Listed for completeness, likely not viable.
4. **Stay on calldata** — accept the cost, keep permanence.

**Nothing in this spike should be implemented before P2 is answered**, because it decides whether blobs are on the table at all.

### P3 — Measurement is harder than it looks

D-0027: the batcher is auto-funded by ChainBank's reconciler on a `0 */6 * * *` cron at a flat 0.6 ETH. `gas-runway.sh` skips any interval where the balance rose, so **auto-funding erases drawdown windows**. A naive before/after comparison will produce a burn figure that is an artifact of top-up timing.

Any measurement must either (a) take an uninterrupted drawdown window between top-ups, or (b) subtract the reconciler's `weiTransferred` over the window. Also note D-0026: the shorter sleep window (23:45–03:00 vs 23:00–04:00) raised daily burn by roughly 22%, so the pre-change baseline must be re-measured, not taken from the 0.168 ETH/day figure recorded before that change.

**Baseline must be captured before any tuning lands**, or the improvement cannot be quantified.

### P4 — Span batches (independent of blobs, no beacon needed)

Delta is active, so op-batcher can emit span batches instead of singular ones. Current live logs show `batch_type=SingularBatch` with `compression_algo=zlib`. Span batches amortise per-batch overhead across many blocks and compress substantially better on a low-traffic chain — which this is (most blocks carry only the L1 attributes deposit).

**This needs no beacon and no new external dependency**, and it is reversible with a flag. It is the cheapest real win available.

### P5 — Fee scalars (runtime, operator-owned)

`l1BaseFeeScalar` and `l1BlobBaseFeeScalar` live in SystemConfig on L1 and are settable by its owner. They determine the L1 data-fee component of what users pay — the dominant term on a low-traffic L2. Changing DA type without revisiting scalars leaves user fees mispriced relative to actual cost.

Writing to SystemConfig is an **L1 transaction from the owner key** — real money, real irreversibility. Out of scope for a worker; operator-run with a documented before/after.

### P6 — L2 execution fee (runtime under Holocene)

Genesis has `eip1559Elasticity: 6`, `eip1559Denominator: 50` (Canyon 250), genesis base fee **1 gwei**, gas limit 60,000,000. 1 gwei is high for an L2 — most OP chains run orders of magnitude lower. Under Holocene these are SystemConfig-settable, so this is tunable without a wipe.

### P7 — Cadence

`--max-channel-duration`, `--sub-safety-margin=2`, `--target-num-frames`, proposer interval. D-0025 named "relaxed cadence" as part of the fix. Trade-off: longer channels mean cheaper batching and **slower safe-head advance**, which directly affects how quickly a settlement reaches `safe`/`finalized` — the property SettlementOS depends on. Do not relax cadence without stating the new time-to-finality.

### P8 — The replica must move in lockstep

The replica derives from L1. Any DA change requires its op-node to be updated in the **same** operational step, in a different repo (`fortel2-replica`). A mini-only change silently breaks the replica, and the replica is what SettlementOS reads.

### Explicit non-dependencies

- Phase 7 re-genesis (see §0)
- Fault proofs / op-challenger
- The custom `batcher/` / `proposer/` Go modules — D-0025 froze them; production path is stock op-batcher
- The write path / Cloudflare / SettlementOS integration — done and unrelated

---

## 2. Sequenced plan (fixed order)

| Step | Work | Reversible? | Owner |
|---|---|---|---|
| **0** | **Answer P2** — blob expiry vs counterparty verifiability | n/a | **Operator** |
| **1** | Capture a clean burn + user-fee baseline, handling the auto-funding artifact (P3) | n/a | Worker |
| **2** | **Span batches** (P4) — no beacon, reversible, measurable on its own | Yes — flag revert | Worker |
| **3** | Measure step 2 in isolation before stacking anything else | n/a | Worker |
| **4** | Beacon endpoint on **both** op-nodes, still `DA=calldata`, verify derivation unaffected | Yes | Worker + operator (secret) |
| **5** | Switch `BATCHER_DA_TYPE=blobs`, sequencer + replica together | Yes — but see P2 | Worker + operator |
| **6** | Re-scalar SystemConfig (P5) so user fees track the new DA cost | L1 tx, owner key | **Operator only** |
| **7** | Cadence (P7), with the new time-to-finality stated for SOS | Yes | Worker |

**Invariant:** never run step 5 before step 4. A blob-posting batcher with beacon-ignoring nodes halts derivation on the whole rail.

**Recommended entry point: step 2.** Span batches need no new dependency, no secret, no external provider, and no answer to P2 — and they are measurable alone. Doing them first buys a real improvement and a clean measurement discipline before the beacon and blob-expiry questions have to be settled.

---

## 3. What this spike deliberately does not decide

- Whether to adopt blobs at all (P2 — operator).
- Which beacon provider, and whether it shares the QuickNode account.
- Target values for scalars or EIP-1559 params — those follow the step-1 baseline, not a guess.
- Whether the time-to-finality change from step 7 is acceptable to SettlementOS — that is a coordination question, and SOS should be asked before it lands, not after.
