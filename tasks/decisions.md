# Shared decisions log — parallel integration work

**Protocol (read before writing):**
- **Append-only.** Never edit or delete a prior entry; supersede it with a new entry that references the old ID.
- **ID format:** `D-<task>-<n>` (e.g. `D-T2-1`). Pre-seeded plan decisions use `D-000x`.
- One entry per decision: context → decision → consequence. Three lines is plenty.
- **Escalations** (things outside your write allowlist that you believe need changing) go in §Escalations with the same ID scheme (`E-<task>-<n>`). Do not implement them.
- Workers read this file at task start and before handoff; the integrator reads it at every merge.

---

## Decisions

### D-0001 — Base SHA for Wave 1
- **Context:** main had uncommitted changes (README, .env.sepolia.example, dev-sleep.sh) at planning time.
- **Decision:** Operator commits them first (T0); Wave 1 branches from the resulting SHA.
- **BASE_SHA:** tag `wave1-base` — resolve with `git rev-parse wave1-base^{commit}`. (Re-pinned 2026-08-04 by D-0007; previous value `d9f3c5ff5b0c3f3e07b4462aaca4e419193e757e` was mid-PR-#58 and predates this file existing on main.)

### D-0002 — Branching model
- **Context:** batch-merging ~3 agent branches caused rebase churn.
- **Decision:** Trunk-based; branches `agent/<task>-<slug>` off pinned BASE_SHA; squash-merge one at a time in plan §6 order; workers never merge.
- **Consequence:** at most one trivial rebase per branch, resolved in merge order.

### D-0003 — Block viewer location (PRD open question resolved)
- **Context:** PRD left "extend `viewer/` vs sibling static app" open.
- **Decision:** Sibling app under `blocks/` with its own vendored ethers copy and serve script. Rationale: disjoint file ownership for parallel work; `viewer/` stays the Phase 1c pipeline viewer untouched.
- **Consequence:** T3 owns `blocks/` exclusively; pattern-copies from `viewer/`/`dapp/` are copies, not shared edits.

### D-0004 — Phase 6 derivation gets its own PRD
- **Context:** learning-chain PRD says expand US-060–062 in place or spin out a PRD before coding.
- **Decision:** Spin out — T2's spike produces `tasks/prd-phase-6-derivation.md`; T4 executes against it.
- **Consequence:** T4 is not launched until T2 merges.

### D-0005 — MR-3/4/5 are trigger-gated, not planned
- **Triggers:** MR-3 when SOS asks for fee abstraction; MR-4 when SOS needs canonical USDC; MR-5 after SOS runs stable on 852. Until a trigger fires these get no worker.

### D-0006 — Verifier module shape (placeholder)
- **Status:** OPEN — to be closed by T2 spike (`D-T2-x`): new `derivation/` module (default assumption) vs extending `batcher/`. T4 ownership follows the answer.

### D-0007 — BASE_SHA re-pin to tag `wave1-base`
- **Context:** The first pinned BASE_SHA (`d9f3c5f`) was the mid-PR-#58 commit: it lacked `tasks/decisions.md` (added in `8763f44`) and the plan/worker-prompt files (never committed), and main had moved (PR #58 merge `671a39f` + CI-workflow commits `be81133`/`e402de3`/`3dd5db8`/`386ffa1`).
- **Decision:** Base = the commit that adds the plan + worker prompts on top of merged main, tagged **`wave1-base`** (a tag, because this file cannot contain its own commit's hash). D-0001's value field now points at the tag.
- **Consequence:** All Wave 1 workers branch from `wave1-base` and diff against it in handoffs. Any future re-pin gets a new decision entry + a new tag (`wave2-base`, …), never a moved tag.

### D-T2-1 — Verifier-only first (US-061 before US-062)
- **Context:** Phase 6 PRD lists derivation verifier and optional sequencer stub; spike must confirm ordering.
- **Decision:** **Verifier-only derivation tool first** — US-061 ships L1→payload-attributes (+ hash check via reference EL); US-062 sequencer stub stays gated.
- **Consequence:** T4 implements `derivation/` verifier + `derivation-check.sh` only; no Engine API block production until US-062 is explicitly approved.

### D-T2-2 — Module shape: new `derivation/` imports `batcher`
- **Context:** D-0006 asked whether to extend `batcher/` or spin out; `batcher/` is encode/submit-oriented but already has decode helpers (`ParseBatcherTxPayload`, `DecompressChannelZlib`, `DecodeSingularBatch`, …).
- **Decision:** **New `derivation/` Go module** (own `go.mod`); import `github.com/StephenForte/ForteL2/batcher` for frame/channel/singular decode; do **not** modify `batcher/*.go`.
- **Consequence:** T4 owns `derivation/` exclusively; span decode, deposits, payload attributes, and diff logic live there. Closes D-0006.

### D-T2-3 — US-061 comparison window
- **Context:** Verifier must define “match” vs reference `op-node` for acceptance tests.
- **Decision:** **Local 901:** default inclusive window blocks **1–20** (override via flags). **Sepolia 852:** **50 blocks** ending at reference `safe_l2.number`. **Match rule:** `derivedHash == eth_getBlockByNumber(n).hash` for every block in window; log `safe_l2`/`unsafe_l2` from `optimism_syncStatus`; first mismatch fails the run.
- **Consequence:** Golden fixtures and `derivation-check.sh` defaults follow this table; metadata-only diffs are insufficient for US-061 acceptance.

### D-0006-superseded — Verifier module shape (closed by T2)
- **Context:** D-0006 left module shape open; T2 spike evaluated `batcher/` reuse vs new module (see D-T2-2).
- **Decision:** Supersedes D-0006 — **`derivation/` Go module** imports `batcher` decode helpers; T4 owns `derivation/`.
- **Consequence:** Do not extend `batcher/*.go` for derivation; US-061 implementation starts in `derivation/` per `tasks/prd-phase-6-derivation.md`.

### D-T1-1 — MR-0 doc closeout (2026-08-04)
- **Context:** Money-rail artifacts (`rail-interface.json`, README/coordination/replica docs) predated PRD checkbox updates; MR-0 was marked “In progress.”
- **Decision:** Verified US-MR-001..003 artifacts on disk; ticked acceptance criteria; set MR-0 status to **Done** in money-rail PRD and learning-chain MR row. No `rail-interface.json` address/chain/URL changes.
- **Consequence:** T2/T3 may assume MR-0 is closed; SOS integration gate unchanged (`sosGate.mayStartIntegration` remains true).

### D-R1-1 — Post-Wave-1 Codex review fixes (R1)
- **Context:** External review of merged T1–T3 found six issues: block viewer tx rows used hash strings not prefetched objects; stale detail-load race; decode-full panic on short channel data; PRD permitted Engine API against reference EL; SOS onboarding misstated deposit recipient; replica sync-check omitted `FORTEL2_ENV`.
- **Decision:** F1–F3 code fixes in `blocks/` and `batcher/cmd/decode-full`; F4–F6 doc fixes in Phase 6 PRD, README SOS onboarding, `replica/README.md`. Reference stack is read-only for derivation; Engine API sealing requires a separate EL instance.
- **Consequence:** T4 runbook must document isolated EL if sealing; operator verifies block viewer tx From/To/Value on live stack.

### D-0008 — Wave 2 base: tag `wave2-base`
- **Context:** Wave 1 (T1–T3) + R1 review fixes are merged; T4 executes against the amended `tasks/prd-phase-6-derivation.md`.
- **Decision:** Wave 2 base = the commit adding `tasks/worker-prompts/T4-derivation-verifier.md` + this entry, tagged **`wave2-base`** (same tag mechanism as D-0007). T4 branches from it; any Wave 2 siblings (T5, hardening H-tasks) branch from the same tag.
- **Consequence:** Handoffs diff against `wave2-base..HEAD`. Next re-pin gets `wave3-base`, never a moved tag.

### D-T4-1 — Separate sealing EL lifecycle (foreground child)
- **Context:** US-061 requires Engine API hash sealing on an isolated EL (D-R1-1); `lib.sh` `start_bg`/`stop_bg` are privileged and out of allowlist.
- **Decision:** `derivation-check.sh` starts/stops sealing `op-geth` as a **foreground-owned background child** (`&` + `trap` kill on exit), not via `start_bg`. Datadir `$DATA_DIR/l2/derivation-op-geth`; ports `19645`/`19651`; P2P `--port=30323`.
- **Consequence:** Reference datadir untouched; operator may wipe derivation datadir freely. No edits to privileged process helpers.

### D-T4-2 — Isthmus withdrawalsRoot JSON patch
- **Context:** op-geth `engine_getPayloadV4` returns payloads without `withdrawalsRoot`; `engine_newPayloadV4` rejects Isthmus blocks with "nil withdrawalsRoot post-Isthmus". Vanilla `go-ethereum` `ExecutableData` lacks the field.
- **Decision:** After `getPayload`, **JSON-patch** `withdrawalsRoot` to the empty-list constant (`0x8ed4baae…`) before `newPayload`. No `replace` to op-geth in `go.mod` (keeps CI portable).
- **Consequence:** Sealing works against stock op-geth binary with upstream go-ethereum types in the verifier module.

### D-T4-3 — Local 901 golden fixture format
- **Context:** US-061 requires checked-in decode fixture; spike captured real batcher tx calldata.
- **Decision:** `derivation/testdata/local901/batcher_tx.hex` — raw L1 tx input hex (15 singular batches, blocks 1–15). Sepolia slot `testdata/sepolia/window.json` is load-if-present / skip-with-notice.
- **Consequence:** CI unit tests decode fixture without a live stack; Sepolia golden remains operator-supplied.

### D-T4-4 — Verified comparison window (local 901)
- **Context:** D-T2-3 binds acceptance to hash equality on blocks 1–20 local default.
- **Decision:** T4 verified **blocks 1–20 inclusive** on chain **901** in Cursor Cloud VM (`./scripts/derivation-check.sh`); all 20 derived hashes matched reference EL.
- **Consequence:** US-061 local acceptance met; Sepolia 852 window remains operator-run.

### D-0009 — US-062 approved; Wave 3 base: tag `wave3-base`
- **Context:** US-061 merged and verified (blocks 1–20 hash-match on 901). Operator explicitly approved the gated US-062 sequencer stub (2026-08-04). Integrator added `--json-out` fixture capture to `derivation-check.sh` (+ `-json` stdout purity in `cmd/verify`).
- **Decision:** T6 implements US-062 per `tasks/worker-prompts/T6-sequencer-stub.md`, branching from tag **`wave3-base`** (the commit adding that prompt, this entry, and the capture flag). Same isolation invariants as T4; T6 also upgrades the Sepolia golden-fixture test from existence-check to replay.
- **Consequence:** After T6, Phase 6 is code-complete; remaining tracks are operator Sepolia runs and the Wave 3 hardening tasks (H1–H3), which branch from `wave3-base` or its successor.

### D-T6-1 — Stub head-selection + isolated EL lifecycle
- **Context:** US-062 must build blocks without `engine_*` against the reference stack; `lib.sh` `start_bg`/`stop_bg` remain privileged/out of allowlist.
- **Decision:** Fresh isolated EL per demo (`$DATA_DIR/l2/sequencer-stub-op-geth`, HTTP `:19745`, auth `:19751`, P2P `:30324`, own JWT) started as a foreground-owned child (`&` + `trap`) like D-T4-1. Head = current tip of that EL (genesis after wipe). Empty blocks advance from that head with a fixed L1 origin (latest tip) and 2s timestamps. Reference sequencer is never stopped or displaced.
- **Consequence:** Concurrent with `derivation-check.sh` (different ports/datadir). Kill switch = stop script + `rm -rf` stub datadir; stock op-node restart is a no-op.

### D-T6-2 — Follow-validation via rebuilt payload attributes
- **Context:** Acceptance requires the US-061 verifier (or reference derivation semantics) to “follow” stub-built blocks.
- **Decision:** After sealing N blocks, re-run `BuildPayloadAttributes` for each built block against the same L1 origin and assert (a) parent-hash links and (b) first tx raw bytes equal the derived L1-info deposit. No second EL and no reference-hash compare (stub chain diverges by design).
- **Consequence:** `sequencer-stub` exits non-zero if follow-validate fails; demo script prints per-block follow notes.

### D-T6-3 — Engine API version pair
- **Context:** Stub must document which Engine API methods and `--l2.enginekind` semantics it targets.
- **Decision:** Same pair as US-061 sealing: `engine_forkchoiceUpdatedV3` + `engine_getPayloadV4` (fallback V3) + `engine_newPayloadV4` (fallback V3) + Isthmus `withdrawalsRoot` JSON patch (D-T4-2). Target EL is stock `op-geth` (`--l2.enginekind=geth` equivalent).
- **Consequence:** README / module docs cite this constant (`EngineAPIVersions`); no op-reth path in v1.
### D-0010 — Sepolia US-061 window re-opened: genesis-anchored design cannot verify mid-chain windows
- **Context:** Operator ran `derivation-check.sh --sepolia` (2026-08-04). After integrator fixes (bash-3.2 en-dash, bounded L1 scan via `-from-l1`, RPC-URL redaction), the run failed honestly: `missing derived block 595045 in window (have 1998 batches)`. Root cause: `pipeline.go` numbers batches sequentially from 1 and `verify.go` seals from genesis state — correct for whole-chain 901 replay, impossible for a mid-chain Sepolia window (sealing block N needs state at N−1).
- **Decision:** Sepolia success metric in `prd-phase-6-derivation.md` marked NOT MET / re-opened. Local-901 US-061 acceptance stands. Follow-up task **R2 (window anchoring)** required: (a) number batches by timestamp — `(batch.timestamp − genesis.l2_time)/block_time` — instead of scan position; (b) give the sealing EL a state anchor for mid-chain windows (candidate: copy the reference datadir while the stack is stopped in the dev-sleep window, then `debug_setHead` on the copy; alternative: full genesis replay of ~595K blocks as a one-time overnight run).
- **Consequence:** Sepolia golden-fixture capture is blocked on R2. T6 (sequencer stub, 901-only) is unaffected and may proceed. Findings for the hardening wave: unbounded scans need guards/progress output; Go tools must redact secret-bearing URLs (fixed in `derivation/rpc.go`; sweep `batcher/`/`proposer/` for the same class).

### D-0011 — R2 window anchoring; Wave 4 base: tag `wave4-base`
- **Context:** T6 merged (US-062 done). D-0010 left the Sepolia US-061 metric re-opened. Dependency bumps landed (pion/dtls CVE-2026-54908, klauspost/compress GO-2026-5841).
- **Decision:** R2 implements window anchoring per `tasks/worker-prompts/R2-window-anchoring.md`: timestamp-based batch numbering + sealing-EL state anchor via stopped-stack datadir copy + `debug_setHead` on the copy only. Base = tag **`wave4-base`** (the commit adding the prompt + this entry).
- **Consequence:** After R2 merges, the operator runs the anchored Sepolia window + captures `testdata/sepolia/window.json` (unskips the golden replay test). Then only the hardening wave (H1–H3) remains.

### D-R2-1 — Timestamp-based batch numbering replaces scan-position indexing
- **Context:** D-0010: mid-chain Sepolia window failed because batches were numbered 1..N by L1 scan order.
- **Decision:** Number every decoded batch by `(batch.timestamp − genesis.l2_time) / block_time`; validate `(ts − l2_time) % block_time == 0`; filter to the requested window; de-duplicate by block number (last write wins, log duplicates). Genesis replay (blocks 1–20) uses the same path.
- **Consequence:** L1 inbox scan must cover enough history for the window; numbering no longer assumes scanning from genesis block 1.

### D-R2-2 — Sealing EL state anchor via stopped-stack datadir copy
- **Context:** Sealing block N requires EL state at N−1; genesis-init sealing EL cannot verify mid-chain windows.
- **Decision:** `derivation-check.sh` gains `--anchor-datadir` / `--make-anchor`. Copy `$DATA_DIR/l2/op-geth` while reference EL is stopped (RPC probe + `geth/LOCK` guard). Sealing EL runs from the copy; `debug_setHead` to block `start−1` runs **only** against the copy. Derivation state (parent hash/time, L1 origin, seq number) initializes from reference block `start−1` L1-info deposit decode.
- **Consequence:** Operator must refresh anchor copy after major chain resets. Sepolia runs require anchor copy before `--sepolia`.

### D-R2-3 — L1 scan hardening: progress output + genesis-scan guard
- **Context:** D-0010 hardening riders; Sepolia genesis scan is ~11M blocks.
- **Decision:** Emit L1 scan progress every 100 blocks on stderr. Refuse `-from-l1 0` (genesis scan) when L1 tip > 1_000_000 unless `-scan-from-genesis` / `--scan-from-genesis`. Anchored windows derive `-from-l1` from anchor L1 origin minus `DERIVATION_L1_LOOKBACK` (default 300); Sepolia `--sepolia` keeps safe-head-based bound.
- **Consequence:** Operators must pass explicit scan bounds or anchor metadata for large L1 chains.

### D-0012 — Codex round 2 triage; R3; Wave 5 base: tag `wave5-base`
- **Context:** Codex reviewed PRs #63/#64/#65 (pre-R2 commits). Six findings: three already fixed (l1.go header decode — R2; genesis-anchored windows — D-0010/R2; unbounded scan — `1240943`+R2). Three live: blob base fee hard-coded to 1 in L1-info bytes (false Sepolia mismatches), stub L1-origin defaults to L1 tip (chain invalid under derivation timestamp rules), README SOS transfer step ran `cast send` without sourcing the env (integrator-fixed).
- **Decision:** R3 fixes the two code findings per `tasks/worker-prompts/R3-codex-round2.md`, branching from tag **`wave5-base`**. The operator Sepolia anchored run + fixture capture wait for R3 (blob-fee bug would produce phantom mismatches).
- **Consequence:** After R3 merges: operator Sepolia run → fixture capture → hardening wave (H1–H3) closes the program.

### D-R3-1 — L1 blob base fee via eth_feeHistory (RPC-authoritative)
- **Context:** R3 F1: `marshalL1Info` hard-coded `blobBaseFee = 1`; Sepolia Ecotone+ origins with ≠1 fee produce wrong L1-info bytes → phantom hash mismatches. Spec-computed path needs fork-dependent BPO update fractions on 2026 L1.
- **Decision:** **`eth_feeHistory`** (`baseFeePerBlobGas`) with per-L1-block cache + optional range prefetch; nil/missing → `1` (pre-Cancun / idle Anvil equivalence). Enriched in `BuildPayloadAttributes` for Ecotone+ blocks only.
- **Consequence:** Sepolia verifier compares real blob fees; local 901 still passes (Anvil blob fee = 1). Other `marshalL1Info` fields audited: `baseFee` from origin header, scalars from `SystemConfig`, `MixDigest`/`PrevRandao` from origin — all spec-sourced; no other hard-code fixes needed.

### D-R3-2 — Stub L1 origin from genesis.l1 / head L1-info + timestamp validation
- **Context:** R3 F2: stub defaulted to L1 tip; fresh genesis EL block 1 has `l2_ts = genesis.l2_time + block_time` while tip timestamp is far ahead → invalid under sequencing-window rules; follow-validation missed it by re-deriving with the same wrong origin.
- **Decision:** Default origin = `rollup.json` `genesis.l1` (fresh head) or L1-info deposit on non-genesis head; advance L1 origin only when drift exceeded. `-l1-origin` override validated (rejected if `l2_ts < l1_ts` or past drift). Follow-validation independently asserts timestamp invariant (spec: sequencing window). Effective drift = 1800s with Fjord active (matches op-node README note).
- **Consequence:** `sequencer-stub-demo.sh` builds valid empty blocks; old L1-tip default would fail validation at demo start.

### D-0013 — Sepolia US-061 metric MET; Phase 6 complete
- **Context:** Post-R3 operator runs still mismatched: diagnosis via field-diff of the sealed block in the anchor copy found `parentBeaconBlockRoot` zeroed (EIP-4788 state write → hash change; invisible on beacon-less Anvil). Integrator fix `06b87ac`. A fixture-capture defect followed: `L2Ref.Number` was `json:"-"` (marshal dropped it; unmarshal choked on absence) — fixed with explicit MarshalJSON + nil tolerance.
- **Decision:** Sepolia anchored window **601219–601268** PASS (twice); golden fixture committed; replay test enforces in CI. Phase 6 marked **Done** in both PRDs.
- **Consequence:** Program remainder: hardening wave (H1–H3 + operator drills). Accumulated H-findings: URL redaction sweep (start-script banners print unredacted L1 URL; Go tools fixed), scan guards/progress (done in derivation, pattern for batcher/proposer), CLI-mode dry-walk review habit, QuickNode token rotation (operator, post-debugging).

### D-0014 — Hardening wave (H1–H3); Wave 6 base: tag `wave6-base`; batcher/proposer redaction exception
- **Context:** Phase 6 + money rail complete (D-0013). Final wave = hardening, carrying the program's accumulated findings: unredacted-URL echo sites across `scripts/` and the same error-leak class in `batcher`/`proposer` Go; Google Fonts self-containment gap; regression-guard backfill for the seven operator-found bug classes; CI shell checks.
- **Decision:** Three parallel workers off tag **`wave6-base`** with disjoint allowlists (H1 security/redaction, H2 deps, H3 tests/CI); merge order H2 → H1 → H3. **Exception to the Phase 4/5 freeze:** H1 may make redaction-only edits (+tests) to `batcher/`/`proposer/` Go files; behavior changes remain forbidden. H3 owns `test-helpers.sh` and CI; H2 owns all go.mod/vendors.
- **Consequence:** After H1–H3 merge + H4 operator drills, the parallel-integration program is complete; remaining roadmap items (3a/3b/7/8/9, MR triggers) are future phases outside this plan.

### D-H2-1 — Wave 6 dependency refresh (H2)
- **Context:** H2 off `wave6-base` (D-0014). `derivation/` already carried patched `klauspost/compress` (GO-2026-5841) and `pion/dtls/v3` (CVE-2026-54908); `batcher/`/`proposer/` indirect pins lagged. GO-2026-5932 (`x/crypto/openpgp`) still has no fix. Vendored ethers at 6.13.5; npm latest 6.13.x patch is 6.13.7.
- **Decision:** Bump `batcher/` + `proposer/` indirect compress/dtls to match `derivation/`. Refresh GO-2026-5932 stance (still uncalled in all three modules). Bump vendored ethers to 6.13.7 in all three copies (integrator renamed the files to `ethers-6.13.7.min.js` and updated the three `app.js` imports — outside H2 allowlist). Skip ethers 6.17.0 (minor jump). `scripts/bridge` audit clean; `forge-std` v1.16.2 already at upstream latest — no bump.
- **Consequence:** README advisories section updated (2026-08-04). H2 merges first per D-0014; H1/H3 rebase onto post-merge main only if needed.

### D-H1-1 — URL redaction sweep + vendored fonts (H1)
- **Context:** D-0014 charter; live QuickNode tokens in `L1_RPC_URL` path; batcher/proposer Go tools echoed raw URLs on transport failure; Google Fonts CDN in static apps.
- **Decision:** Wrap all script echo/banner URL prints with `redact_rpc_url`; add `RedactRPCURL`/`RedactErr` to `batcher/` and `proposer/` (mirroring `derivation/rpc.go`); vendor Sora/Syne under each static app; tighten CSP to `font-src 'self'`.
- **Consequence:** H3 regression tests can assume redacted operator logs; no external font fetches at serve time.

### D-H3-1 — Regression guards for debugging-arc bug classes
- **Context:** D-0010..D-0013 found seven real bugs via operator runs (beacon root, L2Ref JSON, timestamp numbering, seq continuation, CLI-mode flags). H3 must pin each class in tests without touching production code.
- **Decision:** Unit tests in `derivation/attrs_test.go`, `derivation/syncstatus_test.go`, `derivation/numbering_test.go`; static dry-walk assertions for `derivation-check.sh` in `scripts/test-helpers.sh`.
- **Consequence:** Future regressions in these paths fail CI before another Sepolia debugging arc.

### D-H3-2 — CI shell-syntax job + golden-fixture replay confirmed
- **Context:** Hardening wave called for `bash -n scripts/*.sh` and confirmation that derivation golden replay runs in CI.
- **Decision:** New `shell-syntax` job in `.github/workflows/ci.yml`; existing `go test ./...` in `derivation/` already runs `TestDecodeLocal901BatcherTx` + `TestSepoliaGoldenSkipped` (confirmed, not duplicated). shellcheck omitted — not on CI runner. Actions remain SHA-pinned.
- **Consequence:** Syntax errors in scripts fail CI independently; golden replay stays part of the derivation unit-test step.

### D-0015 — H3a dispatch; Wave 7 base: tag `wave7-base`
- **Context:** Hardening wave merged (D-H2-1 `058de63`, D-H1-1 `f449795`, D-H3-1/2 `a755e52`; CI green on each). Codex r3716862854 confirmed the US-062 stub continuation path drops `SeqNumber` + origin hash on non-genesis head recovery, and follow-validation seeds from the same in-memory state (validates its own mistake). Prompt: `tasks/worker-prompts/H3a-stub-seq-continuation.md`.
- **Decision:** Dispatch H3a solo on pre-created branch `agent/h3a-stub-seq` off tag **`wave7-base`** (the commit adding this entry — same tag mechanism as D-0007/D-0008). Existing wave tags never move.
- **Consequence:** After H3a merges, only the H4 operator drills remain in this program; handoff diffs against `wave7-base..HEAD`.

### D-H3a-1 — Stub continuation seq preservation + follow-validation independence
- **Context:** Codex r3716862854 (post-H3): stub head-recovery parsed parent L1-info but kept only `L1OriginNumber`, dropping `SeqNumber` and origin hash. `RunSequencerStub` initialized `DerivationState` from zero, so same-origin continuations built seq=0 instead of `parentSeq+1`; follow-validation seeded from the same zero state and validated its own mistake.
- **Decision:** `SeedStubDerivationState` recovers full parent L1-info on non-genesis heads (same origin → `parentSeq+1`; `OriginForL2Timestamp` advance → seq=0 per [derivation spec L2 block seal](https://specs.optimism.io/protocol/derivation.html#l2-block-seal)). `PlanStubBlockInputs` resolves origin per block. Follow-validation seeds only from parent L1-info re-parse, not builder memory. Fresh-genesis path unchanged (`L1OriginNum=0` → first block origin-change seq=0).
- **Consequence:** `sequencer-stub-demo.sh --no-wipe` reproduces continuation; unit tests pin same-origin seq increment, origin-advance reset, and wrong-builder detection.

---

## Escalations

### E-H1-1 — Add `proposer/.gomodcache/` to `.gitignore`
- **Context:** H1 secrets-hygiene sweep; `batcher/.gomodcache/` and `derivation/.gomodcache/` are gitignored; `proposer/.gomodcache/` is not.
- **Needed change:** Append `proposer/.gomodcache/` to root `.gitignore` (H2 or operator).
- **Why not H1:** `.gitignore` outside H1 write allowlist.
- **Status:** applied to main by integrator (`61f7fce`, 2026-08-04).

---

## Template

```
### D-<task>-<n> — <short title>
- **Context:** <one line>
- **Decision:** <one line>
- **Consequence:** <what other tasks must now assume>
```
