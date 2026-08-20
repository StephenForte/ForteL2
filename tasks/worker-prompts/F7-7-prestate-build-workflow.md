# Worker prompt — F7-7: build the Kona absolute prestate in CI (US-071 step 0b / step 8b)

Copy everything below the line into the worker. **Mid model tier** — one workflow file, but it is the only route to the artifact a network-wide redeploy will commit to, and a green run that silently built the wrong program is the failure this task exists to prevent. Wave 1 this round; standalone, no parallel siblings.

---

DISPATCH · Model: mid · Order: wave 1, standalone (no siblings, no blockers)
Baseline: branch `agent/f7-7-prestate-build-workflow` off tag `wave20-base`
Host: any. **No `.env.sepolia`, no Sepolia keys, nothing signs or spends, no Sepolia RPC needed.** You are writing a GitHub Actions workflow, not running the wipe.
Working directory: main checkout (single delegate this round)
Landing: PR into `main`, squash-merge after review. The workflow must **exist and be proven** before the announcement (step 0b); it is **run** later, at step 8b, once the post-wipe chain exists.

---

You are a worker on the ForteL2 repo (`github.com/StephenForte/ForteL2`). Phase 7 context: `tasks/prd-phase-7-fault-proofs.md`, **US-071 step 0b** and **step 8b**.

An earlier version of this task was written and withdrawn. It assumed the prestate was for game type 1 (`permissioned`). It is not — see D-0060. Do not look for that file; it was deleted deliberately.

## Read before starting (governing material — trust the repository over this brief)

- `tasks/decisions.md` **D-0060** — why Phase 7 runs game type **8** (`cannon-kona`) and not 0 or 1. **D-0061** — why the prestate is built *after* the wipe against the real `rollup.json`. **D-0059** — why stateVersion 8, and what `cannon witness` does and does not prove. **D-0056** — why any of this gates the redeploy.
- `.github/workflows/ci.yml` — house style. Actions are pinned **by commit SHA with a version comment**, e.g. `uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0`. Match that; no floating tags.
- `README.md` § "Network reset procedure" — steps **1b** and **8b** are what this feeds.

## Pre-assigned identifiers — use these exactly

- Task id **F7-7**. Decisions **D-0055/0056/0059/0060/0061** are written; do not add or renumber decisions.
- Branch **`agent/f7-7-prestate-build-workflow`**, cut from tag **`wave20-base`**.
- Workflow file **`.github/workflows/build-prestate.yml`**, workflow `name:` **`build prestate`**.
- Escalations: **E-F7-7-1** and **E-F7-7-2** — both pre-assigned below. Use **E-F7-7-3** for anything else.

These override any "find the highest and add one" convention. If one looks wrong, stop and ask.

## Pinned facts — do not substitute newer values

| Thing | Value |
| --- | --- |
| Monorepo | `ethereum-optimism/optimism` at **`da197e45ed44b9fca258b3b0d0709e8dfca1c7cd`** — use the **SHA**, not the tag |
| Recipe | `rust/justfile` → `build-kona-reproducible-prestate-variant kona-client prestate-artifacts-cannon` |
| Dockerfile | `rust/kona/docker/fpvm-prestates/cannon-repro.dockerfile`, context = monorepo root, `--platform linux/amd64` |
| Outputs | `rust/kona/prestate-artifacts-cannon/` → `prestate.bin.gz`, `prestate-proof.json` (commitment is `.pre`), hash-named `<0x…>.bin.gz` |
| Required state version | **8** (`VersionMultiThreaded64_v5`) — the pinned `cannon` parses nothing else |
| L2 chain id | **852** |
| Custom-config env | `KONA_CUSTOM_CONFIGS=true` + `KONA_CUSTOM_CONFIGS_DIR=<dir>` (`rust/justfile:516-535`) |

## The one thing this task is really about

Chain 852 is **not** in `kona_registry::ROLLUP_CONFIGS`. `rust/kona/crates/proof/proof/src/boot.rs:228` therefore falls back to loading the rollup config from the preimage oracle, with an in-source warning that this is *"insecure in production without additional validation"*. D-0061 chose not to accept that: the prestate must have 852's config **baked into the program image**.

So this workflow must set `KONA_CUSTOM_CONFIGS=true` and point `KONA_CUSTOM_CONFIGS_DIR` at a directory containing chain 852's entries.

**The format is superchain-registry shape, not op-node's `rollup.json`.** `rust/kona/crates/protocol/registry/build.rs:157-158` reads exactly two filenames from that directory:

- `chainList.json` — additional `Chain` entries
- `configs.json` — `Superchain` structures with matching `ChainConfig` and `RollupConfig`

(`depsets.json` is optional — `merge_custom_depsets` — and we have no interop dependency set.) The crate's `README.md` § "Custom chain configurations" documents the contract, `tests/fixtures/custom/` shows the shape, and the build **fails** if the two files disagree or if you try to override an existing chain id.

So there is a conversion step between what we have and what Kona wants, and **establishing that conversion is the main investigative work in this task.**

## E-F7-7-1 (pre-assigned) — how the 852 config reaches CI

