# Worker prompt — F7-4: harden the preflight assertions and fix a stale citation (US-073)

Copy everything below the line into the worker. **Mid model tier** — small and mostly test work, but two of the four items are assertions that must *fail* when the property is broken, and the third changes a fail-closed path. Wave 1 this round; standalone, no parallel siblings.

---

DISPATCH · Model: mid · Order: wave 1, standalone (no siblings, no blockers)
Baseline: branch `agent/f7-4-preflight-assertion-hardening` off tag `wave19-base`
Host: any. **No `.env.sepolia`, no Sepolia keys, no `op-challenger`, and nothing here signs or spends.** No network is required for any part of this task.
Working directory: main checkout (single delegate this round)
Landing: PR into `main`, squash-merge after review. No ordering constraint against US-071/072 — this is cleanup on top of merged F7-3, not a gate.

---

You are a worker on the ForteL2 repo (`github.com/StephenForte/ForteL2`). Phase 7 context: `tasks/prd-phase-7-fault-proofs.md`, **US-073**. F7-3 landed in #93 (`2936c97`) and works. Reviewing it turned up four small things, none of which block anything. This task closes all four.

## Read before starting (governing material — trust the repository over this brief)

- `tasks/decisions.md` **D-0055** (why the preflight reads `gameArgs`), **D-0056** (why the prestate story is still open), **D-0057** (what F7-5 will do, and why it is not this task).
- `scripts/09-start-challenger-sepolia.sh` — `run_preflight()` and the `CHALLENGER_SKIP_PREFLIGHT` branch immediately below it.
- `scripts/test-helpers.sh` — the F7-3 block at the end is the thing you are extending; match its style.
- `scripts/lib.sh` — **read-only, never edit.**

## Pre-assigned identifiers — use these exactly

- Task id **F7-4**. Decisions **D-0055**, **D-0056**, **D-0057** are all written; do not add or renumber decisions.
- Branch **`agent/f7-4-preflight-assertion-hardening`**, cut from tag **`wave19-base`**.
- Escalation ids if you need them: **E-F7-4-1**, **E-F7-4-2**.

These override any "find the highest and add one" convention. If one looks wrong, stop and ask.

## The four items

### 1. The `CHALLENGER_SKIP_PREFLIGHT` assertion is a string match, not a structural one

The F7-3 block ends with `grep -q 'CHALLENGER_SKIP_PREFLIGHT' "$CHALLENGER_START"`. That string now appears **five** times in the script (it was three before F7-3 — the new error messages each mention the bypass). Four of those five are inside error text. Consequence, measured: **deleting the entire bypass block leaves the harness green.**

Reproduce it before you fix it, so you know your replacement is doing something:

```
perl -0pi -e 's{if \[\[ "\$\{CHALLENGER_SKIP_PREFLIGHT:-\}" == "1" \]\]; then\n.*?\nelse\n  run_preflight\nfi\n}{run_preflight\n}s' scripts/09-start-challenger-sepolia.sh
bash scripts/test-helpers.sh   # currently: still passes. It must not.
```

Replace the bare grep with a structural check that the **bypass branch itself** exists and still guards the call: a conditional on `CHALLENGER_SKIP_PREFLIGHT` whose non-bypass arm is what invokes `run_preflight`, and which still emits a warning on the bypass path. `awk` over the script text is the right tool, as elsewhere in this file. Do not assert the exact warning wording.

### 2. The `104` bound is not asserted at all

`run_preflight` refuses a `gameArgs` blob shorter than 104 hex chars (32-byte prestate + 20-byte vm). Relaxing that to `< 0` leaves `test-helpers.sh` green today. Add an assertion that pins the bound. Assert the **property** — that the length gate exists inside the non-empty-`args` branch and rejects anything under the 104-hex minimum — rather than grepping for the literal `104` in isolation, which would pass against a gate that had been moved somewhere harmless.

