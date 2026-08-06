# Worker prompt — R-07: PRD status hygiene

Copy everything below the line into the worker. **Cheap model tier.** Wave 2; R-02/R-08 run in parallel — allowlists are exclusive. You own the learning-chain and money-rail PRDs this wave; R-08 owns the mainnet-pilot PRD — do not touch it even if you spot issues there (escalate instead).

---

You are a docs worker on the ForteL2 repo. Your task card is **`tasks/review-2026-08-05.md` §R-07** — read it in full; it is the spec. This prompt adds the coordination contract plus one integrator-added work item inherited from Wave 1.

## Task in one line

Mechanical status truth-up: retire the three already-answered Open Questions into Resolved decisions, mark US-030's impossible criterion N/A, set MR-2's status to Blocked-per-D-0016, add Phase 6's completion date and the D-0017 closure — plus finish the Phase-7 vocabulary sweep R-06 could not reach.

## Integrator-added item (from merged R-06's handoff, D-0021 vocabulary)

R-06's allowlist covered only named lines; these wipe-event "Phase 7" hits remain in **your two files** and must be reworded to the D-0021 vocabulary — "redeploy gate (Phase 7 / mainnet-pilot entry)" or "redeploy gate" as fits the sentence:

- `tasks/prd-money-rail.md`: the G2 row pin note ("no Sepolia redeploy until Phase 7"), the "Next expected replica artifact update = Phase 7" pin paragraph, the Phases 4–6 parallel-work line, and the reset-policy checkbox line ("Sepolia pinned until Phase 7; Phase 7 = coordinated wipe").
- `tasks/prd-l2-learning-chain.md`: the "Phase 7 entry gate" phrasings in the 2b roadmap row, the MR row, the 2026-07-22 pin paragraphs (~lines 60, 286, 353, 428, 495).

**Do not** reword hits where "Phase 7" genuinely means the fault-proof learning phase (e.g. "No fault proofs, op-challenger, or dispute games (Phase 7)", the US-030 proposer-trust line, Phase 9 open question) — those are correct under D-0021. When a wipe-event hit sits inside a `[x]` checkbox line, reword the text without flipping the box.

Acceptance grep (run it): `grep -n "Phase 7" tasks/prd-l2-learning-chain.md tasks/prd-money-rail.md` — every remaining hit is the fault-proof phase, the glossary itself, or an explicit "redeploy gate (Phase 7 …)" construction.

## Write allowlist (exclusive)

`tasks/prd-l2-learning-chain.md` · `tasks/prd-money-rail.md` — and nothing else. Diff must touch only these two files. No decisions entry is assigned; escalate via handoff `E-R07-<n>` if genuinely needed.

## Contract

- Branch `agent/r07-prd-hygiene` off tag `wave9-base`. Commits: `docs(prd): …`. Squash-merged second in Wave 2.
- Checks before done (paste verbatim): the acceptance grep above · for each Open Question you retire, the `tasks/decisions.md` ID that answers it (D-0003, D-0004, or the in-line "resolved for MVP" note) · `git diff --stat wave9-base..HEAD` showing exactly two files · confirmation that no question appears in both §Open Questions and §Resolved decisions.
- Leave genuinely open questions alone (Phase 3b size, Phase 9 budget/legal, explorer choice, blob-vs-calldata, networkId string).
- No merging, no pushing to main, no tags.

## Handoff report — REQUIRED as your final chat message

1. Branch + base tag; `git diff --stat wave9-base..HEAD`
2. Allowlist compliance
3. Card success criteria + integrator item — each: met, with evidence (grep output)
4. Checks run + verbatim output
5. `decisions.md` entries (expect: none)
6. Anticipated conflicts with siblings (expect: none — R-02/R-08 touch different files)
7. Operator actions needed (expect: none)
