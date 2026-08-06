# Worker prompt — R-04: `rail-interface.json` drift guard in CI

Copy everything below the line into the worker. **Mid model tier.** Wave 3. **Run this one first, alone** — R-09 also appends to a file you touch; running them serially removes the only conflict in this wave.

---

You are a worker on the ForteL2 repo. Your task card is **`tasks/review-2026-08-05.md` §R-04** — read it in full; it is the spec. This prompt adds the coordination contract and the current state of the file you are guarding.

## Task in one line

`deployments/rail-interface.json` is the contract SettlementOS builds against, and nothing stops it drifting from `deployments/sepolia/deployments.json`. Write an **offline** checker, wire it into CI, and add a test-helpers case that proves it catches a corrupted address.

## State you are building against (verified at `wave10-base`)

- The file is now **v2** (merged R-02, D-0020): it gained `availability`, `l2Metadata`, `openQuestions`, and `replica.readRpcUrl` is `null`. Addresses and chain IDs are unchanged from v1.
- The five bridge proxies live under `networks["fortel2-sepolia"].bridge.*`; their counterparts in `deployments/sepolia/deployments.json` are the capitalised keys `OptimismPortalProxy`, `L1StandardBridgeProxy`, `L1CrossDomainMessengerProxy`, `SystemConfigProxy`, `DisputeGameFactoryProxy`. Compare **lowercased** — the two files differ in case today and that is not drift.
- Chain IDs to assert: `fortel2-sepolia` 852 / 11155111 against `.env.sepolia.example`; `fortel2-local` 901 against `.env.example` (`L2_CHAIN_ID`/`L1_CHAIN_ID` in each).
- `docs` values that are repo-relative (no `://`) must exist on disk. Note `l2Metadata.rollupConfig` points at `deployments/sepolia/.deployer/rollup.json` — **check whether that path actually exists before asserting on it**; if it does not, either extend the existence check to `l2Metadata` paths and report the miss as a finding, or scope the check to `docs` only and say so in your handoff. Do not silently skip it.
- `updated` must parse as `%Y-%m-%d`.

## Hard constraints

- **Offline only.** No `cast`, `curl`, `wget`, or any network call — this runs on a CI runner with no Sepolia access and no `.env.sepolia`. Verification: `grep -cE 'cast |curl|wget' scripts/rail-interface-check.sh` → 0.
- `set -euo pipefail`; source `scripts/lib.sh` only for helpers that do not require env (never edit it — CODEOWNERS). macOS bash 3.2 compatible: no `declare -A`, no `${var,,}` (use `tr '[:upper:]' '[:lower:]'`).
- Print one `PASS`/`FAIL` line per check; exit non-zero if any FAIL. Target ≥10 PASS lines on a clean tree.
- CI: add a `Rail interface check` step to the **`guardrails`** job in `.github/workflows/ci.yml`, immediately after `Script helper tests`. **Do not touch any pinned action SHA.**
- `scripts/test-helpers.sh`: append your case at the **end**, following the existing style — copy the real JSON to a temp dir, corrupt one proxy address, assert non-zero exit; then assert the unmodified repo file exits zero. Clean up your temp dir.

## Write allowlist (exclusive)

`scripts/rail-interface-check.sh` (new, executable) · `.github/workflows/ci.yml` (one appended step) · `scripts/test-helpers.sh` (append at end only)

Do NOT touch: `deployments/` (the file you check is read-only to you), `scripts/lib.sh`, `tasks/`. Needs elsewhere → `E-R04-<n>` in your handoff.

## Contract

- Branch `agent/r04-rail-drift-guard` off tag `wave10-base`. Commits: `test(rail): …` / `ci: …`. Merged first in Wave 3.
- Checks before done (paste verbatim): `bash -n scripts/rail-interface-check.sh` · `./scripts/rail-interface-check.sh; echo exit=$?` showing ≥10 PASS and exit 0 · the corrupted-address demo (flip one hex digit in a temp copy) exiting 1 and **naming the key** · `grep -cE 'cast |curl|wget' scripts/rail-interface-check.sh` → 0 · `./scripts/test-helpers.sh` ending `All script helper tests passed.` · `git diff wave10-base..HEAD -- .github/workflows/ci.yml` showing only the added step.
- No merging, no pushing to main, no tags.

## Handoff report — REQUIRED as your final chat message

1. Branch + base tag; `git diff --stat wave10-base..HEAD`
2. Allowlist compliance
3. Card success criteria — each: met, with evidence
4. Checks run + verbatim output
5. `decisions.md` entries (expect: none; escalations in-handoff only)
6. Anticipated conflicts with siblings (R-09 appends nothing to your files if run serially — note if you saw otherwise)
7. Operator actions needed (expect: none — CI proves it on the next push)
