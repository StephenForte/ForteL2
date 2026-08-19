# Worker prompt — F7-3: preflight must read `gameArgs`, not the implementation (US-073)

Copy everything below the line into the worker. **Mid model tier** — shell only, but the change corrects a gate that currently refuses to start against a *healthy* deployment, and getting the replacement subtly wrong reintroduces the same class of error in the opposite direction. Wave 1 this round; standalone, no parallel siblings.

---

DISPATCH · Model: mid · Order: wave 1, standalone (no siblings, no blockers)
Baseline: branch `agent/f7-3-preflight-gameargs` off tag `wave18-base`
Host: any. **No `.env.sepolia`, no Sepolia keys, no `op-challenger`, and nothing here signs or spends.** If your environment has outbound network, you may make the **read-only** public-RPC calls named below and should report their output; if it does not, say so and rely on the static gate. Do not attempt to run the challenger.
Working directory: main checkout (single delegate this round)
Landing: PR into `main`, squash-merge after review. **Must land before US-071/072 (the network wipe)** — post-wipe the current preflight would block US-073 outright.

---

You are a worker on the ForteL2 repo (`github.com/StephenForte/ForteL2`). Phase 7 context: `tasks/prd-phase-7-fault-proofs.md`, **US-073**. The start script `scripts/09-start-challenger-sepolia.sh` is merged and working except for one gate that reads the wrong object.

## Read before starting (governing material — trust the repository and the contracts source over this brief)

- `tasks/decisions.md` **D-0055** — the decision this task implements, with the full evidence. It supersedes **D-0052** Finding 2; read both, and read D-0054 for why `permissioned` is the working trace type.
- `scripts/09-start-challenger-sepolia.sh` — specifically `run_preflight()` and the `CHALLENGER_SKIP_PREFLIGHT` branch below it.
- `~/src/fortel2/optimism/packages/contracts-bedrock/src/dispute/FaultDisputeGame.sol` — the getters at lines ~868-914 and the immutable-backed ones at ~1126+. **If this path does not exist in your environment, say so in your report and work from D-0055's quoted evidence.**
- `~/src/fortel2/optimism/packages/contracts-bedrock/src/dispute/DisputeGameFactory.sol` — `create()`, both CWIA layout branches, and the `gameArgs` mapping.
- `scripts/test-helpers.sh` — the assertion harness; house style is structural `grep`/`awk` over script text (see the `P7-0-A` batcher block and the `F7-2c` block at the end).
- `scripts/lib.sh` — **read-only, never edit.**

## Pre-assigned identifiers — use these exactly

- Task id **F7-3**. Decision record **D-0055** (already written; do not add or renumber decisions).
- Branch **`agent/f7-3-preflight-gameargs`**, cut from tag **`wave18-base`**.
- Escalation ids if you need them: **E-F7-3-1**, **E-F7-3-2**. One of them is pre-assigned a question — see "Report back, do not implement" below.

These override any "find the highest and add one" convention. If one looks wrong, stop and ask.

## The defect

`run_preflight()` currently does this:

```
impl="$(cast call "$GAME_FACTORY" "gameImpls(uint32)(address)" "$type_num" …)"
vm_addr="$(cast call "$impl" "vm()(address)" …)"
prestate="$(cast call "$impl" "absolutePrestate()(bytes32)" …)"
… exits 1 if either is zero
```

In this contracts version (`FaultDisputeGame` v2.4.0) `vm()`, `absolutePrestate()`, `gameType()`, `anchorStateRegistry()`, `weth()` and `l2ChainId()` are **`pure`** functions that read clone-with-immutable-args calldata (`_getArgBytes32(120)`, `_getArgAddress(152)`, …). The **implementation contract is never a clone and carries no appended args**, so all of them return zero no matter how healthy the deployment is. `maxGameDepth()` / `splitDepth()` / `maxClockDuration()` / `clockExtension()` are true Solidity immutables — which is why those read correctly and made the zeros look like real configuration.

