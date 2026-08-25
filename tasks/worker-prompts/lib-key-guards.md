# Worker brief — lib-key-guards: consolidate key/address pairing into lib.sh + loader-level duplicate detection + preflight hardening

```
DISPATCH · Model: Opus 5 · Order: parallel with docs/deposit-note-and-funding-env and ci/prestate-negative-control; merges LAST (Codex review)
Surface: Claude Code worker session, launched by the operator via the desktop app (branch dropdown)
Baseline: main @ 137e679 · branch feat/lib-key-guard-dedup (pre-created — use it, do not cut your own)
Host: the operator's Mac (darwin) — tests exercise `cast` and BSD `stat`; the harness runs here
Working directory: /Users/steveforte/ForteL2 (app-isolated; leave `main` checked out when you finish and never leave the tree dirty — an hourly launchd agent runs scripts from this checkout)
Landing: PR to main. Codex review will be requested (money-path guards). The reviewer writes the decision entry; do not touch tasks/decisions.md or allocate a decision id.
```

Copy everything below the line into the worker.

---

## Task

Three coupled changes to the guard infrastructure. They are one task because they all touch
the same extraction seams. Trust the repo over this brief — every line number here is a
snapshot.

**Read first:** `scripts/lib.sh` (whole file — it is CODEOWNERS-gated and every script
sources it); `scripts/phase7-preflight.sh` (all 41 lines — note the header's design rules:
content-anchored extraction, COULD-NOT-RUN-is-failure); the F7-10 guard in
`scripts/02-deploy-contracts-sepolia.sh` (~L21) and `scripts/deposit-eth-sepolia.sh` (~L23);
the challenger's inline variant in `scripts/09-start-challenger-sepolia.sh` (~L136–140, note
its comment about `cast wallet address` having no env-var form); the F7-10 test block in
`scripts/test-helpers.sh` (~L2210); decisions D-0064 Finding 4/5, D-0066 Finding 5–6, D-0067
Finding 6 in `tasks/decisions.md` for why each guard exists.

### 1. One pairing helper in lib.sh (dedup of the F7-10 guard)

Today: `require_admin_key_matches_address` is textually duplicated in
`02-deploy-contracts-sepolia.sh` and `deposit-eth-sepolia.sh`, and
`09-start-challenger-sepolia.sh` inlines a third variant for `CHALLENGER_PRIVATE_KEY` /
`CHALLENGER_ADDRESS`. (Earlier records said "three identical copies" — measured today it is
two named copies plus one inline variant. Trust this measurement over older entries.)

Outcome: one parameterized helper in `lib.sh` (e.g. taking the key-var and address-var
*names*; bash 3.2 indirect expansion `${!var}` is available), and all three call sites use
it. The guarded properties that must survive at every call site, byte-for-byte in spirit:

- Refuses **before** any network call or value movement (ordering is the guard).
- Mismatch error names the derived and configured **addresses** and the variable names —
  never any part of the key (the `_f710_key_leaked` property: not the full key, not any
  8-character slice).
- Exit nonzero on mismatch; exit 0 pass-through on match.
- `cast wallet address --private-key` argv exposure stays the accepted bounded class — do
  not invent a new mechanism.

### 2. Loader-level duplicate detection in lib.sh (D-0066 Finding 5)

`lib.sh` does `set -a; source "$FORTEL2_ENV_FILE"` — the last assignment wins, silently, for
every consumer script. D-0066 settled the design: **duplicates belong in the loader; absence
does not** (absence stays deploy-path-only — do not move or generalize the F7-11 absence
guard). Outcome: when lib.sh loads an env file, a **duplicate active assignment of any
variable** (same name assigned twice on uncommented lines) is refused with a hard error
naming the **variable names only** — never values — and a nonzero exit. Commented lines are
ignored. `.env.example` and `.env.sepolia.example` currently contain zero duplicates
(D-0066 Finding 6), so CI stays green without fixture changes.

### 3. phase7-preflight.sh: repoint, fix, chmod, and cover

Your change 1 **breaks** two consumers that awk-extract the function body from the deploy
script's text: `phase7-preflight.sh:34` and the F7-10 test block at `test-helpers.sh:~2212`.
Both must be repointed at the helper's new home in `lib.sh`, keeping the preflight's design
rules: extraction anchored on content, and an extraction that comes up empty reports
`COULD NOT RUN — treat as failure`, never a pass. Prove the fail-closed path still works
(mangle the anchor in a scratch copy → NOT CLEAR TO PROCEED).

While you are in the file, fix its one secret-hygiene defect: line 36 expands
`env $(grep -E '^ADMIN_(PRIVATE_KEY|ADDRESS)=' "$E" ...)` — that puts the operator's
private key on `env`'s **argv**, visible to `ps`, on the operator's real env file. Rework so
the key reaches the guard through the environment, not argv (the file's stdout must continue
to never print a key or env line). Also keep its own duplicate-assignment check (line 15)
consistent with the loader check you added — same definition of "duplicate".

Housekeeping, same file: mode **755** (it is 644 today, so README's bare
`scripts/phase7-preflight.sh` invocation fails with permission denied — D-0068 Finding 1);
confirm the README instruction (~line 844) is runnable as written after the chmod, adjusting
the README line only if strictly needed.

