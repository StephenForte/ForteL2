DISPATCH · Model: strongest available · Order: single task, after PRs #115 and #117 are merged
Surface: coding agent with repo write access
Baseline: `main`, after #115 (rail-interface v7 + post-wipe artifacts) and #117 (D-0068) have merged — both edit the text this check reads
Host: any
Working directory: the operator's main checkout · Landing: a PR against `main` on `StephenForte/ForteL2`

# F7-12 — mechanical gate-parity check across the Phase 7 runbook locations

## Read first

- `AGENTS.md:132` — the rule this task mechanises. Read it before anything else.
- `scripts/rail-interface-check.sh` — **the model to copy.** One source of truth plus concrete field-equality assertions. Your script should read like a sibling of this one.
- `tasks/prd-phase-7-fault-proofs.md` § "Operator sequence" — the binding authority.
- `README.md` § "Network reset procedure" — the operator-facing mirror.
- `tasks/decisions.md` D-0068 Findings 6, 7 and 10 — the two defects that justify this task and the precedent that shapes it.

Trust the repository over this brief, including over statements made here confidently. This brief is a snapshot; verify line numbers and section names yourself before relying on them.

## Why this exists — measured, not asserted

Documentation drift has occurred **nine** recorded times in this project. Six were found after the fact. **Three were found by the Codex review bot rather than the author. Zero were prevented by intention.** A prose discipline was proposed as the fix after instance five, and instance six occurred in the very next commit.

**Instance nine is why this task now outranks everything else open.** D-0068 — the decision entry that exists to catalogue instances one through eight, and to argue for the task you are reading — itself declared US-071/US-072 complete in the decision log while leaving the binding PRD marked *In progress* / *Not started* and still instructing the operator to run `FORCE_SEPOLIA_REDEPLOY=1`, and README still presenting steps 3–8 as pending. **The failure mode was no longer a misinformed reader; it was an operator following the declared authority into a second network-wide wipe.** Caught by the bot, on the pull request, as P1. Its author had just spent that same commit enumerating the eight prior instances and had every reason to be watching for exactly this. That is the evidence base: discipline failed, undivided attention failed, and the only thing that has ever actually stopped drift in this repository is a check that refuses to merge.

Two fresh instances were found during the 2026-08-22 wipe, in documents that D-0067 had declared correct two commits earlier:

**Instance seven — the two runbooks number the same steps differently.**

```
                        PRD step   README step
announce                   1            2
stop writers               2            3
redeploy                   3            4
send addresses to SOS      4         (folded into 4)
bump rail-interface v7     9         (folded into 8)
```

They realign at 5 and stay aligned through 8b. A consequence sat inside the collision: README step 2 reads *"Immediately before step 3, run `scripts/phase7-preflight.sh`"*, and in README numbering step 3 is **stop writers** — placing the go/no-go gate one step earlier than the irreversible spend it exists to guard. The same sentence is correct under PRD numbering. `scripts/phase7-preflight.sh` itself prints `clear to run step 2`, so the tooling speaks PRD.

**Instance eight — the two runbooks disagree on when to bump `rail-interface.json` to v7.** PRD step 9 gates it on "after step 3 addresses are in git". README step 8 gates it on "before calling the network healthy". Different triggers, different orderings relative to 8b.

**The precedent that shapes the solution.** During the same window, `rail-interface.json` and `deployments/sepolia/deployments.json` were opened as two separate PRs. Both failed CI inside twenty seconds, in opposite directions, each naming the drifted field with both values:

```
FAIL rail-interface-check should exit 0 on repo file (ec=1)
FAIL bridge.optimismPortalProxy drift (rail=0xf8c7da6c… deploy=0xb4679b1c…)
FAIL bridge.l1StandardBridgeProxy drift (rail=0x113aad08… deploy=0x7ec222d9…)
rail-interface-check: 5 FAIL(s)
```

That is the first drift in this project's history that **could not merge**. It is the existence proof that a mechanical check works where discipline did not, and it is the pattern to reproduce.

