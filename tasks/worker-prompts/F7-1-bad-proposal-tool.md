# Worker prompt — F7-1: US-074 bad-proposal one-shot tool

Copy everything below the line into the worker. **Mid model tier** — mostly copy-adapt of two existing, tested Go files (`propose-loop`, `inspect-game`), but the code signs and would eventually broadcast a deliberately false claim using a real Sepolia key, so the reuse boundary and the "who is allowed to sign" fact below must be gotten exactly right, not just close. Wave 1 this round — nothing else queued in parallel; not blocked on anything.

---

DISPATCH · Model: mid · Order: wave 1, standalone (no parallel siblings, no blockers)
Baseline: branch `agent/f7-1-bad-proposal-tool` off tag `wave13-base`
Host: any — **no live RPC, no `.env.sepolia`, no Sepolia keys in this environment.** All verification is `go build`/`go test`/`go vet` plus reading captured `-h` output. Running this tool for real against Sepolia is operator-only, after the Phase 7 wipe.
Working directory: main checkout (single delegate this round, no shared-write conflict)
Landing: PR into `main`, squash-merge after review; closes the code-readiness half of US-074's "a bad proposal is created in a documented, isolated way"

---

You are a worker on the ForteL2 repo (`github.com/StephenForte/ForteL2`). This is prep work for Phase 7 (`tasks/prd-phase-7-fault-proofs.md`), specifically US-074: "A bad proposal is created in a documented, isolated way (stock test hook or a one-shot script). Do not leave a hostile proposer running." Read that acceptance criterion in full before starting. **You are building the tool, not running it** — there is nothing live to run it against in your environment, and the actual exercise happens post-wipe, operator-only.

## Read before starting (governing material — trust these over this brief if they conflict)

- `proposer/README.md` — Phase 5 custom-proposer module; read the whole file, especially "US-052: one-shot propose (manual)" and "US-054: Sepolia demo window" — your new tool is a sibling to that one-shot pattern, not a new subsystem.
- `proposer/abi.go` — `DisputeGameFactory.create(uint32 gameType, bytes32 rootClaim, bytes extraData)` (payable; bond = `initBonds(gameType)`), plus the parsed ABI helpers `EncodeCreate`, `InitBond`, `EncodeGameAtIndex`/`DecodeGameAtIndex`, `EncodeGameCount`/`DecodeGameCount`.
- `proposer/extradata.go` — `PackExtraData(sequenceNum uint64)`: 32-byte extraData, L2 block number in the last 8 bytes, big-endian. Has a fixture test (`TestPackExtraDataFixture`) — do not change its expected bytes.
- `proposer/rpc.go` — `FetchOutputAtBlock`, `FetchSyncHeads`, `InitBond`, `GameCount`, `GameAtIndex`, `InspectGame`, `LatestGameOfType`, `HexOrAddress`, `ParseExactHash`, `RedactErr`/`RedactRPCURL`. All exported, all reusable by import — you should not need to re-derive any of this.
- `proposer/cmd/propose-loop/main.go` — the **only source of truth for tx signing** in this module: `sendCreate()` builds/signs/broadcasts a legacy tx (nonce via `PendingNonceAt`, gas via `SuggestGasPrice`/`EstimateGas` + 20% headroom, `types.SignTx` with `LatestSignerForChainID`). Your tool's signing step should follow this exactly — it is already proven against real Sepolia traffic (D-0036).
- `proposer/cmd/inspect-game/main.go` — the read-only CLI conventions to mirror: flag parsing, `resolveFactory` (flag → `-deployments` JSON → error), `envOr`/`envOrUint` helpers.
- `deployments/sepolia/.deployer/intent.toml` — **the fact that decides your design.** `[chains.roles] proposer = "0x350A0F7becCE56598962C501CaA02f900F256803"`. This is the **only** address the deployed `PermissionedDisputeGame`/`DisputeGameFactory` will accept a `create()` call from. `challenger = "0x4f05a8556db05d682a67dbB355b8A29A3A5C79fd"` is a **different** role with **different** permissions (disputing an existing game, not creating one).

## The trap

