# Worker prompt — H3a: stub continuation must preserve L1-info sequence (Codex r3716862854)

Copy everything below the line into the worker. Mid-tier model. **Dispatch only after H3 merges** (shared test-file territory). Cloud checkout (runs its own 901 stack).

---

You are a fix-it worker on the ForteL2 repo. One confirmed external-review finding in the US-062 sequencer stub's continuation path. Read `tasks/plan-parallel-integration.md` §5, `tasks/decisions.md` (D-T6-*, D-R3-2, D-0014/15), AGENTS.md. All isolation invariants hold (isolated ELs only; reference read-only; no Sepolia spend).

## The bug

When the stub continues from a **non-genesis head** (`derivation/origin.go` head-recovery path), it parses the head's L1-info deposit but keeps only `L1OriginNumber`, dropping `SeqNumber` (and the origin hash). `RunSequencerStub` then initializes `DerivationState` from zero, so if the next L2 timestamp stays on the same L1 origin, the next block is built as an **origin change with seq=0** instead of `parentSeq+1` — wrong L1-info bytes. Worse, the strengthened follow-validation initializes from the same recovered state, so it **validates its own mistake** (oracle-independence gap). The demo never hits this because it wipes the stub datadir each run — the fresh-genesis path is correct and must stay so.

## Work items

1. **Fix:** carry the parsed `SeqNumber` + origin hash into the continuation state. Rule per the derivation spec: same origin as parent → `seq = parentSeq + 1`; `OriginForL2Timestamp` advances to a new origin → `seq = 0` and epoch hash updates. Fresh-genesis path unchanged.
2. **Make follow-validation independent:** it must not seed its expected seq/epoch from the same in-memory state the builder used — re-derive the expectation from the *parent block's* L1-info bytes (re-parse) so a builder-state bug is detectable. Note the change as `D-H3a-1`.
3. **Tests:** continuation-same-origin (seq increments), continuation-with-origin-advance (seq resets, epoch hash changes), fresh-genesis regression, and a would-have-caught-it test: builder seeded with a wrong seq → follow-validation FAILs.
4. **Live proof (own 901 stack):** run `sequencer-stub-demo.sh` **twice without wiping** the stub datadir between runs (the exact repro); second run's blocks must build on the first run's head with correct seq continuation and follow-validate PASS. Paste both runs' output.
5. Update `derivation/README.md` stub section (continuation semantics, one line) and tick nothing in PRDs — this is post-completion hardening; add an implementation-notes line in `tasks/prd-phase-6-derivation.md` only.

## Write allowlist (exclusive)

`derivation/` (origin.go, stub.go, engine.go if plumbing requires, their tests) · `derivation/README.md` · `tasks/prd-phase-6-derivation.md` (implementation note only) · `tasks/decisions.md` (append `D-H3a-n`) · `scripts/sequencer-stub-demo.sh` (only if a no-wipe rerun flag is needed)

Do NOT touch: `batcher/`, `proposer/`, `scripts/lib.sh`, other scripts, CI, verifier behavior (`verify.go` path must keep passing 901 + golden fixture replay).

## Contract

- Branch `agent/h3a-stub-seq` (pre-created) off tag **`wave7-base`** (pinned post-H-wave, D-0015).
- Commits: `fix(derivation): …` / `test(derivation): …`; squash-merged later.
- Tests before done (paste verbatim, watch exit codes — no grep pipelines): `cd derivation && go build ./... && go test ./... && govulncheck ./...`; `./scripts/test-helpers.sh`; the double-run demo output; a `derivation-check.sh` 901 window PASS proving the verifier is untouched.
- No merging, no pushing to main.

## Handoff report — REQUIRED as your final chat message

One copy-pasteable markdown block, exactly these sections; a PR description alone is bounced.

1. Branch + base; `git diff --stat <base>..HEAD`
2. Allowlist compliance
3. Fix: continuation rule implemented + spec cite; follow-validation independence change
4. The would-have-caught-it test (show it failing against the old behavior)
5. Live double-run demo output + verifier regression PASS
6. Tests + verbatim results
7. decisions.md entries
8. Operator actions needed (expected: none)
