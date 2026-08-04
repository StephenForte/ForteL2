# Worker prompt — T6: minimal sequencer stub (US-062)

Copy everything below the line into the worker. Run on the **strongest model**. Cloud/isolated checkout only (runs its own stack).

---

You are a protocol-engineering worker on the ForteL2 repo (personal OP Stack learning L2; local chain 901 on Anvil L1). Your task is **T6**: US-062, the gated sequencer stub — now explicitly approved by the operator (decisions.md `D-0009`). US-061 (the derivation verifier in `derivation/`) is merged and green; you build on it. Binding context, read all before coding:

- `tasks/prd-l2-learning-chain.md` — US-062 acceptance criteria (your spec) + Phase 6 non-goals
- `tasks/prd-phase-6-derivation.md` — US-062 section + the Engine-API isolation constraints (reference stack READ-ONLY; sealing/production only on a separate EL)
- `tasks/decisions.md` — D-T2-1, D-R1-1, D-T4-1..4, D-0009 bind you; append `D-T6-n` for your decisions
- `derivation/` — reuse, don't reinvent: `engine.go` (sealing-EL lifecycle + Engine API), `attrs.go`/`l1info.go` (payload attributes incl. the per-block L1-info deposit), `rollup.go`, `verify.go`
- `tasks/plan-parallel-integration.md` §5 + AGENTS.md (always)

## Goal

A minimal **block-building sequencer stub**: given a head on the **isolated EL**, produce ≥ N consecutive valid L2 blocks (N ≥ 10) via the Engine API, such that the US-061 verifier logic (or reference derivation semantics) can follow the chain you built. This is a learning artifact, not a sequencer replacement.

## Hard invariants (same as T4 — non-negotiable)

- **Local 901 only.** No Sepolia sequencing, no L1 spend, no funded keys, no redeploy.
- **Never** send `engine_*` (or any state-mutating call) to the reference `op-geth`/`op-node`. All block production happens on the isolated EL (own datadir under `$DATA_DIR`, own ports/JWT — extend the D-T4-1 lifecycle; new default ports if run concurrently with `derivation-check.sh`).
- **Kill switch documented and trivial:** stopping the stub + wiping the isolated EL datadir restores a clean slate; the reference sequencer is never displaced, so "revert to stock op-node" is a no-op by construction. State this explicitly in the README and prove the reference chain is untouched (tip hash unchanged before/after a stub run).

## Work items

1. **Stub** (suggested: `derivation/cmd/sequencer-stub/`, same module): start from a chosen head on the isolated EL (natural choice: the head left by a `derivation-check.sh` run, or re-seal the verified window first), then loop: build payload attributes (2s block time; L1-info deposit each block per `attrs.go`/`l1info.go`; empty user-tx set is acceptable — tx-pool parity is out of scope) → `engine_forkchoiceUpdatedV3` w/ attributes → `engine_getPayload*` → `engine_newPayload*` → forkchoice advance. Record which Engine API version pair you target and the op-geth `--l2.enginekind`-equivalent semantics in the README.
2. **Validation:** demonstrate the "verifier can follow" criterion concretely — your choice of mechanism (e.g. re-run US-061 attribute derivation against your own built blocks + L1-info consistency checks, or a second isolated verifier instance walking your chain), recorded as `D-T6-2`. Chain-validity minimum: every built block passes `engine_newPayload` VALID and parent-links correctly; paste N consecutive built block numbers + hashes in the handoff.
3. **Runner script** `scripts/sequencer-stub-demo.sh` (new): sources `lib.sh` (read-only), local-env asserts, isolated-EL lifecycle per D-T4-1 (foreground-owned child + trap), `--blocks N` flag, prints built blocks and the before/after reference-tip proof.
4. **Fixture-replay upgrade (rider):** `derivation/channel_test.go`'s `TestSepoliaGoldenSkipped` only stats the file. Upgrade it: when `testdata/sepolia/window.json` (a `VerifyReport`) is present, unmarshal it and assert window integrity (contiguous numbers, every block `Match`, derived==expected); keep skip-with-notice when absent. The operator may or may not have captured the fixture by the time you run — handle both.
5. **Tests:** unit-test the stub's attribute-building path with fixtures (reuse T4 patterns); no live-stack dependency in `go test`.
6. **Docs:** README — extend the Phase 6 derivation subsection with a short "Sequencer stub (US-062)" part; tick US-062 boxes you satisfied in both PRDs (leave anything unproven unticked); update the Phase 6 row fragment for US-062 only.
7. **Decisions:** `D-T6-1` (head-selection + EL lifecycle), `D-T6-2` (follow-validation mechanism), more as needed.

## Out of scope (hard)

Tx-pool policy parity · P2P/gossip · decentralized sequencing (Phase 8) · replacing the reference sequencer for real traffic · Sepolia anything · modifying `batcher/`, `proposer/`, `blocks/`, `viewer/`, `dapp/`, `scripts/lib.sh` · editing existing `derivation/*.go` beyond minimal exported-surface needs (prefer additive files; if an existing function must change signature/behavior, escalate `E-T6-n` unless it is a pure addition).

## Write allowlist (exclusive)

`derivation/` (additive: new files/dirs + `channel_test.go` fixture-replay upgrade + minimal additive edits) · `scripts/sequencer-stub-demo.sh` (new) · `README.md` (Phase 6 derivation subsection, US-062 part only) · `tasks/prd-l2-learning-chain.md` (US-062 rows + Phase 6 row US-062 fragment only) · `tasks/prd-phase-6-derivation.md` (US-062 ticks + implementation notes) · `tasks/decisions.md` (append-only) · `.gitignore` (stub scratch patterns only, if needed)

No CI change needed — the `derivation` go-test step already covers new tests.

## Contract

- Branch `agent/t6-sequencer-stub` (pre-created) off tag `wave3-base` — verify with `git merge-base --is-ancestor wave3-base HEAD`.
- Commits: `feat(derivation): …` / `test(derivation): …` / `docs(prd6): …`; squash-merged later.
- Tests before done (paste verbatim): `cd derivation && go build ./... && go test ./... && govulncheck ./...`; `./scripts/test-helpers.sh`; the live stub run output (N built blocks + reference-tip-unchanged proof).
- No merging, no pushing to main.

## Handoff report — REQUIRED as your final chat message

Your last message must BE the report: one copy-pasteable markdown block with exactly these numbered sections. Putting it only in a PR description or a repo file does not count — work without a final-message report is bounced unreviewed.

1. Branch + base (`wave3-base`); `git diff --stat wave3-base..HEAD`
2. Allowlist compliance (call out any edits to existing `derivation/*.go` and why they were additive-safe)
3. Built-chain evidence: N consecutive blocks (numbers + hashes), Engine API versions used, reference-tip before/after proof
4. Follow-validation mechanism (D-T6-2) + its output
5. Tests run + verbatim results (incl. govulncheck; fixture-replay test status: skipped or replayed)
6. PRD boxes ticked vs left open, with why
7. `decisions.md` entries + escalations
8. Operator actions needed
