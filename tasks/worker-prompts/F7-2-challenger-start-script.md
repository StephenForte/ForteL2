# Worker prompt — F7-2: `op-challenger` Sepolia start script (US-073)

Copy everything below the line into the worker. **Mid model tier** — shell only, no Go, and the flag surface is supplied verbatim below rather than derived. Mid rather than cheap because the script gates a process that spends real Sepolia gas and signs with a role key, and because the preflight logic below is the part most likely to be written plausibly-but-wrong. Wave 1 this round; standalone, no parallel siblings.

---

DISPATCH · Model: mid · Order: wave 1, standalone (no siblings, no blockers)
Baseline: branch `agent/f7-2-challenger-start-script` off tag `wave14-base`
Host: any — **no live RPC, no `.env.sepolia`, no Sepolia keys, and `op-challenger` is not installed in your environment.** All verification is `bash -n`, `shellcheck` if available, and reading. Do not attempt to run the challenger.
Working directory: main checkout (single delegate this round)
Landing: PR into `main`, squash-merge after review; closes the code-readiness half of US-073's "Native `op-challenger` process documented in README (start/stop, logs, no keys in git)"

---

You are a worker on the ForteL2 repo (`github.com/StephenForte/ForteL2`). This is prep work for Phase 7 (`tasks/prd-phase-7-fault-proofs.md`), specifically **US-073**: "Stock `op-proposer` posts at least one accepted game on the new factory; native `op-challenger` process documented in README (start/stop, logs, no keys in git); challenger does **not** attack the valid game."

**You are writing the start script, not running it.** The exercise happens after the Phase 7 network wipe, operator-only. There is nothing meaningful to run this against today — the current deployment is pinned and about to be replaced.

## Read before starting (governing material — trust these over this brief if they conflict)

- `tasks/prd-phase-7-fault-proofs.md` — US-073 and the Operator sequence table.
- `scripts/06-start-proposer-sepolia.sh` — **the pattern to follow.** `source lib.sh`, `require_sepolia_env`, `refuse_foundry_defaults_unless_local_l2`, `require_min_balance_eth`, `deployments_json_path`, `wait_for_rpc`, `start_bg`, the trailing "Known-good:" log hint. Your script is a sibling of this one.
- `scripts/stop-all-sepolia.sh` — the stop list you must extend.
- `scripts/status.sh` — the `procs=(…)` array you must extend.
- `scripts/lib.sh` — **read-only, never edit.** `start_bg <name> <cmd> [args…]` daemonizes via double-fork, writes `$PID_DIR/<name>.pid`, logs to `$LOG_DIR/<name>.log`, and returns 0 if the pid is already alive.
- `scripts/create-bad-proposal-sepolia.sh` (merged in F7-1) — the most recent example of an isolated, opt-in Sepolia script with an argument allowlist. Read it; the same discipline applies here.
- `tasks/decisions.md` D-0046, D-0049, D-0050, D-0052.

## Verified environment facts (checked at time of writing — re-verify, don't assume)

