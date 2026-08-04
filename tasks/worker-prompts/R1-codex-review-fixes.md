# Worker prompt — R1: post-Wave-1 review fixes (Codex findings)

Copy everything below the line into the worker. Mid-tier model is sufficient.

---

You are a fix-it worker on the ForteL2 repo. Wave 1 (T1–T3) is merged; an external code review confirmed six issues across the merged work. Your task is **R1**: fix all six. Read `tasks/plan-parallel-integration.md` §5 (commit contract) and `tasks/decisions.md` before starting; both bind you. AGENTS.md conventions apply (textContent, loopback-only, vendored ethers, no lib.sh edits).

You are the only worker in flight — but the write allowlist below is still exclusive and binding.

## Fixes (all six required)

### F1 — `blocks/app.js`: use prefetched transaction objects (P1)
With vendored ethers 6.13.5, `Block.transactions` is always an array of **hash strings**, even after `getBlock(tag, true)`; the full objects are on `block.prefetchedTransactions`. The detail view currently feeds hashes to `summarizeTxRows`, so From/To/Value/Type render as `—` for every non-empty block.
- Use `block.prefetchedTransactions` for the detail rows (it throws if not prefetched — the call site always passes `true`, but guard defensively).
- While there: collapse the pointless identical ternary around `l2.getBlock(parsed.value, true)` (~line 236) into a single call.
- Add a regression test in `blocks/lib.test.js`: `summarizeTxRows` fed full tx-shaped objects yields populated from/to/value/type; fed hash strings yields the `—` fallback (documenting why app.js must pass objects).

### F2 — `blocks/app.js`: newest navigation must supersede in-flight detail loads (P2)
The `detailLoading` boolean (~line 222) *discards* a navigation to block B while block A is loading — A then fills the view under B's URL. Replace with a sequence-token pattern: increment a counter per navigation, capture it in the load, and ignore completions whose token is stale (applies to both success and error paths). Latest navigation always wins; no dropped requests.

### F3 — `batcher/cmd/decode-full/main.go`: guard short channel data (P2)
Line ~66 prints `joined[0], joined[1]` without a length check — a syntactically valid payload with an empty/1-byte frame panics with index-out-of-range instead of reporting malformed channel data. Check `len(joined) >= 2` first and emit a clean error (house style: the existing `fatal(...)` helper).

### F4 — `tasks/prd-phase-6-derivation.md`: isolate Engine API sealing from the reference EL (P1)
The PRD's stage 7 permits v1 to "use Engine API against loopback op-geth to seal blocks." Driving forkchoice on the **live reference** op-geth rewinds/mutates its state and corrupts the very oracle the verifier diffs against, contradicting the PRD's read-only/side-by-side guarantees. Amend the PRD (stage 7 + Constraints/Non-goals as fitting):
- The live reference EL + `op-node` are **read-only** for this project: `eth_getBlockByNumber`, `optimism_syncStatus` comparisons only. Never `engine_*` calls against them.
- If v1 seals via Engine API, it MUST run a **separate EL instance** initialized from the same genesis (own datadir, own ports, own JWT), documented in the runbook; kill/reset of that instance must not touch the reference stack's datadir.

### F5 — `README.md` (SOS onboarding subsection only): fund the actual SOS deployer (P2)
Step 2 claims `deposit-eth-sepolia.sh` funds the SOS deployer — it doesn't: the script signs `bridgeETH` with `ADMIN_PRIVATE_KEY`, credits `ADMIN_ADDRESS` on L2, and takes no recipient. Rewrite the step: deposit lands on the ForteL2 admin; then transfer on L2 to the SOS deployer, e.g.:
`cast send <SOS_DEPLOYER_ADDRESS> --value <amount> --rpc-url "$L2_RPC_URL" --private-key "$ADMIN_PRIVATE_KEY"`
(Keep it a doc fix — do not add a recipient flag to the deposit script.)

### F6 — `replica/README.md`: canonical sync-check invocation (P2)
The added line omits the env file, so `replica-sync-check.sh` fails `require_sepolia_env` from a default checkout. Match the repo's canonical form:
`FORTEL2_ENV=.env.sepolia REPLICA_L2_RPC_URL=… ./scripts/replica-sync-check.sh`

### Housekeeping (allowed, cosmetic)
- Insert the missing blank line before the `### D-T1-1` heading in `tasks/decisions.md` (merge-resolution artifact).
- Commit this prompt file verbatim as `tasks/worker-prompts/R1-codex-review-fixes.md` (it is not yet in the repo; your dispatch message contains it).

## Write allowlist (exclusive)

`blocks/app.js` · `blocks/lib.js` (only if a helper must move there for F1/F2) · `blocks/lib.test.js` · `batcher/cmd/decode-full/main.go` · `tasks/prd-phase-6-derivation.md` (F4 scope only) · `README.md` (SOS onboarding subsection only) · `replica/README.md` (sync-check line only) · `tasks/decisions.md` (append `D-R1-1` summarizing the fixes + the blank-line tidy) · `tasks/worker-prompts/R1-codex-review-fixes.md` (new, verbatim)

Forbidden: `scripts/` (all), `viewer/`, `dapp/`, `blocks/vendor/`, `blocks/index.html`, CI workflows, other Go files, `deployments/`.

## Contract

- Branch `agent/r1-codex-fixes` off the **current `origin/main` tip**; record that SHA in your handoff (no wave tag — you are a solo worker between waves).
- Commits: `fix(blocks): …`, `fix(decode-full): …`, `docs(prd6): …`, `docs(mr0): …` as fitting; squash-merged later.
- Tests before done (paste verbatim results):
  - `node --test blocks/lib.test.js viewer/lib.test.js dapp/lib.test.js`
  - `cd batcher && go build ./... && go test ./...`
  - `./scripts/test-helpers.sh`
  - F3 sanity: `go run ./cmd/decode-full -input 0x00…` with a crafted short/empty-frame payload now errors cleanly instead of panicking (show the command + output).
- Live UI smoke you cannot run → "Operator verification needed."
- No merging, no pushing to main.

## Handoff report — REQUIRED as your final chat message

Your last message must BE the report: one copy-pasteable markdown block with exactly these numbered sections. Putting it only in a PR description or a repo file does not count — work without a final-message report is bounced unreviewed.

1. Branch + base SHA; `git diff --stat <base>..HEAD`
2. Allowlist compliance
3. Per-fix table: F1–F6 → what changed, file:line
4. Tests run + verbatim results (including the F3 panic-repro before/after)
5. `decisions.md` entries added
6. Anticipated conflicts (expected: none — solo worker)
7. Operator actions needed (expected: the deferred US-063 live smokes now also verify F1/F2 visually)
