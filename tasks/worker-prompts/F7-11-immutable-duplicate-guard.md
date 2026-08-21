# Worker prompt — F7-11: refuse duplicate or absent immutables before the wipe (US-071 step 0b)

Copy everything below the line into the worker. **High model tier** — this edits `scripts/02-deploy-contracts-sepolia.sh`, the script that performs the network-wide wipe. The change is small; both failure directions are expensive, and one of them aborts a scheduled outage window.

---

DISPATCH · Model: high · Order: wave 1, standalone (no siblings, no blockers)
Surface: any coding agent with a shell
Baseline: branch `agent/f7-11-immutable-duplicate-guard` off tag `wave23-base` (= commit `0e5ac1458b5e2f82d049fb3c7a4599405d1da6e8`; **both already exist on the remote** — fetch, do not create them)
Host: any with **Foundry on PATH** (`cast` — the existing F7-10 tests need it; CI pins v1.7.1). **No `.env.sepolia`, no Sepolia keys, no `op-deployer` run, no network, no spend.**
Working directory: main checkout (single delegate this round)
Landing: PR into `main`, squash-merge after review. **This is the last item blocking the Phase 7 announcement.**

---

You are a worker on the ForteL2 repo (`github.com/StephenForte/ForteL2`). Phase 7 context: `tasks/prd-phase-7-fault-proofs.md`, **US-071 step 0b**.

**Trust the repository over this brief, including over its confident assertions.** Everything below was measured at the time of writing; check current state before relying on it.

## Read before starting

- `tasks/decisions.md` — **D-0065** (the entire reason this task exists; read Findings 1 and 2 first), **D-0049** (the six values and why no agent edits `.env.sepolia`), **D-0063 Finding 3** and **D-0064** (context on the guards already in this script), **D-0046** (the clock inequality).
- `scripts/02-deploy-contracts-sepolia.sh` — the preamble through line ~50, the defaults at **74-75** and **84-87**, the clock refusals at **89-102**, and the wipe block at **~142**.
- `scripts/lib.sh` — **read-only** (see Scope). Note line **35**: `export FORTEL2_ENV_FILE` — the *resolved* env file path.
- `scripts/test-helpers.sh` — the F7-10 block starting at **1761** is the closest model for what you are writing.
- `AGENTS.md` § "Docs to update with behavior changes" — the four-place rule applies; see Scope.

## Why this task exists — what actually happened

On 2026-08-21 the operator wrote the six Phase 7 immutables into local `.env.sepolia`. The values were correct. The file was still wrong: a stale Phase 2b block **lower in the same file** re-assigned four of them, and `lib.sh` loads config with `set -a; source "$FORTEL2_ENV_FILE"`, so **the last assignment wins**. Effective values were:

```
FAULT_GAME_CLOCK_EXTENSION=600            (correct)
FAULT_GAME_MAX_CLOCK_DURATION=10          <- stale duplicate
PREIMAGE_ORACLE_CHALLENGE_PERIOD=3600     (correct)
PROOF_MATURITY_DELAY_SECONDS=12           <- stale duplicate
DISPUTE_GAME_FINALITY_DELAY_SECONDS=6     <- stale duplicate
FAULT_GAME_WITHDRAWAL_DELAY=1             <- stale duplicate
```

The file *read* as though all six were new. Only sourcing it revealed otherwise.

**It failed closed, but by luck.** `FAULT_GAME_MAX_CLOCK_DURATION=10` trips the `initialize` inequality at line 97. **That check covers only two of the six knobs.** `PROOF_MATURITY_DELAY_SECONDS`, `DISPUTE_GAME_FINALITY_DELAY_SECONDS` and `FAULT_GAME_WITHDRAWAL_DELAY` are constrained by nothing at all. Had the operator responded to the clock complaint by removing only the max-clock-duration duplicate — the obvious, locally correct fix — the wipe would have proceeded and permanently baked in 12 s / 6 s / 1 s on a chain specified for 30 min / 30 min / 1 h.

**All six also have silent defaults**, which is the second half of the same hole:

| Line | Default |
| --- | --- |
| 74 | `PROOF_MATURITY_DELAY_SECONDS="${PROOF_MATURITY_DELAY_SECONDS:-12}"` |
| 75 | `DISPUTE_GAME_FINALITY_DELAY_SECONDS="${DISPUTE_GAME_FINALITY_DELAY_SECONDS:-6}"` |
| 84 | `FAULT_GAME_CLOCK_EXTENSION="${FAULT_GAME_CLOCK_EXTENSION:-5}"` |
| 85 | `FAULT_GAME_MAX_CLOCK_DURATION="${FAULT_GAME_MAX_CLOCK_DURATION:-10}"` |
| 86 | `FAULT_GAME_WITHDRAWAL_DELAY="${FAULT_GAME_WITHDRAWAL_DELAY:-1}"` |
| 87 | `PREIMAGE_ORACLE_CHALLENGE_PERIOD="${PREIMAGE_ORACLE_CHALLENGE_PERIOD:-86400}"` |