Consequence today: the gate is not "fail closed", it is "always fail". Post-wipe it would refuse to start against a correctly wired chain, and the documented bypass `CHALLENGER_SKIP_PREFLIGHT=1` would become the routine path — worse than having no preflight at all.

## Evidence (measured 2026-08-19, public Sepolia RPC, read-only)

The real configuration lives in `DisputeGameFactory.gameArgs(gameType)`, which `create()` appends to the clone calldata. Factory `0xba1fda6baf25f43a340cdd5a86c02a69c8e49eed` (v1.6.1):

```
cast call 0xba1fda6baf25f43a340cdd5a86c02a69c8e49eed "gameArgs(uint32)(bytes)" 1 \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com

0x038512e02c4c3f7bdaec27d00edf55b7155e0905301e1a88083e4e0a6764d54c   <- absolutePrestate  [ 0, 32)
  acc005dcd857b401e4732e6f7837135a22825cfa                           <- vm (MipsImpl)     [32, 52)
  ef9a48838733ad9f060496544aef028e56c5375c                           <- anchorStateRegistry
  9c64ac7894d589270f935188503006ac308d3ec0                           <- weth
  0000…0354                                                          <- l2ChainId = 852
  350a0f7becce56598962c501caa02f900f256803                           <- proposer   (permissioned only)
  4f05a8556db05d682a67dbb355b8a29a3a5c79fd                           <- challenger (permissioned only)
```

`gameArgs(0)` returns `0x` — empty — and `gameImpls(0)` is the zero address: game type 0 (`cannon`) genuinely is not registered on this factory. Both facts are consistent with D-0054.

Confirmation that this is the mechanism and not a coincidence: calling the *same* implementation that returns all zeros, with a synthetic CWIA payload assembled from `gameArgs(1)`, returns `vm` = `0xacc005dc…25cfa`, `absolutePrestate` = `0x038512e0…6764d54c`, `gameType` = `1`, `l2ChainId` = `0x354`, while `maxGameDepth()` stays `73`. You do **not** need to reproduce that experiment.

## The trap

**The offsets in this brief are a snapshot; the contracts source is the authority.** `[0,32)` for the prestate and `[32,52)` for the VM are the *tail* offsets — they follow from the game's absolute offsets (120 and 152 into the full clone calldata) minus the 120-byte header that `create()` writes ahead of `implArgs`. Read `FaultDisputeGame.sol` and `DisputeGameFactory.create()` and satisfy yourself that the arithmetic holds for the version in the tree before you write the decode. If your reading disagrees with this brief, **the brief is wrong** — report it as E-F7-3-2 rather than coding around it.

Second trap, the one that matters more: **do not turn "always fail" into "always pass."** A preflight that silently succeeds when it cannot determine the answer is worse than the bug you are fixing, because it spends real Sepolia gas on a game the challenger cannot step. Every path that cannot positively establish a non-zero VM and a non-zero prestate must exit non-zero.

## What to build

The property that must hold, **for a trace type the preflight actually inspects**: the preflight exits non-zero unless it has positively read a non-zero `vm` and a non-zero `absolutePrestate`, from whichever location this factory actually keeps them.

"A trace type the preflight actually inspects" means one that `game_impls_type_number()` maps to a number — today `cannon` = 0 and `permissioned` = 1, and nothing else. `run_preflight()` opens with an early `return 0` for every unmapped type, printing "no confident gameImpls(uint32) mapping …; skipping factory lookup." **That skip is correct, is out of scope, and must survive unchanged.** `alphabet`, `fast` and `zk` are startable types (D-0054) whose games carry no Cannon VM or prestate configuration to read; making them fail the preflight would break three working modes. Extending the type-number mapping is a separate open question (E-F7-2-1) and is not yours.

### 1. `scripts/09-start-challenger-sepolia.sh` — `run_preflight()`

