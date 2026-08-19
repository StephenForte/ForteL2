# Worker prompt — F7-2b: CheckRequired flags for the Sepolia challenger start script

Copy everything below the line into the worker. **Mid model tier.** Same branch / same PR as F7-2.

---

DISPATCH · Model: mid · Order: after F7-2 review, same PR
Baseline: existing branch `agent/f7-2-challenger-start-script` (PR #87). Rebase onto current `origin/main` if needed (#86 is docs-only).
Host: any — prefer a host with `bin/op-challenger` so you can prove CheckRequired; if the binary is absent, `bash -n` + reading and say so. Still no `.env.sepolia`, no live Sepolia spend, **do not `start_bg` the challenger**.
Working directory: main checkout (single delegate)
Landing: additional commit(s) on PR #87; do not open a second product PR

---

You are continuing F7-2 on ForteL2. Planner review of #87 (and Codex P1) is: the documented start command cannot reach `starting monitoring` because this build's `CheckRequired` rejects the current flag set.

**Proved on the pinned binary** (`untagged-da197e45`), dummy `http://127.0.0.1:1`, no daemonize:

1. Current F7-2 flags + `--game-types=permissioned` → `flag l1-beacon is required` (exit 1)
2. Same + dummy `--l1-beacon` → `flag network or rollup-config/cannon-rollup-config and l2-genesis/cannon-l2-genesis is required` (exit 1)
3. Same + `--cannon-rollup-config` / `--cannon-l2-genesis` from the deploy tree → CheckRequired **passes**; next error is dummy L1 chain-id (expected)

Chain 852 is not in the superchain registry. **Do not pass `--network`.**

## What to change

### 1. `scripts/09-start-challenger-sepolia.sh`

- Fail closed if `L1_BEACON_URL` is empty, naming the env var and that this is a CheckRequired gate, **not** a DA change (D-0037 / D-0053). Then pass `--l1-beacon="$L1_BEACON_URL"`. Redact before any echo.
- For Cannon-family types that this build's `CheckCannonFlags` covers (`cannon`, `permissioned`): pass `--cannon-rollup-config` and `--cannon-l2-genesis` pointing at `$DEPLOY_DIR/rollup.json` and `$DEPLOY_DIR/genesis.json`. **Canonicalize both to absolute paths** before `start_bg` (the daemonizer `chdir`s to `/`). Fail closed if either file is missing.
- For `cannon-kona` / `super-cannon-kona`: the matching `--cannon-kona-rollup-config` / `--cannon-kona-l2-genesis` (same files). Super-cannon-kona also wants `--supernode-rpc` in this build — if you cannot map that confidently, fail with a clear message rather than guessing; say so in the handoff.
- Keep every existing fail-closed path (key/address match, trace type, prestate, three RPCs, balance, D-0052 preflight, env-var key for the daemon).
- Codex P2: after resolving `CHALLENGER_PRESTATE`, require `[[ -f && -r ]]`, not only `-f`.

### 2. README subsection "Phase 7 challenger (US-073)" — additive sentences only

State that `L1_BEACON_URL` is required for this binary's CheckRequired, that it does not turn on blob DA, and that rollup/genesis come from the Sepolia deploy tree.

### 3. `.env.sepolia.example` — additive comment only next to the existing `# L1_BEACON_URL=` line

Note that the challenger start script requires it (CheckRequired), while op-node still uses `--l1.beacon.ignore` (D-0037). Do not invent a URL. Do not uncomment a fake value.

## Scope

Freely changeable: `scripts/09-start-challenger-sepolia.sh`.
Additive only: README Phase 7 challenger subsection; the `L1_BEACON_URL` comment in `.env.sepolia.example`.
Do not touch: `scripts/lib.sh`, `scripts/06-start-proposer-sepolia.sh`, `stop-all-sepolia.sh`, `status.sh` (already done), `tasks/prd-phase-7-fault-proofs.md`, `tasks/decisions.md`.

If you think the task needs anything else, stop and report.

## Verification

Re-run F7-2's syntax/helpers/grep checks. If `bin/op-challenger` exists, re-run probes 10–13 equivalent: after your change, probe 10-equivalent (now including beacon + rollup/genesis from a temp copy of those two files) must **not** print `flag l1-beacon is required` or `flag network or rollup-config`. Dummy L1 chain-id failure is success for CheckRequired. Do not `start_bg`. Do not use live Sepolia.

Return the F7-2 handoff format. Status complete-with-caveats if you could not run the binary.

## Unresolved (do not settle)

Obtaining the absolute prestate (D-0052). Whether the post-wipe game has a non-zero VM. Trace-type default.