- `op-challenger` and `cannon` are now built and symlinked into `bin/` (operator did this before dispatch). `scripts/lib.sh` already prepends `$BIN_DIR` to `PATH`, so `require_bin op-challenger` works.
- `scripts/04-start-sequencer-sepolia.sh:41` sets `--http.api=eth,net,web3,debug,txpool,admin,miner` and `--gcmode=archive`. op-challenger's `--l2-eth-rpc` requires the **eth and debug** namespaces, so the existing loopback op-geth on `$L2_RPC_URL` already satisfies it. Do not add a new EL.
- `scripts/sepolia-fund-check.sh:50` already prints a `CHALLENGER` row (advisory only — it does not count toward that script's exit status).
- `.env.sepolia.example:68-69` already declares `CHALLENGER_ADDRESS` / `CHALLENGER_PRIVATE_KEY`.
- No `scripts/09-*` exists. **`09` is your pre-assigned number** — use `scripts/09-start-challenger-sepolia.sh`. Do not scan the directory and pick your own; do not renumber anything.

## The trap (two of them)

**1. The role key is the inverse of F7-1.** The bad-proposal tool (F7-1) signs with `PROPOSER_PRIVATE_KEY` because only the proposer role may `create()` a game. The **challenger** is a different address (`[chains.roles] challenger` in `deployments/sepolia/.deployer/intent.toml`) and this script must sign with **`CHALLENGER_PRIVATE_KEY`**, never `PROPOSER_PRIVATE_KEY`. Using the proposer key here would have the honest-party process signing as the party it is supposed to be disputing — it would either revert or, worse, succeed and make the exercise meaningless. Get this right in code, in every echo, and in the README.

**2. The deployed game may have no VM wired up — fail loudly before spending gas.** Verified on the current pinned deployment (2026-08-19, public Sepolia RPC), reading the impl that `gameImpls(1)` returns:

```
maxClockDuration()  = 10          <- matches intent.toml, proves these reads work
clockExtension()    = 5           <- likewise
vm()                = 0x0000...0000
absolutePrestate()  = 0x0000...0000
gameType()          = 0
(bogus selector)    -> reverts    <- control: the zeros above are real returns
```

`MipsImpl` and `PreimageOracleImpl` are deployed as standalone contracts, but the game impl does not appear to reference them. If the post-wipe deployment has the same shape, `op-challenger` with any Cannon-family trace type has no VM to step and no prestate to anchor against. Discovering that by watching op-challenger crash — *after* an irreversible network-wide wipe — is the outcome this script exists to prevent. See **Preflight** below. Do not treat this as settled: it is a finding about the *old* deployment, and the post-wipe values must be read fresh.

## What to build

### 1. `scripts/09-start-challenger-sepolia.sh` (new, executable)

Follows `06-start-proposer-sepolia.sh`'s conventions. Requirements:

- `set -euo pipefail`; `source "$SCRIPT_DIR/lib.sh"`; `require_bin op-challenger`; `require_bin jq`; `require_bin cast`; `require_sepolia_env`.
- `refuse_foundry_defaults_unless_local_l2 "${CHALLENGER_PRIVATE_KEY:-}" "CHALLENGER_PRIVATE_KEY"`.
- Hard-require `CHALLENGER_PRIVATE_KEY` non-empty; error clearly naming that it is **not** `PROPOSER_PRIVATE_KEY` if missing.
- **Verify the key actually belongs to the challenger address, before anything else touches the network.** Neither existing helper does this: `refuse_foundry_defaults_unless_local_l2` only matches the key against a hardcoded list of Anvil default keys (`scripts/lib.sh:250-268`), and `require_min_balance_eth` independently checks a balance at whatever address you hand it. So dropping `PROPOSER_PRIVATE_KEY`'s value into the `CHALLENGER_PRIVATE_KEY` slot passes both checks and the daemon then signs as the proposer — silently, with no error, invalidating the exercise (trap 1). Derive the address from the key and compare, case-insensitively, against `CHALLENGER_ADDRESS`; exit non-zero on mismatch with a message naming both the derived and the configured address:

  ```
  derived="$(cast wallet address --private-key "$CHALLENGER_PRIVATE_KEY")"
  # lowercase both sides before comparing — cast returns EIP-55 checksummed,
  # .env.sepolia may hold either case
  ```

  Note in a code comment that this is the one place the key touches `argv`, for a single short-lived `cast` process — `cast wallet address` has no env-var form (verified: `ETH_PRIVATE_KEY` is not accepted). That bounded exposure is deliberately accepted to close a silent-wrong-signer failure; the long-running daemon still gets the key via `OP_CHALLENGER_PRIVATE_KEY`, never `argv`.
- `require_min_balance_eth "$CHALLENGER_ADDRESS" "${SEPOLIA_CHALLENGER_MIN_ETH:-0.15}" "CHALLENGER"` — the challenger posts bonds and moves, so it needs gas like the proposer does. Run this **after** the key/address match above, so a mismatched key fails on identity rather than on a confusing balance error.
- Resolve `DisputeGameFactoryProxy` via `deployments_json_path` + `jq`, same as `06-start-proposer-sepolia.sh` (including its "not found" error path that dumps `jq keys`).
- `wait_for_rpc` on **all three** endpoints the daemon is configured with — `$L1_RPC_URL`, `$L2_NODE_RPC_URL`, **and `$L2_RPC_URL`**. Waiting only on op-node is not enough: op-node can be answering while the loopback op-geth behind `--l2-eth-rpc` is down, and the script would then launch a challenger that is unhealthy from its first tick instead of failing before `start_bg`.
- **Keep the key out of the daemon's `argv`.** `06-start-proposer-sepolia.sh` passes `--private-key=…` on the command line, which puts the secret in `ps` output. `op-challenger` reads every flag from an env var, so `export OP_CHALLENGER_PRIVATE_KEY="$CHALLENGER_PRIVATE_KEY"` and **do not** pass `--private-key`. This is a deliberate improvement on the existing pattern, not an oversight — note it in your handoff. (Do not retrofit the other scripts; out of scope.)
- Launch via `start_bg op-challenger op-challenger <flags…>` so pid/log handling matches the rest of the stack.
- Print a trailing hint line in the style of the proposer script's `echo "Known-good: …"`, naming what a healthy first log looks like and where the log is.

**Flags — from the real `op-challenger --help` on the operator's build (`untagged-da197e45`). Use exactly these names; do not invent or abbreviate:**

| Flag | Value |
|---|---|
| `--l1-eth-rpc` | `$L1_RPC_URL` |
| `--rollup-rpc` | `$L2_NODE_RPC_URL` |
| `--l2-eth-rpc` | `$L2_RPC_URL` (eth+debug namespaces; already satisfied — see facts above) |
| `--game-factory-address` | resolved factory |
| `--game-types` | `$CHALLENGER_TRACE_TYPE` — **operator-supplied, no default** (see Unresolved below) |
| `--datadir` | `$DATA_DIR/challenger` (create with `mkdir -p`) |
| `--cannon-bin` | `$BIN_DIR/cannon` — only when the trace type is a Cannon family type |
| `--l1-rpc-kind` | `${SEPOLIA_L1_RPC_KIND:-standard}` (valid: `alchemy, quicknode, infura, parity, nethermind, debug_geth, erigon, basic, any, standard`; the operator is on QuickNode, hence the knob) |
| `--num-confirmations` | `${SEPOLIA_CHALLENGER_CONFIRMATIONS:-3}` (that is op-challenger's own default) |
| `--log.level` | `${CHALLENGER_LOG_LEVEL:-info}` |

Prestate flags are **trace-type dependent** and the flag names differ per family — `--cannon-prestate` / `--cannon-prestates-url` for `cannon`, `--cannon-kona-prestate` / `--cannon-kona-prestates-url` for `cannon-kona`, plus a generic `--prestates-url`. Do **not** hardcode one family. Accept `CHALLENGER_PRESTATE` (local path) and `CHALLENGER_PRESTATES_URL` (base URL) from the environment and map them onto the correct flag name for the configured trace type. If the trace type is a Cannon family type and **neither** is set, fail with a message that names both env vars and points at the README section. If a local path is given, verify the file exists **and resolve it to an absolute path** before building the flag. This is not cosmetic: `start_bg`'s daemonizer runs `os.chdir("/")` (`scripts/lib.sh:140`) before `execvp`, so a relative `CHALLENGER_PRESTATE` would pass your existence check in the caller's working directory and then resolve against `/` inside the daemon — op-challenger fails to load its prestate, and the pid/log indirection makes that a slow thing to diagnose. **Settled: canonicalize, do not reject.** Resolve a relative path against the caller's working directory (that is what an operator typing `./prestate.bin` expects), then pass the absolute result to the flag, and echo the resolved path so what the daemon actually receives is visible in the start output. Fail only when the resolved path does not exist. Do not leave this as a choice — the acceptance list below is written to match this behaviour.

`--game-window` is left at op-challenger's 672h default deliberately: it only widens how far back the challenger looks for games, and the new 2h `maxClockDuration` (D-0049) makes a shorter window pointless to tune. Do not add a flag for it.

### 2. Preflight (in the same script, before `start_bg`)

Before launching, use `cast call` against `$L1_RPC_URL` to read, from the factory:

- `gameImpls(uint32)(address)` for the configured game type, and fail if it is the zero address (nothing registered for that type).
- On that impl: `vm()(address)` and `absolutePrestate()(bytes32)`. If **either** is zero, **exit non-zero** with a message stating plainly that the deployed game has no VM / no absolute prestate, that `op-challenger` cannot play a Cannon-family game against it, and citing `tasks/decisions.md` D-0052.

Provide `CHALLENGER_SKIP_PREFLIGHT=1` as a documented escape hatch, because the preflight itself is unrunnable in your environment and a subtly wrong `cast` invocation must not be able to permanently block a legitimate start. Echo a clear warning when it is bypassed.

Map the game type for `gameImpls` from the configured trace type (`permissioned` → `1`, `cannon` → `0`); for any trace type you cannot map confidently, skip the `gameImpls` lookup with an explicit echo rather than guessing a number — and say so in your handoff.

### 3. `scripts/stop-all-sepolia.sh` — additive

Add `op-challenger` to the stop loop. **Order matters**: it must stop before `op-node` / `op-geth`, since it dials them. The existing comment explains the same reasoning for `l2-rpc-filter`; match that style. One-line change to the `for name in …` list.

### 4. `scripts/status.sh` — additive

Add `op-challenger` to the reported processes. Follow the existing conditional pattern used for `l2-rpc-filter` (only report it when relevant/running) rather than making a stopped challenger look like a failure in normal operation.

### 5. `README.md` — new subsection only

A "Phase 7 challenger (US-073)" subsection covering: start/stop commands, where the log lives, the challenger-vs-proposer key distinction, the two prestate env vars, the preflight and its bypass, and that no keys are in git. Match the surrounding style. **Append a new subsection; do not edit or reflow existing sections.**

## Scope

**Freely changeable:** `scripts/09-start-challenger-sepolia.sh` (new).
**Additive only** (other work touches these; keep changes to the single lines described): `scripts/stop-all-sepolia.sh`, `scripts/status.sh`, `README.md` (new subsection only).
**Not to be touched:**
- `scripts/lib.sh` — privileged, never edited by any task.
- `scripts/06-start-proposer-sepolia.sh`, `scripts/create-bad-proposal-sepolia.sh` — read as patterns, do not modify. Do not "fix" the proposer script's argv key handling.
- `proposer/`, `batcher/`, `derivation/` — no Go changes in this task.
- `tasks/prd-phase-7-fault-proofs.md`, `tasks/decisions.md` — planner-owned. Propose additions in your handoff as `E-F7-2-<n>`.
- `.env.sepolia.example` — the challenger vars already exist there; if you believe new names need documenting, propose it in the handoff instead of editing.
- `.github/workflows/ci.yml` — should need no change.

If the task appears to need anything outside this list, stop and report rather than widening scope.

## What must survive

- Nothing may start the challenger automatically. It must **not** be added to `start-all-sepolia.sh` or any launchd plist. Grep for your script name across `scripts/` and `launchd/` before hand-back and confirm the only hit is the script itself.
- `scripts/test-helpers.sh` must still pass unchanged.
- The script must fail closed. Every one of these exits non-zero **before** `start_bg`: missing key; **key that does not derive to `CHALLENGER_ADDRESS`**; missing trace type; missing prestate when the trace type needs one; **a `CHALLENGER_PRESTATE` that does not resolve to an existing file** (a relative path is canonicalized, not rejected — see above); unfunded challenger; **any of the three RPCs unreachable**; failed preflight.
- **The long-running daemon's `argv` must contain no secret** — `op-challenger` gets its key via `OP_CHALLENGER_PRIVATE_KEY`, never `--private-key`. The single short-lived `cast wallet address --private-key …` call specified above is the one deliberate, documented exception to this, because that tool has no env-var form and the check it enables (wrong-signer detection) is worth more than a milliseconds-long exposure; it is not a violation of this rule. No secret may reach any log line or any echo, without exception. Pass RPC URLs through `redact_rpc_url` before echoing, consistent with the rest of `scripts/`.

## Verification (run against `wave14-base` at hand-back, restated after any rebase)

```
bash -n scripts/09-start-challenger-sepolia.sh
bash -n scripts/stop-all-sepolia.sh
bash -n scripts/status.sh
shellcheck scripts/09-start-challenger-sepolia.sh   # if available; report if not installed
./scripts/test-helpers.sh                            # expect: All script helper tests passed.
grep -rn "09-start-challenger-sepolia" scripts/ launchd/ .github/ ; # expect: only the script itself
```

You cannot execute the script — no `op-challenger`, no `.env.sepolia`, no RPC. That is expected and is not a gap to engineer around. **Do not add a mock op-challenger, a fake RPC, or test scaffolding for it.** State plainly in your handoff which behaviours are verified by syntax check and reading versus which are unexecuted.

## Out of scope

- Running the challenger, or the US-073/074 exercise itself (operator-only, post-wipe).
- Obtaining the absolute prestate — genuinely unresolved and tracked separately; the script only consumes it.
- Retrofitting `--private-key` argv handling in the batcher/proposer scripts.
- Any `op-dispute-mon` integration.
- Changing acceptance checkboxes in the Phase 7 PRD — the planner does that.

## Unresolved decisions — flag these back, do not settle them silently

1. **Trace type.** `--game-types` valid options on this build are `alphabet, cannon, cannon-kona, permissioned, fast, super-cannon-kona, zk`. The correct value depends on what the **post-wipe** deployment actually registers, which does not exist yet. Make it `CHALLENGER_TRACE_TYPE` with **no default**, failing clearly when unset and listing the valid options. Do not guess `permissioned` just because the contract is named `PermissionedDisputeGameImpl` — note in your handoff that the old deployment's impl reported `gameType() == 0`, which is `cannon`, not `permissioned`, and that this contradiction is unresolved.
2. **Preflight strictness.** Specified above as fail-closed with `CHALLENGER_SKIP_PREFLIGHT=1`. If you think advisory-warn is the better default given you cannot test the `cast` calls, argue it in the handoff rather than quietly switching.

## Invite objection

If you think this should be a `run-trace` invocation rather than the default `op-challenger` run mode, or that the preflight belongs in a separate script, say so with reasoning instead of implementing something you can see is wrong. The `--help` output shows subcommands (`list-games`, `move`, `resolve`, `run-trace`) — if one of them serves US-073's "watch, don't attack" goal better than the default daemon, that is a real argument worth making.

## Required return format

```
TASK:        F7-2 — op-challenger Sepolia start script
LINE OF WORK: agent/f7-2-challenger-start-script (off wave14-base)
REVIEW ARTIFACT: <PR URL>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: bash -n (3 files) — pass/fail; shellcheck — pass/fail/not-installed;
              test-helpers.sh — pass/fail with final line; auto-start grep — what it returned
              (run against wave14-base as of hand-back)
MIGRATION:   none

SHARED FILES TOUCHED: stop-all-sepolia.sh / status.sh / README.md — exact lines, why additive
IDENTIFIERS USED:     F7-2, script number 09, branch agent/f7-2-challenger-start-script
EXISTING CHECKS MODIFIED: none expected — list any with before/after/why
DECISIONS NEEDED:    trace-type default; preflight strictness; game-type→number mapping
                     you could not make confidently; any E-F7-2-n
RESIDUAL GAPS:       everything unexecuted (no op-challenger/RPC/keys) — say exactly what
                     was checked by syntax/reading vs never run
```