### 3. The bypass WARN still cites D-0052

Line ~384: `WARN: CHALLENGER_SKIP_PREFLIGHT=1 — skipping gameImpls/vm/absolutePrestate checks (D-0052).` D-0052 Finding 2 was withdrawn by D-0055. Change the citation to **D-0055**. Text only — the branch, the exit behaviour and the `>&2` redirection all stay exactly as they are. (F7-3 was told to leave this line untouched, which was the right call at the time; the instruction was self-contradictory and that was the planner's error, not the worker's.)

### 4. A factory with no `gameArgs` function dies with a raw `cast` error

`run_preflight` handles an **empty** `gameArgs` by falling back to the implementation getters — correct, and reachable, because `DisputeGameFactory.create()` v1.6.1 still has a legacy `implArgs.length == 0` branch. But a factory *predating the `gameArgs` function entirely* makes `cast call` revert, and `set -euo pipefail` then kills the script with foundry's error and no context. It fails closed, which is right; it just does not say why.

Make that state named. If the `gameArgs` call fails, exit 1 with a message that says the call failed, names the factory and the type number, and gives the two candidate causes — a factory that predates `gameArgs`, or an RPC failure. **Do not fall back to the implementation getters on a failed call.** An RPC blip must not be silently reinterpreted as "this is an old factory"; the two are indistinguishable from here, and guessing is how D-0055 happened.

Note the shell hazard: under `set -e`, `args="$(cast call …)"` aborts before you can inspect the status. You need a form that captures the failure without the assignment killing the script, and it must not accidentally swallow a *successful* empty (`0x`) result, which is legitimate data and must still reach the fallback. Prove both cases still behave — see Verification.

## Scope

**Freely changeable:** `scripts/09-start-challenger-sepolia.sh` — items 3 and 4 only. Items 1 and 2 must not require changing it.

**Additive only:** `scripts/test-helpers.sh`.

**Do not touch:** `scripts/lib.sh`; `tasks/decisions.md`; `README.md` (the Preflight paragraph is correct as merged — item 4 does not change what it describes); `.env.sepolia.example`; `scripts/06-start-proposer-sepolia.sh`, `status.sh`, `stop-all-sepolia.sh`; anything under `deployments/`; CI config.

If the task appears to require changing something outside that surface, **stop and report rather than widening scope.**

## What must survive this change

- Everything F7-3 established: `gameArgs` read before the implementation getters; the four distinct failure messages; the `≥104` bound including its odd-length rejection; the empty-`gameArgs` fallback to `vm()` / `absolutePrestate()`; the `gameImpls` zero-address refusal; the early `return 0` skip for unmapped trace types (`alphabet`, `fast`, `zk` must still start).
- Every gate from F7-2 / F7-2b / F7-2c: key/address derivation match, the three `wait_for_rpc` calls, the balance check, the prestate `-f` **and** `-r` check, absolute-path canonicalization, `--l1-beacon`, the Cannon rollup/genesis flags, the `cannon` / `cannon-kona` pre-image-server refusal, the `super-cannon-kona` refusal.
- The daemon still receives its key via `OP_CHALLENGER_PRIVATE_KEY`, never on argv; RPC URLs still pass through `redact_rpc_url`; no secret in any output.
- `scripts/test-helpers.sh` reports **108 PASS** and `All script helper tests passed.` at `wave19-base`. Existing assertions may not be weakened, skipped, or deleted. The F7-3 block may be **edited in place** for items 1 and 2 — that is the one exception, and it is a strengthening; say exactly what you changed and why.

## Verification (run against `wave19-base` at hand-back, restated after any rebase)

```
bash -n scripts/09-start-challenger-sepolia.sh
shellcheck scripts/09-start-challenger-sepolia.sh   # if available; say so if not
bash scripts/test-helpers.sh
```

Expected: `bash -n` clean; `test-helpers.sh` ends `All script helper tests passed.` with a PASS count **above 108** (state the number).

