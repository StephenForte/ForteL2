# FRD — US-P7-005: Independent derivation (Path A)

**Status:** specified (D-0094) · **PRD:** `tasks/prd-mainnet-pilot.md` § US-P7-005 · **Gap:** `derivation/README.md` § Limitations

## 1. Problem

`cmd/verify` is tethered to the operator's node twice:

1. **The expected value** — `verify.go` fetches the "expected" hash from `-ref-l2`, the operator's own L2 EL (`ref.BlockHash`, verify.go:84). The oracle being audited supplies the answer key.
2. **The anchor** — mid-chain windows start from a datadir copied from the operator's node (`--make-anchor`, D-R2-2).

A counterparty running this today proves consistency, not honesty.

## 2. Decision (D-0094)

**Path A: self-derived state from genesis, compared against the operator's on-chain proposals.**

- The chain was wiped 2026-08-22 (D-0068); full history is ~3 days (~130k mostly-empty L2 blocks). A genesis replay will never be cheaper.
- After the first full replay, the derivation EL's **own datadir becomes the anchor** for all future runs — self-anchored incremental audits, never the operator's datadir again.
- The comparison oracle becomes the operator's **proposals on L1** (type-8 dispute games in the DisputeGameFactory, D-0077): derive from L1 → compute output root → diff against the root claim the operator staked on. That is exactly the claim a counterparty needs audited.

Path B (counterparty-replica anchor) was rejected as primary: independence would rest on stock op-node, it needs counterparty infra that is itself blocked on this story (PRD § 3, replica pack), and alone it does not remove tether 1. T3 may document it as a future alternative; nothing here builds it.

## 3. Non-goals

- Replica pack / counterparty Docker runbook (stays blocked until T3 lands, then unblocks separately).
- Independence of the fault-proof VM path (kona prestate trust is US-075 §trust-boundary material, unchanged).
- Phase 8 anything.

## 4. Tasks

### T1 — `spike/genesis-replay-measure` (measure first; the number decides the rest)

**Owns:** `scripts/derivation-check.sh`. May append tests to `scripts/test-helpers.sh`. Must not touch `derivation/*.go`.

- Add `--self-anchor` (name negotiable): seal-EL datadir is **kept** after a run and reused as the start state for the next window; refuse to mix with `--anchor-datadir`.
- Measure on Sepolia: seal rate (blocks/s) over a ≥1000-block window, projected genesis→head wall-clock, and a proven stop/resume (derive 1..N, exit, derive N+1..M from own datadir, hashes contiguous).
- **Deliverable includes the measurement in the handoff.** If projected full replay exceeds ~12 h, say so — that triggers an operator decision on checkpoint cadence, not silent scope growth.

### T2 — `feat/proposal-compare` (kills tether 1)

**Owns:** `derivation/` Go (new files, e.g. `proposals.go`, `outputroot.go`; `cmd/verify` flags). Must not edit `batcher/*.go` (import-only rule stands). May append tests.

- Fetch proposals: enumerate DisputeGameFactory games of the configured game type (default 8), decode `rootClaim` + `l2BlockNumber` (extraData); factory address from the deploy artifacts, overridable by flag.
- Compute output root at a proposal height from the **seal EL**: version-0 preimage `keccak(version ‖ stateRoot ‖ messagePasserStorageRoot ‖ blockHash)`, storage root via `eth_getProof` on `0x…4200…0016`.
- New mode (e.g. `-compare proposals`): derived output root vs claimed root at each proposal height in the window; report per-proposal MATCH/MISMATCH plus the game's resolution status (comparison is against the claim regardless of resolution; status is context, not a gate).
- `-ref-l2` remains for the legacy consistency mode; proposal mode must run without it.
- Tests: fixture-driven (synthetic games + known preimages); no live-chain dependency in `go test`.

### T3 — `docs/derivation-independence` (after T1+T2 merge)

**Owns:** `derivation/README.md` (Limitations + runbook), counterparty-facing docs language sweep ("consistency" → what is now true), `tasks/prd-mainnet-pilot.md` US-P7-005 checkboxes 2–3.

- Limitations section rewritten to state the new trust base: L1 data + this verifier + the sealing op-geth. What is still trusted, plainly.
- Counterparty runbook: first full replay, then self-anchored incremental audit, then proposal comparison — as run-button-complete blocks.

## 5. Order, models, review

- **Order:** T1 → T2 → T3. T1 ∥ T2 acceptable (disjoint files); T3 strictly after both merge.
- **Branching:** per D-0093-era protocol — the brief assigns branch name + baseline sha; the **worker cuts the branch off main itself**; stop-and-ask if it exists.
- **Models:** T1, T3 Sonnet. T2 Sonnet + **Codex review** (metered budget justified: this is the honesty/audit path).
- **Decision ids:** allocated at review time from the next free id (D-0095 onward after D-0094). decisions.md entries stack in id order at the Escalations marker (the #149 lesson).
- **Gates (every task):** `bash -n` on touched scripts, `./scripts/test-helpers.sh` 0 FAIL, `phase7-gate-parity.sh` exit 0, `cd derivation && go test ./...` where Go is touched. Live shakeout per task in the brief (never-run-live scripts break live).

## 6. Risks

- **Seal-rate unknown** — T1 exists to measure it before T2's mode is promised to anyone.
- **Proposal cadence:** proposals are per-interval, not per-block; audits are at proposal granularity. Acceptable — that is the granularity disputes happen at.
- **Live-vs-CI split:** proposal enumeration needs L1 RPC; tests stay fixture-only, live proof happens in the shakeout.
