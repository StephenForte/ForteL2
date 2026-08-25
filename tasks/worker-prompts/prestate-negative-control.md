# Worker brief — prestate-negative-control (F7-9): decisive negative control in the prestate build workflow

```
DISPATCH · Model: Sonnet 5 · Order: parallel with docs/deposit-note-and-funding-env and feat/lib-key-guard-dedup (file-disjoint)
Surface: Claude Code worker session, launched by the operator via the desktop app (branch dropdown)
Baseline: main @ 137e679 · branch ci/prestate-negative-control (pre-created — use it, do not cut your own)
Host: any with `gh` authenticated (the verification run happens in GitHub Actions)
Working directory: /Users/steveforte/ForteL2 (app-isolated; leave `main` checked out when you finish — an hourly launchd agent runs from this checkout)
Landing: PR to main. The reviewer writes the decision entry; do not touch tasks/decisions.md or allocate a decision id.
```

Copy everything below the line into the worker.

---

## Task

Implement **F7-9** (D-0062, quantified in D-0063 Finding 5): upgrade
`.github/workflows/build-prestate.yml`'s check 2 from probabilistic image inspection to a
decisive **negative control**: a second prestate build with **stock configs** (custom-config
injection off), asserting its commitment **differs** from the custom-config build's.

**Read first:** the whole workflow file (its header comments carry the design decisions);
D-0059 through D-0063 in `tasks/decisions.md` (dispatch-only rule, pinned monorepo SHA,
smoke-vs-real lifetimes, and D-0063 Finding 5 — the measured runtime).

**Evidence.** The workflow's current check 2 greps the prestate memory image for the L2
genesis hash, with a stock-source pre-check and a sentinel to prove the scanner can fail.
That was chosen when a second build was believed to cost 45–90 minutes. D-0063 Finding 5
measured run `32416709442`: **4.5 minutes wall clock, 3.7 for the Docker build** — the
cannon-builder image is digest-pinned and prebuilt; only kona-client compiles. At that price
D-0063 records the design verdict: the negative control "is decisive rather than
probabilistic and removes the page-straddle false-negative risk" (a genesis hash straddling
an internal page boundary would make the grep miss — a false FAIL; and any encoding drift
makes it an unprovable check). The doubled runtime objection is void.

**Outcome — properties:**

1. The job builds the prestate twice from the same pinned tree: once with
   `KONA_CUSTOM_CONFIGS=true` + the generated configs dir (as today), once stock (injection
   env unset/false). The job **fails** unless both builds' commitments (`.pre` from each
   `prestate-proof.json`) are present, well-formed, and **different**.
2. Check 1 (witnessHash == `.pre`, stateVersion 8 via `cannon witness --input`) still runs
   against the **custom** build and still gates.
3. The uploaded `kona-prestate-cannon` artifact and the job summary's `commitment` row carry
   the **custom** build's outputs, provably untouched by the stock build. The summary should
   also report the stock commitment, labeled as the negative control, with the existing
   "smoke-test values are not for pinning" caveat intact.
4. `workflow_dispatch`-only survives (firing on push is a defect — D-0059); pinned
   `OP_MONOREPO_SHA` and digest-pinned actions survive; permissions stay `contents: read`;
   the timeout may stay generous (it is hang-detection, not a target).
5. Latitude: build order, whether the old image-grep + sentinel stays as a cheap
   supplementary check or goes (D-0062/63 say "replace"; keeping it costs little — your
   call, state the reasoning), and whether the stock-source pre-check step remains (it only
   existed to validate the grep discriminator — if the grep goes, it goes).

## Scope

- **Freely changeable:** `.github/workflows/build-prestate.yml` only.
- **Do not touch:** everything else — `scripts/` and `README.md` belong to sibling tasks in
  flight; `.github/prestate/gen-kona-custom-configs.py` is proven (a change there needs a
  stop-and-report); `tasks/decisions.md` is reviewer-owned.
- If the task appears to need anything outside this surface, stop and report.

## The trap

**Both builds write to the same artifact path** (`optimism/rust/kona/prestate-artifacts-cannon/`).
If the stock build runs second and the upload/summary reads that directory, the operator
downloads a **stock** prestate under the trusted artifact name and pins a commitment for a
program that cannot prove chain 852. Per D-0066 Finding 5, a wrong prestate pinned into the
type-8 game cannot be corrected through op-deployer — it takes a direct L1PAO
`setImplementation` or **another network-wide wipe**. Copy each build's outputs to distinct
directories immediately after each build (or build stock first), and make the upload step's
paths point at the preserved custom outputs by construction, not by ordering luck. Assert it:
the uploaded `prestate-proof.json`'s `.pre` must equal the custom commitment the summary
reports.

Also: the `KONA_CUSTOM_CONFIGS` env contract — confirm from the pinned monorepo's justfile
what actually toggles injection rather than assuming `false` works like unset; a stock build
that silently still injects makes the two commitments identical and the job red for the
wrong reason (or worse, a subtly wrong toggle makes them identical and you "fix" it by
weakening the assert).

## What must survive

- Everything in Outcome 4; check 1's gating; the "do not build kona-client-int" rule and its
  comment; the informational registry comparison step (must not fail the job).
- No repo scripts touched → `test-helpers.sh` (263 PASS) and `phase7-gate-parity.sh` (60
  PASS) are regression-only; run them anyway.

## Verification — the workflow must actually run

The GitHub token has the `workflow` scope (writes to `.github/workflows/` without it fail
**404, not 403** — recognize that on sight rather than debugging paths). This workflow has
never met your change; assume one latent integration gap and budget the shakeout:

```
gh workflow run "build prestate" --ref ci/prestate-negative-control
gh run watch <run-id>            # expect ~10 min; both commitments in the summary, different
./scripts/test-helpers.sh        # 263 PASS 0 FAIL (regression only)
./scripts/phase7-gate-parity.sh  # 60 PASS, exit 0
```

Report the run URL, both commitments, and the wall-clock time. This dispatch uses the
current tracked `deployments/sepolia/rollup.json` — a smoke run; per the workflow header its
commitment is thrown away, so state that in the report. If you can cheaply prove the assert
can fail (e.g. a temporary run with the stock commitment compared to itself), do it and
report; if that costs another full run, skip it and say so under RESIDUAL GAPS.

## Return format — verbatim

```
TASK:        prestate-negative-control — F7-9 decisive negative control
LINE OF WORK: ci/prestate-negative-control
REVIEW ARTIFACT: <PR URL>
STATUS:      complete | complete-with-caveats | blocked
VERIFICATION: <each check named> — pass/fail; workflow run URL, both commitments, runtime
SHARED FILES TOUCHED: none expected — declare any
EXISTING CHECKS MODIFIED: <the check-2 replacement, stated as before → after and why decisive>
DECISIONS NEEDED:    none | <question + interim choice>
RESIDUAL GAPS:       what was not proven (e.g. assert-can-fail), risk stated plainly
```

If you believe the negative control is the wrong design after reading the workflow — e.g.
you find the grep is load-bearing for something D-0063 missed — argue it with evidence in
the report rather than implementing it half-heartedly.