## The locations

`AGENTS.md:132` enumerates them, and the distinction between them is the crux of this task:

| # | location | status |
|---|---|---|
| 1 | `tasks/prd-phase-7-fault-proofs.md` § Operator sequence | **binding and complete — the authority** |
| 2 | `README.md` § "Network reset procedure" | asserts parity with (1) |
| 3 | `.env.sepolia.example` | pointer only |
| 4 | `tasks/prd-l2-learning-chain.md:19` glossary | self-declared **summary**, not a closed list |
| 5 | `tasks/prd-l2-learning-chain.md:51` Phase 7 row | self-declared **summary**, not a closed list |

**Locations 3, 4 and 5 are pointers and summaries.** A check that demands they enumerate every gate will fail permanently and be disabled, which is worse than no check. For those three, assert **non-contradiction** — they must not state something the authority contradicts — never completeness.

## What to build

A check that fails CI when the runbook locations disagree with each other about the Phase 7 operator sequence.

The property that must hold: **it is not possible to merge a change that leaves two locations asserting different facts about the same gate.**

Follow the `rail-interface-check.sh` shape — declare the canonical facts in one machine-readable file, then assert each location agrees with it:

1. **A declared-facts file.** Suggested `tasks/phase7-gates.json`; name it as you see fit. It holds, at minimum:
   - the step ↔ action mapping under **both** numbering schemes, so the PRD/README collision becomes declared and locked rather than accidental
   - the notice timestamp and the ≥24h gate timestamp
   - the trigger condition for the v7 bump
2. **`scripts/phase7-gate-parity.sh`** asserting each location agrees. Completeness for locations 1 and 2; non-contradiction only for 3, 4 and 5.
3. **Coverage in `scripts/test-helpers.sh`**, following the existing conventions there.
4. **Wired into the same CI job** that runs `rail-interface-check.sh`, so it gates merges.

Latitude on everything else — file format, assertion style, how you extract text — is yours. Where you can assert something concrete instead of something fuzzy, do.

## The trap

**A gate check that cannot run must report failure, not success.**

This exact defect was shipped in this repo six weeks of work ago and caught only during falsification: the first draft of `scripts/phase7-preflight.sh` printed `ALL CHECKS PASSED` while one of its checks had silently failed to execute. On a go/no-go gate that is the worst possible failure — it reports safety it did not establish.

The same entry records the mechanism: the check had hard-coded a **line range**, and F7-11 had shifted the target by roughly 136 lines. That is the fourth recorded instance of the extracted-harness trap in this project. **Anchor every extraction on content — section headings, table markers, regexes — never on line numbers**, including the line numbers quoted in this brief. If your script cannot locate a section it is looking for, it must exit non-zero with a message naming what it could not find.

Falsify your own check before handing it back, in **both** directions:
- introduce a real disagreement between two locations → it must FAIL and name both values
- break an extraction anchor → it must FAIL, not pass

A check believed on its green is only as good as its red. A bogus red costs the same as a bogus green and is more likely to be acted on.

## Scope

**Freely changeable**
- `scripts/phase7-gate-parity.sh` (new)
- `tasks/phase7-gates.json` (new, or whatever you name the declared-facts file)
- the CI workflow file, to add the new check to the existing job

**Additive only**
- `scripts/test-helpers.sh` — append your cases; do not restructure or renumber existing ones. The suite's PASS count is a tracked baseline and other work appends here.

**Do not touch**
- `tasks/decisions.md` — planner-owned. The decision id for this work is allocated by the planner, not by you. Do not add an entry and do not allocate an id.
- `tasks/review-*.md` and `tasks/worker-prompts/` — **these are dated historical records.** `AGENTS.md:132` is explicit that they must not be edited to match current state. They will contain stale gate text and stale addresses **by design**; your check must exclude them or it will fail forever on history.
- `scripts/02-deploy-contracts-sepolia.sh` and `scripts/phase7-preflight.sh` — live deploy path, mid-Phase-7. Not this task's surface.
- `deployments/rail-interface.json` and `deployments/sepolia/*` — settled by #115.
- **The prose of the five runbook locations themselves.** See the operator decision below. Your task is to build the check and declare the current facts, not to rewrite the runbooks to satisfy it.