A deleted line and a mistyped variable name both land on a default, silently.

## Pre-assigned identifiers

- Task id **F7-11**. Branch **`agent/f7-11-immutable-duplicate-guard`** off tag **`wave23-base`** (`0e5ac145`). Both exist.
- **No new environment variable.**
- **Do not add a decision entry.** `D-0066` is the planner's.
- Escalations: **E-F7-11-1** (`lib.sh` placement) and **E-F7-11-2** (broaden beyond the six), both required and specified below. **E-F7-11-3** for anything else.

These override any "find the highest and add one" convention.

## What to build — properties, not an implementation

Two refusals in `scripts/02-deploy-contracts-sepolia.sh`, placed **after** the F7-10 guard call at line 37 and **before** `require_min_balance_eth` (line 47) and the `rm -rf "$DEPLOY_DIR"` (~142).

**1. Duplicate refusal — unconditional, every run of this script.** If any of the six immutables is assigned more than once in the resolved env file, refuse. The error must name the variable and the line numbers of the offending assignments.

**2. Absence refusal — only on the two irreversible paths.** If any of the six is **absent, or assigned an empty value**, refuse **when `FORCE_SEPOLIA_REDEPLOY=1`** (the wipe) **or when `FAULT_GAME_ABSOLUTE_PRESTATE` is set** (step 8b, the second apply).

**"Assigned" is not the test — "has a non-empty effective value" is.** All six defaults use `${VAR:-default}` (colon-dash, verified: 6 of 6), which substitutes the default when the variable is **unset *or* empty**. So a line like `FAULT_GAME_WITHDRAWAL_DELAY=` passes any assigned-at-all check and still silently bakes in `1`. Measured:

```
VAR=''    -> ${VAR:-1} = '1'      <- empty is indistinguishable from unset; SILENT
VAR=abc   -> ${VAR:-1} = 'abc'    <- garbage survives into intent.toml; TOML rejects it; LOUD
```

That asymmetry is why this rule is scoped to *empty* rather than to value validation: a malformed value fails loudly at `op-deployer apply`, an empty one is baked in permanently and silently. Rejecting non-integer values is **out of scope** — raise it as E-F7-11-3 if you disagree, do not add it.

Both conditions are settled decisions; the reasoning, so you can recognise variants:

- **Unconditional for duplicates** because a duplicate is never intentional in this file and never harmless — it makes the file lie about its own effective values on every path, not just the irreversible ones.
- **Gated for absence** because the defaults at 74-87 are deliberate. The comment at 79-83 argues they are honest about the currently-live chain so that a partial wipe fails closed. Refusing absence unconditionally would change behaviour on paths that are working correctly today.
- **Step 8b is in the gate** because the F7-6 type-8 stanza interpolates `FAULT_GAME_CLOCK_EXTENSION` and `FAULT_GAME_MAX_CLOCK_DURATION` directly, and registration is **once-only** (D-0063 Finding 5 — `shouldDeployAdditionalDisputeGames` skips, and on-chain `SetDisputeGameImpl` requires `gameImpls(8) == address(0)`). An absent knob at 8b registers a permanent game with default clocks. That is as irreversible as the wipe.

**Read the resolved path from `$FORTEL2_ENV_FILE`** (exported by `lib.sh:35`), never `.env.sepolia` by name — see the trap.

Everything else about the shape is yours.

## The trap

**Three ways to get this wrong, all of which have the same consequence: a false refusal aborts a scheduled wipe after writers are already stopped, turning a routine step into an unplanned outage.**

1. **Hard-coding the filename.** `FORTEL2_ENV` accepts an absolute path (`lib.sh:11-13`), and the operator's own verification recipes use exactly that. A guard that greps `.env.sepolia` by name is **silently inert** whenever the env file is anything else — the worst outcome, because it reports success.
2. **A sloppy assignment matcher.** `#FAULT_GAME_CLOCK_EXTENSION=5` is a comment, not an assignment; `export FAULT_GAME_CLOCK_EXTENSION=5` *is* an assignment; leading whitespace is legal. Counting a commented-out line as a duplicate produces a false refusal on a perfectly good file. Get the matcher right and test all three forms.
3. **Leaking the file's contents.** This file holds seven private keys. Error messages may name **variables and line numbers**; they must never print the content of any line. Do not `cat`, `grep -n` into output, or echo matched text.

## What must survive the change

