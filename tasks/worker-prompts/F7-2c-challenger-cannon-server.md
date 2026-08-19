# Worker prompt — F7-2c: fail closed on `cannon` / `cannon-kona` unless a pre-image server is supplied (US-073)

Copy everything below the line into the worker. **Mid model tier** — shell only and a small diff, but the property at stake is fail-closed on a process that spends real Sepolia gas, and the review that created this task found the current script reporting success for a daemon that had already died. Wave 1 this round; standalone, no parallel siblings.

---

DISPATCH · Model: mid · Order: wave 1, standalone (no siblings, no blockers)
Baseline: branch `agent/f7-2c-challenger-cannon-server` off tag `wave16-base`
Host: any — **no live RPC, no `.env.sepolia`, no Sepolia keys, and `op-challenger` is not installed in your environment.** All verification is `bash -n`, `shellcheck` if available, and `scripts/test-helpers.sh`. Do not attempt to run the challenger.
Working directory: main checkout (single delegate this round)
Landing: PR into `main`, squash-merge after review. Closes the fail-open gap found reviewing #87; **must land before US-071/072 (the network wipe)**.

---

You are a worker on the ForteL2 repo (`github.com/StephenForte/ForteL2`). This is prep work for Phase 7 (`tasks/prd-phase-7-fault-proofs.md`), specifically **US-073**. The start script already exists — `scripts/09-start-challenger-sepolia.sh`, merged as #87 (F7-2 + F7-2b). Your job is one behavioural gap in it.

**You are editing the start script, not running it.** The exercise happens after the Phase 7 network wipe, operator-only.

## Read before starting (governing material — trust the repository over this brief, including over its confident assertions)

- `tasks/decisions.md` **D-0054** — the decision this task implements. Also D-0052 (no VM / no prestate on the pinned impl) and D-0053 (the CheckRequired flags F7-2b added).
- `scripts/09-start-challenger-sepolia.sh` — the file you are changing. Read all of it before touching anything.
- `scripts/test-helpers.sh` — the assertion harness you must extend. Note the house style: structural `grep`/`awk` assertions over script text (see the `P7-0-A` batcher block at the end) plus `assert_true` / `assert_false` for pure functions.
- `scripts/lib.sh` — **read-only, never edit.** `start_bg <name> <cmd> [args…]` daemonizes via double-fork and **chdirs to `/`**, which is why every path handed to the daemon must be absolute.
- `README.md` § "Phase 7 challenger (US-073)".
- `tasks/prd-phase-7-fault-proofs.md` — US-073 and the Operator sequence table.

## Pre-assigned identifiers — use these exactly, do not derive your own

- Task id **F7-2c**. Decision record **D-0054** (already written; do not add a decision entry, do not renumber).
- Branch **`agent/f7-2c-challenger-cannon-server`**, cut from tag **`wave16-base`**.
- Environment variable names, exactly: **`CHALLENGER_CANNON_SERVER`** and **`CHALLENGER_KONA_SERVER`**. These were chosen by the operator; do not rename them to match the binary's own `OP_CHALLENGER_*` names, and do not collapse them into one variable.
- Escalation ids, if you need them: **E-F7-2c-1**, **E-F7-2c-2**.

These override any "find the highest and add one" convention in the repo. If one of them looks wrong, stop and report rather than picking a different one.

## Evidence (measured 2026-08-19 against the pinned binary `untagged-da197e45-1782514747`)

Probes ran in a throwaway clone with `start_bg` stubbed to capture the wrapper's real argv, which was then fed to the real binary with dummy `http://127.0.0.1:1` endpoints and a throwaway key.

| `CHALLENGER_TRACE_TYPE` | Wrapper today | Binary, given the wrapper's argv |
|---|---|---|
| `permissioned` | builds argv, prints "started" | CheckRequired **passes** (next failure is the dummy L1) |
| `alphabet` / `fast` / `zk` | builds argv, prints "started" | CheckRequired **passes** |
| `cannon` | builds argv, prints **"Sepolia challenger started"** | `failed to setup: flag cannon-server is required` — dies immediately |
| `cannon-kona` | builds argv, prints **"Sepolia challenger started"** | `failed to setup: flag cannon-kona-server is required` — dies immediately |
| `super-cannon-kona` | **refused, exit 1** | n/a |

Supplying a stub path closes it completely — this is the whole gap:

```
--game-types=cannon      … --cannon-server=/bin/echo
  → err="failed to setup: … could not fetch L1 chain ID: Post \"http://127.0.0.1:1\": connection refused"

--game-types=cannon-kona … --cannon-kona-server=/bin/echo
  → err="failed to setup: … could not fetch L1 chain ID: Post \"http://127.0.0.1:1\": connection refused"
```

Two consequences to keep in mind. The binary does **not** validate that path at flag time — `/bin/echo` was accepted — so the wrapper has to do its own check. And nothing valid can be supplied on the operator's host today: `op-program` is gone from the pinned monorepo, and `kona-host`, `kona`, `cargo` and `rustc` are all absent from `PATH`. The unset branch is the branch that will actually run.

