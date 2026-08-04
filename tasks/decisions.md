# Shared decisions log — parallel integration work

**Protocol (read before writing):**
- **Append-only.** Never edit or delete a prior entry; supersede it with a new entry that references the old ID.
- **ID format:** `D-<task>-<n>` (e.g. `D-T2-1`). Pre-seeded plan decisions use `D-000x`.
- One entry per decision: context → decision → consequence. Three lines is plenty.
- **Escalations** (things outside your write allowlist that you believe need changing) go in §Escalations with the same ID scheme (`E-<task>-<n>`). Do not implement them.
- Workers read this file at task start and before handoff; the integrator reads it at every merge.

---

## Decisions

### D-0001 — Base SHA for Wave 1
- **Context:** main had uncommitted changes (README, .env.sepolia.example, dev-sleep.sh) at planning time.
- **Decision:** Operator commits them first (T0); Wave 1 branches from the resulting SHA.
- **BASE_SHA:** tag `wave1-base` — resolve with `git rev-parse wave1-base^{commit}`. (Re-pinned 2026-08-04 by D-0007; previous value `d9f3c5ff5b0c3f3e07b4462aaca4e419193e757e` was mid-PR-#58 and predates this file existing on main.)

### D-0002 — Branching model
- **Context:** batch-merging ~3 agent branches caused rebase churn.
- **Decision:** Trunk-based; branches `agent/<task>-<slug>` off pinned BASE_SHA; squash-merge one at a time in plan §6 order; workers never merge.
- **Consequence:** at most one trivial rebase per branch, resolved in merge order.

### D-0003 — Block viewer location (PRD open question resolved)
- **Context:** PRD left "extend `viewer/` vs sibling static app" open.
- **Decision:** Sibling app under `blocks/` with its own vendored ethers copy and serve script. Rationale: disjoint file ownership for parallel work; `viewer/` stays the Phase 1c pipeline viewer untouched.
- **Consequence:** T3 owns `blocks/` exclusively; pattern-copies from `viewer/`/`dapp/` are copies, not shared edits.

### D-0004 — Phase 6 derivation gets its own PRD
- **Context:** learning-chain PRD says expand US-060–062 in place or spin out a PRD before coding.
- **Decision:** Spin out — T2's spike produces `tasks/prd-phase-6-derivation.md`; T4 executes against it.
- **Consequence:** T4 is not launched until T2 merges.

### D-0005 — MR-3/4/5 are trigger-gated, not planned
- **Triggers:** MR-3 when SOS asks for fee abstraction; MR-4 when SOS needs canonical USDC; MR-5 after SOS runs stable on 852. Until a trigger fires these get no worker.

### D-0006 — Verifier module shape (placeholder)
- **Status:** OPEN — to be closed by T2 spike (`D-T2-x`): new `derivation/` module (default assumption) vs extending `batcher/`. T4 ownership follows the answer.

---

### D-0007 — BASE_SHA re-pin to tag `wave1-base`
- **Context:** The first pinned BASE_SHA (`d9f3c5f`) was the mid-PR-#58 commit: it lacked `tasks/decisions.md` (added in `8763f44`) and the plan/worker-prompt files (never committed), and main had moved (PR #58 merge `671a39f` + CI-workflow commits `be81133`/`e402de3`/`3dd5db8`/`386ffa1`).
- **Decision:** Base = the commit that adds the plan + worker prompts on top of merged main, tagged **`wave1-base`** (a tag, because this file cannot contain its own commit's hash). D-0001's value field now points at the tag.
- **Consequence:** All Wave 1 workers branch from `wave1-base` and diff against it in handoffs. Any future re-pin gets a new decision entry + a new tag (`wave2-base`, …), never a moved tag.

---

## Escalations

*(none yet)*

---

## Template

```
### D-<task>-<n> — <short title>
- **Context:** <one line>
- **Decision:** <one line>
- **Consequence:** <what other tasks must now assume>
```
