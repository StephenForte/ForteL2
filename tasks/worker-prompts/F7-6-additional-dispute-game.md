# Worker prompt — F7-6: register the type-8 dispute game from the deploy script (US-071 step 0b / step 8b)

Copy everything below the line into the worker. **High model tier** — this edits `scripts/02-deploy-contracts-sepolia.sh`, the script that performs the network-wide wipe. The change itself is contained, but the guard rails around it are the point, and getting one backwards spends a redeploy.

---

DISPATCH · Model: high · Order: wave 1, standalone (no siblings, no blockers)
Baseline: branch `agent/f7-6-additional-dispute-game` off tag `wave21-base`
Host: any. **No `.env.sepolia`, no Sepolia keys, no `op-deployer` run, no network.** Nothing in this task signs, spends, deploys, or wipes anything. You are editing a script and asserting on its text.
Working directory: main checkout (single delegate this round)
Landing: PR into `main`, squash-merge after review. **This is the last step-0b prerequisite** — F7-7 and F7-8 are done.

---

You are a worker on the ForteL2 repo (`github.com/StephenForte/ForteL2`). Phase 7 context: `tasks/prd-phase-7-fault-proofs.md`, **US-071 step 0b** and **step 8b**.

`scripts/02-deploy-contracts-sepolia.sh` rewrites `intent.toml` from the environment on every run and hands it to `op-deployer apply`. Today it can only produce the standard game. Phase 7 needs it to also register a **game type 8** (`cannon-kona`) dispute game carrying a Kona prestate — but **only on a later, separate apply**, never during the wipe.

## Read before starting (governing material — trust the repository over this brief)