The binary's own help, for reference:

```
--cannon-server value        ($OP_CHALLENGER_CANNON_SERVER)
      Path to executable to use as pre-image oracle server when generating trace data
      (cannon game type only)
--cannon-kona-server value   ($OP_CHALLENGER_CANNON_KONA_SERVER)
      Path to kona executable to use as pre-image oracle server when generating trace
      data (cannon-kona game type only)
```

## The trap

**`start_bg` returns 0 whether or not the daemon survives.** It double-forks, writes the pid file, and returns; the wrapper then prints "Sepolia challenger started" and exits 0. Every check that matters must therefore happen **before** `start_bg` is reached — and, for anything cheap, before the three `wait_for_rpc` calls and the balance check, so an operator with a misconfigured trace type finds out in a second rather than after a minute of RPC waits and a live factory read.

The consequence of getting this wrong generalises beyond this task: any condition the wrapper does not check itself becomes a success message followed by a silent death, discovered only by reading `$LOG_DIR/op-challenger.log`. That is exactly what happens today for `cannon` and `cannon-kona`, and post-wipe it will happen at the moment the factory finally registers a type-0 impl — the least convenient possible moment.

## What to build

The property that must hold when you are done: **for every value of `CHALLENGER_TRACE_TYPE` the script accepts, either the daemon can pass `CheckRequired`, or the script exits non-zero before `start_bg` with the missing flag and the environment variable that supplies it named in the error.** No value may reach `start_bg` and then die on flag validation.

Implementation latitude is yours; the following are the constraints, not a design.

### 1. `scripts/09-start-challenger-sepolia.sh`

- For `cannon`, resolve the pre-image server from **`CHALLENGER_CANNON_SERVER`**; for `cannon-kona`, from **`CHALLENGER_KONA_SERVER`**.
- **Unset or empty → exit non-zero** with an error naming the missing flag (`--cannon-server` / `--cannon-kona-server`) and the variable that supplies it. Follow the wording and shape of the existing `super-cannon-kona` refusal block so the family reads consistently.
- **Set → validate:** canonicalize with the script's existing `canonical_abs_path` (the daemon chdirs to `/`), then require an existing **executable** file. A path that is missing, a directory, or non-executable exits non-zero with the resolved path in the message. Do not silently fall back to the unset branch.
- When validated, append `--cannon-server=…` / `--cannon-kona-server=…` to `challenger_args`, guarded by trace type the same way the existing `--cannon-rollup-config` / `--cannon-kona-rollup-config` block is.
- Both the refusal and the validation belong **early**, next to the existing `super-cannon-kona` block, before `L1_RPC_KIND` and well before the `wait_for_rpc` calls.
- Echo the resolved server path in the existing summary block (it is a path, not a secret — but do not echo anything derived from the private key).
- `super-cannon-kona` keeps its current outright refusal. Do not extend the supply mechanism to it: it additionally requires `--supernode-rpc` and `--cannon-kona-depset-config`, and ForteL2 has neither a supernode nor an interop depset. If you think otherwise, report it as **E-F7-2c-1** rather than implementing it.

### 2. `scripts/test-helpers.sh` — first assertions for this script

There are currently **no** tests referencing `09-start-challenger-sepolia.sh`. Add a block in the house style asserting the properties, not the phrasing:

- `cannon` and `cannon-kona` each have a refusal path keyed on their own variable and naming their own flag.
- Both `--cannon-server=` and `--cannon-kona-server=` appear in the argv construction, trace-type guarded.
- The supplied path is checked for executability, not merely existence.
- **Ordering:** the server gate appears before the first `wait_for_rpc` call in the file. An `awk` line-order assertion is the right tool here — see the batcher `stop_bg` / `start_bg` ordering check at the end of the file for the pattern.
- `.env.sepolia.example` declares both variables (commented).

Assert properties that survive rewording. A test that greps for one exact sentence will be a maintenance tax the next time this script is touched.

### 3. `README.md` § "Phase 7 challenger (US-073)"

Add a short statement of what can actually start on the pinned binary and host today: `permissioned` is the working Cannon-family path (still needs a prestate — D-0052); `alphabet` / `fast` / `zk` start but prove nothing about fault proofs; `cannon` / `cannon-kona` need a pre-image server binary that does not exist on this host and are refused until `CHALLENGER_CANNON_SERVER` / `CHALLENGER_KONA_SERVER` is supplied; `super-cannon-kona` is unsupported. Additive — do not restructure the section or touch neighbouring sections.

### 4. `.env.sepolia.example`

Declare both variables **commented out**, with a one-line comment each saying what they are for. No placeholder value, no fake path, nothing that would look like a working default.

## Scope

**Freely changeable:** `scripts/09-start-challenger-sepolia.sh`.