Two candidate routes. **Establish which works, implement that one, and report what you found either way.**

**Route A — hand-authored from published artifacts.** Build `chainList.json` and `configs.json` from `rollup.json` (and `genesis.json` if needed) against the schema of the generated files in `rust/kona/crates/protocol/registry/etc/`. These artifacts are already public — `pack-replica-artifacts.sh` ships them to the replica repo — so committing `rollup.json` under `deployments/sepolia/` is safe and matches the existing pattern (`deployments/sepolia/deployments.json` is already committed).

**Route B — the registry's own tooling.** `superchain-registry/ops/cmd/import_devnet` (`--create-config`) turns an op-deployer **`state.json`** plus a `manifest.yaml` into staging chain configs, and `ops/cmd/codegen` generates `chainList.json` / `configs.json` from staging.

**Constraint on Route B, and it is not yours to relax:** `state.json` is gitignored (`.gitignore:5`, and `deployments/sepolia/.deployer/` wholesale at line 9) and has **not** been reviewed for publication. **Do not commit `state.json`, and do not write a workflow that requires it**, unless you first report under E-F7-7-1 that Route A is unworkable and say precisely why. Whether to publish `state.json` is an operator decision, not a workaround.

**Prefer Route A.** If it works, the workflow's only new repo input is a `rollup.json` that is already public by design.

**Either way, this task must commit `deployments/sepolia/rollup.json`.** Today **no** `rollup.json` is tracked (`git ls-files '*rollup.json'` is empty) — the live one sits under the gitignored `deployments/sepolia/.deployer/`. A GitHub-hosted run sees only the checked-out commit, so with nothing tracked the workflow can never be exercised before the wipe, and the missing-file check below would kill every run. Commit the **current** config at that path so the pipeline can be proven at step 0b; at step **8b** the operator replaces it in place with the post-wipe config and re-runs. One tracked path, two lifetimes.

The file has been checked for publication: it carries chain config, fork activation times, and the batcher / deposit-contract / system-config addresses — no keys, no URLs, no secrets. Those addresses are already in the committed `deployments/sepolia/deployments.json`, and `pack-replica-artifacts.sh` already ships this exact file to the public replica repo, so tracking it changes nothing about its exposure.

## What to build

`.github/workflows/build-prestate.yml`:

### 1. Trigger and inputs

- **`workflow_dispatch` only.** No `push`, no `pull_request`, no `schedule`. This is an expensive, deliberate, operator-initiated build; firing it on every push would be a defect.
- Take an input for the rollup-config path, defaulting to **`deployments/sepolia/rollup.json`** — the file this task commits. At step 0b that path holds the *current* config, so a dispatch there is a genuine end-to-end smoke test whose commitment is **thrown away**; at step 8b the operator replaces the file with the post-wipe config and re-runs for the real one. Say this in a comment, so nobody mistakes a smoke-test hash for the real one. The input exists so an operator can point at an alternate copy without editing the workflow; the default should be right for both real uses.
- **Fail clearly and early if the config file is missing** — name the path and say "commit the post-wipe `rollup.json` first". A confusing failure here lands at the worst moment.
- `runs-on: ubuntu-latest` — x86_64 with Docker, so `--platform linux/amd64` is native. Do **not** add QEMU/binfmt setup; that would silently make this an emulated build.
- Generous `timeout-minutes` — this compiles a Rust MIPS64 target from scratch. Pick a number, comment why.

### 2. Build

Check out this repo and the pinned monorepo. Produce the custom-configs directory per E-F7-7-1, export `KONA_CUSTOM_CONFIGS=true` and `KONA_CUSTOM_CONFIGS_DIR`, then run the **`kona-client` / `prestate-artifacts-cannon`** variant **only**. Do not build `kona-client-int` / interop — we do not need it and it doubles the runtime.

### 3. Two self-checks, and they prove different things

Be precise about this; conflating them is the defect that produced D-0059's correction.

**Check 1 — commitment integrity and state version.** Build the pinned `cannon` from the same checkout (`cd cannon && just cannon` — Go, no Rust needed), run `cannon witness --input <prestate>`, and **fail the job** if `witnessHash` ≠ `.pre` from `prestate-proof.json`. That the file parses at all is the stateVersion-8 proof: the pinned multicannon embeds only `cannon-8` and errors `unknown version: N` otherwise. Comment this so the next reader knows why it is sufficient *for that property*.

**Check 2 — the custom config actually landed.** Check 1 proves **nothing** about which chain the program can prove. A build that silently ignored `KONA_CUSTOM_CONFIGS_DIR` produces a perfectly valid prestate for the wrong thing, and every other signal in this workflow would still be green. **The job must fail if the config was not incorporated.** Two techniques worth trying — pick one, or find better, and report which and why:

- **Negative control:** build once without custom configs and once with, and assert the two commitments **differ**. Decisive, but roughly doubles runtime.
- **Image inspection:** decompress the prestate and search the memory image for a value that can only be present if the config was compiled in — chain id 852, or the L2 genesis hash from `rollup.json`. Cheap, but you must confirm it can actually fail: verify it finds nothing in a stock build before trusting it on a custom one.

