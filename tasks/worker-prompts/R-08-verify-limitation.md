# Worker prompt — R-08: document the counterparty-verification limitation

Copy everything below the line into the worker. **Cheap model tier** (bump to mid if the prose bar isn't met — see acceptance). Wave 2; R-02/R-07 run in parallel — allowlists are exclusive. You own `derivation/README.md` and `tasks/prd-mainnet-pilot.md` this wave.

---

You are a docs worker on the ForteL2 repo. Your task card is **`tasks/review-2026-08-05.md` §R-08** — read it in full; it is the spec. This prompt adds the coordination contract plus one integrator-added one-liner inherited from Wave 1. **No code changes.**

## Task in one line

D-0018 promotes the `derivation/` verifier to "the counterparty audit tool," but as built it verifies the operator's chain *against the operator's own node* — write that limitation down in `derivation/README.md` before it gets promised to a pilot customer, and link it from the pilot PRD's P7-2 block.

## What the limitation section must say (card step 1, in your own words)

- `cmd/verify` requires `-ref-l2` / `-ref-node` — the operator's own stack — as the comparison oracle.
- Mid-chain windows additionally require an anchor datadir copied from the operator's **stopped** node (D-R2-2).
- Consequence, in one sentence a non-engineer can follow: a third party running this today is checking the operator's chain against the operator's own answers, which proves consistency, not honesty.
- What independent verification would need: a self-derived state root from genesis, or an anchor sourced from the counterparty's own replica rather than the operator's datadir.

## Integrator-added item (E-R06-1, from merged R-06's handoff)

While you are in `tasks/prd-mainnet-pilot.md`: the P7-1 checkbox line still reads "(Phase 7 gate)" for the mainnet deploy. Reword to "(redeploy gate)" per D-0021 vocabulary. Do not flip the checkbox; do not touch any other line of P7-1. This is a sanctioned one-line extension of the card's scope — cite it in your handoff.

## Write allowlist (exclusive)

`derivation/README.md` (new `## Limitations — independent verification` section; plus nothing else in that file except, if present, adjusting a table-of-contents line) · `tasks/prd-mainnet-pilot.md` (P7-2 sub-bullet + the E-R06-1 one-liner in P7-1 only)

Do NOT touch: any `.go` file, `tasks/decisions.md` (D-0018 is append-only history; if you believe a new decision is warranted, propose it in the handoff as `E-R08-<n>` — do not write it), the other PRDs (R-07 owns them this wave).

## Contract

- Branch `agent/r08-verify-limitation` off tag `wave9-base`. Commits: `docs(derivation): …`. Squash-merged last in Wave 2.
- Checks before done (paste verbatim): `cd derivation && go test ./...` still passes (proves no code touched) · `git diff --stat wave9-base..HEAD` → exactly two files · `grep -n "ref-l2\|ref-node\|anchor" derivation/README.md` showing the new section names both dependencies · `grep -n "redeploy gate" tasks/prd-mainnet-pilot.md` showing P7-1 reworded and P7-2 linking the README section.
- No merging, no pushing to main, no tags.

## Handoff report — REQUIRED as your final chat message

1. Branch + base tag; `git diff --stat wave9-base..HEAD`
2. Allowlist compliance
3. Card success criteria + E-R06-1 item — each: met, with evidence
4. Checks run + verbatim output (including the `go test` pass)
5. `decisions.md` entries (expect: none; E-R08-n proposals in-handoff only)
6. Anticipated conflicts with siblings (expect: none — exclusive files this wave)
7. Operator actions needed (expect: none)
