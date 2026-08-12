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

### D-0016 — Replica sync-drill access model: Render Web Shell, not SSH tunnel
- **Context:** H4 replica check. `fortel2-replica` is a Render **private service** (`type: pserv`, no public URL by design). SSH port-forwarding was attempted (operator SSH key registered, fingerprint-verified): auth succeeds but Render's gateway closes the session within seconds, with `-N` and with a keep-alive command — tunneling is not supported. `replica-sync-check.sh` therefore has no Mac-reachable `REPLICA_L2_RPC_URL`.
- **Decision:** Drill mechanism is the Render dashboard **Web Shell** on the running instance: JSON-RPC via python3/urllib against `localhost:10000` (op-geth EL; op-node RPC is `:9545`; the image ships no curl). `.env.sepolia` carries a comment, not a URL. First capture (2026-08-04 ~22:05 PT, local stack asleep): chain **852**, head **609591** vs local pre-sleep head 609485 at 20:51 — replica deriving posted batches correctly.
- **Consequence:** The scripted `replica-sync-check.sh` path stays valid for any future Mac-reachable replica (e.g. if the service is ever made public or Private Link is added); until then the H4 replica drill = simultaneous Web-Shell + local head capture with the script's lag rule (`REPLICA_MAX_SAFE_LAG`, default 50, judged against batch-posting delay).

### D-0017 — Parallel-integration program COMPLETE
- **Context:** All waves merged and verified: T1–T3 (Wave 1), T4, T6, R1–R3, Sepolia US-061 window PASS + golden fixture (D-0013), hardening H2→H1→H3 (`058de63`/`f449795`/`a755e52`), H3a (`141acfe`, live double-run verified). H4 operator drills all PASS (see `hardening-findings.md` H4 section): local 901 redeploy, stub continuation, derivation-check, `demo-checklist --sepolia`, fund check, replica sync (lag 41≤50 via D-0016 Web Shell), dev-sleep/wake cycle, cold start **~15 min** (10:53:06→≤11:08, 2026-08-05, log-verified). Drills found and fixed H4-001..003; H4-004 (launchd reload) pending operator click.
- **Decision:** The program defined in `tasks/plan-parallel-integration.md` is closed. Both PRDs' in-scope work is done and operator-verified live. No further worker dispatches under this plan; the `wave*-base` tags remain as history and never move.
- **Consequence:** Remaining roadmap (Phases 3a/3b/7/8/9, MR-3/4/5 triggers, any Sepolia redeploy = Phase 7 gate) is future work outside this plan and starts with a new plan + new decisions entries. Worker-prompt files stay as templates.

### D-0018 — Go live on mainnet for pilot customer: stock OP Stack; custom modules retained
- **Context:** Feasibility review (2026-08-05) for moving from learning chain to a real mainnet L2 — potential SEA bank acquisition + pilot customer running SettlementOS. Findings: batcher burn is a tuning artifact (calldata + 30-block channels + 5-min proposals) — blobs + span batches + relaxed cadence cut L1 cost to single-digit $/day; TPS is a non-issue for settlement (<1 TPS need vs ~200+ ceiling); QuickNode is replaceable by self-hosted L1 primary + paid fallback via the existing `l1_rpc_router.py` pattern; replicas = 2 operator-run + one per counterparty (derivation verifier = counterparty audit tool); scope = stablecoin transfers between institutions + lightweight defi + future RWA, with public-DA transparency flagged to the pilot early; SOS path = revive T5 write-tunnel decision → SOS on 852 staging → settle demo → MR-1 → mainnet.
- **Decision:** Mainnet go-live runs **stock OP Stack releases** (op-batcher on blobs, tuned channel/proposal cadence). The custom `batcher/`/`proposer/` Go modules stay frozen as learning artifacts and emergency backup — not the production path. `derivation/` verifier is promoted to the institutional audit tool. Key custody (HSM/MPC, multisig admin + timelock, security audit) is a gating workstream, longest lead-time item. Sepolia 852 stays staging; mainnet deploy is the Phase 7 gate (fresh genesis + replica republish per D-0013).
- **Consequence:** `tasks/prd-mainnet-pilot.md` (skeleton) seeds the next parallel plan, which expands it into spec/FRDs/user stories. MR-4 (canonical USDC) and MR-3 (paymaster) triggers fire inside that plan. Operator does SOS-side work in its repo first; this repo's next dispatch waits for the new plan.