Whichever you choose, **prove it can fail**. An assertion that passes against a stock build is worse than no assertion.

### 4. Report, do not gate, on the registry comparison

Fetch `validation/standard/standard-prestates.toml` from the superchain registry (`ops/prestate-reproducibility/prestates/fetcher.go` has the URL) and report whether the computed hash matches any entry. **This must not fail the job.** Our prestate bakes in a custom chain config, so it *should not* match anything published — a match would be the surprising outcome. Information only.

### 5. Surface it, then upload

Write the commitment, both self-check results, the registry comparison, the monorepo SHA and the rollup-config path into `$GITHUB_STEP_SUMMARY` — the operator should read the hash off the run page without downloading. Then upload `prestate.bin.gz`, the hash-named `<0x…>.bin.gz` and `prestate-proof.json` as a named artifact.

## Scope

**Freely changeable:** `.github/workflows/build-prestate.yml` (new).

**Additive, required:** `deployments/sepolia/rollup.json` — copy the current file from `deployments/sepolia/.deployer/rollup.json` verbatim, no edits. **Additive if the conversion needs it:** a small generator script (put it somewhere sensible and say where).

**Do not touch:** `ci.yml`, `security-scans.yml`; `scripts/` of any kind; `README.md`; `.env.sepolia.example`; `tasks/` (planner-owned); `.gitignore`; anything under `deployments/sepolia/.deployer/`.

If the task appears to require changing something outside that surface, **stop and report rather than widening scope.**

## What must survive this change

- `ci.yml` and `security-scans.yml` behave exactly as before; adding a workflow must not change when they run.
- **No secrets.** Every input here is public. If you reach for `secrets.`, stop and report as **E-F7-7-3**.
- Nothing touches Sepolia, signs anything, or spends gas.
- `scripts/test-helpers.sh` still reports **110 PASS** and `All script helper tests passed.` — you are not changing scripts, so movement there means something went wrong.

## Verification

You probably cannot trigger a GitHub Actions run, and you must not push branches around trying. Verify what you can and be exact about the boundary:

```
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-prestate.yml')); print('yaml ok')"
actionlint .github/workflows/build-prestate.yml   # if available; say so if not
bash scripts/test-helpers.sh
```

**If your environment has Docker and is x86_64, run the build for real** and report the commitment, both self-check results and the wall-clock time. That converts this from a reviewed guess into a measured result and is by far the most valuable thing you can return. **If you do not have Docker, say so plainly** — it is not a failure.

State explicitly which you did.

## E-F7-7-2 (pre-assigned) — runtime and cost

Report the **actual** runtime if you ran it, or an evidence-based estimate from the Dockerfile's stages if you did not. The operator needs to know whether this is re-runnable on a whim or a once-per-wipe event. **Do not add build caching** — caching a reproducible build is a correctness question, not a performance one, and it needs its own decision.

## Out of scope

- Registering the type-8 game or emitting the intent stanza — that is **F7-6** against `scripts/02-deploy-contracts-sepolia.sh`.
- Obtaining `kona-host` for the mini — that is **F7-8**, not yet written.
- The preflight prestate-commitment check — **F7-5** (D-0057), still unwritten.
- Anything about the wipe or redeploy — not authorized.
- The interop prestate, supernode, or depset config.
- Build caching, matrix builds, scheduled runs.
- Documenting the procedure in `README.md` — the planner writes that once the workflow has actually produced an artifact, so the docs describe something proven rather than intended.

## If you think this is wrong

Argue it with evidence. Two judgements worth challenging if you disagree:

1. **Check 2 is mandatory and fails the job.** A prestate that does not commit to 852's config is the exact defect D-0061 exists to prevent, and it is invisible to every other signal here.
2. **Route A is preferred over Route B.** If `import_devnet` turns out to be the only workable path, say so under E-F7-7-1 with what you tried — do not quietly commit `state.json`.

## Return exactly this

```
TASK:        F7-7 — build the Kona absolute prestate in CI
LINE OF WORK: agent/f7-7-prestate-build-workflow (off wave20-base)
REVIEW ARTIFACT: <PR URL>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: yaml parse — pass/fail; actionlint — pass/fail/not-installed;
              test-helpers.sh — pass/fail, PASS count (expect 110), final line;
              did you run the build? yes/no — if yes: commitment, check 1 result,
              check 2 result and how you proved it can fail, registry comparison,
              wall-clock time; if no: what you verified statically
MIGRATION:   none

SHARED FILES TOUCHED: none expected — confirm, or name what and why
IDENTIFIERS USED:     F7-7, branch, PR number, workflow filename
EXISTING CHECKS MODIFIED: none | <path> — <before> → <after>; why this strengthens
DECISIONS NEEDED:    E-F7-7-1 config route (required — which route, what you tried);
                     E-F7-7-2 runtime/cost (required); anything else
RESIDUAL GAPS:       what you could not exercise; reasoned vs measured; risk plainly
```

Disclosure in those last three fields counts as diligence, not failure.
