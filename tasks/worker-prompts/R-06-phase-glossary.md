# Worker prompt — R-06: settle the "Phase 7" naming collision

Copy everything below the line into the worker. **Cheap model tier.** Wave 1; R-01/R-03/R-05 run in parallel — allowlists are exclusive. R-01 also appends to `decisions.md`; expect a trivial append-side merge handled by the integrator. You are the only Wave-1 task touching the three PRDs.

---

You are a docs worker on the ForteL2 repo. Your task card is **`tasks/review-2026-08-05.md` §R-06** — read it in full; it is the spec. This prompt adds the coordination contract.

## Task in one line

"Phase 7" currently names three different things (the fault-proof learning phase, the redeploy *event*, and the mainnet-pilot program). Add a three-term glossary to the learning PRD, one roadmap row for the pilot track, retitle/reword the pilot and money-rail PRDs so every "Phase 7" is unambiguous — and change nothing else.

## The edits, precisely (card steps 1–5)

1. `tasks/prd-l2-learning-chain.md`: insert a **Phase glossary** immediately after the Terminology note (~line 11), defining exactly three terms — **Phase 7 (learning)** = fault proofs / op-challenger per the roadmap; **Redeploy gate** = the coordinated contract redeploy + network-wide wipe, an *event* not a phase, precondition for Phase 7 and the pilot; **Mainnet pilot (Phase 9 track)** = the D-0018 program in `tasks/prd-mainnet-pilot.md`.
2. Same file: one new roadmap-table row after row 9 linking the pilot PRD, citing D-0018, status "Skeleton — next plan expands".
3. `tasks/prd-mainnet-pilot.md`: retitle to *"Mainnet pilot — Phase 9 track; entered via the redeploy gate"*; in §2 row 5 replace "mainnet deploy is the Phase 7 gate" with the redeploy-gate wording from the card; add one line under §3 noting `P7-x` is a stable block identifier, not a phase number. **`P7-0`..`P7-5` IDs themselves stay byte-identical.**
4. `tasks/prd-money-rail.md`: wherever "Phase 7" means the wipe event (the replica table row and FR-4), substitute "redeploy gate (Phase 7 / mainnet-pilot entry)".
5. Append `### D-0021 — Phase-7 vocabulary settled` to `tasks/decisions.md` (template at the bottom of that file; three lines; append at the very end of §Decisions, never edit above).

## Acceptance grep (run it yourself)

`grep -n "Phase 7" tasks/*.md` — every remaining hit must be either the fault-proof learning phase or an explicit "redeploy gate (Phase 7 …)" construction. No bare "Phase 7 gate" meaning mainnet. (Hits inside `tasks/review-2026-08-05.md` and `tasks/decisions.md` are historical records — leave them; the card's append-only rule protects them.)

## Write allowlist (exclusive)

`tasks/prd-l2-learning-chain.md` (glossary + one roadmap row only) · `tasks/prd-mainnet-pilot.md` (title, §2 row 5, §3 note only) · `tasks/prd-money-rail.md` (replica row + FR-4 wording only) · `tasks/decisions.md` (append D-0021 only)

Do NOT touch: `tasks/review-2026-08-05.md`, D-0018 or any existing decisions entry, checkbox states in any PRD, `README.md`, anything outside `tasks/`. R-07 (next wave) owns Open Questions / status hygiene in these same PRDs — do not "fix" stale statuses you notice; leave them or escalate `E-R06-n`.

## Contract

- Branch `agent/r06-phase-glossary` off tag `wave8-base`. Commits: `docs(prd): …`. Squash-merged second in Wave 1 (right after R-01).
- Checks before done (paste verbatim): the acceptance grep above · `grep -c "P7-" tasks/prd-mainnet-pilot.md` unchanged vs base · `git diff --stat wave8-base..HEAD` shows exactly the four allowlisted files · `git diff wave8-base..HEAD -- tasks/decisions.md` shows additions only, at the end.
- No merging, no pushing to main, no tags.

## Handoff report — REQUIRED as your final chat message

1. Branch + base tag; `git diff --stat wave8-base..HEAD`
2. Allowlist compliance
3. Card success criteria — each: met, with evidence (grep output)
4. Checks run + verbatim output
5. `decisions.md` entries appended (expect: D-0021)
6. Anticipated conflicts with siblings (expect: `decisions.md` append vs R-01; none elsewhere)
7. Operator actions needed (expect: none)
