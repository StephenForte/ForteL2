> **CORRECTION (2026-08-23, planner) — this brief was dispatched containing a false claim.**
> The section below headed *"A correction to the record you will otherwise trip over"* asserts that
> `README.md` has never described what happens to addresses on re-genesis, and that D-0071 Finding 4
> was wrong to say the README half landed in #120. **Both assertions are false. D-0071 was correct.**
> README carries the canonical treatment — *"Expired does not mean empty… revalidate code, type and
> decimals rather than assuming it is dead"* — and item 4 spanned **four** locations, not three.
> The claim came from a concept-search piped through `cut -c1-200`, which hid the relevant text.
>
> Consequence: the worker was explicitly told not to seek a README precedent, so it invented wording
> instead of matching the established phrasing, and the new prose broke the parallel list in
> `rail-interface.json` and orphaned a clause in `AGENTS.md`. Both were corrected by the planner
> directly on the branches (ForteL2#123, settlementos#92); the worker's regression test was correct
> and untouched. Full write-up: **D-0073 Findings 4 and 5**.
>
> The brief is committed **as dispatched**, not retroactively fixed, so the record shows what the
> worker actually received.

DISPATCH · Model: mid-tier (prose accuracy + one additive test; no design latitude needed) · Order: single task, no dependencies — settlementos#91 merged 2026-08-23T04:50Z, which was the only blocker
Surface: coding agent with repo write access
Baseline: ForteL2 `main` at `848237b` · settlementos `main` at `d3f1092`
Host: any
Working directory: the operator's `ForteL2` and `settlementos` checkouts · Landing: **two** PRs — one per repository, see below

# R-11 / T9 — a re-genesis *reassigns* addresses, it does not merely expire them

This is one correction applied in three places across two repositories, plus one additive regression test. Two ids, two branches, two PRs.

## Identifiers — pre-assigned, do not derive

| Repo | Task id | Branch (cut from `main`) | PR contents |
|---|---|---|---|
| `StephenForte/ForteL2` | **R-11** | `docs/r-11-reset-policy-reassigned` | `deployments/rail-interface.json`, `tasks/coordination-settlementos.md` |
| `StephenForte/settlementos` | **T9** | `fix/t9-reassignment-wording-and-adopt-guard` | `AGENTS.md`, `tests/unit/deploy-testnet-preflight.test.ts` |

Both ids are free as of `848237b` / `d3f1092`. **They override any "find the highest and add one" convention** — and in `settlementos` that convention is actively wrong: `T1`–`T8` are consumed and the worker-prompts file stops at `T6`, understating the high-water mark. If you believe either id is taken, **stop and ask**.

**Do not bump `rail-interface.json`'s `version`.** It stays at `7`. This is a settled operator decision, not an oversight — see Decisions already made.

## Read first

- `tasks/decisions.md` **D-0069 Finding 2** (ForteL2) — the measured event this correction exists to describe. Read it before writing a single word of the new prose.
- `tasks/decisions.md` **D-0071 Finding 4** — the no-version-bump decision and its reasoning. **Note: this entry contains one wrong claim; see the correction below.**
- `tasks/decisions.md` **D-0072** — the T8 review context and why identity ≠ presence.
- `deployments/rail-interface.json` `$schema_note` — the rule governing when `version` bumps.
- `AGENTS.md` § "Where addresses come from, and when they change" (settlementos) — the table you are editing.

Trust the repositories over this brief. Line numbers are a snapshot; verify them.

### A correction to the record you will otherwise trip over

D-0071 Finding 4 states *"The README half of this correction already landed in #120."* **That is wrong.** PR #120's title reads "expired addresses are reassigned, not empty", but its README hunk changed only the step-10 status banner and the outstanding-work list — no address-fate wording. `README.md` has never contained a statement about what happens to addresses on re-genesis, so there is no README half, landed or otherwise.

Consequence for you: **do not go looking for a README precedent to match.** There isn't one. Adding a README sentence is explicitly out of scope (see below) — the correction targets the three locations that already make the claim.

## Why this exists — measured, not asserted

On 2026-08-22 chain 852 was re-genesised. The recovery deposit consumed deployer nonce 0 before the redeploy, so the `CREATE` sequence started one slot later than pre-wipe. **The old addresses were not emptied. Three of them are now live contracts of a different type**, verified on 852 by `symbol()` and `decimals()`:

| Old entry | Address | Now holds |
|---|---|---|
| `PaymentSettlement` | `0x9d8b8b7c476ab02306046f3da719d380fa0456aa` | `mockSGD` (6dp) |
| `mockJPY` (0dp) | `0x7d7b168cfab3dba1afc41f6160e886ffe9997e63` | `mockUSDC` (6dp) |
| `mockSGD` (6dp) | `0x0b6fa033c034d694e876b56f2dd8377a2be5691d` | `mockJPY` (0dp) |

The first fails loudly on an ABI mismatch. **The other two do not fail at all** — a stale reference reads a real ERC-20 and returns an amount wrong by a factor of 10^6.

"Expires" tells a consumer their cached address is dead, which implies their next call errors. The truth is that their next call may **succeed and lie**. That is the gap the wording has to close.

## The three locations

All three currently make the "expires" claim. None have been corrected.

1. **`deployments/rail-interface.json`** → `networks["fortel2-sepolia"].resetPolicy`, the sentence *"every ForteL2 address held before this date is expired"*. **This is the machine-readable copy SettlementOS consumes** — highest consequence of the three.
2. **`tasks/coordination-settlementos.md`** (~line 32), the Phase 7 redeploy row: *"re-genesis expires every ForteL2 address they hold and breaks their live explorer address book (D-0028)"*. This is the SOS-facing coordination contract.
3. **`AGENTS.md`** (settlementos, ~line 554), the ForteL2 re-genesis row: *"Every ForteL2 contract address above expires, including the backed-up overlay's contract entries."*

## What to write

The property the new prose must carry, in all three:

- An address held before a re-genesis is **not reliably dead**. It may be empty, or it may hold a **different live contract** at the same slot, because the deployer's nonce sequence can shift.
- A consumer that caches by address and does not re-verify identity can therefore get a **successful call with wrong data**, not an error. Say this plainly — it is the whole point.
- The remedy is re-verifying identity after a re-genesis, not merely refreshing on failure.

**Do not simply swap the word "expires" for "is reassigned".** A reader needs to know the failure is silent; a one-word substitution does not convey that. Keep each location's existing voice, length budget and surrounding facts intact — these are dense operator documents, not prose to rewrite.

**Match the concept, not the string.** The three locations word the claim differently and one of them ("breaks their live explorer address book") carries a second fact you must preserve. Search by concept before you edit and after: `expire`, `dead`, `stale`, `no longer valid`, `unreachable`. If you find a fourth location this brief does not name, **that is a finding — report it**; do not silently expand or silently skip it.

### One thing the wording must now also cover

The T8 gate that shipped in settlementos#91 verifies every overlay-recorded token's on-chain `decimals()` against the overlay. It catches the two reassignments above. **It does not catch a reassignment between two tokens with equal decimals** — and in the real deploy `mockUSDC` and `mockSGD` are *both* 6dp, so a swap between those two would pass the gate clean. Verified during the #91 review by direct probe.

The `AGENTS.md` row is the right home for that caveat, since it sits next to the gate it qualifies. One clause is enough; do not write a paragraph. The other two locations should not carry SettlementOS-internal gate detail.

## The regression test (T9, settlementos)

`listAdoptContractAddresses()` now emits `expectedDecimals` for every token, on the `--adopt` path as well as the overlay path. The adopt call site in `main()` is safe **only** because it destructures the field away:

```js
for (const { label, address } of toCheck) {      // ← expectedDecimals dropped here
  withCode.push({ label, address, code });
}
```

Rewrite that as the spread form a future edit naturally reaches for, and `--adopt` aborts on every token. Measured during review:

```
Adopt aborted: one or more recorded contracts do not match on-chain state on base-sepolia.
  mockUSDC 0x2066738d…d6aa — decimals unreadable, overlay recorded 6
```

That would break the path whose entire job is recovering a network whose overlay was lost. **Current behaviour is correct — nothing encodes why.**

Add a test asserting `evaluateAdoptBytecode` returns `ok: true` for the real adopt call-site shape (entries carrying `label`/`address`/`code` and **no** `expectedDecimals`), with a comment naming what it protects. Purely additive; changes no behaviour. A short comment on the destructure itself is welcome but optional.

## Decisions already made — do not reopen

- **No version bump.** `rail-interface.json` `version` stays `7`. The reset *policy* has not changed — only its description became accurate — and a v8 hours after v7 would signal an event to SettlementOS that did not occur, which is the false-event failure the `$schema_note` exists to prevent. Operator decision, 2026-08-23 (D-0071 Finding 4).
- **Fix the wording, do not extend the gate.** Closing the equal-decimals hole would need a `symbol()` check and a new source of truth for expected symbols. Deliberately not in scope.

## Scope

**Freely changeable:**
- ForteL2: `deployments/rail-interface.json` (the `resetPolicy` string only), `tasks/coordination-settlementos.md`
- settlementos: `AGENTS.md` (the re-genesis row, plus the adjacent gate caveat), `tests/unit/deploy-testnet-preflight.test.ts`

**Do not touch:**
- `rail-interface.json` `version`, `$schema_note`, `networkId` values, any address or URL field. You are editing one prose string inside one network's object.
- `networks["fortel2-local"].resetPolicy` — different network, different wording, no expiry claim. Out of scope; flag it if you think it needs the same treatment.
- `scripts/deploy-testnet.mjs` — the test is additive; the source is already correct. Changing it turns a docs task into a code task with no review budget for it.
- `tasks/decisions.md` in either repo — planner-owned. Report findings; do not write entries.
- `README.md` in ForteL2 — see the correction above; there is nothing there to fix.
- Anything under `scripts/` in ForteL2.

**If the task appears to require changing something outside this surface, stop and report rather than widening scope.**

## What must survive

- `rail-interface.json` stays valid JSON and `version` stays `7`.
- Every fact currently in each of the three sentences survives the rewrite — the explorer-address-book consequence, the overlay-backup consequence, the D-0028 citation. This is a correction, not a replacement.
- The `--adopt` path's runtime behaviour is unchanged. Your test asserts current behaviour; it must not require a source change to pass.
- Existing checks may not be weakened, skipped, or deleted. If a test legitimately changes, declare it with before/after and why it strengthens.

## Verification

**ForteL2 (R-11)** — run all three; the first two must be re-run because they parse the file you edited:

```bash
./scripts/rail-interface-check.sh
```

```bash
./scripts/phase7-gate-parity.sh
```

```bash
./scripts/test-helpers.sh
```

Expected at baseline: `test-helpers.sh` **194 PASS**, `phase7-gate-parity.sh` **60 PASS parity**, `rail-interface-check.sh` **20**. Neither gate asserts `resetPolicy` content, so these should be unmoved — **any movement is a finding**, not something to accept.

**settlementos (T9):**

```bash
npx tsc --noEmit && npm run lint
```

```bash
npx vitest run tests/unit/deploy-testnet-preflight.test.ts
```

```bash
npm test
```

Baselines at `d3f1092`, measured independently during the #91 review: targeted file **67 tests**, full suite **73 files / 652 tests**. Expect **+1** from your regression test in both. `npm test` needs a local Postgres 16 on `127.0.0.1:5432` and provisions its own ephemeral database — do not point `DATABASE_URL` at anything shared, and do not run `npm run setup`.

Re-run everything after bringing both branches onto current `main` at hand-back.

## Out of scope, with reasons

- **A README sentence about address fate.** README never made this claim, so there is nothing to correct; adding one is new documentation, and drift risk grows with each location that repeats a fact.
- **`symbol()` verification / closing the equal-decimals hole.** Needs a new source of truth. Recorded as a follow-up.
- **`fortel2-local` reset policy.** No expiry claim to correct.
- **Any change to `deploy-testnet.mjs`.** The source is correct; only the guarantee is unencoded.

## If you think this is wrong

If you believe the framing is wrong — that "expires" was adequate, that the caveat belongs elsewhere, that the regression test guards nothing real — **argue it with evidence rather than implementing it half-heartedly**. Statements here were made confidently and some may still be wrong; one demonstrably was (the README claim), which is why this section exists.

## Return format — verbatim, these labels, this order

Return **one block per repository.**

```
TASK:        R-11 | T9 — <one line>
LINE OF WORK: <branch as assigned>
REVIEW ARTIFACT: <PR url>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: <each command named> — pass/fail, with counts
              (run against <repo> main as of hand-back, sha: <sha>)
MIGRATION:   none | <name> — applied forward on populated data: yes/no, evidence

SHARED FILES TOUCHED: <path> — what changed, why it is additive   (or: none)
IDENTIFIERS USED:     <the pre-assigned ones actually consumed>   (or: none)
EXISTING CHECKS MODIFIED: <path> — <before> → <after>; why this strengthens
                          rather than weakens                      (or: none)
DECISIONS NEEDED:    none | <the question, and what you did in the interim>
RESIDUAL GAPS:       what this does not cover; what was verified by hand vs
                     automatically; risk stated plainly
```

Additionally, state explicitly: **the concept-search you ran, and every location it returned** — including ones you did not edit and why. A fourth location found and reported is worth more than three edited silently.

Disclosure in the last three fields counts as diligence, not failure.
