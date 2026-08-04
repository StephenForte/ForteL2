# Worker prompt — T2: Phase 6 derivation spike (US-060)

Copy everything below the line into the worker. Run on the **strongest model**.

---

You are a protocol-engineering worker on the ForteL2 repo (personal OP Stack learning L2, chain 852 on Sepolia, chain 901 local). Your task is **T2** in `tasks/plan-parallel-integration.md`. Read that plan's §5 (commit & merge contract) and `tasks/decisions.md` before starting; both bind you. This is a **timeboxed spike** (US-060 in `tasks/prd-l2-learning-chain.md`): the deliverable is understanding + a PRD, **not** a derivation implementation.

## Goal

Ground Phase 6 derivation scope in the real wire format: decode at least one real batch from this chain's L1 history, relate it to known L2 blocks, decide the implementation shape, and write the PRD that the US-061 verifier worker will execute against.

## Read first

- `tasks/prd-l2-learning-chain.md` — Phase 6 section (US-060..063), Technical Considerations, deployment constraint (**Sepolia deploy is pinned; no redeploy, ever, in this task**)
- `batcher/` — the whole module. It already implements frames (`frame.go`), zlib channels (`channel.go`), singular batches (`singular.go`), and `cmd/decode-l1` fetches an L1 batcher tx and prints frame metadata. **Your spike starts from this, not from zero.**
- `tasks/prd-phase-4-batcher.md` + `tasks/spike-phase-4-batcher.md` — the house style for spike notes and phase PRDs (match it)
- `proposer/` — for the output-root side of the comparison story
- ethereum-optimism/specs: derivation pipeline (frames → channels → batches → payload attributes), batch formats (singular + span), L1 info deposit tx

## Work items

1. **Decode real data:** using `cmd/decode-l1` and/or a throwaway extension, walk frames → channel reassembly → decompression → batch decode for at least one real batcher tx from the pinned Sepolia (852) history — or local 901 history if you cannot reach an L1 RPC (see constraints; say which you used). Local Anvil history is acceptable for format work; note that Sepolia batches may include **span batches** (stock op-batcher) while `batcher/` only emits singular — decoding span batches is the likely new ground. Record what you could and could not decode.
2. **Relate to L2 blocks:** map decoded batch contents to concrete L2 block numbers/hashes as reported by reference op-node data (`optimism_syncStatus` semantics; use recorded data in the repo/README if no live node is reachable — do not fabricate).
3. **Decide (and record in `tasks/decisions.md`):**
   - `D-T2-1`: verifier-only derivation tool first vs block-building sequencer stub (PRD expects verifier-first; confirm or argue).
   - `D-T2-2`: module shape — new `derivation/` Go module (default per D-0006) vs extending `batcher/`. Consider: `batcher/` frame/channel code is encode-oriented; what's reusable for decode, what must be new, can `derivation/` import `github.com/StephenForte/ForteL2/batcher` cleanly?
   - `D-T2-3`: scope of the US-061 comparison window (how many blocks, which head labels, what counts as a match).
4. **Write `tasks/spike-phase-6-derivation.md`:** spec sections cited, what was decoded (tx hashes, channel IDs, batch types), gaps hit, decisions taken. Match the Phase 4 spike-notes style.
5. **Write `tasks/prd-phase-6-derivation.md`:** an executable PRD for US-061 (and gated US-062) with concrete acceptance criteria: inputs (L1 RPC + rollup config from the active deploy tree), outputs (derived block window + diff-vs-reference), runbook shape, non-goals (no P2P, no EVM reimpl, no redeploy). The next worker must be able to start from this file alone.
6. **Tick US-060 boxes** in `tasks/prd-l2-learning-chain.md` you actually satisfied; update the Phase 6 roadmap row status only.

## Constraints

- **No Sepolia spend, no redeploy, no funded keys.** You must never ask for or handle private keys. If no L1 RPC is reachable from your environment, work from local 901 data (`./scripts/start-all.sh` stack per AGENTS.md if your VM has the toolchain) and clearly mark the Sepolia-decode step as operator-verification-needed.
- Spike code is throwaway: keep experiments in `batcher/cmd/` as a **new** command dir or in the spike doc as snippets — do not modify existing `batcher/*.go` files or their tests. If a helper genuinely needs changing, escalate (`E-T2-n`), don't edit.
- Do not start US-061 implementation, however tempting.

## Write allowlist (exclusive)

`tasks/spike-phase-6-derivation.md` (new) · `tasks/prd-phase-6-derivation.md` (new) · `tasks/prd-l2-learning-chain.md` (US-060 checkboxes + Phase 6 row only) · optionally one new dir `batcher/cmd/<new-tool>/` (new files only) · `tasks/decisions.md` (append-only)

## Contract

- Branch `agent/t2-derivation-spike` off BASE_SHA (decisions.md D-0001).
- Commits: `spike(derivation): <what>`.
- Tests: if you added a `batcher/cmd/` tool, `cd batcher && go build ./... && go test ./...` must stay green; paste results.
- No merging, no pushing to main.

## Handoff report — REQUIRED as your final chat message

Your last message must BE the report: one copy-pasteable markdown block with exactly these numbered sections. Putting it only in a PR description or a repo file does not count — work without a final-message report is bounced unreviewed.

1. Branch + base SHA; `git diff --stat`
2. Allowlist compliance
3. What was decoded: chain (852/901), tx hashes, frame/channel/batch summary; what failed and why
4. Decisions recorded (D-T2-1..3) with one-line rationale each
5. The three things most likely to bite the US-061 worker
6. Tests run + verbatim results
7. Operator verification needed (e.g. re-run decode against live Sepolia RPC)
8. Anticipated conflicts with T1/T3 (expected: only PRD roadmap-table adjacency)