There is no separate "attacker" identity on this deployment — only one `proposer` role exists, and it is the same key the stock `op-proposer` binary already uses honestly. **Your tool must sign with `PROPOSER_PRIVATE_KEY` (or a `-private-key` flag, same convention as `propose-loop`), never `CHALLENGER_PRIVATE_KEY`.** If you reach for the challenger key because "challenger" sounds adversarial, the `create()` call reverts (or the deployment's role gating rejects it) and the whole exercise fails on-chain, not at review time. This is exactly the kind of mistake that only shows up once someone spends real Sepolia gas running it — get the role right in code and in every doc string, so nobody has to learn it the expensive way.

Second-order consequence of "same key as stock": if stock `op-proposer` happens to be running when this tool is invoked for real, both processes share one nonce sequence and can race. You do not need to solve this in code — document it (mirror `proposer/README.md`'s US-052 "stop stock proposer only" step) so the operator does it by hand before ever running this for real.

## What to build

A new one-shot CLI, `proposer/cmd/bad-proposal/main.go`, plus a thin Sepolia wrapper script, that:

1. Resolves the `DisputeGameFactoryProxy` address (flag, `-deployments` JSON, or `DISPUTE_GAME_FACTORY` env — mirror `resolveFactory` from `propose-loop`/`inspect-game`).
2. Determines the target L2 block: a `-block` flag override, defaulting to the current safe head via `FetchSyncHeads`/`FetchOutputAtBlock` (same as `propose-loop`).
3. Fetches the **real, honest** output root for that block via `FetchOutputAtBlock` — reused, not reimplemented.
4. Deliberately corrupts it into a claim that is provably wrong. Recommendation (keep it simple and obvious, not clever): XOR the last byte of the real root with `0xFF`. Implement this as a small, separately unit-testable pure function (e.g. `corruptRoot(real common.Hash) common.Hash`) so a reviewer can see exactly what was changed. Print **both** the real root and the corrupted root before sending, clearly labeled — the whole point of this tool is a documented, traceable deviation, not a hidden one.
5. Fetches the required bond via `InitBond` (reused).
6. Packs extraData via `PackExtraData(blockNum)` (reused).
7. Encodes `create()` calldata via `EncodeCreate` (reused).
8. Signs and broadcasts using the same pattern as `propose-loop`'s `sendCreate` (nonce/gas/signing — copy-adapt, or factor into a shared helper if you judge that cleaner; see "invite objection" below).
9. **Waits for the transaction to be mined and checks its status before declaring success.** `inspect-game` is read-only and does not poll for receipts — it reads `gameCount` once and inspects whatever index you give it, synchronously, right now. Telling the operator to run it immediately after broadcast is unsafe: if the tx isn't mined yet, `gameCount-1` points at the *previous* (honest) game, and the operator would see a correct root and wrongly conclude the bad proposal landed; if the tx reverts, nothing would ever say so. So this tool must itself: poll `client.TransactionReceipt` (standard `ethclient`, not a `propose-loop` reuse — its `waitReceiptConfirmed` is unexported and its reorg/pending-across-restarts machinery is overkill for a synchronous one-shot call) until mined or a timeout (a few minutes is enough at Sepolia's block time), fail loudly with the tx hash and revert status if it reverted, and on success read `GameCount`/`GameAtIndex` (reused from `rpc.go`) to find the index it just created, then `InspectGame` (reused) to read back the on-chain `rootClaim` and assert it equals the corrupted value you sent — this is a self-check, not just a print. Print the game index, proxy address, tx hash, and the confirmed matching root. Only *after* this passes does the tool say "done" — no separate manual follow-up step is required or should be documented as necessary.
10. **Never loops. Exits after one broadcast attempt.** No `-interval`, no retry-forever, nothing that could be mistaken for a daemon.
11. **Refuses to run without an explicit, named confirmation.** Require a flag (e.g. `-i-understand-this-posts-a-false-claim=true`) or an equivalently unambiguous env var before it will broadcast; without it, print what it *would* do (block, real root, corrupted root, bond, factory) and exit non-zero. This is the tool's only safety rail — make it impossible to fire by accident (e.g. via a stray CI run or a copy-pasted example command).

Plus `scripts/create-bad-proposal-sepolia.sh` — a thin wrapper mirroring the existing Sepolia script conventions: `source scripts/lib.sh` (read-only, do not edit it), `require_sepolia_env`, `refuse_foundry_defaults_unless_local_l2 "${PROPOSER_PRIVATE_KEY:-}" "PROPOSER_PRIVATE_KEY"`, and a second opt-in gate matching the existing `CONFIRM_CUSTOM_PROPOSER_SEPOLIA=1` pattern in `scripts/06-start-proposer-sepolia.sh` (e.g. `CONFIRM_BAD_PROPOSAL_SEPOLIA=1`) before it will `go run ./cmd/bad-proposal ...`. This script is never invoked by any other script — it has no automatic caller.

Plus a new subsection in `proposer/README.md`, styled like the existing "US-052"/"US-054" sections, documenting: what the tool does, the proposer-vs-challenger role fact above, the "stop stock proposer first" step, and the two-gate safety model (code-level confirm flag + script-level env var).

## Scope

**Freely changeable (new files only):**
- `proposer/cmd/bad-proposal/main.go` (new)
- `proposer/cmd/bad-proposal/main_test.go` (new — unit test `corruptRoot` and any other pure helper you extract; table-driven, following `proposer/extradata_test.go`'s style)
- `scripts/create-bad-proposal-sepolia.sh` (new, executable)
- `proposer/README.md` — **append-only new subsection**, do not edit existing sections

**Not to be touched (read/import only):**
- `proposer/abi.go`, `proposer/extradata.go`, `proposer/rpc.go`, `proposer/cmd/propose-loop/*`, `proposer/cmd/inspect-game/*` — reuse via Go import, do not modify. If something you need isn't exported, stop and report it in your handoff rather than editing these files.
- `scripts/lib.sh` — privileged, never edited by any task.
- `tasks/prd-phase-7-fault-proofs.md`, `tasks/decisions.md` — planner-owned; do not touch. If you believe a decision needs recording, propose it in your handoff as `E-F7-1-<n>`.
- `.github/workflows/ci.yml` — should not need changes (`go test ./...` in the `proposer` working-directory already covers `./cmd/bad-proposal` as a subpackage); if you find you need a CI change, stop and report rather than editing the workflow.

If the task seems to need anything outside this list, stop and report rather than widening scope.

## What must survive

- `cd proposer && go test ./...` must still pass **unchanged in every existing test** — you are adding a new package, not modifying `abi_test.go` / `extradata_test.go` behavior.
- `TestPackExtraDataFixture`'s expected bytes must not change.
- The tool must be inert by default (see confirm-flag requirement above) and must never be referenced from any script that runs automatically (`start-all-sepolia.sh`, launchd, etc.) — grep for your new script/binary name across `scripts/` before handing back and confirm nothing calls it unprompted.

## Verification (run against `wave13-base` at hand-back, restated after any rebase)

```
cd proposer && go build ./... && go vet ./... && go test ./...
bash -n ../scripts/create-bad-proposal-sepolia.sh
go run ./cmd/bad-proposal -h    # paste full output in your handoff
```

You have no RPC to test the actual broadcast path against — that is expected, not a gap to work around. Do not add a mock RPC server or any live-network test scaffolding for this task; state plainly in your handoff that the signing/broadcast path is verified by code review and pattern-match against `propose-loop`'s proven `sendCreate`, not by execution.

## Out of scope

- Actually running this against Sepolia (operator-only, after the Phase 7 wipe — the current pinned deployment is a different, soon-to-be-replaced `DisputeGameFactoryProxy`, so there is nothing meaningful to run this against right now even if you had keys).
- The `op-challenger` start script (separate task, blocked on the operator building `op-challenger`/`cannon`/`op-program` locally first — not this task).
- Any change to `tasks/prd-phase-7-fault-proofs.md` acceptance checkboxes — the planner updates those once this merges and, separately, once the tool is actually run for real.

## Unresolved decision — flag back, don't decide silently

The exact corruption (XOR last byte with `0xFF`) is a recommendation, not a settled requirement — any deterministic, obviously-wrong, clearly-documented transform is acceptable. If you pick something different, say what and why in your handoff so the operator can bless it before first live use; don't silently pick something clever.

## Invite objection

If duplicating `sendCreate` into this new command feels like the wrong call — e.g. you think it should be factored into an exported helper in `proposer/rpc.go` or a new `proposer/tx.go` shared by both `propose-loop` and `bad-proposal` — say so with your reasoning in the handoff rather than mechanically copy-pasting. Either is acceptable; state which you did and why.

## Required return format

```
TASK:        F7-1 — US-074 bad-proposal one-shot tool
LINE OF WORK: agent/f7-1-bad-proposal-tool (off wave13-base)
REVIEW ARTIFACT: <PR URL>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: go build/vet/test — pass/fail with counts; bash -n — pass/fail;
              `-h` output pasted in full
              (run against wave13-base as of hand-back)
MIGRATION:   none

SHARED FILES TOUCHED: proposer/README.md — new subsection only (or: none if you
                      judge it unnecessary — explain)
IDENTIFIERS USED:     F7-1, branch agent/f7-1-bad-proposal-tool
EXISTING CHECKS MODIFIED: none expected — list any with before/after/why if it happened
DECISIONS NEEDED:    corruption-transform choice (if different from the XOR recommendation);
                     any E-F7-1-n proposals
RESIDUAL GAPS:       broadcast path unexecuted (no RPC available) — state exactly what
                     was verified by code review/pattern-match vs by running something
```
