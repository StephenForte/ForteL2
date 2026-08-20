# Worker prompt — F7-7: build the Cannon absolute prestate in CI (US-071 step 0b)

Copy everything below the line into the worker. **Mid model tier** — one new workflow file, but it is the only route to an artifact the redeploy will commit to, and a workflow that "succeeds" without proving what it built is worse than none. Wave 1 this round; standalone, no parallel siblings.

---

DISPATCH · Model: mid · Order: wave 1, standalone (no siblings, no blockers)
Baseline: branch `agent/f7-7-prestate-build-workflow` off tag `wave20-base`
Host: any. **No `.env.sepolia`, no Sepolia keys, nothing signs or spends, and no Sepolia RPC is required.** You are writing a GitHub Actions workflow; you are not running one.
Working directory: main checkout (single delegate this round)
Landing: PR into `main`, squash-merge after review. **Must land before US-071 step 0b can be executed** — it is the route to the artifact, not a nice-to-have.

---

You are a worker on the ForteL2 repo (`github.com/StephenForte/ForteL2`). Phase 7 context: `tasks/prd-phase-7-fault-proofs.md`, **US-071 step 0b**. The redeploy must commit to an absolute prestate we actually hold, and neither build path works on the operator's Mac mini. This task builds it in CI instead.

## Read before starting (governing material — trust the repository over this brief)

- `tasks/decisions.md` **D-0059** — the decision this task implements, with all the measurements. Read **D-0056** (why the gate exists) and **D-0055** (why `gameArgs` is the source of truth, and note that D-0059 corrects its closing sentence about Kona).
- `.github/workflows/ci.yml` — house style. Note especially that actions are pinned **by commit SHA with a version comment**, e.g. `uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0`. Match that; do not use floating tags.
- `README.md` § "Network reset procedure" — step **1b** is the gate this feeds.

## Pre-assigned identifiers — use these exactly

- Task id **F7-7**. Decisions **D-0055**, **D-0056**, **D-0059** are written; do not add or renumber decisions.
- Branch **`agent/f7-7-prestate-build-workflow`**, cut from tag **`wave20-base`**.
- Workflow file: **`.github/workflows/build-prestate.yml`**. Workflow `name:` **`build prestate`**.
- Escalation ids if you need them: **E-F7-7-1**, **E-F7-7-2**.

These override any "find the highest and add one" convention. If one looks wrong, stop and ask.

## The pinned facts this workflow depends on

Do not substitute newer values for any of these. They are pinned because the rest of the stack is.

| Thing | Value |
| --- | --- |
| Monorepo | `ethereum-optimism/optimism` |
| Commit | **`da197e45ed44b9fca258b3b0d0709e8dfca1c7cd`** (tag `op-node/v1.19.2`) — use the **SHA**, not the tag |
| Build recipe | `rust/justfile` → `build-kona-reproducible-prestate-variant kona-client prestate-artifacts-cannon` |
| Dockerfile it drives | `rust/kona/docker/fpvm-prestates/cannon-repro.dockerfile`, context = monorepo root, `--platform linux/amd64` |
| Outputs land in | `rust/kona/prestate-artifacts-cannon/` |
| Output files | `prestate.bin.gz`, `prestate-proof.json` (commitment is `.pre`), and a hash-named copy `<0x…>.bin.gz` |
| Required VM state version | **8** (`VersionMultiThreaded64_v5`) — the pinned `cannon` parses nothing else |

## What to build

`.github/workflows/build-prestate.yml`, doing exactly this:

### 1. Trigger and runner

- **`workflow_dispatch` only.** No `push`, no `pull_request`, no `schedule`. This is an expensive, deliberate, operator-initiated build. A workflow that fires on every push to `main` is a defect, not a convenience.
- `runs-on: ubuntu-latest`. It is x86_64 and ships Docker, so `--platform linux/amd64` is native — do **not** add QEMU/binfmt setup, which would silently make this an emulated build.
- Give the job a generous `timeout-minutes` — this compiles a Rust MIPS64 target from scratch and will take tens of minutes. Pick a number and say why in a comment.

### 2. Check out the pinned monorepo

Check out `ethereum-optimism/optimism` at the SHA above, into a subdirectory. You need this repo checked out too only if you actually use something from it — if you don't, don't check it out, and say so in your report.

### 3. Build

Install `just`, then run the **`kona-client` / `prestate-artifacts-cannon`** variant **only**. Do not run the wrapper `reproducible-prestate` if it also builds the interop variant — we do not need `cannon64-kona-interop`, and building it doubles the runtime for nothing. Invoke the variant recipe directly.

### 4. Self-check — this is the part that matters

A workflow that uploads a file it has not verified is a workflow that will eventually hand the operator a bad artifact with a green tick. Before uploading:

- Build the pinned **`cannon`** binary from the same checkout (`cd cannon && just cannon`, Go — no Rust needed for this part).
- Run `cannon witness --input <the built prestate>` and capture `witnessHash` from its JSON output.
- **Assert `witnessHash` equals `.pre` from `prestate-proof.json`.** If they differ, **fail the job** — that is the artifact and its claimed commitment disagreeing, and nothing downstream should see it.
- The fact that `cannon witness` parsed the file at all is itself the stateVersion-8 proof: the pinned multicannon embeds only `cannon-8` and errors `unknown version: N` on anything else. Say so in a comment so the next reader knows why this check is sufficient.

