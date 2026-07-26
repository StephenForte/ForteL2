# PRD: Phase 5 — Custom Proposer (replace op-proposer)

## Introduction

Reimplement a **minimal DisputeGameFactory proposer** from scratch that can fetch L2 output roots from the rollup RPC, pack proposal `extraData`, and call `DisputeGameFactory.create` — then swap it in for stock `op-proposer` on the learning stack.

This is a **learning rebuild**, not a production proposer. Target the [dispute-game interface specs](https://specs.optimism.io/fault-proof/stage-one/dispute-game-interface.html); use stock `op-proposer` as the reference oracle. **No Sepolia redeploy** (pinned 2026-07-22 deploy through Phase 6).

**Parent roadmap:** `tasks/prd-l2-learning-chain.md` Phase 5  
**Companion:** SettlementOS money-rail proceeds in parallel and must not be broken by proposer experiments (same L1 contracts / genesis).  
**Predecessor:** Phase 4 custom batcher (`batcher/`, `USE_CUSTOM_BATCHER=1`).

## Goals

- Understand the propose path end-to-end (safe L2 head → output root → DGF game).
- Ship a separate Go module/binary under `proposer/` that can replace `op-proposer` for a demo window.
- Prove it by inspecting real ForteL2 dispute games and by creating at least one accepted game on the **local** Anvil stack first.
- Keep a one-command kill switch back to stock `op-proposer`.

## Non-goals

- Recomputing the output-root hash locally (v1 **fetches** via `optimism_outputAtBlock`; formula is a documented follow-up)
- L2OutputOracle path (proxy is zero on this deploy; DGF only)
- Fault proofs / `op-challenger` / dispute resolution (Phase 7)
- Super-root / multi-chain proposals
- Production fee estimation or multi-proposer coordination
- Sepolia redeploy, portal/immutables changes, or touching fortel2-replica genesis
- Replacing derivation/op-node (Phase 6)

## Constraints

| Constraint | Rule |
|---|---|
| Deploy | **Pinned** Sepolia L1 contracts — no `FORCE_SEPOLIA_REDEPLOY` |
| Host | Native Go; no Docker on the workstation |
| Keys | Never commit `.env.sepolia`; never ask operator to paste keys |
| L2 RPC | Loopback only for sequencer |
| Rollback | Stock `op-proposer` via existing `06-start-proposer*.sh` always works |
| SOS | Do not change chain ID, genesis, or DisputeGameFactory address |
| Privileged | No `lib.sh` `start_bg` / `stop_bg` edits |

## Minimal loop (from stock op-proposer + DGF specs)

1. Poll rollup `optimism_syncStatus`; pick proposeable L2 number (`safe` when `allow-non-finalized`, else `finalized`).
2. Skip genesis (`0`) and skip if a proposal was created within `proposal-interval` by this proposer.
3. Fetch output root via `optimism_outputAtBlock(blockNum)`.
4. Pack `extraData` as 32 bytes with L2 sequence number in the last 8 bytes (big-endian).
5. Read `initBonds(gameType)`; call `DisputeGameFactory.create(gameType, rootClaim, extraData)` with that value.
6. Track last proposed L2 sequence; on restart initialize from latest matching factory game.

## Phase roadmap

| Story | Scope | Status |
|---|---|---|
| **US-050** | Spec spike: inspect real DGF game + document root/extraData fields | **Done** |
| **US-051** | ABI helpers: extraData pack, create encode, initBonds (unit-tested) | **Done** |
| **US-052** | Propose loop against **local** Anvil L2 (901); stock proposer stopped | **Done** |
| **US-053** | Script switch: `USE_CUSTOM_PROPOSER=1` for local start path | **Done** |
| **US-054** | Optional Sepolia demo window + documented revert to stock | **Done** (documented + confirm gate; stock default) |
| **US-055** | Operator write-up: what an output root is; trust model → Phase 7 | **Done** |

## User stories

### US-050: Spec-aligned inspect spike
**Description:** As the operator, I want to inspect a real ForteL2 dispute game on L1 so Phase 5 is grounded in the DGF ABI, not guesswork.

**Acceptance Criteria:**
- [x] `proposer/` Go module exists with README citing dispute-game factory specs
- [x] Pure helpers for packing/unpacking proposal `extraData` (L2 sequence number)
- [x] CLI can take L1 RPC + factory address and print `gameCount`, latest game proxy, `rootClaim`, `l2SequenceNumber`, game type
- [x] Spike notes in `tasks/spike-phase-5-proposer.md`
- [x] Non-goal: submitting txs in this story

### US-051: Proposal ABI builder
**Description:** As the operator, I want unit-tested helpers that build `create` calldata and read `initBonds` so the propose loop does not hand-roll ABI bytes.

**Acceptance Criteria:**
- [x] Encode `create(uint32,bytes32,bytes)` calldata from game type, root claim, extraData
- [x] Pack/unpack 32-byte extraData (sequence in last 8 bytes BE)
- [x] Unit tests with fixtures
- [x] Explicit note: v1 fetches output root from rollup RPC (does not recompute)

### US-052: Local propose loop
**Description:** As the operator, I want the custom proposer to create at least one dispute game on local Anvil L1 while stock `op-proposer` is stopped.

**Acceptance Criteria:**
- [x] Binary reads L1 RPC, rollup RPC, factory address, proposer key from env (not committed) — `proposer/cmd/propose-loop`
- [x] With stock proposer stopped: custom proposer creates a game; `gameCount` advances (documented)
- [x] Duplicate-submission safeguards (track last proposed L2; init from factory; respect proposal interval)
- [x] Failure leaves chain recoverable by restarting stock `op-proposer`

### US-053: Script integration (local)
**Description:** As the operator, I want a flag to start the custom proposer instead of stock for local demos.

**Acceptance Criteria:**
- [x] `USE_CUSTOM_PROPOSER=1 ./scripts/06-start-proposer.sh` starts `proposer` binary
- [x] Default path unchanged (stock `op-proposer`)
- [x] README Phase 5 section documents the switch + kill switch
- [x] No privileged `lib.sh` changes unless unavoidable and human-reviewed (CODEOWNERS)

### US-054: Sepolia demo window (optional, careful)
**Description:** As the operator, I may run the custom proposer briefly on Sepolia 852 after local success.

**Acceptance Criteria:**
- [x] Local US-052 green first
- [x] Credit-budget poll/interval defaults respected (do not spam QuickNode)
- [x] Requires `CONFIRM_CUSTOM_PROPOSER_SEPOLIA=1`; documented max runtime / stop; revert to `06-start-proposer-sepolia.sh`
- [x] No genesis pack required; pinned deploy unchanged
- [x] If unsafe: abort and leave stock proposer as default for Sepolia until fixed

### US-055: Learning write-up
**Acceptance Criteria:**
- [x] ~1 page in README or `tasks/spike-phase-5-proposer.md`: what an output root is; safe vs finalize timing; what breaks if proposer stops; trust model → Phase 7
- [x] Phase 5 status updated in learning-chain PRD when US-052 (or US-054) accepted

## Success metrics

- Inspect spike green without operator pasting keys into chat
- One local dispute game created and visible via `cast` / pipeline viewer
- Stock proposer remains the default; custom path is opt-in
- Sepolia deploy remains pinned; replica not republished

## Open questions

- Should v2 recompute output roots locally for learning (vs always fetching)? Deferred — fetch is enough for Phase 5 acceptance.
- Permissioned game type `1` remains correct on the pinned deploy (yes — matches stock scripts).