- `tasks/decisions.md` **D-0060** (why game type 8 at all), **D-0061** (why the registration is a *second* apply after the network is healthy), **D-0056** (why op-deployer's built-in prestate default is poison), **D-0059** (stateVersion 8), **D-0062** (what is already built).
- `scripts/02-deploy-contracts-sepolia.sh` — the whole intent heredoc, and the clock-combo refusal above it.
- `scripts/test-helpers.sh` — the assertion harness; house style is structural `grep`/`awk` over script text.
- `README.md` § "Network reset procedure" steps **1b** and **8b**.
- `scripts/lib.sh` — **read-only, never edit.**

## Pre-assigned identifiers — use these exactly

- Task id **F7-6**. Decisions listed above are written; do not add or renumber decisions.
- Branch **`agent/f7-6-additional-dispute-game`**, cut from tag **`wave21-base`**.
- New environment variable: **`FAULT_GAME_ABSOLUTE_PRESTATE`** — this exact name.
- Escalations: **E-F7-6-1**, **E-F7-6-2**.

These override any "find the highest and add one" convention. If one looks wrong, stop and ask.

## Verified facts — these were measured, do not re-derive or "correct" them

| Fact | Source |
| --- | --- |
| Intent field is `dangerousAdditionalDisputeGames`, on `ChainIntent` | `op-deployer/pkg/deployer/state/chain_intent.go:89` |
| TOML is parsed by **BurntSushi/toml v1.5.0**; untagged Go fields match on **field name** | `go.mod`; `AdditionalDisputeGame` has no tags on `VMType` / `MakeRespected` |
| `AdditionalDisputeGame` embeds `ChainProofParams`, so its fields sit at the same level | `chain_intent.go:46-52` |
| `VMType = "CANNON"` deploys a **fresh MIPS** at `versions.GetCurrentVersion()` | `pipeline/dispute_games.go:95-124` |
| `GetCurrentVersion()` = `VersionMultiThreaded64_v5` = **8** | `cannon/mipsevm/versions/version.go:107` |
| Depth/clock values come **only** from the stanza; omitted means **zero** | `dispute_games.go:196-201` |
| Standard depths: `faultGameMaxDepth` **73**, `faultGameSplitDepth` **30** | `standard/standard.go:27-28`, cross-checked on the live type-1 impl (`maxGameDepth()` = 73, `splitDepth()` = 30) |
| `dangerouslyAllowCustomDisputeParameters` is **not** consulted for additional games | only `pipeline/opchain.go:156` reads it |
| Registration is once-only: it skips if state already has additional games | `dispute_games.go:260-270` |
| Requires the deployer to be the L1ProxyAdminOwner | `dispute_games.go:39-41` |

## What to build

### 1. The stanza, emitted **conditionally**

When `FAULT_GAME_ABSOLUTE_PRESTATE` is set, append this to the `[[chains]]` table in the generated `intent.toml`:

```
  [[chains.dangerousAdditionalDisputeGames]]
    respectedGameType = 8
    faultGameAbsolutePrestate = "${FAULT_GAME_ABSOLUTE_PRESTATE}"
    faultGameMaxDepth = 73
    faultGameSplitDepth = 30
    faultGameClockExtension = ${FAULT_GAME_CLOCK_EXTENSION}
    faultGameMaxClockDuration = ${FAULT_GAME_MAX_CLOCK_DURATION}
    VMType = "CANNON"
    MakeRespected = true
```

Points that are deliberate, not incidental:

- **Reuse the existing clock variables.** Do not invent new ones. The script already refuses a combo that fails `PermissionedDisputeGame.initialize`; reusing the same values means that refusal covers this game too, rather than leaving a second set unvalidated.
- **73 / 30 are literals with a comment naming their source.** They match op-deployer's standard *and* the live type-1 implementation. A shell script cannot read Go constants, so hardcode and cite.
- `respectedGameType = 8`, `VMType = "CANNON"` and `MakeRespected = true` are **fixed**. Do not make them configurable — a configurable game type invites someone to set 1, which D-0060 established can never play.
- Mind the TOML nesting: this is a sub-table of `[[chains]]`, so it must appear **after** the chain's scalar keys. Getting it before them silently reparents the keys.

**When `FAULT_GAME_ABSOLUTE_PRESTATE` is unset, emit nothing at all** — byte-identical intent to today. That is the normal case, including the wipe itself.

### 2. Three refusals, all fail-closed

**(a) Refuse when the prestate is set *and* `FORCE_SEPOLIA_REDEPLOY=1`.** This is the important one. D-0061 puts the type-8 registration in a **second apply after the network is healthy** — precisely because the prestate must commit to the *post-wipe* rollup config, which does not exist during the wipe. Any value present at wipe time is therefore, by construction, for the old chain. Refuse with a message that says so and points at step 8b.

**(b) Refuse a malformed value.** Require exactly `0x` followed by 64 hex characters. Anything else exits non-zero before `op-deployer apply`.

**(c) Refuse op-deployer's built-in default,** `0x038512e02c4c3f7bdaec27d00edf55b7155e0905301e1a88083e4e0a6764d54c`. That is a **cannon32** artifact and the MIPS64 VM requires stateVersion 8 (D-0056). If it appears in this variable, someone has pasted the wrong hash from the wrong place, and the whole point of D-0056 was to stop that value reaching a redeploy. Name it in the error.

Every refusal must fire **before** anything is written or applied, and must name the variable and what to do instead.

### 3. Echo what mode it is in

The script already echoes `Deploy overrides: …`. Add one line saying either that no additional dispute game is configured, or that type 8 will be registered with the given prestate (echo the prestate — it is a public commitment, not a secret). An operator watching a wipe scroll past should be able to see which of the two shapes they are getting.

### 4. `.env.sepolia.example`

Document `FAULT_GAME_ABSOLUTE_PRESTATE` — commented out, with the rule that it is set **only for the step-8b second apply**, never for the wipe, and that its value comes from the CI prestate build (D-0059/D-0061), not from op-deployer's default.

### 5. `scripts/test-helpers.sh`

Append one block in the house style. Assert properties, not phrasing:

- With the variable unset, the generated intent contains no `dangerousAdditionalDisputeGames`.
- With it set, the stanza appears **inside** the `[[chains]]` table with all eight keys, and `respectedGameType` is `8`.
- The three refusals exist and each reaches a non-zero exit.
- The clock keys reference the **existing** `FAULT_GAME_CLOCK_EXTENSION` / `FAULT_GAME_MAX_CLOCK_DURATION` variables, not new ones.

**Mutation-test your own assertions** and report the results: break each property, confirm the harness goes red, restore. An assertion you could not make fail does not work — say so rather than shipping it.

## Scope

**Freely changeable:** `scripts/02-deploy-contracts-sepolia.sh`.
**Additive only:** `scripts/test-helpers.sh`, `.env.sepolia.example`.
**Do not touch:** `scripts/lib.sh`; `tasks/` (planner-owned); `README.md`; `.github/`; any other script; anything under `deployments/`.

If the task appears to require changing something outside that surface, **stop and report rather than widening scope.**

## What must survive this change

- **With `FAULT_GAME_ABSOLUTE_PRESTATE` unset, the generated `intent.toml` must be byte-identical to today's.** Prove this, do not assert it — generate one before and one after and `diff` them.
- The existing clock-combo refusal, the `preimageOracleChallengePeriod` echo, the `FORCE_SEPOLIA_REDEPLOY` resume/wipe logic, and every existing `[globalDeployOverrides]` / `[superchainRoles]` / `[[chains]]` / `[chains.roles]` key, unchanged.
- No secret is ever echoed. `redact_rpc_url` still guards every URL that is printed.
- `scripts/test-helpers.sh` reports **110 PASS** and `All script helper tests passed.` at `wave21-base`; your additions raise it. Existing assertions may not be weakened, skipped, or deleted.

## Verification

```
bash -n scripts/02-deploy-contracts-sepolia.sh
shellcheck scripts/02-deploy-contracts-sepolia.sh   # if available; say so if not
bash scripts/test-helpers.sh
```

**You cannot run `op-deployer apply` and must not try.** What you *can* do, and should: source or stub the script far enough to make it emit an `intent.toml` into a scratch directory, with dummy values, and inspect the result. Report the generated stanza verbatim, and the `diff` proving the unset case is unchanged. That is the difference between a reviewed guess and a measured result.

State exactly what you exercised and what you did not.

## E-F7-6-1 (pre-assigned) — the L1PAO precondition

`dispute_games.go:39-41` refuses outright when the deployer is not the L1ProxyAdminOwner. Our intent sets `l1ProxyAdminOwner = ${ADMIN_ADDRESS}`. **Report whether the key `op-deployer apply` signs with is the same ADMIN address**, citing where you established it. Do not change anything to make it true — if it is not, that is an operator decision about which key runs the second apply, and it needs to surface before step 8b rather than during it.

## E-F7-6-2 (pre-assigned) — the once-only property

`shouldDeployAdditionalDisputeGames` returns false if state already records an additional game, so the registration cannot be repeated by re-running apply. **Report what that means for a mistaken prestate**: if the wrong hash is registered, what would it take to correct it? You are not implementing a fix — the planner needs the answer to decide how much verification belongs *before* the second apply.

## Out of scope

- Building or verifying the prestate — F7-7, done; the artifact comes from CI.
- The challenger start script — F7-2/2b/2c/F7-3/F7-4, all merged.
- The preflight commitment check — F7-5 (D-0057), still unwritten.
- Running the wipe, the redeploy, or the second apply — **not authorized**, and this task does not make them authorized.
- Interop, supernode, ZK dispute games, `dangerouslyAllowCustomDisputeParameters`.

## If you think this is wrong

Argue it with evidence. The judgement most worth challenging: **refusal (a)** — that a set prestate plus `FORCE_SEPOLIA_REDEPLOY=1` is an error rather than a convenience. It means the operator cannot do the wipe and the registration in one command, which looks like friction. It is deliberate: at wipe time the post-wipe rollup config does not exist, so any prestate present is for the old chain, and registering it would burn the wipe. If you see a way to make one-shot safe, say so as **E-F7-6-1** rather than relaxing the guard.

## Return exactly this

```
TASK:        F7-6 — register the type-8 dispute game from the deploy script
LINE OF WORK: agent/f7-6-additional-dispute-game (off wave21-base)
REVIEW ARTIFACT: <PR URL>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: bash -n — pass/fail; shellcheck — pass/fail/not-installed;
              test-helpers.sh — pass/fail, PASS count 110 → N, final line;
              generated intent with the var UNSET — diff vs today (must be empty);
              generated intent with the var SET — paste the stanza verbatim;
              the three refusals — how each was exercised and its exit code;
              mutation tests — one row per new assertion, red/not-red
MIGRATION:   none

SHARED FILES TOUCHED: test-helpers.sh / .env.sepolia.example — exact lines
IDENTIFIERS USED:     F7-6, FAULT_GAME_ABSOLUTE_PRESTATE, branch, PR number
EXISTING CHECKS MODIFIED: none | <path> — <before> → <after>; why this strengthens
DECISIONS NEEDED:    E-F7-6-1 L1PAO finding (required); E-F7-6-2 once-only
                     finding (required); anything else you hit
RESIDUAL GAPS:       what you could not exercise without op-deployer; reasoned vs
                     measured; risk stated plainly
```

Disclosure in those last three fields counts as diligence, not failure.