- Keep the existing `gameImpls(<type>)` lookup and its zero-address refusal unchanged. That check is correct and is the one that catches an unregistered type.
- Read `gameArgs(<type>)` from the factory.
  - **Non-empty** → decode `absolutePrestate` and `vm` from it and apply the existing zero checks to those values. A blob too short to contain both is a refusal, not a pass — do not assume 164 bytes; a non-permissioned game's args are shorter, so bound-check rather than length-match.
  - **Empty** → fall back to calling `vm()` / `absolutePrestate()` on the implementation, which is correct for older layouts where those are true immutables, and apply the same zero checks.
- Echo which source the values came from (`gameArgs` vs implementation getters) so the operator can see it in the log. Echo the decoded values as it does today.
- Error messages must name the failure precisely — unregistered type, empty args with zero impl getters, decoded zero VM, decoded zero prestate are four different states and should not share one message. Cite D-0055 where the current text cites D-0052.
- `CHALLENGER_SKIP_PREFLIGHT=1` stays exactly as it is, warning and all.
- `cast` returns `0x` for empty bytes; `set -euo pipefail` is in force and a reverting `cast call` aborts the script. Both are acceptable failure modes, but make sure an *empty* result is handled as data, not as an error, since `gameArgs` legitimately returns empty.

### 2. `scripts/test-helpers.sh`

Append one block in the house style, asserting properties rather than phrasing:

- `run_preflight` references `gameArgs` and no longer treats the implementation's `vm()` / `absolutePrestate()` as the primary source.
- The implementation-getter path still exists as a fallback (the file should contain both).
- The `gameImpls` zero-address refusal survives.
- `CHALLENGER_SKIP_PREFLIGHT` survives.
- The early `return 0` skip for unmapped trace types is still present and still reached before any factory call.
- **Once the preflight has committed to a factory lookup** (a mapped type), every path that cannot establish both values reaches an `exit 1` — an `awk` structural check is the right tool; a grep for one sentence is not. Do not assert this about the unmapped-type skip, which returns 0 by design.

Assert what survives rewording. Say in your report how many assertions you added.

### 3. `README.md` § "Phase 7 challenger (US-073)"

The **Preflight** paragraph currently says the script reads `gameImpls` → `vm()` / `absolutePrestate()` and cites "the pinned 2026-07-22 impl reported both zero — D-0052". That sentence is now actively misleading and **you are authorized to rewrite that paragraph** (this is the one place in this task where you may edit existing prose rather than append): say that the values are read from `gameArgs(gameType)` with a fallback to the implementation getters, and cite **D-0055**. Leave every other paragraph in that section alone.

## Scope

**Freely changeable:** `scripts/09-start-challenger-sepolia.sh`.

**Additive only:** `scripts/test-helpers.sh`.

**One authorized rewrite:** the **Preflight** paragraph of `README.md` § Phase 7 challenger, as described above.

**Do not touch:** `scripts/lib.sh`; `tasks/decisions.md` (planner-owned; D-0055 is written); `.env.sepolia.example` (no new variables here); `scripts/06-start-proposer-sepolia.sh`, `status.sh`, `stop-all-sepolia.sh`; anything under `deployments/`; CI config.

If the task appears to require changing something outside that surface, **stop and report rather than widening scope.**

## What must survive this change

- Every gate from F7-2 / F7-2b / F7-2c: the key/address derivation match, the three `wait_for_rpc` calls, the balance check, the prestate `-f` **and** `-r` check, absolute-path canonicalization, the `--l1-beacon` requirement, the Cannon rollup/genesis flags, the `cannon` / `cannon-kona` pre-image-server refusal, and the `super-cannon-kona` refusal. None of them are in scope; all of them must still be there.
- `run_preflight()`'s early `return 0` for trace types with no `game_impls_type_number()` mapping, unchanged — `alphabet`, `fast` and `zk` must still start.
- The daemon still receives its key via `OP_CHALLENGER_PRIVATE_KEY`, never on argv; RPC URLs still pass through `redact_rpc_url` before being echoed; no secret in any output.
- `scripts/test-helpers.sh` reports **107 PASS** and `All script helper tests passed.` at `wave18-base`. Existing assertions may not be weakened, skipped, or deleted. If you believe one encoded the behaviour this change corrects, say so with before, after, and why it is a strengthening.

