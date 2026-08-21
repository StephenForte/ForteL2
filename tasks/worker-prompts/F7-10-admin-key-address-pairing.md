# Worker prompt — F7-10: pair `ADMIN_PRIVATE_KEY` to `ADMIN_ADDRESS` before the wipe (US-071 step 3 / step 8b)

Copy everything below the line into the worker. **High model tier** — this edits `scripts/02-deploy-contracts-sepolia.sh`, the script that performs the network-wide wipe. The change is small; the failure mode it closes is silent, and a guard written backwards turns a legitimate redeploy into a self-inflicted outage.

---

DISPATCH · Model: high · Order: wave 1, standalone (no siblings, no blockers)
Surface: any coding agent with a shell
Baseline: branch `agent/f7-10-admin-key-address-pairing` off tag `wave22-base` (= commit `d7c923d4d5c2fa690421ca93785000d7bfdb9c08`; **both the tag and the branch already exist on the remote** — fetch, do not create them)
Host: any with **Foundry on PATH** (`cast` — CI pins v1.7.1; both the guard and your tests need it). **No `.env.sepolia`, no Sepolia keys, no `op-deployer` run, no network, no spend.** Nothing in this task signs, deploys, or wipes anything. You are editing a script and asserting on its behaviour with throwaway keys.
Working directory: main checkout (single delegate this round)
Landing: PR into `main`, squash-merge after review.

---

You are a worker on the ForteL2 repo (`github.com/StephenForte/ForteL2`). Phase 7 context: `tasks/prd-phase-7-fault-proofs.md`, **US-071 step 3** (the redeploy) and **step 8b** (the second apply).

**Trust the repository over this brief, including over its confident assertions.** Everything below was measured at the time of writing; check current state before relying on it.

## Read before starting (governing material)

