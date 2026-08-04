# Worker prompt — T4: minimal derivation verifier (US-061)

Copy everything below the line into the worker. Run on the **strongest model**.

---

You are a protocol-engineering worker on the ForteL2 repo (personal OP Stack learning L2; local chain 901 on Anvil L1, Sepolia-backed chain 852 — the Sepolia deployment is **pinned; no redeploy, no L1 spend, ever**). Your task is **T4** in `tasks/plan-parallel-integration.md`. Binding context, read all before coding:

- `tasks/prd-phase-6-derivation.md` — **your spec** (as amended: reference stack is READ-ONLY; Engine API sealing only on a separate EL instance)
- `tasks/decisions.md` — D-T2-1..3 and D-R1-1 bind you; append `D-T4-n` for your own decisions
- `tasks/spike-phase-6-derivation.md` — what the spike decoded and where it stopped
- `tasks/plan-parallel-integration.md` §5 (commit contract) + AGENTS.md (always)
- `batcher/` — the decode helpers you import (`ParseBatcherTxPayload`, `JoinFrameData`, `DecompressChannelZlib`, `ReadChannelBatches`, `DecodeSingularBatch`, …) and `cmd/decode-full` as a worked example

## Goal

Implement US-061: a from-scratch derivation **verifier** — new `derivation/` Go module — that reads L1 (batcher txs to the inbox + Portal deposits), derives an L2 block window, and checks it against the reference stack. Acceptance is D-T2-3's match rule: `derivedHash == eth_getBlockByNumber(n).hash` for every block in the window; metadata-only comparison is explicitly insufficient.

## Two facts the PRD does not spell out (do not rediscover them the hard way)

1. **Module wiring:** neither Go module in this repo is version-tagged, so a bare `go get github.com/StephenForte/ForteL2/batcher` resolves against the remote, not your checkout. `derivation/go.mod` needs:
   ```
   require github.com/StephenForte/ForteL2/batcher v0.0.0
   replace github.com/StephenForte/ForteL2/batcher => ../batcher
   ```
   CI runs per-module `go test` from the module dir, so the relative replace works there too.
2. **Hash-match implies execution.** Payload attributes alone cannot produce a block hash — state root and receipts root require executing the txs. Per the amended PRD you MAY seal via Engine API, but **only on a separate EL instance**: own datadir (under `$DATA_DIR`, never in the repo), own ports, own JWT, initialized from the same genesis as the active deploy tree. The live reference `op-geth`/`op-node` are read-only oracles (`eth_getBlockByNumber`, `optimism_syncStatus`) — never send `engine_*` to them. If running a second EL proves infeasible in your environment, **escalate (`E-T4-n`) and stop** — do not silently downgrade acceptance to metadata-only (D-T2-3 forbids it).

## Work items

1. **`derivation/` Go module** (own `go.mod` + README citing the spec sections you implement): L1 fetch/filter (inbox txs from authorized batcher, Portal deposit events) → frames → channel → batches (singular `0x00` decode; **span `0x01` decode required** even though sampled history is singular-only) → L1-info + deposit + user-tx sequencing → payload attributes per derived block → sealing via the separate EL → hash comparison against the reference EL.
2. **Window & flags** per D-T2-3: local 901 default blocks 1–20 inclusive (`--start-l2`/`--end-l2` override), or `--channel-tx <L1 hash>` to derive one channel's span. Sepolia 852: 50 blocks ending at reference `safe_l2.number` — implement, but live verification is the operator's.
3. **`scripts/derivation-check.sh`** (new): sources `scripts/lib.sh` (read-only — do not edit it), respects `FORTEL2_ENV`, uses the standard RPC asserts, runs the verifier over the default window, exits non-zero on first mismatch, prints `safe_l2`/`unsafe_l2` from `optimism_syncStatus`. Manages the separate sealing EL's lifecycle (start/stop/clean) without touching the reference stack's datadir; if that requires privileged `start_bg`/`stop_bg` patterns, prefer a plain foreground child process you own.
4. **Tests** (`go test ./...`): unit tests for each pipeline stage using committed fixtures — synthetic frames/channels plus real calldata captured from local 901 history (the spike's decode commands show how). Structure a golden-fixture slot for the Sepolia window (`testdata/sepolia/`, load-if-present, skip-with-notice otherwise) — the operator capture (T2 handoff item) is still pending; do not fabricate it.
5. **Run it for real on local 901:** the worker VM can run the stack (`./scripts/start-all.sh`, see AGENTS.md Cursor Cloud notes). Produce at least one verified window (derived hashes == reference hashes) and paste the run output in your handoff. If the VM cannot sustain stack + second EL, escalate rather than claim it.
6. **Docs:** README — new "Phase 6: derivation verifier" subsection (start command, what a pass/fail looks like, separate-EL note); `tasks/prd-phase-6-derivation.md` — tick only criteria you satisfied and verified; `tasks/prd-l2-learning-chain.md` — US-061 checkboxes + the derivation fragment of the Phase 6 row only. Anything live-Sepolia stays unticked under "operator verification needed."
7. **Decisions:** append `D-T4-n` for every judgment call (span-batch test vectors, EL lifecycle model, fixture format). Silent decisions get bounced.

## Out of scope (hard)

US-062 sequencer stub (gated; needs separate approval) · any `engine_*` call to the reference stack · modifying `batcher/*.go`, `proposer/`, `scripts/lib.sh`, `viewer/`, `blocks/`, `dapp/` · Sepolia broadcast/spend/keys · redeploy · P2P · containers on this host · datadirs or fixtures >1 MB committed to the repo.

## Write allowlist (exclusive)

`derivation/` (new) · `scripts/derivation-check.sh` (new) · `README.md` (new Phase 6 derivation subsection only) · `tasks/prd-phase-6-derivation.md` (checkbox ticks + a short "implementation notes" appendix only) · `tasks/prd-l2-learning-chain.md` (US-061 rows + Phase 6 row derivation fragment only) · `.github/workflows/ci.yml` (append one `derivation` Go-test step only) · `tasks/decisions.md` (append-only) · `.gitignore` (derivation scratch/datadir patterns only, if needed)

## Contract

- Branch `agent/t4-derivation-verifier` (pre-created) off tag `wave2-base` — verify with `git merge-base --is-ancestor wave2-base HEAD`.
- Commits: `feat(derivation): …`, `test(derivation): …`, `docs(prd6): …`; squash-merged later.
- Tests before done (paste verbatim): `cd derivation && go build ./... && go test ./... && govulncheck ./...`; `(cd batcher && go test ./...)` unchanged-but-verified; `./scripts/test-helpers.sh`; the local-901 verified-window run output.
- No merging, no pushing to main.

## Handoff report — REQUIRED as your final chat message

Your last message must BE the report: one copy-pasteable markdown block with exactly these numbered sections. Putting it only in a PR description or a repo file does not count — work without a final-message report is bounced unreviewed.

1. Branch + base (`wave2-base`); `git diff --stat wave2-base..HEAD`
2. Allowlist compliance
3. Pipeline stages implemented vs deferred, with file pointers; the verified local-901 window (numbers, hashes, PASS/FAIL output)
4. Tests run + verbatim results (incl. govulncheck)
5. PRD boxes ticked vs left for operator, with why
6. `decisions.md` entries (D-T4-n) and escalations
7. Anticipated conflicts (expected: README/PRD row adjacency only)
8. Operator actions needed (Sepolia golden fixture capture, live 852 window run, …)