## Verification (run against `wave18-base` at hand-back, restated after any rebase)

```
bash -n scripts/09-start-challenger-sepolia.sh
shellcheck scripts/09-start-challenger-sepolia.sh   # if available; say so if not
bash scripts/test-helpers.sh
grep -rn "09-start-challenger-sepolia" scripts/ launchd/ .github/
```

Expected: `bash -n` clean; `test-helpers.sh` ends `All script helper tests passed.` with a PASS count **above 107** (state the number); the `grep` returns only the script's own `usage()` line and the assertions in `test-helpers.sh`.

**If your environment has outbound network**, also run these two read-only calls and paste the output — they need no keys, sign nothing, and cost nothing:

```
cast call 0xba1fda6baf25f43a340cdd5a86c02a69c8e49eed "gameArgs(uint32)(bytes)" 1 --rpc-url https://ethereum-sepolia-rpc.publicnode.com
```

```
cast call 0xba1fda6baf25f43a340cdd5a86c02a69c8e49eed "gameArgs(uint32)(bytes)" 0 --rpc-url https://ethereum-sepolia-rpc.publicnode.com
```

The first must begin `0x038512e02c4c3f7bdaec27d00edf55b7155e0905301e1a88083e4e0a6764d54cacc005dc…`; the second must be exactly `0x`. If either differs, stop and report — the chain changed under us and this task's premise needs re-checking. If you have no network or no `cast`, say so plainly; it is not a failure.

You cannot exercise the preflight end to end without a live L1 and a factory. Do not build a harness that fakes one, and do not install `op-challenger`. State exactly what you exercised and what you did not.

## Report back, do not implement

**E-F7-3-1 (pre-assigned):** the highest-value check we still cannot make is whether the operator's `CHALLENGER_PRESTATE` **file** matches the on-chain commitment (`0x038512e0…6764d54c` on the current chain). Report whether the pinned `cannon` binary, `op-challenger`, or anything else in the tree can compute a prestate file's commitment — command, and what it outputs. **Do not implement such a check in this task.** If nothing can, say that; it becomes a planner decision either way.

## Out of scope

- Obtaining the prestate artifact itself (open; D-0055).
- Anything about the wipe or redeploy (US-071 / US-072) — not authorized.
- Changing which trace types are startable — that is D-0054 and it is settled.
- Adding new environment variables.
- Running the challenger, the proposer, or the bad-proposal tool against anything.

## Unresolved, and staying that way

Which game type the post-wipe factory registers, and with what args, is unknown until it exists. Write the preflight so it reads whatever the factory actually says and refuses when it cannot tell; do not encode an expectation about which type or which layout will be present.

## If you think this is wrong

Argue it with evidence. This brief overturns a previously recorded decision (D-0052) on the strength of a source reading and one experiment, and the person who wrote it also wrote the brief that produced the defect you are fixing. If the contracts source says something different from what is written above, the source wins and you should say so.

## Return exactly this

```
TASK:        F7-3 — preflight reads gameArgs, not the implementation
LINE OF WORK: agent/f7-3-preflight-gameargs (off wave18-base)
REVIEW ARTIFACT: <PR URL>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: bash -n — pass/fail; shellcheck — pass/fail/not-installed;
              test-helpers.sh — pass/fail, PASS count 107 → N, final line;
              auto-start grep — what it returned;
              public-RPC reads — output, or "no network"
              (run against wave18-base as of hand-back)
MIGRATION:   none

SHARED FILES TOUCHED: test-helpers.sh / README.md — exact lines, what changed
IDENTIFIERS USED:     F7-3, D-0055, branch, PR number
EXISTING CHECKS MODIFIED: none | <path> — <before> → <after>; why this strengthens
DECISIONS NEEDED:    E-F7-3-1 finding (required); anything else you hit
RESIDUAL GAPS:       what you could not exercise without a live factory; what was
                     checked by hand vs by test; risk stated plainly
```

Disclosure in those last three fields counts as diligence, not failure.
