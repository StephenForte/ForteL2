DISPATCH · Model: strongest available · Order: single task, no dependencies — does not block and is not blocked by ForteL2 step 8b
Surface: coding agent with repo write access
Baseline: `main` at `513352a` on `StephenForte/settlementos` (CI green there — the deepmerge-ts CVE-2026-40345 override has landed, so a red Trivy run is a real finding, not the known-red baseline)
Host: any
Working directory: the operator's `settlementos` checkout · Landing: a PR against `main` on `StephenForte/settlementos`

# T8 — on-chain verification for the non-adopt deploy paths

## Identifiers — pre-assigned, do not derive

Your task id is **T8**. This overrides any "find the highest and add one" convention.

The numbering in this repo is genuinely unreliable and you will second-guess this if you look: `T1`–`T7` are all consumed (T7 completed 2026-08-07, PR #46 — see `CLAUDE.md:203`), and the parallel `J1`–`J9` series in `tasks/hosting-worker-plan.md` is fully consumed too. `T8` is free. If you believe it is taken, **stop and ask** rather than picking another.

Branch: **`fix/deploy-overlay-onchain-gate`**, cut from `main`. Do not rename it.

## Read first

- `AGENTS.md` § "Where addresses come from, and when they change" (around line 546) — the table that governs this work. Read the ForteL2 re-genesis row especially.
- `AGENTS.md` § "Invariants — do not break these" (around line 98).
- `scripts/deploy-testnet.mjs` — the file you are changing. Read the header comment block (lines 22–40) before anything else; it documents the flags and the adopt contract.
- `tests/unit/deploy-testnet-preflight.test.ts` — 54 `it()` blocks covering this script's pure helpers. This is the shape your tests must match.

Trust the repository over this brief. Line numbers and counts here are a snapshot taken at `513352a`; verify them yourself. Statements made confidently below are still snapshots.

**One correction to a claim you may encounter:** an earlier framing of this task described it as "add an `eth_getCode` check to `decideDeployMode`". That is wrong and would break a deliberate contract — see The trap.

## Why this exists — measured, not asserted

On 2026-08-22 the ForteL2 L2 (chain 852) was re-genesised, wiping all L2 state. SettlementOS's `PaymentSettlement`, three `MockERC20`s and `TokenizedMMF` were L2 contracts and did not survive.

**What the deploy script did with a pre-wipe overlay still on disk:** `decideDeployMode()` read `chain/deployments.fortel2-sepolia.json`, found a recorded `TokenizedMMF`, and returned:

```
noop — TokenizedMMF already present in overlay
Nothing to do
```

It sent no transactions. All five recorded addresses were empty code on 852 at that moment. **A confident no-op is indistinguishable from success**, and there was nothing in the output to point at the cause.

`--force-full-deploy` does not override this. That flag only short-circuits `assertAdoptableFullDeployAllowed`; it does not change the resolved mode. A `noop` stays `noop` with the flag set. The only lever today is removing the overlay from the script's view.

**The asymmetry that makes this a defect rather than a quirk:** the `--adopt` path already fetches bytecode for every registered address and aborts on empty code (`scripts/deploy-testnet.mjs`, in `main()`, the block beginning `// Bytecode verification is part of adopt preflight`). The `noop` and `mmf_addon` paths check nothing.

### Bytecode presence alone is not sufficient, and this is the part that matters most

The recovery deposit consumed deployer nonce 0 before the redeploy, so the `CREATE` sequence started one slot later than it had pre-wipe. The result is **not** "the old addresses are dead". Three of them are now **live contracts of a different type**, verified on chain 852 by `symbol()` and `decimals()`:

| Stale overlay entry | Address | What actually lives there now |
|---|---|---|
| `PaymentSettlement` | `0x9d8b8b7c476ab02306046f3da719d380fa0456aa` | `mockSGD` (6dp) |
| `mockJPY` (0dp) | `0x7d7b168cfab3dba1afc41f6160e886ffe9997e63` | `mockUSDC` (6dp) |
| `mockSGD` (6dp) | `0x0b6fa033c034d694e876b56f2dd8377a2be5691d` | `mockJPY` (0dp) |

The first fails loudly on an ABI mismatch. **The other two do not fail at all** — a stale reference reads a real ERC-20 and returns an amount wrong by a factor of 10^6.

Those three addresses return **non-empty bytecode**. A gate that only asks "is there code here?" passes them. That is why this task is not a straight copy of the adopt gate.

## What to build

Two properties must hold when the deploy script runs a **non-adopt** path (`full`, `mmf_addon`, `noop`) against a network with an existing overlay slice:

1. **Presence** — every contract address recorded in the overlay slice holds non-empty bytecode on the target chain.
2. **Identity** — for every recorded token that carries a `decimals` value in the overlay, the on-chain `decimals()` at that address equals the recorded value.

If either fails, the run **aborts** with a message naming each offending entry: its label, its address, and what was found versus what was expected. This is a settled decision — see Decisions already made.

**Where it goes.** At the call site in `main()`, in the `else` branch (the non-adopt branch), after the mode is resolved by `decideDeployMode()` and the `assertAdoptableFullDeployAllowed` guard, and **before the `--preflight-only` early return**. A dry run must report the same finding a real run would; that is the whole point, because `--preflight-only` is the tool the operator reaches for to answer exactly this question.

**Structure it the way the adopt path is structured** — that shape exists so the logic is unit-testable without a network, and your tests depend on you preserving it:

- a **pure** extractor that flattens the overlay slice into labeled entries (`{ label, address, expectedDecimals? }`),
- the **I/O** in `main()` (the `getBytecode` and `decimals()` reads),
- a **pure** evaluator that takes the fetched results and returns `{ ok: true, results }` or `{ ok: false, message, results }`.

`listAdoptContractAddresses()` reads only `.contracts` and is shape-compatible with an overlay slice, so it is reusable rather than re-implementable. `evaluateAdoptBytecode()` is the model for the evaluator, but its message hardcodes `"Adopt aborted:"` — parameterise the label rather than copying the function. Print a per-entry result table before aborting, as the adopt path does.

**Constraint on the `decimals()` read:** use a minimal inline ABI fragment, not `artifact("MockERC20")`. Compiled artifacts land in `chain/artifacts/`, which is gitignored and requires `npm run compile` first; a preflight gate must not acquire that dependency.

**No overlay, or no recorded contracts** → nothing to check, gate passes silently. Do not make a fresh full deploy noisier.

## Decisions already made — do not reopen

These were settled by the operator on 2026-08-23. If you disagree, argue it in your report; do not quietly implement something else.

- **Fail loudly, do not auto-escalate.** On finding recorded-but-absent or wrong-identity contracts, abort. Do **not** silently promote the mode to `full`. Auto-escalating turns a safety check into an unrequested deployment that spends gas and mints new addresses.
- **`--force-full-deploy` does not bypass this gate.** It does not affect resolved mode today, so wiring a bypass would be new behaviour rather than preservation. Leave it alone.
- **The operator remedy is moving the overlay aside.** Your abort message must say so concretely, naming the actual path (`chain/deployments.<network>.json`), and note that `--adopt` re-homes live contracts into a fresh overlay where an `ADOPTABLE_NETWORKS` entry exists. This is the same remedy `assertAdoptableFullDeployAllowed` already prints — match its phrasing so the script speaks with one voice.

## The trap

**`decideDeployMode()` is documented `(pure — no I/O)` and must stay that way.** Putting a network call inside it makes a pure decision function async and network-dependent, and breaks the unit tests that depend on its purity. The verification belongs at the call site, not in the decision function. If you find yourself making `decideDeployMode` async, you have taken the wrong turn.

The generalisable form: in this script, **deciding is pure and fetching is not**, and the two are deliberately separated so the deciding half is testable without a chain. Any new logic you add inherits that split.

**Second trap, from this project's own history:** a hand-rolled restatement of a check is not the check. When this defect was first predicted, it was talked away because someone tested `decideDeployMode()` against the *top level* of the overlay file — which nests everything under `networks["<network>"]` — got `full` back, and withdrew the warning as a false alarm. The operator then ran `--preflight-only` and it reported `noop`. Verify through the real entry point, not through a paraphrase of it.

## Scope

**Freely changeable:**
- `scripts/deploy-testnet.mjs`
- `tests/unit/deploy-testnet-preflight.test.ts`

**Additive only** (append; do not restructure or renumber existing content):
- `AGENTS.md` — if you add a gotcha, add it as a new bullet.
- `CLAUDE.md` — a `T8 complete` status line matching the existing `T5`/`T6`/`T7` format.

**Do not touch:**
- `AGENTS.md` § "Where addresses come from" table, the ForteL2 re-genesis row. It currently says a re-genesis makes addresses *"expire"*, which understates the hazard your own task is about — they are frequently *reassigned*. **This is a known defect already assigned elsewhere** (ForteL2 fix-list item 4, which corrects the same wording in `rail-interface.json` so both land together with consistent phrasing). Correcting it here would collide. Read the row for context; leave the text alone.
- `chain/deployments.*.json` — gitignored operator state holding live private keys.
- `ADOPTABLE_NETWORKS` — adding a ForteL2 entry is a separate decision with on-chain consequences.
- `prisma/schema.prisma` and anything under `prisma/migrations/` — no schema change is needed here.
- The `--adopt` branch of `main()` and `evaluateAdoptBytecode`'s existing behaviour, beyond parameterising the message label.

**If the task appears to require changing something outside this surface, stop and report rather than widening scope.**

## What must survive

- `decideDeployMode()` stays pure and synchronous. Its four existing tests must pass unmodified.
- The `--adopt` path's behaviour is unchanged. Its bytecode gate still aborts on empty code with an equivalent message.
- `--preflight-only` still sends **zero transactions** on every path, including your new abort path.
- `assertAdoptableFullDeployAllowed`'s existing refusals and hint text are unchanged.
- Exit behaviour on failure goes through the existing `fail()` helper — same exit code, same shape.
- A fresh full deploy with no overlay is unaffected and no noisier.

**Existing checks may not be weakened, skipped, or deleted to make this pass.** If a test legitimately changes because it encoded the very behaviour being corrected, declare it in your report with before, after, and why it is a strengthening.

## Coverage — as properties, not file targets

Add unit tests asserting these hold. All should be runnable without a network, against the pure helpers:

- An overlay recording a `TokenizedMMF` whose address has **empty code** aborts, and the message names that address. (This is the literal D-0069 case.)
- An overlay whose addresses **all hold code** but where a token's on-chain `decimals()` **differs from the recorded value** aborts, and the message names the token, the expected decimals and the found decimals. Use the real reassignment shape: recorded `mockJPY` at 0dp, on-chain 6dp.
- An overlay that is **fully consistent** passes, and the resolved mode is unchanged by the gate.
- A recorded contract with **no `decimals` recorded** (`PaymentSettlement`, `TokenizedMMF`) is presence-checked but not identity-checked, and does not spuriously fail.
- **No overlay** produces no findings and no abort.
- The abort message **names every** offending entry, not just the first — an operator diagnosing a re-genesis needs the whole list in one run.
- `--preflight-only` reaches the gate. Assert the ordering property directly rather than by inspection: the gate must be evaluated on a preflight run.

## Verification

Run all of these, and re-run them after bringing your branch onto current `main` **at the moment of hand-back** — green against a stale base says nothing about what it is merging into.

```bash
npx tsc --noEmit && npm run lint
```

```bash
npx vitest run tests/unit/deploy-testnet-preflight.test.ts
```

```bash
npm test
```

`npm test` needs a local Postgres 16 on `127.0.0.1:5432` and builds its own ephemeral DB and chains — see `AGENTS.md` § "Run & verify" for setup. Use a disposable database; never point `DATABASE_URL` at anything shared. Do not run `npm run setup` against a database you care about — it wipes it.

**Report counts before and after, for both the targeted file and the full suite.** The targeted file has **54** `it()` blocks at `513352a`. Unexplained movement in any number is itself a finding — report it rather than smoothing it over.

Do not add a live-chain integration test for this. There is no funded fixture chain in CI for `fortel2-sepolia`, and a test that skips when it cannot reach a node is green and worthless.

## Out of scope, with reasons

- **`symbol()` verification.** `decimals()` is checked because the overlay already records the expected value; the overlay does not record on-chain symbols, so a symbol check would need a new source of truth. Not worth coupling to now.
- **Verifying `PaymentSettlement`/`TokenizedMMF` identity beyond bytecode presence.** No recorded field to compare against. This is a real residual gap — a reassigned `PaymentSettlement` that happens to hold code still passes presence. State it in your report; do not try to close it here.
- **Adding a `fortel2-sepolia` entry to `ADOPTABLE_NETWORKS`.** Separate decision.
- **The `AGENTS.md` "expires" wording.** Assigned elsewhere, as above.
- **Anything in the ForteL2 repo.** This task is settlementos-only.

## If you think this is wrong

If you believe the approach is wrong — the gate location, the pure/impure split, the fail-loudly decision, the decimals-based identity check — **argue it with evidence rather than implementing it half-heartedly**. Statements in this brief were made confidently and some of them may still be wrong. A reasoned objection with a counter-proposal is a better outcome than a faithful implementation of a bad design.

## Return format — verbatim, these labels, this order

```
TASK:        T8 — on-chain verification for the non-adopt deploy paths
LINE OF WORK: fix/deploy-overlay-onchain-gate
REVIEW ARTIFACT: <PR url>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: <each command named> — pass/fail, with counts
              (run against main as of hand-back, sha: <sha>)
MIGRATION:   none | <name> — applied forward on populated data: yes/no, evidence

SHARED FILES TOUCHED: <path> — what changed, why it is additive   (or: none)
IDENTIFIERS USED:     <the pre-assigned ones actually consumed>   (or: none)
EXISTING CHECKS MODIFIED: <path> — <before> → <after>; why this strengthens
                          rather than weakens                      (or: none)
DECISIONS NEEDED:    none | <the question, and what you did in the interim>
RESIDUAL GAPS:       what this does not cover; what was verified by hand vs
                     automatically; risk stated plainly
```

Disclosure in the last three fields counts as diligence, not failure. A declared assertion change is reviewable and a silent one is how a guarantee dies; a disclosed gap gets checked and an undisclosed one becomes an incident.