- **All 122 existing PASSes.** No existing check may be weakened, skipped, or deleted. If one legitimately must change, declare it with before, after, and why it strengthens.
- **The F7-6 byte-identity property** — with `FAULT_GAME_ABSOLUTE_PRESTATE` unset, the generated intent is byte-identical to `wave23-base`. Prove it.
- **The F7-10 pairing guard, the clock refusals, and the three F7-6 prestate refusals**, all unchanged.
- **Today's behaviour on every non-irreversible path.** A run with neither `FORCE_SEPOLIA_REDEPLOY=1` nor `FAULT_GAME_ABSOLUTE_PRESTATE` set, against a file missing some of the six, must still proceed exactly as it does now.

## Coverage — assert these properties

Append an F7-11 block to `scripts/test-helpers.sh`, before the final `if (( fail ))` gate. **Do not modify the F7-6 block (1536-1757) or the F7-10 block (from 1761).** Assert:

- a duplicate of **each** of the six refuses, naming the variable and both line numbers
- `#VAR=…` (commented) is **not** a duplicate — must pass
- `export VAR=…` **is** an assignment — must count
- leading-whitespace assignment counts
- absence + `FORCE_SEPOLIA_REDEPLOY=1` refuses
- absence + `FAULT_GAME_ABSOLUTE_PRESTATE` set refuses
- **`VAR=` (empty) and `VAR=""` refuse on both irreversible paths**, exactly as absence does — assert this per variable, since three of the six are covered by no other check
- `VAR=3600` followed later by `VAR=` is a **duplicate** and refuses unconditionally, on every path
- absence or emptiness with **neither** gate set still proceeds (today's behaviour preserved)
- the guard reads `$FORTEL2_ENV_FILE`, not a hard-coded `.env.sepolia`
- error output contains no value from any line of the env file
- structurally, both refusals run before `require_min_balance_eth` and before `rm -rf "$DEPLOY_DIR"`

**Build fixture env files at runtime; never commit one containing a key-shaped literal.** The existing frozen-allowlist assertion will fail you if you add a `0x`-prefixed 64-hex literal to `test-helpers.sh`.

**One specific regression to avoid.** Any test you write that runs a script against a fixture env **must** use `env -u FORTEL2_ENV`. D-0065 records why: an inherited absolute `FORTEL2_ENV` re-sets `FORTEL2_ROOT` after the caller's prefix, so the fixture is bypassed and the assertion passes **vacuously** — green while proving nothing. There is precedent at `test-helpers.sh:251` and in the F7-10 block.

**Then mutation-test every new assertion.** One row each: break the guard, confirm red, restore. Report which assertion actually fired — if something other than the intended one catches it, say so rather than claiming the intended one did.

## Scope

**Freely changeable:** `scripts/02-deploy-contracts-sepolia.sh`.

**Addition only:**
- `scripts/test-helpers.sh` — append the F7-11 block only.
- `README.md` § "Network reset procedure", `.env.sepolia.example`, `tasks/prd-phase-7-fault-proofs.md` § Operator sequence, `tasks/prd-l2-learning-chain.md` `:19`/`:51`. **All four already name F7-11 as outstanding.** Your edit flips them to describe the landed guard and removes the "do not announce before it merges" wording. The two `tasks/` files are normally planner-owned and are in scope only because `AGENTS.md` requires the four to move in one commit.

**Do not touch:** `scripts/lib.sh` (see E-F7-11-1), `tasks/decisions.md` (D-0066 is the planner's), any other script, `.github/`, `deployments/`, any real `.env*` file, `tasks/worker-prompts/`.

**If this task appears to require changing anything outside the permitted surface, stop and report rather than widening scope.**

## Verification — against `main` as of hand-back

Re-fetch `origin/main` and re-run everything at hand-back time.

- `bash -n scripts/02-deploy-contracts-sepolia.sh`
- `shellcheck scripts/02-deploy-contracts-sepolia.sh` — report `not-installed` if absent; do not install it.
- `./scripts/test-helpers.sh` — **baseline is 122 PASS** on `wave23-base`, final line `All script helper tests passed.` Report the new count; unexplained movement is itself a finding.

  Run it with a temporary, secret-free env file rather than bare — with no local `.env` the suite falls back to tracked `.env.example`, whose `FORTEL2_ROOT` is a macOS-only path:

  ```bash
  TMPENV="$(mktemp "${TMPDIR:-/tmp}/fortel2-test-env.XXXXXX")"
  sed -e "s|/Users/steveforte/ForteL2|$PWD|g" \
      -e "s|/Users/steveforte/src/fortel2/data|${TMPDIR:-/tmp}/fortel2-test-data|g" \
      .env.example > "$TMPENV"
  FORTEL2_ENV="$TMPENV" ./scripts/test-helpers.sh; rm -f "$TMPENV"
  ```

  This produced 122 PASS on `wave23-base`. **Do not write a repo-root `.env`** — the operator has one.

  That `mktemp` form is the house convention — every `mktemp` in `test-helpers.sh` uses `"${TMPDIR:-/tmp}/name.XXXXXX"`, e.g. `FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/fortel2-viewer-XXXXXX")"`. Use it for any fixture you create. The `-t prefix` form without explicit `X`s works on BSD/macOS and fails on GNU/Linux with `too few X's in template`, which would stop the mandatory gate before it started.

- **Byte-identity:** regenerate `intent.toml` with `FAULT_GAME_ABSOLUTE_PRESTATE` unset, under identical dummy env, from both `wave23-base` and your branch. `diff` must be empty. **Assert both captures are non-empty before comparing** — an empty-vs-empty comparison reports a false match, and that has happened twice on this project (D-0064 Finding 7, D-0065 Finding 4). Report the command, the byte count, and the hash.
- The refusal drives and the mutation table.

**You cannot run `op-deployer apply` and must not try.** State exactly what you exercised and what you did not.

## E-F7-11-1 (pre-assigned) — should this live in `lib.sh` instead?

The duplicate check arguably belongs in `_fortel2_resolve_env_file` / the loader, where it would protect `.env`, `.env.sepolia` and every consumer script rather than one script's six variables. It is deliberately **not** in scope: `lib.sh` is CODEOWNERS-privileged, a loader-level refusal changes behaviour for every script at once, and this task is the last thing blocking an announcement. **Argue it with evidence as E-F7-11-1 if you think it is right; do not implement it.**

## E-F7-11-2 (pre-assigned) — should it cover more than the six?

Measured at the time of writing: neither `.env.example` nor `.env.sepolia.example` contains any duplicated assignment, so a check covering **all** variables would not break CI today. What is unknown is whether broadening creates false refusals on legitimate re-assignment patterns in operator files this brief cannot see. **Report your judgement — scope-to-six vs all-variables, and what you would need to measure to be confident. Do not broaden it yourself.**

## Out of scope

- Validating that the six equal any particular values. This guard checks *shape* — assigned once, assigned at all — not policy. Making the script enforce D-0049's numbers would turn every future parameter change into a code change.
- `scripts/02-deploy-contracts.sh` (local Anvil), and every other script.
- The preflight prestate-commitment check — **F7-5** (D-0057), unwritten.
- The negative-control prestate build — **F7-9** (D-0062), unwritten.
- The `deposit-eth-sepolia.sh` key/address gap (D-0064 Finding 4) — recorded, unassigned.
- Running the wipe, the redeploy, or the second apply — **not authorized**.

## If you think this is wrong

Argue it with evidence rather than implementing it half-heartedly. The judgements most worth challenging are the absence gate (why not unconditional?) and the scope-to-six decision (**E-F7-11-2**). **If you find a case where either refusal would reject a legitimate configuration, that is a defect in this brief and it must surface before merge, not during an outage window.**

## Return this, verbatim

```
TASK:        F7-11 — refuse duplicate or absent immutables before the wipe
LINE OF WORK: agent/f7-11-immutable-duplicate-guard (off wave23-base = 0e5ac145)
REVIEW ARTIFACT: <PR url>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: bash -n — pass/fail; shellcheck — pass/fail/not-installed;
              test-helpers.sh — pass/fail, PASS count 122 → N, final line;
              byte-identity of intent with the prestate var UNSET — diff vs
              wave23-base, with both captures asserted non-empty; byte count
              and hash;
              duplicate drives — one per immutable, exit codes, and the
              commented / export / leading-whitespace forms;
              absence drives — FORCE=1, prestate-set, and neither (must pass);
              resolved-path drive — guard fires with FORTEL2_ENV set to an
              absolute temp file, proving it does not key on the filename;
              leak check — how you established no env-file line reached output;
              mutation tests — one row per new assertion, red/not-red, and
              which assertion actually fired
              (run against origin/main as of hand-back)
MIGRATION:   none

SHARED FILES TOUCHED: <path> — what changed, why it is additive
IDENTIFIERS USED:     F7-11, branch, PR number
EXISTING CHECKS MODIFIED: none | <path> — <before> → <after>; why this strengthens
DECISIONS NEEDED:    E-F7-11-1 lib.sh placement (required); E-F7-11-2 scope
                     beyond the six (required); anything else you hit
RESIDUAL GAPS:       what you could not exercise without op-deployer or a real
                     env file; reasoned vs measured; risk stated plainly
```

Disclosure in those last three fields counts as diligence, not failure.
