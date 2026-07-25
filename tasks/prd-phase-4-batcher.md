# PRD: Phase 4 — Custom Batcher (replace op-batcher)

## Introduction

Reimplement a **minimal calldata batcher** from scratch that can read unsafe L2 blocks, encode/compress them per the [OP Stack derivation / batcher specs](https://specs.optimism.io/protocol/derivation.html), and post frames to the L1 Batch Inbox — then swap it in for stock `op-batcher` on the learning stack.

This is a **learning rebuild**, not a production batcher. Target the specs; use stock `op-batcher` as the reference oracle. **No Sepolia redeploy** (pinned 2026-07-22 deploy through Phase 6).

**Parent roadmap:** `tasks/prd-l2-learning-chain.md` Phase 4  
**Companion:** SettlementOS money-rail proceeds in parallel and must not be broken by batcher experiments (same L1 contracts / genesis).

## Goals

- Understand batch submission wire format end-to-end (tx → frames → channel → batches).
- Ship a separate Go module/binary under `batcher/` that can eventually replace `op-batcher` for a demo window.
- Prove parity by decoding real L1 batches from ForteL2 history and by submitting at least one accepted channel on the **local** Anvil stack first.
- Keep a one-command kill switch back to stock `op-batcher`.

## Non-goals

- EIP-4844 blob DA (calldata only; matches current `BATCHER_DA_TYPE=calldata`)
- Alt-DA / experimental batcher tx version 1
- Production fee estimation, multi-batcher coordination, or P2P
- Span-batch perfection on day one (singular batches first; span as follow-up once singular works)
- Sepolia redeploy, portal/immutables changes, or touching fortel2-replica genesis
- Replacing proposer (Phase 5) or derivation/op-node (Phase 6)

## Constraints

| Constraint | Rule |
|---|---|
| Deploy | **Pinned** Sepolia L1 contracts — no `FORCE_SEPOLIA_REDEPLOY` |
| Host | Native Go on Apple Silicon; no Docker on this Mac |
| Keys | Never commit `.env.sepolia`; never ask operator to paste keys |
| L2 RPC | Loopback only for sequencer |
| Rollback | Stock `op-batcher` via existing `05-start-batcher*.sh` always works |
| SOS | Do not change chain ID, genesis, or Batch Inbox address |

## Minimal loop (from OP batcher spec)

1. If L2 `unsafe` > `safe`, there is data to submit.  
2. Iterate unsafe L2 blocks not yet submitted.  
3. Open a channel; encode + compress batches per derivation spec.  
4. Split channel into frames; pack into version-0 batcher txs.  
5. Submit to L1 Batch Inbox from the configured batcher EOA.  

## Phase roadmap

| Story | Scope | Status |
|---|---|---|
| **US-040** | Spec spike: frame/channel decode + one real L1 batch decoded | **Done** |
| **US-041** | Singular-batch encode + zlib channel + frame pack (unit-tested) | **Done** |
| **US-042** | Submit loop against **local** Anvil L2 (901); stock batcher stopped | **Done** |
| **US-043** | Script switch: `USE_CUSTOM_BATCHER=1` for local start path | Planned |
| **US-044** | Optional Sepolia demo window + documented revert to stock | Planned |
| **US-045** | Operator write-up: what a batch contains; safe/unsafe lag; lessons | Planned |

## User stories

### US-040: Spec-aligned decode spike
**Description:** As the operator, I want to decode real ForteL2 batcher calldata into frames (and ideally a channel) so Phase 4 is grounded in the wire format, not guesswork.

**Acceptance Criteria:**
- [x] `batcher/` Go module exists with README citing specs URLs (derivation + batcher overview)
- [x] Pure functions: parse version-0 batcher tx payload → frames; round-trip encode/decode in tests
- [x] CLI (or script) can take L1 RPC + Batch Inbox + optional batcher address and print frame metadata for ≥1 real tx — CLI shipped; live local tx `0x97de57af…` decoded (see spike notes)
- [x] Spike notes in `tasks/spike-phase-4-batcher.md`: compression (zlib vs Fjord), singular vs span decision for US-041
- [x] Non-goal: submitting txs in this story

### US-041: Channel builder (singular batches)
**Description:** As the operator, I want to build a zlib channel from singular batches so we can produce valid frames without stock op-batcher.

**Acceptance Criteria:**
- [x] Encode singular batch (version 0) from L2 block fields needed by the spec
- [x] zlib channel compress + frame split with configurable max frame data size
- [x] Unit tests with fixtures; optional compare against a captured stock-batcher payload (live local channel decompresses; first batches are singular)
- [x] Explicit deferral note if span batches are required by the live chain’s fork schedule — **deferred**: builder emits singular only; live fixture may also contain span (type 1); revisit if local submit (US-042) rejects singular-only channels

### US-042: Local submit loop
**Description:** As the operator, I want the custom batcher to post at least one channel to local Anvil L1 while stock `op-batcher` is stopped, and see `op-node` advance safe head.

**Acceptance Criteria:**
- [x] Binary reads L2 EL + rollup RPC (`optimism_syncStatus` or equivalent), L1 RPC, rollup.json inbox, batcher key from env (not committed) — `batcher/cmd/submit-loop`
- [x] With stock batcher stopped: custom batcher submits; safe L2 head moves forward within a documented window — live 2026-07-24: safe 16→22 after `-once`
- [x] Duplicate-submission safeguards documented (at least: track last submitted L2 block) — see `batcher/README.md`
- [x] Failure leaves chain recoverable by restarting stock `op-batcher`

### US-043: Script integration (local)
**Description:** As the operator, I want a flag to start the custom batcher instead of stock for local demos.

**Acceptance Criteria:**
- [ ] `USE_CUSTOM_BATCHER=1 ./scripts/05-start-batcher.sh` (or sibling script) starts `batcher` binary
- [ ] Default path unchanged (stock `op-batcher`)
- [ ] README Phase 4 section documents the switch + kill switch
- [ ] No privileged `lib.sh` changes unless unavoidable and human-reviewed (CODEOWNERS)

### US-044: Sepolia demo window (optional, careful)
**Description:** As the operator, I may run the custom batcher briefly on Sepolia 852 after local success.

**Acceptance Criteria:**
- [ ] Local US-042 green first
- [ ] Credit-budget poll/channel defaults respected (do not spam QuickNode)
- [ ] Documented max runtime / stop procedure; revert to `05-start-batcher-sepolia.sh`
- [ ] Replica continues deriving (L1 data still valid); no genesis pack required
- [ ] If unsafe: abort and leave stock batcher as default forever for Sepolia until fixed

### US-045: Learning write-up
**Acceptance Criteria:**
- [ ] ~1 page in README or `tasks/spike-phase-4-batcher.md`: batch anatomy, why safe lags unsafe, what breaks if batcher stops
- [ ] Phase 4 status updated in learning-chain PRD when US-042 (or US-044) accepted

## Success metrics

- Decode spike green without operator pasting keys into chat
- One local channel submitted and reflected in safe head
- Stock batcher remains the default; custom path is opt-in
- Sepolia deploy remains pinned; replica not republished

## Open questions

- Does the pinned chain’s fork schedule require span batches for new channels, or are singular batches still accepted?
- Fjord channel encoding version byte / brotli — confirm against live `rollup.json` `l2_chain_id` 852 config before US-041
- Should the custom batcher live as `batcher/` in this repo (yes, default) vs a separate repo?