Coverage (append to `test-helpers.sh`, following its idiom — check how existing
cast-dependent and darwin-dependent tests guard themselves, and note `ci.yml`'s runner):

- Helper: match → 0; mismatch → nonzero naming both addresses; key never in output (full or
  any 8-char slice); called before network/spend in all three scripts (ordering assert, the
  shape the existing F7-10 block uses).
- Loader: duplicate active assignment → refused, names-only; commented duplicate → accepted;
  clean file → accepted.
- Preflight (fixture `FORTEL2_ROOT` with a copied deploy script and a fabricated
  `.env.sepolia`, mode 600, well-known throwaway key — never the real env file, which D-0049
  bars you from reading): green path → `ALL CHECKS PASSED`; mismatched key fixture → `NOT
  CLEAR TO PROCEED`; broken extraction anchor → `COULD NOT RUN` and `NOT CLEAR TO PROCEED`.

## Scope

- **Freely changeable:** `scripts/lib.sh`, `scripts/phase7-preflight.sh` (including its mode).
- **Changeable with declared modifications:** `scripts/02-deploy-contracts-sepolia.sh`,
  `scripts/deposit-eth-sepolia.sh`, `scripts/09-start-challenger-sepolia.sh` — call-site
  swap only, nothing else in these proven production scripts; the existing F7-10 test block
  in `scripts/test-helpers.sh` — extraction repoint only, declared with before → after.
- **Additive only:** `scripts/test-helpers.sh` (new coverage at the end; a sibling task also
  appends — do not reorder existing tests), `README.md` (only if the preflight invocation
  line needs adjusting; a sibling task edits a different README section).
- **Do not touch:** `tasks/decisions.md` (reviewer-owned), `.env.sepolia.example` (sibling
  task), `.github/workflows/` (sibling task), `refresh_health.sh`, `scripts/alert-watch.sh`,
  `scripts/resolve-games-sepolia.sh`, `scripts/funding-watch.sh`.
- If the task appears to need anything outside this surface, stop and report.

## The trap

**Every script sources lib.sh — including the hourly bond-recovery agent running unattended
from the operator's checkout.** A loader refusal that misfires (a regex that trips on a
commented line, on `export KEY=`, on whitespace, on a value containing `=`) does not fail
CI — it bricks `resolve-games-sepolia.sh` at the next :00 run and every other script
simultaneously, silently from the operator's point of view until the new alert-watch notices
the logs went quiet hours later. The refusal must be surgical and the error message must say
exactly which variable is duplicated (names only). Test the accept paths as hard as the
refuse paths.

Second trap: the guarded scripts are **proven and value-moving**. The dedup must not change
ordering (guard before spend), and a behavioral difference between the old challenger inline
variant and the new shared helper — different env var expectations, different exit code,
different message contract that `test-helpers` asserts — is a regression even if it looks
like an improvement. Diff the behavior, not just the text.

## What must survive

- All existing `test-helpers.sh` tests: **263 PASS 0 FAIL** on main today. The F7-10
  extraction repoint is the only permitted modification, declared with before → after and
  why it is refactor-following, not weakening.
- `phase7-gate-parity.sh`: 60 PASS, exit 0.
- Preflight's contract: read-only, offline, never prints a key or env-file line, COULD-NOT-RUN
  is failure, `ALL CHECKS PASSED` only when every check ran and passed.
- The #145 tripwire; the F7-11 guards in the deploy script (untouched).

## Verification — run at hand-back against main merged in

```
bash -n scripts/lib.sh scripts/phase7-preflight.sh scripts/02-deploy-contracts-sepolia.sh scripts/deposit-eth-sepolia.sh scripts/09-start-challenger-sepolia.sh
./scripts/test-helpers.sh          # 263 + N additive PASS, 0 FAIL — state N; unexplained movement is a finding
./scripts/phase7-gate-parity.sh    # 60 PASS, exit 0
ls -l scripts/phase7-preflight.sh  # -rwxr-xr-x, and the mode change is IN the commit (git ls-files -s shows 100755)
```

Do not run the deploy, deposit, or challenger scripts against Sepolia, and do not read the
operator's `.env.sepolia`. The operator's post-merge shakeout (their step, not yours — state
it in RESIDUAL GAPS): one ordinary script run (e.g. `status.sh`) to prove the loader accepts
the real env file, and one `phase7-preflight.sh` run to prove the repointed gate passes live.

## Out of scope, with reasons

- Generalizing the **absence** guard to the loader — D-0066 Finding 6: it would refuse the
  example templates' intentionally empty placeholders.
- Any behavior change to the F7-11 duplicate/absence guards inside the deploy script.
- The FUNDING_* templating and README deposit sentence (sibling task A); the prestate
  workflow (sibling task C).

## Return format — verbatim

```
TASK:        lib-key-guards — pairing helper dedup + loader duplicate detection + preflight hardening
LINE OF WORK: feat/lib-key-guard-dedup
REVIEW ARTIFACT: <PR URL>
STATUS:      complete | complete-with-caveats | blocked
VERIFICATION: <each check named> — pass/fail, with counts (against main merged in at hand-back)
SHARED FILES TOUCHED: <path> — what changed, why it is additive   (or: none)
EXISTING CHECKS MODIFIED: <path> — <before> → <after>; why this strengthens rather than weakens (or: none)
DECISIONS NEEDED:    none | <question + interim choice>
RESIDUAL GAPS:       what was verified by hand vs automatically; what only the operator can prove live; risk stated plainly
```

If you believe the consolidation itself is wrong — that three proven scripts should keep
their own copies, or the loader is the wrong layer — argue it with evidence in the report
rather than implementing it half-heartedly. D-0066 already argued the loader placement once;
new evidence beats old reasoning.
