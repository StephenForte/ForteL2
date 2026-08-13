# Spike P7-0 — Cut L1 cost and user transaction fees (blobs, span batches, cadence, scalars)

**Date:** 2026-08-13
**Status:** **CLOSED 2026-08-13 (D-0037).** Steps 1–3 done (P7-0-A) — span batches live on 852, **11.82× cheaper per L2 block**. Steps 4–5 (beacon + blob DA) **not pursued** — blob pruning at ~18 days conflicts with counterparty re-derivation (§1 P2). Step 7 (cadence) parked — it trades time-to-finality SOS depends on for cost no longer needed. **Step 6 (fee scalars) remains OPEN as a separate operator decision** — it is orthogonal to blobs and is the only step that reaches user-facing fees. **No SystemConfig writes were made.**
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
| **1** | Capture a clean burn + user-fee baseline, handling the auto-funding artifact (P3) | n/a | **Done (P7-0-A)** — see §4 |
| **2** | **Span batches** (P4) — no beacon, reversible, measurable on its own | Yes — flag revert | **Done (P7-0-A)** — `BATCHER_BATCH_TYPE=span` → `--batch-type=1` |
| **3** | Measure step 2 in isolation before stacking anything else | n/a | **Done (P7-0-A)** — ~11.8× cheaper per L2 block |
| **4** | ~~Beacon endpoint on both op-nodes~~ | — | **Not pursued (D-0037)** — only needed for blobs |
| **5** | ~~Switch `BATCHER_DA_TYPE=blobs`~~ | — | **Not pursued (D-0037)** — ~18-day blob pruning vs counterparty re-derivation |
| **6** | Re-scalar SystemConfig (P5) so **user fees** track the new cost | L1 tx, owner key | **OPEN — operator only.** Independent of steps 4–5. Scalars verified unchanged at OP Stack defaults (`baseFeeScalar` 1368) on 2026-08-13, so P7-0-A's 11.82× has **not** reached users. |
| **7** | ~~Cadence~~ | — | **Parked (D-0037)** — trades SOS-visible time-to-finality for cost no longer needed |

**Invariant:** never run step 5 before step 4. A blob-posting batcher with beacon-ignoring nodes halts derivation on the whole rail.

**Outcome: step 2 was the entry point and, as it turned out, most of the value.** Span batches need no new dependency, no secret, no external provider, and no answer to P2 — and they are measurable alone. Doing them first buys a real improvement and a clean measurement discipline before the beacon and blob-expiry questions have to be settled.

---

## 3. What this spike deliberately does not decide

- Whether to adopt blobs at all (P2 — operator).
- Which beacon provider, and whether it shares the QuickNode account.
- Target values for scalars or EIP-1559 params — those follow the step-1 baseline, not a guess.
- Whether the time-to-finality change from step 7 is acceptable to SettlementOS — that is a coordination question, and SOS should be asked before it lands, not after.

---

## 4. P7-0-A measurement (2026-08-13, Mac mini, live 852)

**Method (primary):** for each confirmed batcher→inbox L1 tx in the window, `gasUsed × effectiveGasPrice` from the receipt; divide the sum by the L2 blocks those channels covered (decoded from the channel: singular count, or span `blockCount`). This is immune to D-0027 auto-funding. Cadence (`max-channel-duration=30`), `--sub-safety-margin=2`, compression (`zlib`), and `DA=calldata` were not changed.

**Pinned op-batcher flag** (from `--help` + `flags.go`): `--batch-type` is a `UintFlag`, `0`=SingularBatch, `1`=SpanBatch (`DefaultText: singular`). Script default `BATCHER_BATCH_TYPE=span` maps to `--batch-type=1`. **Revert:** `BATCHER_BATCH_TYPE=singular ./scripts/05-start-batcher-sepolia.sh` (stock path stops an existing pid first so `start_bg` re-execs with the new flag).

| | before (singular) | after (span) |
|---|---|---|
| L1 txs | 12 | 12 |
| L1 blocks | 11482057–11482331 | 11482357–11482638 |
| L2 blocks | 981950–983791 (1842, contiguous) | 983792–985692 (1901, contiguous) |
| Window (PT) | 2026-08-13 11:52:40–12:49:04 | 2026-08-13 12:54:13–13:52:25 |
| Total L1 cost | 6,995,322,791,181,630 wei (0.006995 ETH) | 610,554,200,339,110 wei (0.000611 ETH) |
| **wei per L2 block** | **3,797,677,953,953** | **321,175,276,349** |
| ETH per L2 block | 0.000003798 | 0.000000321 |

**~11.8× cheaper per L2 block.** Calldata size dropped from ~6.5–7.2 KiB/channel to ~103–114 bytes/channel on this idle chain.

**Wallet-delta (secondary, D-0027):** funder last ran 2026-08-13T18:00:33Z; next slot 00:00 UTC. The after window is entirely between top-ups; batcher balance drop 0.000611 ETH matched on-chain gas. The before window had no balance sample at its start, so no honest wallet-delta for singular — the receipt method is the number to keep.

**Derivation:** `FORTEL2_ENV=.env.sepolia ./scripts/derivation-check.sh --sepolia` over blocks **985825–985874** (safe_l2 window, all after the span switch at 983792) — **PASS**, every derived hash matched the reference EL. Span decode is now load-bearing on real L1 data. `TestSepoliaGoldenReplay` still **matched=50** (historical singular fixture). Duplicate-channel logs after the 17s anchor restart (batcher re-posted overlapping spans) were last-write-wins and still matched.

**Replica:** Render `fortel2-replica` logged `decoded span batch from channel batch_type=SpanBatch` on the first new channel (block_count=154) and kept inserting; head 986024 vs sequencer safe 986024 at 14:03 PT. Lag still ~one channel (~5 min / tens-to-low-hundreds of blocks), unchanged character. No revert.