- `tasks/decisions.md` — **D-0063 Finding 4** (this task's entire reason for existing; read it first), **D-0063 Finding 3a** (why the same key must also be Guardian), **D-0061** (why there is a second apply at all), **D-0056** (why the prestate story is what it is).
- `scripts/02-deploy-contracts-sepolia.sh` — the whole preamble, lines 9–25, and the wipe block.
- `scripts/09-start-challenger-sepolia.sh:131–147` — **the existing in-house check you are mirroring**, including the comment at `:133–137` that reasons through the argv exposure. Read it before writing anything.
- `scripts/test-helpers.sh` — the assertion harness. The F7-6 block at `1536–1757` is the house style for this kind of test: structural `grep`/`awk` over script text, plus behavioural drives of an extracted function.
- `scripts/lib.sh` — **read-only for this task** (see Scope).
- `AGENTS.md` § "Docs to update with behavior changes" — the **four-place rule**. It applies to this change; see Scope.

## Why this task exists — the measured evidence

`02-deploy-contracts-sepolia.sh` writes `l1ProxyAdminOwner = "${ADMIN_ADDRESS}"` into the intent, and signs the apply with `--private-key "$ADMIN_PRIVATE_KEY"`. Those are two independent values from `.env.sepolia`. Nothing checks that they describe the same account.

| Fact | Source |
| --- | --- |
| Intent sets `l1ProxyAdminOwner = ${ADMIN_ADDRESS}` | `02-deploy-contracts-sepolia.sh:171` |
| Apply signs with `--private-key "$ADMIN_PRIVATE_KEY"` | `02-deploy-contracts-sepolia.sh:220` |
| op-deployer derives the deployer from that key: `deployer = crypto.PubkeyToAddress(opts.DeployerPrivateKey.PublicKey)` | `op-deployer/pkg/deployer/apply.go:223–225`, passed at `:351` |
| Registering the type-8 game **refuses** when deployer ≠ L1ProxyAdminOwner | `op-deployer/pkg/deployer/pipeline/dispute_games.go:39–41` |
| `MakeRespected` also calls `setRespectedGameType`, which is **Guardian**-gated | `AnchorStateRegistry.sol:153–155`; intent sets `SuperchainGuardian = ${ADMIN_ADDRESS}` at `:153` |
| `require_eth_address` validates **format only** | `scripts/lib.sh:206` |
| `refuse_foundry_defaults_unless_local_l2` only rejects Anvil defaults, and **returns 0 on an empty key** | `scripts/lib.sh:271–287` |

**The consequence is what makes this worth a task.** The standard deploy path never compares deployer to L1PAO, so a mismatched pair completes the wipe, the network rebuilds, and the failure first appears at **step 8b** — by which time L1PAO and Guardian are baked into deployed contracts. Recovery is signing 8b with whatever key actually owns those roles, or another network-wide wipe.

Two things that look like evidence and are not:

- `deployments/sepolia/deploy-spend.txt` records `spent_eth≈0` for the 2026-07-23 apply. The delta is clamped at 0 and an incoming transfer during apply masks it, so **it proves nothing** about whether the pair matched.
- `ADMIN_ADDRESS` (`0xBB3E19811B2c3423069B54BDFF3e90Dd8094bb0F`) has **nonce 28** on Sepolia — circumstantial, not proof.

The operator ran the derivation by hand on 2026-08-20 and it returned **MATCH**, so the pair is correct *today*. This task is not fixing a live defect. It is putting a fail-closed check in front of **US-070 step 0**, in which the operator hand-edits all six immutables into `.env.sepolia` — the exact moment a paste error could break the pairing, silently, days before it would surface.

## Pre-assigned identifiers — use these exactly

- Task id **F7-10**. Branch **`agent/f7-10-admin-key-address-pairing`**, already cut from tag **`wave22-base`** (`d7c923d4`). Both refs exist; `git fetch --tags` if your clone predates them.
- **No new environment variable.** This task introduces none.
- **Do not add a decision entry.** `D-0064` is the planner's and is not yours to allocate.
- Escalations: **E-F7-10-1** (role-key sweep, required) and **E-F7-10-2** (reserved for the `lib.sh` helper argument), both specified below. Use **E-F7-10-3** for anything else.

These override any "find the highest and add one" convention. If one looks wrong, stop and ask.

## What to build — stated as properties, not an implementation

`scripts/02-deploy-contracts-sepolia.sh` must hold all of the following:

1. **It refuses when the address derived from `ADMIN_PRIVATE_KEY` differs from `ADMIN_ADDRESS`.** Non-zero exit, message on stderr naming both addresses.
2. **It refuses when `ADMIN_PRIVATE_KEY` is unset or empty.** Today an unset key sails past `refuse_foundry_defaults_unless_local_l2` (which returns 0 on empty) and does not fail until `set -u` bites at `:220` — *after* `rm -rf "$DEPLOY_DIR"` at `:120` has already run. Closing that is in scope and is part of the same guard.
3. **The refusal happens before any spend and before any write.** Specifically before `require_min_balance_eth` (`:25`), before `rm -rf "$DEPLOY_DIR"`, and before `op-deployer apply`. The natural home is immediately after `require_eth_address "ADMIN_ADDRESS"` at `:15` — it needs only `cast`, already required at `:10`.
4. **The comparison is case-insensitive.** See the trap.
5. **Neither the key nor any fragment of it ever reaches stdout, stderr, or a log.** Derived and configured addresses are public and may be printed; the key may not.
6. **The generated `intent.toml` is byte-identical to `wave22-base` for every input that is not a mismatch.** This task adds a guard; it changes no output.

**Use `cast wallet address --private-key "$ADMIN_PRIVATE_KEY"`, mirroring `09-start-challenger-sepolia.sh:138`, and carry an equivalent comment.** That script already reasons through the tradeoff — `cast wallet address` has no env-var form, so the key touches argv for one short-lived process, and that bounded exposure is deliberately accepted to close a silent-wrong-signer failure. The same reasoning applies here, and this script already passes the key to `op-deployer apply` on argv, so this adds no new class of exposure. Do not invent a different derivation method.

Everything else about the shape is yours.

## The trap

**`cast wallet address` returns an EIP-55 checksummed address; `.env.sepolia` may hold any case.** A raw string comparison produces a **false mismatch** on a perfectly good keypair — and because this guard sits on the redeploy path, that means aborting a scheduled wipe *after writers have already been stopped*, turning a routine step into an unplanned outage. Lowercase both sides before comparing, exactly as `09-start-challenger-sepolia.sh:139–141` does.

The generalisation worth carrying: **this guard fails an operator's day if it is wrong in either direction.** A false pass leaves the type-8 game unregisterable after an irreversible wipe; a false failure aborts the wipe mid-sequence. Both directions need a test.

The second trap is ordering. If the check lands after `require_min_balance_eth` it makes a network call before refusing; if it lands after the wipe block it destroys `$DEPLOY_DIR` before refusing. Assert the ordering structurally — the F7-6 block's `awk` line-number comparison at `test-helpers.sh:1606` is the pattern, and `:1675` shows how to extract a shell function from the script and drive it in isolation — the technique you want for the behavioural drives.

## What must survive the change

- **All 115 existing PASSes.** No existing check may be weakened, skipped, or deleted to make this pass. If one legitimately must change because it encoded the behaviour you are correcting, declare it in the return report with before, after, and why it is a strengthening.
- **The F7-6 byte-identity property** — with `FAULT_GAME_ABSOLUTE_PRESTATE` unset, the generated intent is unchanged. Prove it, do not assume it.
- **The three F7-6 refusals** and the clock-combo refusal above them.
- Exit codes and the existing stderr conventions.

## Coverage — assert these properties

Append a new F7-10 block to `scripts/test-helpers.sh`, before the final `if (( fail ))` gate at the end of the file. Assert:

- a **matching** pair passes the check (including a checksummed-vs-lowercase pair of the same account — this is the false-mismatch guard)
- a **mismatched** pair exits non-zero, and no `rm -rf` has run
- an **unset/empty** `ADMIN_PRIVATE_KEY` exits non-zero
- the error output contains **neither the key nor any 8-character substring of it**
- structurally, the check appears **before** `require_min_balance_eth` and **before** the wipe block
- `cast wallet address` is used with `--private-key`, not a positional argument

**Generate the test keypair at runtime — `cast wallet new` — and never write a key literal into a tracked file.** `AGENTS.md:14-15` prohibits committing private keys and writing keys into committed files, with no throwaway exemption; a secret scanner cannot tell a disposable key from a live one. Hold the generated key in a shell variable for the duration of the test and let it die with the process. Do **not** reach for a Foundry/Anvil default either: `refuse_foundry_defaults_unless_local_l2` fires first on any non-901 chain and you would be testing the wrong refusal.

Add one assertion while you are here: **`scripts/test-helpers.sh` contains no `0x`-prefixed 64-hex literal** beyond the F7-6 prestate constants already present (`_F76_VALID_PRESTATE`, `_F76_CANNON32_DEFAULT` — public hashes, not keys). That makes the prohibition self-enforcing instead of something reviewers must remember.

**Then mutation-test every new assertion.** One row per assertion: break the guard, confirm the harness goes red, restore. An assertion that stays green under mutation is not an assertion. Report the table, and report honestly which assertion went red — if a mutation is caught by something other than the check you intended, say so rather than claiming the intended one fired.

## Scope

**Freely changeable — this task owns them:**
- `scripts/02-deploy-contracts-sepolia.sh`
- `README.md` § "Network reset procedure" and `.env.sepolia.example` (see the four-place rule below)

**Addition only:**
- `scripts/test-helpers.sh` — append a new F7-10 block before the final `if (( fail ))` gate. **Do not modify the F7-6 block at `1536–1757`.**
- `tasks/prd-phase-7-fault-proofs.md` and `tasks/prd-l2-learning-chain.md` — **normally planner-owned and off-limits to workers.** They are in scope for this task *only* because `AGENTS.md` requires a new pre-redeploy gate to move in all four places in one commit, and this is one. Touch only the sentences that describe the redeploy precondition. Nothing else in those files.
  **Step 0b's status text has already been corrected by the planner** — it previously claimed no further Phase 7 code was required, which this task contradicts — so your PRD edit is purely additive: describe the new guard, do not restate the gate status. If you find any remaining completion claim that this task contradicts, that is a planner defect: **report it, do not silently rewrite it**.

**Do not touch:**
- `scripts/lib.sh` — see E-F7-10-2. Its process helpers are privileged under CODEOWNERS, and a new shared helper is a design question, not this task's call.
- `tasks/decisions.md` — the planner writes D-0064.
- Any other script, `.github/`, `deployments/`, any real `.env*` file, `tasks/worker-prompts/`.

**The four-place rule.** `AGENTS.md` states that a new pre-redeploy gate is restated in four places and missing one "leaves a reader routed to an irreversible network-wide wipe with an incomplete gate". This guard can abort the wipe, so it qualifies. The four are: `tasks/prd-phase-7-fault-proofs.md` § Operator sequence (binding, the authority), `README.md` § "Network reset procedure", `.env.sepolia.example` (pointer), and `tasks/prd-l2-learning-chain.md` `:19` glossary + `:51` Phase 7 row. Search by **concept** ("precondition", "redeploy", "immutables"), not by the string `FORCE_SEPOLIA_REDEPLOY`. Do **not** edit dated records (`tasks/review-*.md`, `tasks/worker-prompts/`) — those are history.

**If this task appears to require changing anything outside the permitted surface, stop and report rather than widening scope.**

## Verification — run all of it against `main` as of hand-back

Re-fetch `origin/main` and re-run everything at the moment you hand back, not against the state you started from.

- `bash -n scripts/02-deploy-contracts-sepolia.sh`
- `shellcheck scripts/02-deploy-contracts-sepolia.sh` — report `not-installed` if absent; do not install it.
- `./scripts/test-helpers.sh` — **baseline is 115 PASS** on `wave22-base`, final line `All script helper tests passed.` Report the new count. Unexplained movement is itself a finding.

  **Run it with a temporary, secret-free env file, not bare.** `test-helpers.sh` sources `lib.sh`, which resolves an env file and `mkdir -p`s `$DATA_DIR`. With no local `.env` it falls back to tracked `.env.example`, whose `FORTEL2_ROOT` is `/Users/steveforte/ForteL2` — harmless on that one Mac, but on Linux it dies with `mkdir: cannot create directory '/Users'` (documented in `AGENTS.md` § Cursor Cloud). CI avoids it with a dedicated "Prepare CI .env" step; do the same without clobbering anything:

  ```bash
  TMPENV="$(mktemp -t fortel2-test-env)"
  sed -e "s|/Users/steveforte/ForteL2|$PWD|g" \
      -e "s|/Users/steveforte/src/fortel2/data|${TMPDIR:-/tmp}/fortel2-test-data|g" \
      .env.example > "$TMPENV"
  FORTEL2_ENV="$TMPENV" ./scripts/test-helpers.sh; rm -f "$TMPENV"
  ```

  `FORTEL2_ENV` accepts an absolute path (`lib.sh:11-13`). This recipe was run against `wave22-base` and produced **115 PASS** with no `.env.example` fallback warning. **Do not write a repo-root `.env`** — the operator has one and you would overwrite it.
- **Byte-identity:** regenerate `intent.toml` with `FAULT_GAME_ABSOLUTE_PRESTATE` unset, under identical dummy env, from both `wave22-base` and your branch. `diff` must be empty. Report the command and the result.
- The three behavioural drives (match / mismatch / unset) with exit codes.
- The mutation table.

**You cannot run `op-deployer apply` and must not try.** State exactly what you exercised and what you did not.

## E-F7-10-1 (pre-assigned) — the role-key sweep, report only

`09-start-challenger-sepolia.sh` is the **only** script in the repo that derives an address from a key. These sign with a key whose address is separately configured and never paired: `02-deploy-contracts-sepolia.sh` (this task), `04-start-sequencer-sepolia.sh`, `05-start-batcher-sepolia.sh`, `06-start-proposer-sepolia.sh`, `create-bad-proposal-sepolia.sh`, `deposit-eth-sepolia.sh`, `withdraw-{initiate,prove,finalize}.sh`.

**Do not fix any of them.** For each, report one line: is a mismatch **loud and cheap** (fails immediately, no state lost, operator retries) or **silent and costly** (proceeds, spends, or leaves the system wrong)? That judgement decides whether a follow-up task is worth dispatching, and it needs someone reading the scripts — which you will be.

## E-F7-10-2 (pre-assigned) — the `lib.sh` helper argument

The obvious objection to this brief is that an inline check duplicates `09-start-challenger-sepolia.sh` and a shared `require_key_matches_address` helper in `lib.sh` would be better. That may be right. It is deliberately **not** in scope: it would make the challenger script a refactor candidate, and that script is currently correct and sits on the fault-proof path. **Argue it as E-F7-10-2 with evidence if you believe it, rather than doing it.** If the planner agrees it becomes its own task with its own review.

## Out of scope

- Fixing the other role keys — E-F7-10-1 is report-only.
- `scripts/02-deploy-contracts.sh` (local Anvil). A mismatch there costs one restart against a disposable chain; the guard belongs where the failure is irreversible.
- The preflight prestate-commitment check — **F7-5** (D-0057), still unwritten.
- The negative-control prestate build — **F7-9** (D-0062), still unwritten.
- Anything about `MakeRespected`, the proposer game-type switch, or step 8b's sequence — landed in D-0063 and the docs; this task only guards the key.
- Running the wipe, the redeploy, or the second apply — **not authorized**, and this task does not make them authorized.

## If you think this is wrong

Argue it with evidence rather than implementing it half-heartedly. The judgements most worth challenging are the placement (immediately after `:15`) and the decision to inline rather than share (**E-F7-10-2**). If you find a case where this guard would refuse a legitimate configuration, that is a defect in the brief and it needs to surface before merge, not after a wipe.

## Return this, verbatim

```
TASK:        F7-10 — pair ADMIN_PRIVATE_KEY to ADMIN_ADDRESS before the wipe
LINE OF WORK: agent/f7-10-admin-key-address-pairing (off wave22-base = d7c923d4)
REVIEW ARTIFACT: <PR url>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: bash -n — pass/fail; shellcheck — pass/fail/not-installed;
              test-helpers.sh — pass/fail, PASS count 115 → N, final line;
              byte-identity of intent with the prestate var UNSET — diff vs
              wave22-base (must be empty), command and result;
              match / mismatch / unset drives — exit codes, and confirmation
              that the checksummed-vs-lowercase pair is treated as a match;
              key-leak check — how you established the key is absent from output;
              mutation tests — one row per new assertion, red/not-red, and which
              assertion actually fired
              (run against origin/main as of hand-back)
MIGRATION:   none

SHARED FILES TOUCHED: <path> — what changed, why it is additive
IDENTIFIERS USED:     F7-10, branch, PR number
EXISTING CHECKS MODIFIED: none | <path> — <before> → <after>; why this strengthens
DECISIONS NEEDED:    E-F7-10-1 role-key sweep (required); E-F7-10-2 lib.sh helper
                     (only if you are arguing for it); anything else you hit
RESIDUAL GAPS:       what you could not exercise without op-deployer or a real
                     key; reasoned vs measured; risk stated plainly
```

Disclosure in those last three fields counts as diligence, not failure. A declared assertion change is reviewable; a silent one is how a guarantee dies.
