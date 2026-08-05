# PRD: Phase 6 — Derivation verifier (+ gated sequencer stub)

## Introduction

Reimplement a **minimal derivation verifier** that reads ForteL2 batch data from L1, walks the OP Stack derivation pipeline for a bounded L2 window, and **diffs** against reference `op-node` (`optimism_syncStatus` + L2 block headers). Optional US-062 adds a block-building sequencer stub **only after** US-061 is green.

This is a **learning rebuild**, not a production rollup node. Target [ethereum-optimism/specs](https://specs.optimism.io/protocol/derivation.html); use stock `op-node` + `op-geth` as the oracle. **No Sepolia redeploy** (pinned 2026-07-22 deploy through Phase 6).

**Parent roadmap:** `tasks/prd-l2-learning-chain.md` Phase 6 (US-061, US-062)  
**Spike input:** `tasks/spike-phase-6-derivation.md` (US-060)  
**Predecessors:** Phase 4 batcher (`batcher/`), Phase 5 proposer (`proposer/`)

## Goals

- Understand L1 → L2 derivation end-to-end (frames → channels → batches → payload attributes → block headers).
- Ship a separate Go module under `derivation/` with a read-only verifier CLI and `scripts/derivation-check.sh` runbook helper.
- Prove parity on a **documented block window** against reference `op-node` on local **901** first, then Sepolia **852** (operator-run).
- Keep stock `op-node` sequencer running; verifier is side-by-side until US-062 is explicitly approved.

## Non-goals

- P2P, tx gossip, or replacing the sequencer in US-061
- Full EVM implementation from scratch (use a **separate** loopback `op-geth` Engine API instance for block-hash sealing when needed — never against the live reference EL)
- Patching upstream `op-node` in place
- Alt-DA, blob DA, batcher tx version ≠ 0
- Sepolia redeploy, portal/immutables changes, replica genesis republish
- Production sync performance or long historical backfill

## Constraints

| Constraint | Rule |
|---|---|
| Deploy | **Pinned** Sepolia L1 — no `FORCE_SEPOLIA_REDEPLOY` |
| Host | Native Go; no Docker on the workstation |
| Keys | Never commit `.env.sepolia`; never ask operator to paste keys |
| L2 RPC | Loopback only for reference stack |
| Reference stack | **Read-only** — `eth_getBlockByNumber` + `optimism_syncStatus` only; **never** `engine_*` against live reference `op-geth` / `op-node` |
| Engine API sealing | If used, **separate EL instance** (own datadir, ports, JWT) from same genesis; runbook documents isolation; kill/reset must not touch reference datadir |
| Rollback | Verifier is additive; stop custom binary, keep stock stack |
| Module boundaries | **Do not edit** `batcher/*.go` or `proposer/*.go`; import `batcher` decode helpers or copy with attribution + decision log |
| Privileged | No `lib.sh` `start_bg` / `stop_bg` edits |

## Architecture (US-061 v1)

```text
L1 RPC ──► derivation verifier
              ├─ traverse batch inbox txs (calldata v0)
              ├─ frames → channel (zlib) → batches (singular + span)
              ├─ deposits (Portal) + L1-info deposit handling
              ├─ payload attributes per L2 block
              └─ optional: separate loopback op-geth (Engine API) to seal block hashes — **not** the reference EL
Reference op-node / op-geth ──► optimism_syncStatus + eth_getBlockByNumber (read-only)
              └─ diff tool logs first mismatch (number, expected hash, got hash)
```

**Reuse from `batcher/` (import, read-only):** `ParseBatcherTxPayload`, `JoinFrameData`, `DecompressChannelZlib`, `ReadChannelBatches`, `DecodeSingularBatch`, `ParseL1InfoEpoch`.

**New in `derivation/`:** L1 batch inbox scanner, span-batch decoder, channel-bank / sequencing-window policy, deposit inclusion, payload-attribute builder, reference RPC client, diff reporter.

## Phase roadmap

| Story | Scope | Status |
|---|---|---|
| **US-060** | Spec spike + PRD + decode real batches | **Done** — `tasks/spike-phase-6-derivation.md` |
| **US-061** | Minimal derivation verifier + diff runbook | **Done** (T4) |
| **US-062** | Optional sequencer stub (Engine API block builder) | **Done** (T6) |

## User stories

### US-061: Minimal derivation verifier

**Description:** As the operator, I want a custom derivation verifier that advances over a bounded L2 window from L1 data and compares results to reference `op-node`, so I can trust the derivation path before any sequencer work.

**Acceptance Criteria:**

- [x] **`derivation/` Go module** with own `go.mod`, README citing spec URLs, and `go test ./...` green
- [x] **Inputs** (flags or env, no committed secrets):
  - L1 RPC URL (`assert_local_rpc_urls` or `assert_sepolia_rpc_urls` pattern in run script)
  - Rollup config path: `$DEPLOY_DIR/rollup.json` (`batch_inbox_address`, `l2_chain_id`, genesis/l1 anchors)
  - Deploy addresses: Portal, SystemConfig batcher hash check (from active `deployments.json` tree)
  - Reference rollup RPC: `$L2_NODE_RPC_URL` (loopback)
  - Window: `--start-l2` / `--end-l2` inclusive **or** `--channel-tx <L1 hash>` to derive the channel’s block span
- [x] **Pipeline stages implemented:**
  1. Fetch + filter L1 txs to batch inbox from authorized batcher(s)
  2. Parse version-0 frames; reassemble channel; zlib decompress
  3. Decode **singular** batches (type `0x00`)
  4. Decode **span** batches (type `0x01`) — required even if ForteL2 history is singular-only today
  5. Include **user deposits** from L1 Portal in the derived sequence (spec deposit derivation)
  6. Emit payload attributes / L2 block metadata for each derived block in the window
  7. **Block hash check:** compare derived block hash to reference `op-geth` `eth_getBlockByNumber` — v1 **MAY** seal via Engine API on a **separate loopback EL instance** (same genesis, own datadir/ports/JWT; document in runbook). **Never** call `engine_*` on the live reference `op-geth` used for diffing.
- [x] **Outputs:** stdout + optional JSON report:
  - Per-block: `{number, hash, parentHash, timestamp, txCount, source}` (`batch` | `deposit`)
  - Summary: `{matched, mismatched, windowStart, windowEnd, referenceSafeL2, referenceUnsafeL2}`
  - On mismatch: log block number, expected hash, actual hash, and derivation source tx
- [x] **`scripts/derivation-check.sh`** runbook:
  1. Require reference stack running (`status.sh` or explicit RPC checks)
  2. Local default window: L2 blocks **1–20** on chain **901** **or** blocks covered by batch tx `0x5548fd9463208e10a1bbcc0f544f78cc789d02b8461fb8f5b6da8c2629e90495`
  3. Sepolia optional: `--sepolia` uses `FORTEL2_ENV=.env.sepolia`; default window = last **50** blocks at reference `safe_l2` (inclusive)
  4. Exit code **0** iff all hashes in window match; **1** on any mismatch or RPC/derivation error
- [x] **Safe alongside stock stack** — does not bind sequencer ports or replace `op-node`
- [x] **Golden tests:** at least one checked-in fixture (hex channel body or L1 tx input) from local 901; Sepolia fixture optional (operator-supplied, gitignored OK)
- [x] README Phase 6 subsection (T4): link spike notes, runbook, kill switch (simply don’t run the verifier)

**Comparison window (D-T2-3 — binding):**

| Mode | Window | Match rule |
|---|---|---|
| Local **901** | Default blocks **1–20** (override allowed) | `derivedHash == eth_getBlockByNumber(n).hash` for every *n* in range |
| Sepolia **852** | **50 blocks** ending at reference `safe_l2.number` (inclusive) | Same hash equality; log `safe_l2` / `unsafe_l2` from `optimism_syncStatus` in report header |
| Heads | Primary: **`safe_l2`** block number + hash | `unsafe_l2` logged but not required to match in v1 |

**Kill switch:** do not run `derivation-check.sh`; stock derivation unchanged.

### US-062: Optional minimal sequencer stub (gated)

**Description:** As the operator, I want an optional sequencer that builds L2 blocks only after US-061 matches, so sequencing complexity does not block derivation learning.

**Gate:** **Do not start US-062** until all US-061 acceptance criteria are checked on **local 901**.

**Acceptance Criteria:**

- [x] Separate command under `derivation/cmd/` (e.g. `sequencer-stub`) — not merged into verifier binary
- [x] Engine API target: **separate loopback op-geth** (`--l2.enginekind=geth` equivalent documented); reference EL stays read-only
- [x] Produce **≥ 10** consecutive L2 blocks on the isolated EL; US-061 attribute derivation follows the stub’s blocks *(stock sequencer stays running/untouched — D-T6-1; “stopped” softened to isolation)*
- [x] Kill switch: stop stub + wipe isolated datadir; stock `op-node` never displaced (restart is a no-op by construction)
- [x] Out of scope: tx-pool parity, P2P, decentralized sequencing

## Success metrics

- US-061 exits 0 on local 901 default window against a running reference stack ✅ (2026-08-04, blocks 1–20)
- Sepolia 852 window matches when operator runs `FORTEL2_ENV=.env.sepolia ./scripts/derivation-check.sh --sepolia` — **MET** ✅ (2026-08-04): anchored window **601219–601268**, 50/50 hash match vs reference EL; golden fixture `derivation/testdata/sepolia/window.json` committed and replay-enforced in CI. (History: re-opened by D-0010; closed by R2 anchoring + R3 blob fee + the parentBeaconBlockRoot fix `06b87ac`.)
- No Sepolia redeploy; no edits to pinned `deployments/sepolia/` contracts tree

## Open questions (for T4)

- Engine API vs header-only weak mode: default to Engine API hash check on a **separate EL instance** unless operator flag `--metadata-only`; reference stack remains read-only
- Span batches: none in Aug 2026 Sepolia sample — still implement decoder before claiming Sepolia green
- Fjord brotli: add when a live channel fails zlib inflate

## Tracked dependency advisories

Same as `batcher/` / `proposer/` — **GO-2026-5932** (`x/crypto/openpgp` indirect); `govulncheck ./…` on `derivation/` module.

## Implementation notes (T4, 2026-08-04)

- **Verified local 901:** blocks **1–20** inclusive, all hashes match reference EL (Cursor Cloud VM, `./scripts/derivation-check.sh`).
- **Sealing EL:** `$DATA_DIR/l2/derivation-op-geth`, HTTP `:19645`, auth `:19651`, P2P `:30323`, JWT `$DATA_DIR/jwt/derivation-jwt.txt`. Foreground child process in runbook (no `lib.sh` `start_bg` edits).
- **Isthmus withdrawalsRoot:** op-geth `getPayload` omits `withdrawalsRoot`; verifier JSON-patches `0x8ed4baae…` before `engine_newPayloadV4`.
- **Sepolia live window:** implemented (`--sepolia`); operator verification pending (no golden fixture in repo yet).
- **US-062 (T6, 2026-08-04):** `derivation/cmd/sequencer-stub` + `scripts/sequencer-stub-demo.sh`. Isolated EL at `$DATA_DIR/l2/sequencer-stub-op-geth` (ports `:19745`/`:19751`, P2P `:30324`). Engine API: FCU V3 + getPayload/newPayload V4 (V3 fallback). Follow-validation: rebuild `BuildPayloadAttributes`, match L1-info deposit bytes + parent links (D-T6-2). Sepolia golden fixture test upgraded to replay-if-present.
- **R2 window anchoring (2026-08-04):** batches numbered by `(timestamp − genesis.l2_time) / block_time` with drift/duplicate handling; mid-chain windows copy reference datadir while stopped (`--make-anchor`), roll sealing copy to `start−1` via `debug_setHead`, initialize derivation state from L1-info deposit in reference block `start−1`; L1 scan progress every 100 blocks; genesis scan guard at L1 tip > 1M unless `--scan-from-genesis`. Local 901 genesis replay (1–20) unchanged.
- **R3 Codex round 2 (2026-08-04):** L1-info Ecotone+ `blobBaseFee` sourced from `eth_feeHistory` with per-block cache (D-R3-1); sequencer stub default L1 origin is `genesis.l1` / head L1-info (not L1 tip) with `-l1-origin` validation; follow-validation asserts sequencing-window timestamp invariant (D-R3-2). Unblocks operator Sepolia anchored run + fixture capture.
- **H3a stub continuation (2026-08-05):** non-genesis stub runs recover `SeqNumber` + origin hash from parent L1-info; follow-validation seeds independently from parent re-parse (D-H3a-1). `sequencer-stub-demo.sh --no-wipe` for double-run continuation repro.

## References

- Spike decode log: `tasks/spike-phase-6-derivation.md`
- Phase 4 batch wire format: `tasks/spike-phase-4-batcher.md`
- Decisions: `tasks/decisions.md` (`D-T2-1` … `D-T2-3`, closes `D-0006`)