If the task appears to require changing something outside the permitted surface, **stop and report** rather than widening scope.

## The operator decision you must not make

The PRD/README step-number collision can be resolved two ways: **renumber README to match the binding PRD**, or **declare the mapping and check it**. This brief instructs the second, because the first is a substantive prose change to an operator-facing document during a live phase, and because the PRD is structurally different from the README (it carries steps 0, 0b and 4 that README folds or omits).

**Whether README should ultimately be renumbered is an operator decision and is not yours to make.** Build the declared-mapping check. If while working you conclude renumbering is the only way to make the check meaningful, **stop and report that as a decision needed** rather than renumbering.

## What must survive

- Existing checks may not be weakened, skipped, or deleted to make this pass. If your check disagrees with a runbook, the finding is real — report it; do not soften the check.
- `scripts/test-helpers.sh` baseline is **189 PASS** at the time of writing. Your additions raise it. Any *fall* is a finding.
- `rail-interface-check.sh` must keep passing unchanged.
- Locations 3, 4 and 5 keep their right to be summaries.

## Verification

Run all of these against `main` **as of hand-back**, not the state you started from:

```bash
bash scripts/phase7-gate-parity.sh; echo "exit=$?"
```

```bash
bash scripts/rail-interface-check.sh; echo "exit=$?"
```

```bash
bash scripts/test-helpers.sh 2>&1 | tail -20
```

Report the PASS count and state the delta from 189 explicitly. Unexplained movement in either direction is itself a finding.

Then both falsification runs from **The trap**, with their actual output pasted into your report.

## Out of scope, with reasons

- **F7-N open/closed status parity** — checking that every `F7-N` status agrees across locations is valuable but the status vocabulary is free prose, so it is not mechanically tractable in this pass. Deferred deliberately.
- **Renumbering README** — operator decision, see above.
- **`test-helpers.sh` coverage for `scripts/phase7-preflight.sh`** — a known gap recorded in D-0067 Finding 8, but a separate task.
- **Fixing the mode-644 and README-command defects on `phase7-preflight.sh`** (D-0068 Finding 1) — real, but a different surface.

## If you think this is wrong

If you believe the declared-facts approach is the wrong shape, or that the check cannot be made meaningful within this scope, **argue it with evidence rather than implementing it half-heartedly**. This brief is confident in places it has not earned. A worker who can show the approach fails is more useful than one who ships something that passes vacuously — and this project's whole reason for wanting F7-12 is that a check nobody trusts is worse than none.

## Return format — verbatim, these labels, this order

```
TASK:        F7-12 — mechanical gate-parity check across the Phase 7 runbook locations
LINE OF WORK: agent/f7-12-gate-parity
REVIEW ARTIFACT: <PR url>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: <each check named> — pass/fail, with counts
              (run against main as of hand-back)
              test-helpers.sh: <N> PASS (baseline 189, delta <+N>)
              falsification — real disagreement: <output>
              falsification — broken anchor:     <output>
MIGRATION:   none

SHARED FILES TOUCHED: <path> — what changed, why it is additive   (or: none)
IDENTIFIERS USED:     F7-12 only; no decision id allocated
EXISTING CHECKS MODIFIED: <path> — <before> → <after>; why this strengthens
                          rather than weakens                      (or: none)
DECISIONS NEEDED:    none | <the question, and what you did in the interim>
RESIDUAL GAPS:       which locations are checked for completeness vs only
                     non-contradiction; what you verified by hand vs
                     automatically; risk stated plainly
```

Disclosure in the last three fields counts as diligence, not failure. A declared assertion change is reviewable; a silent one is how a guarantee dies. A disclosed gap gets checked; an undisclosed one becomes an incident.
