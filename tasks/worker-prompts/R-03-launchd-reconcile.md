# Worker prompt — R-03: launchd schedule reconcile + drift check script

Copy everything below the line into the worker. **Mid model tier.** Wave 1; R-01/R-05/R-06 run in parallel — allowlists are exclusive. R-05 also edits `README.md` (a different section, Phase 3 funding); touch only your paragraph and do not reflow surrounding text.

---

You are a worker on the ForteL2 repo. Your task card is **`tasks/review-2026-08-05.md` §R-03** — read it in full; it is the spec. This prompt adds the coordination contract.

## Task in one line

The repo says the chain sleeps at 21:00; the installed launchd agent fires at 23:00 and the operator has settled 23:00/04:00 as correct (do not re-ask). Fix the repo to match (plist + two READMEs), then add a read-only `scripts/check-launchd.sh` that detects this drift class permanently.

## Facts you build against (verified 2026-08-05 by the integrator)

- `launchd/com.steve.fortel2-sleep.plist` has `Hour 21` in **dict** form → change to `Hour 23`, **keep dict form** (installed host copy uses single-element array; both are valid — your script must accept both, your edit must not churn the form).
- Wake plist stays `Hour 4`, untouched. Health plist untouched.
- Installed host state (you likely cannot see it — do not fake it): sleep = Hour 23 array-form; wake wrapped by `/Applications/LaunchControl.app/…/fdautil exec /bin/zsh …` (WARN case, not FAIL); stale `~/Library/LaunchAgents/com.steve.fortel2-dev-wake.plist` with no repo counterpart (STALE case).
- `21:00` appears in three places: `launchd/README.md` (schedule table), `README.md` ~line 668 ("Scheduled on the Mac mini (launchd)" paragraph), and the XML **comment** at `launchd/com.steve.fortel2-sleep.plist:21` ("Daily 21:00 local") — update all three. After you're done, `grep -rn "21:00" README.md launchd/` must be empty.

## Script requirements (the card's step 3, sharpened)

- `set -euo pipefail`; source `scripts/lib.sh` for `require_bin` (read-only use — never edit `lib.sh`, it is CODEOWNERS-protected). **macOS bash 3.2 compatible**: no `declare -A`, no `${var,,}`, no `$VAR`-adjacent en-dashes (see commit `ede2ddf`).
- Per agent (`fortel2-health`, `fortel2-sleep`, `fortel2-wake`): normalize repo plist and `~/Library/LaunchAgents/<label>.plist` via `plutil -convert xml1 -o -`, compare `StartCalendarInterval` (dict OR single-element-array both accepted as equal) and the repo-script path inside `ProgramArguments`.
- WARN (not FAIL) when `ProgramArguments` is wrapper-prefixed but ends in the same repo script; print that the wrapper (LaunchControl's `fdautil`) is a third-party dependency.
- FAIL on schedule mismatch, different script path, or repo plist not installed. List `~/Library/LaunchAgents/com.steve.fortel2-*.plist` files with no repo counterpart as `STALE` and print (never run) the `launchctl bootout` + `rm` commands.
- Exit 0 all-match (warnings allowed), 1 otherwise. The script must **never** invoke `launchctl bootout`/`bootstrap`/`kickstart`, `rm`, or `sudo` — it prints, the operator acts.
- Missing `~/Library/LaunchAgents` entirely (e.g. CI or a worker VM) → treat every repo plist as not-installed and FAIL with a clear message; that is correct behavior, and it is why this script is NOT added to CI (do not touch `.github/`).
- Add the card's step-4 note to `launchd/README.md` (repo plists are source of truth; edits need `bootout`+`bootstrap` per H4-004; this script verifies).

## Write allowlist (exclusive)

`launchd/com.steve.fortel2-sleep.plist` · `launchd/README.md` · `README.md` **schedule paragraph only** · `scripts/check-launchd.sh` (new, executable)

Do NOT touch: other plists, `scripts/lib.sh`, `scripts/test-helpers.sh` (R-05 owns its append this wave), `.github/`, `tasks/` (no decisions entry is assigned to this task — escalate via `E-R03-n` only if genuinely needed).

## Contract

- Branch `agent/r03-launchd-reconcile` off tag `wave8-base`. Commits: `fix(launchd): …` / `feat(scripts): …`. Squash-merged third in Wave 1.
- Checks before done (paste verbatim): `bash -n scripts/check-launchd.sh` · `plutil -lint launchd/*.plist` (if `plutil` unavailable in your environment, say so — operator re-lints) · `grep -rn "21:00" README.md launchd/` (expect empty) · `ls -l scripts/check-launchd.sh` showing the executable bit · `grep -nE "launchctl (bootout|bootstrap|kickstart)|(^|[^a-z])rm " scripts/check-launchd.sh` (expect empty).
- Running the script against the real host is **operator verification** — list it in the handoff; do not claim it, and do not simulate its output.
- No merging, no pushing to main, no tags.

## Handoff report — REQUIRED as your final chat message

1. Branch + base tag; `git diff --stat wave8-base..HEAD`
2. Allowlist compliance
3. Card success criteria — each: met / operator-verification-needed, with evidence
4. Checks run + verbatim output
5. `decisions.md` entries (expect: none, or E-R03-n)
6. Anticipated conflicts with siblings (expect: README adjacency with R-05 only)
7. Operator actions needed (expect: run `check-launchd.sh` on the mini; `bootout`+`bootstrap` the corrected sleep plist; remove the stale dev-wake plist the script flags; confirm next 04:00 wake in the log → closes H4-004)