### 5. Report, do not gate, on the registry comparison

Fetch `validation/standard/standard-prestates.toml` from the superchain registry (the pinned tree fetches it from `raw.githubusercontent.com/ethereum-optimism/superchain-registry/refs/heads/main/validation/standard/standard-prestates.toml` — see `ops/prestate-reproducibility/prestates/fetcher.go`) and report whether the computed hash matches any entry, and if so which release and type.

**This must not fail the job when it does not match.** The redeploy's `faultGameAbsolutePrestate` is ours to choose (D-0056 / D-0059), so a hash that matches nothing published is a legitimate outcome — it means we pin our own. Treat this purely as information.

### 6. Surface the result without requiring a download

Write the commitment, the registry-match result, the monorepo SHA and the output filenames into `$GITHUB_STEP_SUMMARY`. The operator should be able to read the hash from the run page.

### 7. Upload

Upload `prestate.bin.gz`, the hash-named `<0x…>.bin.gz`, and `prestate-proof.json` as a build artifact. Name it so the run it came from is identifiable. Default retention is fine.

## Scope

**Freely changeable:** `.github/workflows/build-prestate.yml` — a new file.

**Do not touch:** every existing workflow (`ci.yml`, `security-scans.yml`); `scripts/` of any kind; `README.md`; `.env.sepolia.example`; `tasks/` (planner-owned); anything under `deployments/`.

If the task appears to require changing something outside that surface, **stop and report rather than widening scope.**

## What must survive this change

- `ci.yml` and `security-scans.yml` behave exactly as before. Adding a workflow must not alter when they run.
- No secrets are used and none are needed — every input is public. If you find yourself reaching for `secrets.`, stop and report as **E-F7-7-1**.
- Nothing in this workflow touches Sepolia, signs anything, or spends gas.

## Verification

You almost certainly cannot run a GitHub Actions workflow from your environment, and you must not push branches around trying to trigger one. So verify what you can and be exact about the boundary:

```
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/build-prestate.yml')); print('yaml ok')"
actionlint .github/workflows/build-prestate.yml   # if available; say so if not
bash scripts/test-helpers.sh
```

`test-helpers.sh` must still report **110 PASS** and `All script helper tests passed.` — you are not changing scripts, so a change there means something went wrong.

**If your environment has Docker and is x86_64**, then run the build for real and report the resulting commitment — that turns this from a reviewed guess into a measured result, and it is by far the most valuable thing you can hand back. It will take a long time; say how long. **If you do not have Docker, say so plainly** — it is not a failure, and the operator will run the workflow.

State explicitly which of these you did.

## Report back, do not implement

**E-F7-7-2 (pre-assigned):** report the **actual runtime and runner cost** if you ran the build, or your best evidence-based estimate if you did not (e.g. from the Dockerfile's stages). The operator is deciding whether this is a thing we re-run casually or once. Do not add caching to speed it up in this task — caching a reproducible build is a correctness question, not a performance one, and it needs its own decision.

## Out of scope

- Pinning the hash into the deploy intent — that is **F7-6** against `scripts/02-deploy-contracts-sepolia.sh`, not this task.
- The preflight prestate-commitment check — that is **F7-5** (D-0057), still unwritten.
- Anything about the wipe or redeploy (US-071 / US-072) — not authorized.
- The interop prestate (`cannon64-kona-interop`), supernode, or depset config.
- Build caching, matrix builds, or running this on a schedule.
- Documenting the procedure in `README.md` — the planner will write that once the workflow has actually produced an artifact, so the docs describe something proven rather than intended.

## If you think this is wrong

Argue it with evidence. One judgement worth challenging if you disagree: the self-check fails the job when `witnessHash` and `.pre` disagree. That is deliberate — the two disagreeing means the reproducible build and the VM disagree about what was produced, and shipping the artifact anyway would push an unexplained inconsistency downstream to a network-wide redeploy. If you think there is a benign cause for a mismatch, say so as **E-F7-7-1** rather than downgrading it to a warning.

## Return exactly this

```
TASK:        F7-7 — build the Cannon absolute prestate in CI
LINE OF WORK: agent/f7-7-prestate-build-workflow (off wave20-base)
REVIEW ARTIFACT: <PR URL>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: yaml parse — pass/fail; actionlint — pass/fail/not-installed;
              test-helpers.sh — pass/fail, PASS count (expect 110), final line;
              did you run the build? yes/no — if yes: commitment produced,
              witnessHash vs .pre, registry match result, wall-clock time;
              if no: say so plainly and state what you verified statically
MIGRATION:   none

SHARED FILES TOUCHED: none expected — confirm, or name what and why
IDENTIFIERS USED:     F7-7, branch, PR number, workflow filename
EXISTING CHECKS MODIFIED: none | <path> — <before> → <after>; why this strengthens
DECISIONS NEEDED:    E-F7-7-2 runtime/cost finding (required); anything else you hit
RESIDUAL GAPS:       what you could not exercise; what was reasoned vs measured;
                     risk stated plainly
```

Disclosure in those last three fields counts as diligence, not failure.