**Additive only** (other Phase 7 work also lands in these; append, do not restructure): `scripts/test-helpers.sh`, `README.md` § Phase 7 challenger, `.env.sepolia.example`.

**Do not touch:** `scripts/lib.sh` (shared by every script in the repo; `start_bg`'s daemonizing behaviour is depended on elsewhere and is not the problem here). `scripts/06-start-proposer-sepolia.sh`, `scripts/status.sh`, `scripts/stop-all-sepolia.sh` (already carry their F7-2 changes; nothing here needs them). `tasks/decisions.md` (planner-owned; D-0054 is already written). Anything under `deployments/`, `.env.sepolia` itself, or CI config.

If the task appears to require changing something outside that surface, **stop and report rather than widening scope.**

## What must survive this change

- Every gate F7-2 and F7-2b established stays intact: the key/address derivation match, the three `wait_for_rpc` calls, the balance check, the D-0052 `gameImpls` → `vm()` / `absolutePrestate()` preflight and its `CHALLENGER_SKIP_PREFLIGHT=1` bypass, the prestate `-f` **and** `-r` check, absolute-path canonicalization, the `--l1-beacon` requirement, and the Cannon rollup/genesis flags.
- The daemon still receives its key via `OP_CHALLENGER_PRIVATE_KEY`, never on argv. The single short-lived `cast wallet address --private-key` call is the one documented exception; do not add a second one and do not remove it.
- No secret in any log line, echo, or error message. RPC URLs still go through `redact_rpc_url` before being echoed.
- The wrapper still accepts no flags other than `-h` / `--help`.
- `scripts/test-helpers.sh` currently reports **106 PASS** and `All script helper tests passed.` Existing assertions may not be weakened, skipped, or deleted to make anything pass. If you believe one encoded a behaviour this change legitimately corrects, say so in the return report with before, after, and why it is a strengthening.

## Verification (run against `wave16-base` at hand-back, restated after any rebase)

```
bash -n scripts/09-start-challenger-sepolia.sh
shellcheck scripts/09-start-challenger-sepolia.sh   # if available; say so if not
bash scripts/test-helpers.sh
grep -rn "09-start-challenger-sepolia" scripts/ launchd/ .github/
```

Expected: `bash -n` clean; `test-helpers.sh` ends `All script helper tests passed.` with a PASS count **above 106** (state the new number — unexplained movement in either direction is itself a finding); the `grep` returns only the script's own `usage()` line and your new assertions in `test-helpers.sh` — the challenger must remain isolated and opt-in, never auto-started.

You cannot run `op-challenger`, so you cannot prove `CheckRequired` yourself. Do not build a harness for it and do not install the binary. State plainly in your report what you exercised and what you did not.

## Out of scope

- Obtaining a pre-image server binary, building Kona, or installing a Rust toolchain (D-0052, open and unassigned).
- Obtaining the absolute prestate (same).
- Anything about the wipe or redeploy (US-071 / US-072) — not authorized, not yours.
- Running the challenger, the proposer, or the bad-proposal tool against anything.
- Changing the trace-type default. There is none by design, and there will not be one until the post-wipe factory is read.

## Unresolved, and staying that way

Which trace type the post-wipe factory will actually register is unknown and is the operator's call after reading the new contracts. Write the code so every accepted type is honest about whether it can start; do not encode a guess about which one will be chosen, and do not add a default. If your work turns up a reason the operator's choice is constrained, report it as an operator decision rather than resolving it.

## If you think this is wrong

Argue it with evidence rather than implementing it half-heartedly. In particular: if you find that `cannon` needs more than `--cannon-server` to pass `CheckRequired` on this build, or that the refusal ought to live somewhere else in the flow, say so with the specific finding. The evidence above was measured, but it was measured by someone else on a different machine.

## Return exactly this

```
TASK:        F7-2c — fail closed on cannon / cannon-kona without a pre-image server
LINE OF WORK: agent/f7-2c-challenger-cannon-server (off wave16-base)
REVIEW ARTIFACT: <PR URL>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: bash -n — pass/fail; shellcheck — pass/fail/not-installed;
              test-helpers.sh — pass/fail, PASS count before → after, final line;
              auto-start grep — what it returned
              (run against wave16-base as of hand-back)
MIGRATION:   none

SHARED FILES TOUCHED: test-helpers.sh / README.md / .env.sepolia.example — exact lines, why additive
IDENTIFIERS USED:     F7-2c, D-0054, CHALLENGER_CANNON_SERVER, CHALLENGER_KONA_SERVER,
                      branch, PR number
EXISTING CHECKS MODIFIED: none | <path> — <before> → <after>; why this strengthens rather than weakens
DECISIONS NEEDED:    none | <the question, and what you did in the interim>
RESIDUAL GAPS:       what you could not exercise without the binary; anything checked by
                     hand rather than by test; risk stated plainly
```

Disclosure in those last three fields counts as diligence, not failure. A declared assertion change is reviewable; a silent one is how a guarantee dies.