**Mutation-test your own assertions. This is the point of the task, not a formality.** For each of the four items, break the property in the script, confirm `test-helpers.sh` goes **red**, then restore. At minimum:

- delete the `CHALLENGER_SKIP_PREFLIGHT` bypass block (the `perl` one-liner above) → must go red
- relax `< 104` to `< 0` → must go red
- revert the WARN citation to D-0052 → must go red
- remove the failed-`gameArgs` refusal → must go red

Paste the four before/after results. An assertion you could not make fail is an assertion that does not work; say so rather than shipping it.

**Also exercise `run_preflight` directly**, since the gate cannot reach a live factory. Lift `is_zero_hex`, `game_impls_type_number` and `run_preflight` verbatim into a scratch harness with a stubbed `cast`, and confirm at least these five, reporting the observed exit code for each:

| Case | Expected |
| --- | --- |
| `gameArgs` returns a valid ≥104-hex blob | pass, `source=gameArgs(N)` |
| `gameArgs` returns exactly `0x` | pass via implementation-getter fallback |
| `gameArgs` call **fails** (stub returns non-zero) | exit 1, **your new named message**, no fallback attempted |
| unmapped trace type (`alphabet`) | return 0, no `cast` call reached |
| `gameArgs` blob of 102 hex chars | exit 1, "too short" |

The third row is the new behaviour and the second row is the regression risk beside it — a fix for one that breaks the other is the failure mode here. Delete the harness afterwards; it is an instrument, not a deliverable.

## Out of scope

- **The prestate-commitment check (D-0057).** That is F7-5 and it is deliberately not written yet — it depends on D-0056 being resolved. Do not add `cannon witness`, do not read `CHALLENGER_PRESTATE`'s contents, do not add any flag or variable for it.
- Anything about the wipe or redeploy (US-071 / US-072) — not authorized.
- The intent's `faultGameAbsolutePrestate` (D-0056). That is **F7-6**, a separate task against `scripts/02-deploy-contracts-sepolia.sh` — the deploy script rewrites `intent.toml` on every run, so the override has to be written there, not hand-edited. Nothing about it belongs in this task.
- Changing which trace types are startable (D-0054, settled) or extending `game_impls_type_number` (E-F7-2-1, someone else's).
- Adding new environment variables.
- Running the challenger, the proposer, or the bad-proposal tool against anything.

## If you think this is wrong

Argue it with evidence. Item 4 in particular is a judgement call: refusing on a failed `gameArgs` call means a factory that predates the function can never pass preflight. That is deliberate — no such factory is in play here, and silently treating an RPC failure as an old layout is the exact shape of the bug D-0055 removed. If you see a way to distinguish the two states reliably from a shell script, say so as **E-F7-4-1** rather than building it.

## Return exactly this

```
TASK:        F7-4 — preflight assertion hardening + stale citation
LINE OF WORK: agent/f7-4-preflight-assertion-hardening (off wave19-base)
REVIEW ARTIFACT: <PR URL>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: bash -n — pass/fail; shellcheck — pass/fail/not-installed;
              test-helpers.sh — pass/fail, PASS count 108 → N, final line;
              mutation tests — four rows, each red/not-red;
              run_preflight harness — five rows, observed exit codes
              (run against wave19-base as of hand-back)
MIGRATION:   none

SHARED FILES TOUCHED: test-helpers.sh — exact lines, what changed
IDENTIFIERS USED:     F7-4, branch, PR number
EXISTING CHECKS MODIFIED: the F7-3 block — <before> → <after>; why this strengthens
DECISIONS NEEDED:    E-F7-4-1 if you hit the item-4 argument; anything else
RESIDUAL GAPS:       what you could not exercise without a live factory; what was
                     checked by hand vs by test; risk stated plainly
```

Disclosure in those last three fields counts as diligence, not failure.
