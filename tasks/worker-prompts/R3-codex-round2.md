# Worker prompt — R3: blob base fee correctness + stub L1-origin validity (Codex round 2)

Copy everything below the line into the worker. Run on the **strongest model**. Cloud/isolated checkout (runs its own 901 stack).

---

You are a protocol-engineering worker on the ForteL2 repo. Your task is **R3**: two confirmed external-review findings in `derivation/`, both live on main. Read first: `tasks/decisions.md` (D-0010..D-0012, D-R2-n, D-T6-n bind you), `tasks/plan-parallel-integration.md` §5, AGENTS.md. All prior isolation invariants hold (reference stack read-only; `engine_*`/`debug_*` only to isolated ELs; no Sepolia spend/keys/redeploy; never touch `batcher/`, `proposer/`, `scripts/lib.sh`).

## F1 — Derive the real L1 blob base fee (blocks the operator's Sepolia run)

`derivation/l1info.go:68` hard-codes `blobBaseFee := big.NewInt(1)` in the Ecotone/Isthmus/Jovian L1-info payloads. On Ecotone+ L1s the actual blob base fee of the origin block belongs in those bytes; any origin where it ≠ 1 changes the L1-info tx → wrong sealed block hash → **false mismatch** against the reference. Local 901 passes only because idle Anvil sits at 1 — which also means a naive fix can silently regress; prove equivalence both ways.

- Source the real value per origin block. Two candidate designs — pick one, record as `D-R3-1`, and justify:
  1. **RPC-authoritative:** `eth_feeHistory` (geth returns `baseFeePerBlobGas` per block, Cancun+) — no fork math in our code; needs batching/caching so you don't add one RPC call per derived block against QuickNode.
  2. **Spec-computed:** extend the header struct with `excessBlobGas` and compute `fake_exponential(MIN_BLOB_GASPRICE, excessBlobGas, blobBaseFeeUpdateFraction)` — beware: the update fraction is **fork-dependent on 2026 L1** (Cancun → Prague/BPO schedules differ); hard-coding Cancun's constant is exactly the same class of bug you are fixing.
- Whatever the source, the arbiter is the hash match: 901 windows must still PASS, and add a unit test with a non-1 blob base fee vector proving the Ecotone+ marshal bytes change accordingly.
- Also audit the neighbouring hard-codes in the same function (anything else defaulted that the spec says comes from the origin block) — fix or explicitly justify in the decision entry.

## F2 — Stub L1 origin must satisfy derivation timestamp semantics

`derivation/stub.go` defaults the origin to the **L1 tip**. A fresh stub EL builds block 1 with timestamp `genesis.l2_time + block_time`, so its L1 origin's timestamp is far in the future relative to the L2 timestamp — the Engine API accepts it, but the chain is invalid under OP derivation rules (an L2 block's timestamp must be ≥ its origin's, within sequencer drift). The stub's follow-validation missed this because it re-derives with the same wrong origin.

- Fix the default: choose an origin valid for the planned next L2 timestamp — from a fresh genesis head that is the chain's L1 genesis anchor (`rollup.json` genesis.l1), advancing epochs only when the L1 origin timestamp keeps `l2_ts ≥ l1_ts` within `max_sequencer_drift`. When starting from a non-genesis head, recover the current epoch from the head's L1-info deposit (the R2 `ParseL1InfoDeposit` path) and continue from there.
- Keep an explicit `-l1-origin` override but **validate it** (reject origins whose timestamp violates the constraint) instead of trusting it.
- Strengthen follow-validation so it would have caught this: assert the timestamp/origin invariant independently of how attributes were built, and cite the spec section (derivation: sequencing window / origin selection rules) in `derivation/README.md`.
- Live proof (your VM, own 901 stack): `sequencer-stub-demo.sh` run whose built blocks pass the strengthened validation; plus a regression note showing the old default would now be rejected.

## Write allowlist (exclusive)

`derivation/` · `scripts/derivation-check.sh` + `scripts/sequencer-stub-demo.sh` (only if flag plumbing requires) · `derivation/README.md` + `README.md` (Phase 6 derivation subsection only, only if behavior notes change) · `tasks/prd-phase-6-derivation.md` (implementation notes) · `tasks/decisions.md` (append `D-R3-n`) 

## Contract

- Branch `agent/r3-codex-round2` (pre-created) off tag `wave5-base` — verify with `git merge-base --is-ancestor wave5-base HEAD`.
- Commits: `fix(derivation): …` / `test(derivation): …`; squash-merged later.
- Tests before done (paste verbatim): `cd derivation && go build ./... && go test ./... && govulncheck ./...`; `./scripts/test-helpers.sh`; `/bin/bash -n` on any touched script (macOS bash 3.2; no `$VAR`-adjacent en-dashes); live 901 verifier window PASS (genesis 1–20 **and** a mid-chain anchored window) + the stub demo run.
- No merging, no pushing to main.

## Handoff report — REQUIRED as your final chat message

Your last message must BE the report: one copy-pasteable markdown block with exactly these numbered sections. A PR description alone is bounced unreviewed.

1. Branch + base (`wave5-base`); `git diff --stat wave5-base..HEAD`
2. Allowlist compliance
3. F1: chosen blob-fee source (D-R3-1) + why; the non-1 vector test; other hard-codes audited in `marshalL1Info` (fixed or justified)
4. F2: origin-selection rule implemented + spec cite; strengthened follow-validation; proof the old default is now rejected
5. Live runs: 901 genesis window, 901 mid-chain anchored window, stub demo — verbatim PASS output
6. Tests run + verbatim results (incl. govulncheck, bash -n)
7. `decisions.md` entries + escalations
8. Operator actions needed (expect: the Sepolia anchored run + fixture capture, now unblocked)