### D-0022 — R-01..R-10 review-fixes program dispatched; Wave 1 base: tag `wave8-base`
- **Context:** `tasks/review-2026-08-05.md` (baseline `d0d5f69`) found the money-rail write path undecided (P0-1), `rail-interface.json` stale (P0-2), the checked-in launchd schedule diverged from the installed one (P0-3), plus six lower-severity drift/hygiene findings — ten task cards, R-01..R-10. `tasks/plan-parallel-review-fixes.md` sequences them into four waves (trunk-based, pinned-tag-per-wave, serialized squash-merge — same mechanism as D-0007..D-0017) with per-task ownership, model tiers, and a commit/merge contract; Wave-1 prompts are `tasks/worker-prompts/R-01-write-path-spike.md`, `R-03-launchd-reconcile.md`, `R-05-gas-runway.md`, `R-06-phase-glossary.md`.
- **Decision:** Dispatch Wave 1 (R-01, R-03, R-05, R-06) in parallel on branches off tag **`wave8-base`** (the commit adding this entry). Wave 2 (R-02, R-07, R-08) starts only after Wave 1 merges and retags `wave9-base`; Wave 3 (R-04, R-09) after `wave10-base`; Wave 4 (R-10) after `wave11-base`. Wave tags never move. R-01's operator go/no-go (US-012 non-loopback review) is a human decision after Wave 1, not a worker deliverable.
- **Consequence:** IDs D-0019 (R-01), D-0020 (R-02), D-0021 (R-06) are pre-reserved per `tasks/plan-parallel-review-fixes.md` §5 and will append out of numeric order relative to this entry — append order, not ID order, reflects merge order. Handoff reports are reviewed against `tasks/plan-parallel-review-fixes.md` §7 before merge.

### D-0019 — SOS write-path options recorded (T5 revival)
- **Context:** P0-1 / money-rail open question — SOS has no documented off-box write path to chain 852; sequencer RPC is loopback-only with a wide `eth,net,web3,debug,txpool,admin,miner` surface (`scripts/04-start-sequencer-sepolia.sh`).
- **Decision:** Options and dependency map are documented in `tasks/spike-t5-write-path.md` (recommend Tailscale after D1 narrow-to-`eth,net,web3`); **loopback stands for now**; US-012 non-loopback go/no-go remains the operator’s.
- **Consequence:** No ports, binds, or `rail-interface.json` URL changes in this wave; R-02 may truth-up the file without publishing a write URL; transport work waits on operator go after D1.

### D-0021 — Phase-7 vocabulary settled
- **Context:** "Phase 7" collided across fault-proof learning phase, redeploy wipe event, and mainnet-pilot program (P1-6 / R-06).
- **Decision:** Glossary in `prd-l2-learning-chain.md`: Phase 7 (learning) = fault proofs; Redeploy gate = wipe event; Mainnet pilot = Phase 9 track (D-0018). Pilot PRD and money-rail FR-4/replica row use that vocabulary.
- **Consequence:** Readers treat bare "Phase 7" as the learning fault-proof phase; wipe/mainnet entry is always "redeploy gate".

