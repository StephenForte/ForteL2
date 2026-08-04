# Worker prompt — T1: MR-0 closeout + doc truth-up

Copy everything below the line into the worker.

---

You are a documentation-sync worker on the ForteL2 repo. Your task is **T1** in `tasks/plan-parallel-integration.md`. Read that plan's §5 (commit & merge contract) and `tasks/decisions.md` before starting; both bind you.

## Goal

The money-rail work (MR-0) is more built than its PRD admits. Verify each artifact yourself, then bring the docs in line with reality. You are truing up records, not building anything.

## Read first

- `tasks/prd-money-rail.md` (your main target)
- `tasks/coordination-settlementos.md`
- `deployments/rail-interface.json`
- `replica/README.md`
- `README.md` — SettlementOS subsection only
- `tasks/prd-l2-learning-chain.md` — MR roadmap row + Resolved decisions section

## Work items

1. For each acceptance criterion under US-MR-001, US-MR-002, US-MR-003 in `tasks/prd-money-rail.md`: verify the claimed artifact actually exists and satisfies the criterion (open the file, check the content — do not trust the plan or this prompt). Tick `[x]` only what you verified; leave unmet items unticked and list them in your handoff.
2. Update the money-rail phase table: MR-0 from "In progress" to its true state per your verification. Do not change MR-3/4/5 (they stay gated — see `decisions.md` D-0005).
3. `tasks/prd-l2-learning-chain.md`: update the **MR row only** in the roadmap table to match, and add one line to Resolved decisions dating the MR-0 closeout. Touch nothing else in that file.
4. `deployments/rail-interface.json`: if (and only if) your doc changes alter anything a consumer reads, bump `version` and `updated`. **Never change addresses, chain IDs, or URLs** — if one looks wrong, escalate (E-T1-n in `decisions.md`), don't fix.
5. Cross-check the three "replica update checklist" locations the PRD requires (README, `replica/README.md`, money-rail PRD) still agree with each other; fix drift in the files you own.
6. `README.md`: edits confined to the SettlementOS subsection, and only if verification found drift.

## Write allowlist (exclusive — anything else is a review rejection)

`tasks/prd-money-rail.md` · `tasks/coordination-settlementos.md` · `replica/README.md` · `deployments/rail-interface.json` (metadata only) · `tasks/prd-l2-learning-chain.md` (MR row + Resolved decisions only) · `README.md` (SettlementOS subsection only) · `tasks/decisions.md` (append-only)

Forbidden: everything else, especially `scripts/`, `deployments/sepolia/`, Go modules, `viewer/`, `dapp/`, AGENTS.md.

## Contract

- Branch `agent/t1-docs-truthup` off the BASE_SHA in `decisions.md` D-0001.
- Commits: `docs(mr0): <what>` (conventional commits; squash-merged later).
- Tests: none required for pure doc changes, but run `./scripts/test-helpers.sh` once to confirm you broke nothing by accident; paste the result.
- No merging, no pushing to main.

## Handoff report — REQUIRED as your final chat message

Your last message must BE the report: one copy-pasteable markdown block with exactly these numbered sections. Putting it only in a PR description or a repo file does not count — work without a final-message report is bounced unreviewed.

1. Branch + base SHA; `git diff --stat` output
2. Allowlist compliance (expected: clean)
3. Verification table: each US-MR criterion → verified/unmet, with the file:line evidence you checked
4. Unmet criteria left unticked, if any
5. Tests run + verbatim results
6. `decisions.md` entries added (IDs), escalations raised
7. Anticipated conflicts: which PRD rows / README lines siblings T2/T3 also touch
8. Operator actions needed (expected: none)