### D-0023 — Wave 1 merged; Wave 2 dispatched (R-02, R-07, R-08); base: tag `wave9-base`
- **Context:** Wave 1 squash-merged in order R-01 (`7d9ec0d`) → R-03 (`d07102b`, incl. E-R03-1 wake-comment fix by integrator) → R-06 (`3bc8472`, decisions append conflict resolved in merge order) → R-05 (`0964b2d`). Full `test-helpers.sh` green post-merge incl. five new gas-runway cases; `check-launchd.sh` live run OK (1 WARN: fdautil wrapper) after operator removed the stale `dev-wake` plist; first gas sample recorded (samples live in `$DATA_DIR`, not repo `data/` — accepted deviation, safer than the card's location).
- **Decision:** Wave 2 = R-02 (rail-interface v2), R-07 (PRD hygiene + Phase-7 wording sweep R-06 escalated), R-08 (verification-limitation doc + E-R06-1 one-liner) on branches off tag **`wave9-base`** (the commit adding this entry). Prompts: `tasks/worker-prompts/R-02-rail-interface-v2.md`, `R-07-prd-hygiene.md`, `R-08-verify-limitation.md`. Merge order R-02 → R-07 → R-08. D-0020 remains reserved for R-02.
- **Consequence:** Wave 3 (R-04, R-09) branches from `wave10-base` after Wave 2 merges; H4-004 closes on the first post-reconcile 04:00 wake log; second gas sample due ≥1 h after the first.

### D-0020 — `rail-interface.json` v2 truth-up (addresses unchanged)
- **Context:** P0-2 / P0-3(b) — v1 (`updated` 2026-07-24) still said Phase 6 pin, advertised a non-existent replica read URL, and omitted nightly downtime; R-01 (D-0019) left loopback / no published write URL.
- **Decision:** Bump to `"version": "2"`, `"updated": "2026-08-05"`: rewrite `resetPolicy` (Phase 6 done; 2026-07-22 deploy remains pinned per D-0018), set `replica.readRpcUrl` to `null` with Web Shell `accessModel` (D-0016), add top-level `availability` (23:00–04:00 America/Los_Angeles), `l2Metadata`, and `openQuestions`. No bridge proxy, chain ID, or sequencer/L1 RPC URL values changed; no write URL published.
- **Consequence:** SOS/consumers treat v2 as the contract; R-04 may add a drift guard against `deployments/sepolia/deployments.json`; post–US-012 go write URL is a later bump per `tasks/spike-t5-write-path.md` §5.

### D-0024 — Wave 2 merged; Wave 3 dispatched (R-04, R-09) **serially**; base: tag `wave10-base`
- **Context:** Wave 2 squash-merged R-02 (`58945d5`) → R-07 (`3450042`) → R-08 (`801e434`), plus the first live gas-runway record (`5cec454`). All suites green post-merge; pushed `cac380d..5cec454`. Running three workers concurrently through one working folder made the app's branch label unreliable (it showed the last-selected branch while another session wrote); git showed **no cross-contamination** — each branch held exactly its allowlisted files — but the operator lost real time to the ambiguity.
- **Decision:** Wave 3 = R-04 (rail-interface drift guard) then R-09 (small fixes), run **one at a time, not in parallel**, off tag **`wave10-base`** (the commit adding this entry). R-04 merges before R-09 starts. Rationale: they are the only two remaining pre-R-10 tasks, both small, and serial execution removes both the `test-helpers.sh` append collision and the folder ambiguity entirely — parallelism buys minutes here and costs clarity.
- **Consequence:** R-09's prompt tells it to confirm its base tag at branch time (it may be a post-R-04 tag). Wave 4 (R-10, consumer docs) follows from `wave11-base` and closes the R-programme; the review's §4 Final QA runs in full after it. Integrator-found items folded into Wave 3: stale `21:00` in `prd-mainnet-pilot.md:48` → R-09.

### D-0025-pending — Wave 3 merged; Wave 4 dispatched (R-10, final task); base: tag `wave12-base`
- **Context:** Wave 3 ran **serially** per D-0024 and it worked cleanly: R-04 (`805395c`, offline drift guard + CI step, 20 PASS, E-R04-1 scoping `l2Metadata.rollupConfig` out because `deployments/sepolia/.deployer/` is gitignored and absent on CI) then R-09 (`41c5941`, router reference, D-0016 env comment, `TestSepoliaGoldenReplay` rename, stale 21:00). Nine of ten R-tasks are merged; suites green at each step.
- **Decision:** Wave 4 = **R-10** alone (consumer-facing availability + write-path docs) off tag **`wave12-base`** (the commit adding this entry), prompt `tasks/worker-prompts/R-10-consumer-docs.md`. R-10 additionally closes **E-R02-1** (the `rail-interface.json` `notes` sentence contradicting `replica.readRpcUrl: null`) as a sanctioned scope extension, wording-only, no version bump. Its own decisions entry is **D-0025**; this entry is the dispatch note and is superseded in numbering by R-10's append.
- **Consequence:** After R-10 merges, the review's §4 Final QA runs in full (automated by integrator; live/host section by operator). Then the R-programme is closed and the next plan is the mainnet-pilot expansion per D-0018. Outstanding operator items carried forward: US-012 write-path go/no-go (D-0019), H4-004 wake confirmation, and batcher gas runway (P1-5, first live burn recorded in `hardening-findings.md`).

### D-0025 — Consumer docs carry availability + write-path status; E-R02-1 closed
- **Context:** P0-3(b) — nightly downtime and loopback-only writes were true in the repo (R-01…R-03) but invisible to a SettlementOS integrator reading only consumer docs; `fortel2-sepolia.notes` still said prefer replica reads when reachable despite `replica.readRpcUrl: null`.
- **Decision:** README SOS onboarding step 0, coordination onboarding gate, and money-rail FR-2 now state availability (**23:00–04:00** local) and write-path status (loopback today; US-012 go/no-go outstanding; link `tasks/spike-t5-write-path.md`). E-R02-1 closed by rewriting the one `notes` sentence — reads today land on the sequencer; no reachable replica URL (D-0016); no version/`updated` bump.
- **Consequence:** SOS can plan retry/backoff and colocation from README alone; off-box writes remain blocked on the operator US-012 go/no-go from D-0019.

### D-0026 — R-programme COMPLETE; nightly window changed to 23:45–03:00
- **Context:** All ten review tasks (R-01..R-10) from `tasks/review-2026-08-05.md` merged in four waves and pushed; review §4 automated QA run in full and green (`bash -n` 49 scripts, `test-helpers.sh`, `rail-interface-check.sh`, `forge test` 15/15, all three Go modules incl. `TestSepoliaGoldenReplay` matched=50, `node --test` 61/61, pipeline snapshot); addresses and chain IDs byte-identical to `d0d5f69` across the whole programme; CI green. H4-004 closed (wake fired 04:00, log-verified). Separately, `launchctl print` revealed the **sleep** agent was still running a loaded Hour=21 definition while its plist file said 23 — H4-004's bug class recurring one layer deeper, invisible to `check-launchd.sh` because that compares file-to-file, never file-to-loaded.
- **Decision:** Programme closed. Operator set the nightly window to **sleep 23:45 / wake 03:00** `America/Los_Angeles` (2026-08-11), applied to both plists, `launchd/README.md`, `README.md` (schedule paragraph + SOS onboarding step 0), `tasks/coordination-settlementos.md`, and `rail-interface.json` `availability`; installed copies re-copied and bootout/bootstrapped, with `launchctl print` confirming Hour=23/Minute=45 and Hour=3 actually loaded. Copying the repo wake plist over the installed one also removed LaunchControl's `fdautil` wrapper.
- **Consequence:** The shorter outage means ~20.75 awake hours vs 17, roughly +22% daily batcher burn. `check-launchd.sh` still cannot see loaded-vs-file drift — a known gap; verifying a schedule change requires `launchctl print`, not the checker. Known unresolved drift: `com.steve.fortel2-health` repo 5:05 vs installed 5:00, so the checker exits 1 until reconciled.

### D-0027 — Batcher funding is a cross-repo dependency; ForteL2 watches it and trusts facts over labels
- **Context:** The batcher's L1 balance is funded solely by `chainbank-wallet-reconciler` — a Render cron in the **ChainBank** repo (`0 */6 * * *`, flat 0.6 ETH under policy, verified sends 2026-08-06 ×2 and 08-08). Nothing in ForteL2 started, monitored, or alerted on it; a silent stop would leave L2 producing blocks while batches stopped reaching L1. First live measurement also confirmed P1-5: 0.169 ETH/day burn, batcher under floor the day the meter shipped.
- **Decision:** `scripts/funding-watch.sh` (new) answers "is the external funder still working?" from local gas samples, wired into the daily 05:05 health agent (additive; can never fail the pipeline-health snapshot). It optionally queries ChainBank's `GET /health/funding` (token in `.env.sepolia`, gitignored) but **derives from facts, not their rollup labels**: escalates on `lastRun.finishedAt` older than tolerance and on our own wallet entry — matched by address — reading `blocked`/`failed`. Rationale: the rollup spans five wallets, three of them ChainBank's, and ChainBank confirmed two Bugbot label defects that under-report severity. Escalation only; a healthy label never de-escalates a local balance breach, and an unusable endpoint falls back to local inference. **Deliberate divergence from ChainBank's guidance:** they advise treating `not_reconciled` as inventory rather than a funding failure — correct for their wallets, wrong for ours, since our batcher being excluded from the reconciler means auto-funding is off; ForteL2 warns while the balance holds and fails once also under policy.
- **Consequence:** ForteL2 now detects funder death within ~24 h (bounded by sampling frequency). Two floors exist and must not be conflated: `0.15` tooling floor (time-to-breakage, what `days_to_floor` measures) vs `~0.6` funding policy (time-to-refill). Auto-funding erases burn-measurement windows, so P7-0's cost model needs either an uninterrupted drawdown or subtraction of the reconciler's `weiTransferred`. Cross-repo ask recorded in `tasks/worker-prompts/CB-01-funding-observability.md`; ChainBank shipped CB-03 (500 fixed, `wallets[]` now covers all policy wallets, new `not_reconciled` status), verified live 2026-08-11.

### D-0028 — `networkId` settled as `fortel2-sepolia` (SOS-owned, fixed across re-genesis); re-genesis is an SOS-notified event
- **Context:** `rail-interface.json` v2 shipped `networks.fortel2-sepolia.networkId = "fortel2-sepolia"` while listing the string as an openQuestion (`fortel2-sepolia` vs `forte-l2`) — the review's R-02 left it open because the registry key is SOS's to choose. Asked 2026-08-11; SOS answered that it was never an open choice on their side. The id is live: registry key in `lib/networks.ts` (chain 852), filename of their deployment overlay (`chain/deployments.fortel2-sepolia.json`, sole copy of their generated ForteL2 wallet keys), stem of `FORTEL2_SEPOLIA_RPC_URL` / `FORTEL2_SEPOLIA_READ_RPC_URL`, and the literal `fortel2-` prefix their RPC retry policy matches to set retries to 0 on a single-sequencer rail. Contracts deployed and payments settled under it 2026-08-07. `forte-l2` would have renamed a live key for nothing.
- **Decision:** Keep `"fortel2-sepolia"` unchanged; drop the openQuestion (`openQuestions` now empty). `rail-interface.json` bumped to `"version": "3"` because `resetPolicy` changed (below), and `$schema_note` now states that networkIds are SOS registry keys, fixed and **stable across re-genesis** — a wipe changes addresses, never the id — so a future regeneration of this file must not reopen the question. Sibling `fortel2-local` (901) already matches their convention `fortel2-<environment>`, lowercase, hyphenated. Step 5 of `tasks/spike-t5-write-path.md` needs no id coordination: when US-012 clears, SOS simply points `FORTEL2_SEPOLIA_RPC_URL` at the published URL.
- **Consequence:** Two obligations now sit on the redeploy gate, recorded in `resetPolicy`, README "Network reset procedure" step 1, and the coordination replica table. (1) **SOS is a notified party** alongside replica operators: ≥1 day advance notice, plus the new contract addresses once step 4 produces them — a re-genesis expires every ForteL2 address they hold (escrow, three mock tokens, TokenizedMMF), kills cited tx hashes, and makes the 11 ForteL2 rows in their *live public* explorer address book wrong; their recovery is redeploy-or-adopt, re-seed wallets, re-verify one settlement, republish the address book. (2) **SOS asked that the re-genesis and the off-box write-URL publish land in the same beat**, since either alone costs them that full cycle and both together cost one. That couples two decisions previously independent — US-012 (D-0019) and the Phase 7 gate (D-0018) — and the coupling is *not* accepted here: it is a scheduling preference to weigh when US-012 is decided, not a constraint on it. Also flagged back to SOS: they believe the re-genesis comes "after Phase 7/8", but per README the redeploy **is** the Phase 7 entry gate, so it lands earlier than they are planning for.

### D-0029 — Supersedes D-0028 clause (2): SOS withdrew the same-beat ask; US-012 is decoupled from the redeploy again
- **Context:** D-0028 recorded SOS's request to land the Phase 7 re-genesis and the off-box write-URL publish in the same beat, and left it as a preference to weigh at US-012 time. Asked them what a recovery cycle actually costs. Their answer withdrew the ask outright (2026-08-11) and materially revised the blast radius stated in D-0028: SOS is a proof of concept with **one user**, and **nobody outside sees the rail before the re-genesis** — so the "live public explorer address book" framing, which was the strongest argument for coupling, does not describe a real external audience today. They also pre-emptively declined any funding ask, and confirmed their own docs already read "entry gate" (the ordering correction landed).
- **Decision:** Coupling dropped. The write URL ships whenever the operator US-012 go/no-go clears (D-0019) — it is **not** held for the Phase 7 redeploy (D-0018). Same-beat language removed from `rail-interface.json` `resetPolicy` and README "Network reset procedure" step 1, both of which now say explicitly that the two are independent, so a future reader cannot re-derive the coupling from a stale sentence. `rail-interface.json` bumped `"version": "3"` → `"4"` (second `resetPolicy` change the same day; the bump rule is mechanical and SOS keys off it).
- **Consequence:** US-012 is a clean single-variable decision again — exposing a write-facing RPC off-box, judged on its own security merits with no SOS scheduling weight attached. The **notice obligation survives unchanged and is the only live commitment**: ≥1 day of advance warning before a re-genesis, plus the new contract addresses once they exist; SOS reaffirmed a day is plenty. Treat D-0028's severity language about SOS's explorer as overstated per this entry. Nothing is owed to SOS; nothing of theirs blocks ForteL2. The registry-id thread is closed on both sides.

### D-0030 — US-012 resolved: **GO** for an authenticated off-box write path; public reads move to the replica; Tailscale rejected
- **Context:** Operator ran the US-012 review (D-0019/D2) 2026-08-11. The spike's standing recommendation was option 2 (Tailscale tailnet-only), written when SOS was assumed to be a colocation candidate. Two operator inputs invalidated it: `settlementos` is already live on Render (`srv-d9tafn3m8hqs73cks7cg`, own workspace, `StephenForte/settlementos`) where a tailnet node is awkward, and the design goal is an explicitly **public** rail with the mini demoted to dev work after Phase 7. Gas runway was green at decision time (batcher 0.671 ETH, 0.168 ETH/day, `days_to_floor` 3.1, exit 0), retiring D6 as a blocker. Also clarified: "super low gas" means low **user transaction fees**, not low operator spend — same lever either way (blobs cut both the L1 data-fee component users pay and total burn), and still P7-0, not a write-path decision.
- **Decision:** **GO**, recorded in README "US-012 non-loopback go/no-go", for **one authenticated write listener and nothing else**: `eth,net,web3` via Cloudflare tunnel dialing `127.0.0.1`, audience = the `settlementos` Render service only, auth = Cloudflare Access service token held as a Render env var, rollback = revoke token / stop `cloudflared`. **D1 is a hard precondition** — the sequencer still serves `admin,miner,debug` with `vhosts=*`, and narrowing must ship before any tunnel starts. Option 2 rejected (wrong shape for a public rail; Render can't cleanly hold a tailnet node). Option 3's deny-all Access rejected in favour of splitting by *service*: writes authenticated on the mini, reads public on the replica. Option 5 (relocate) **deferred into the Phase 7 re-genesis**, where it is near-free because that wipe destroys the state a standalone migration would have to move.
- **Consequence:** Three findings are now load-bearing and are recorded in the README so they cannot be re-derived away. (1) **Writes must stay authenticated even as reads go public** — transactions become batcher calldata burning L1 ETH refilled by an external funder (D-0027), so an open write endpoint is a stranger's lever on operator spend, and tuning L2 fees down (P7-0) makes spam *cheaper* while leaving the cost with the operator. (2) **The replica lags ~3m10s** (94 blocks, measured 2026-08-11, corroborated by its own `age=` field) because it derives from L1 batches rather than following the sequencer — so it cannot serve read-your-own-write and SOS must poll receipts on the write endpoint; a settle-and-confirm loop pointed at the public replica reads as failed transactions. (3) **The replica serves `debug`** (`--http.api=eth,net,web3,debug,txpool`, verified in `fortel2-replica/entrypoint.sh`), so `debug_traceTransaction` against a ~908k-block chain would be public and free — it needs the same narrowing as D1 before exposure, EL (port 10000) only, never op-node (9545). Replica exposure is deliberately **not** part of US-012: different host, never on loopback, no `lib.sh` impact — keeping it separate leaves US-012 a single-variable decision about the mini. Work items: `tasks/worker-prompts/T5-D1-narrow-sequencer-rpc.md`, `tasks/worker-prompts/MR-2-public-read-path.md`.

### D-0031 — Public replica URL stays unpublished; filter is live on the Private Service
- **Context:** D-0030 split writes (authenticated on the mini) from reads (replica). MR-2 narrowed the replica RPC; it is live on `fortel2-replica:10000`.
- **Decision:** Do not publish `networks.fortel2-sepolia.replica.readRpcUrl` in `rail-interface.json`. No public `onrender.com` read URL until a diskless reverse-proxy (or equivalent) exists. The live service stays a Private Service.
- **Consequence:** SOS may use the private hostname via env (D-0032). Integrators reading only `rail-interface.json` still see `readRpcUrl: null`.

### D-0032 — SOS uses the replica over Render private network; rail-interface read URL stays null
- **Context:** MR-2 filter is live on Private Service `fortel2-replica:10000` (Oregon). SOS already splits readClientFor vs sequencer writes. Operator verified `eth_chainId` → `0x354` from `settlementos` Shell to that hostname (2026-08-12).
- **Decision:** SettlementOS sets `FORTEL2_SEPOLIA_READ_RPC_URL=http://fortel2-replica:10000`. `networks.fortel2-sepolia.replica.readRpcUrl` in `rail-interface.json` remains `null` until a public read URL exists.
- **Consequence:** Integrators must not treat the private hostname as a published rail URL. Writes and confirm() stay on the sequencer / authenticated write path (D-0030).

### D-0033 — Write RPC filter closes desynced keep-alive and caps chunked headers
- **Context:** Replica MR-2 proved unbounded chunk-size lines, trailer floods, and keep-alive smuggle after oversize bodies. Mini filter still has those reads; cloudflared will sit in front of it.
- **Decision:** Port MAX_LINE_BYTES=8192, MAX_TRAILER_LINES=64, body budget includes size lines/trailers, ValueError → 400 Connection: close. Allowlist unchanged (writes still allowed).
- **Consequence:** T5-TUNNEL (D-0034) may proceed.

### D-0034 — Authenticated Cloudflare tunnel to L2_WRITE_RPC_PORT (:9555)
- **Context:** D-0030 GO; D1 filter on loopback :9555; SOS reads use the replica (D-0032).
- **Decision:** cloudflared origin is http://127.0.0.1:9555 only. Access service token; audience = settlementos Render. L2_RPC_URL stays loopback. rail-interface write URL not published in this change.
- **Consequence:** SOS FORTEL2_SEPOLIA_RPC_URL + CF Access headers are a follow-up. Rollback = stop cloudflared / revoke token.

---

## Escalations

### E-R02-1 — `fortel2-sepolia.notes` still says prefer replica reads when reachable
- **Context:** R-02 set `replica.readRpcUrl` to `null` (D-0016); `notes` still says "Reads: prefer replica when reachable."
- **Needed change:** Align the notes sentence with null read URL / sequencer interim reads (D8 in T5 spike); card steps did not authorize a notes rewrite.
- **Why not R-02:** Outside the nine instruction steps; left for integrator or R-10 consumer-doc pass.
- **Status:** open.

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
