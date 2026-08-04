# Parallel-worker plan — money rail closeout + Phase 6 + hardening

**Status:** proposed (2026-08-03) · **Owner:** VP Eng · **Scope PRDs:** `prd-money-rail.md`, `prd-l2-learning-chain.md` (Phase 6), + hardening phase
**Companion:** `tasks/decisions.md` (shared decisions log), `tasks/worker-prompts/` (ready-to-run prompts)

---

## 1. Verified state (claims checked 2026-08-03, not taken on faith)

| Claim | Verdict | Evidence |
|---|---|---|
| Phases 0–3, 2a–2d done | **Holds** (repo-side) | `deployments/sepolia/deployments.json`, scripts, replica pack tooling all present. Live-chain health not verifiable from a worker VM — operator drill covers it in hardening (H4). |
| Phase 4 batcher done | **Holds** | `batcher/` builds; `go test ./...` green (3 pkgs). Frame/channel/singular-batch code + `cmd/decode-l1` exist. |
| Phase 5 proposer done | **Holds** | `proposer/` builds; `go test ./...` green. |
| MR-0 "in progress" | **Understated — mostly done** | `deployments/rail-interface.json` v1 exists with bridge proxies, reset policy, health checks, SOS gate. README SettlementOS section exists. `replica/README.md` consumers table exists. Only the PRD checkboxes (US-MR-001..003) are stale. |
| MR-1/MR-2 "ready" | **Holds, and terminal for this repo** | Remaining MR-1 work (deploy + settle) lives in the SOS repo, not here. |

**Feasibility pushback (read before assigning workers):**

1. **MR-3 (paymaster), MR-4 (USDC), MR-5 (AuditAnchor) are not plannable now.** Each is gated on SOS needing it / being stable on 852. Do not burn workers on them; they enter the tree when the SOS-side trigger fires (logged in `decisions.md` as triggers).
2. **US-062 (sequencer stub) cannot be parallelized** with US-061 — the PRD gates it on US-061 acceptance and says "out of scope unless separately approved." It is Wave 3, opt-in.
3. **Hardening splits into agent-runnable vs operator-only.** Anything needing the live Mac stack, Sepolia keys, or the Render dashboard (cold-start drill, replica sync check, fund checks) cannot run on a worker VM. Those are operator checklists, not worker tasks.
4. **`main` is dirty.** `.env.sepolia.example`, `README.md`, `scripts/dev-sleep.sh` have uncommitted Render-RPC-schedule changes; `tasks/.solomd/` is untracked. Wave 0 (operator) commits these **before** any worker branches, or every worker inherits a README conflict.
5. **US-060 → US-061 is inherently sequential.** The spike produces the decisions (verifier-first vs sequencer, module shape) that the verifier task consumes. Don't launch T4 until T2 merges.

---

## 2. Branching scheme — verdict on yours

Your current shape (N agents off main/shared, merge a batch of ~3 when they finish) fails for a known reason: unordered batch merges against shared doc surfaces (README, PRD roadmap table, CI workflow). The fix is not a long-lived integration branch — this repo is small, CI is fast, and the tasks have real dependency ordering. Use:

**Trunk-based, pinned base, serialized integration:**

- **Wave 0 (operator, ~10 min):** commit the dirty working tree to main. Record the resulting SHA as `BASE_SHA` in `decisions.md`.
- Every Wave-1 worker branches from `BASE_SHA` — never "latest main," never each other.
- Branch naming: `agent/<task-id>-<slug>` (e.g. `agent/t3-block-viewer`).
- **Workers never merge.** They deliver a branch + handoff report. You (or an integrator agent) merge **one at a time in the stated order** (§6), squash-merge, run CI, then move on. A later branch that no longer applies cleanly gets a single rebase by its worker (or you) — cheap because ownership keeps overlap to doc-section adjacency.
- Next wave branches from post-merge main (new pinned SHA, recorded again).
- **Squash-merge** each task: one revertable commit per task, title in conventional-commit form.

Why not an integration branch: it only defers the same conflicts and adds a second merge. Why not stacked branches: the Wave-1 tasks are genuinely independent; stacking would serialize work that doesn't need it.

---

## 3. Task tree with ownership

Ownership = **exclusive write allowlist**. A worker touching a file outside its allowlist is a review rejection (§7), even if the change is "helpful." Shared surfaces (README, learning-chain PRD, CI workflow) are section/row-scoped, listed explicitly.

### Wave 0 — operator (no worker)

**T0 — clean main.** Commit `.env.sepolia.example` + `README.md` + `scripts/dev-sleep.sh` (Render RPC schedule docs) as one commit; decide whether `tasks/.solomd/` is scratch (gitignore it) or content (commit it). Record `BASE_SHA` in `decisions.md`.

### Wave 1 — parallel (3 workers)

**T1 — MR-0 closeout + doc truth-up** · model: **cheap** · prompt: `worker-prompts/T1-docs-truthup.md`
Bring the PRDs in line with verified reality; version-stamp the rail interface.
- Owns: `tasks/prd-money-rail.md`; `tasks/coordination-settlementos.md`; `replica/README.md`; `deployments/rail-interface.json` (metadata only — no address changes); `tasks/prd-l2-learning-chain.md` **MR row + Resolved decisions only**; `README.md` **SettlementOS subsection only**.
- Must not: touch scripts, Go, viewer/dapp, deployments/sepolia.

**T2 — Phase 6 derivation spike (US-060)** · model: **strongest** · prompt: `worker-prompts/T2-derivation-spike.md`
Decode ≥1 real batch from the pinned Sepolia history (reuse `batcher/` frame+channel code + `cmd/decode-l1`), relate it to reference-op-node L2 blocks, and produce the expanded Phase 6 PRD the verifier task will execute against.
- Owns: `tasks/spike-phase-6-derivation.md` (new); `tasks/prd-phase-6-derivation.md` (new); `tasks/prd-l2-learning-chain.md` **US-060 checkboxes + Phase 6 row only**; read-only everywhere else. Throwaway decode experiments live in the spike-notes doc or `batcher/cmd/` **without modifying existing files** — if a shared batcher helper needs changing, log a decision instead.
- Must not: start US-061 implementation; touch scripts, viewer, README.

**T3 — Block viewer (US-063)** · model: **mid** · prompt: `worker-prompts/T3-block-viewer.md`
Blockchair-style latest-blocks list + per-block detail, loopback static app. Decision (pre-made, see `decisions.md` D-003): **sibling app under `blocks/`**, not an extension of `viewer/` — that is what keeps T3's ownership disjoint from the pipeline viewer.
- Owns: `blocks/` (new dir incl. vendored ethers copy); `scripts/serve-blocks.sh` (new) + `scripts/gen-blocks-config.sh` (new, may pattern-copy `gen-viewer-config.sh`); `README.md` **new "Block viewer (Phase 6)" subsection only**; `tasks/prd-l2-learning-chain.md` **US-063 checkboxes + Phase 6 row only**; `.github/workflows/ci.yml` **append one test step only**.
- Must not: edit `scripts/lib.sh` (privileged; CODEOWNERS), `viewer/` (read/copy only), `dapp/` (read/copy only).

### Wave 2 — after T2 merges

**T4 — Minimal derivation verifier (US-061)** · model: **strongest**
New Go module implementing frames→channels→batches→derived-block-window per `tasks/prd-phase-6-derivation.md` (T2's output), diffable against reference `op-node`.
- Owns: `derivation/` (new Go module, own go.mod — same pattern as `batcher/`/`proposer/`); `scripts/derivation-check.sh` (new); `README.md` **new Phase 6 derivation subsection only**; `tasks/prd-l2-learning-chain.md` **US-061 rows only**; CI **append one Go-test step only**.
- Must not: modify `batcher/`/`proposer/` source (import them if module layout allows, else copy with attribution and log a decision); no Sepolia redeploy, no changes under `deployments/`.
- Prompt: written after T2 merges, from `prd-phase-6-derivation.md` acceptance criteria + the T1–T3 contract template.

**T5 — SOS write-tunnel decision spike (optional)** · model: **mid** · **blocked on your go**
The money-rail open question (stable off-box write URL for SOS). Deliverable is a written go/no-go per US-012 non-loopback review + rail-interface v2 draft — **not** an implementation. Only launch if SOS actually needs off-box writes; otherwise the open question stays open for free.

### Wave 3 — hardening (after T4; H-tasks parallel)

**H1 — Script & serve-surface security review** · model: **mid**
Audit `scripts/*.sh` + `serve-*` + viewer/blocks CSP against AGENTS.md security expectations: loopback asserts on every serve path, `redact_rpc_url` coverage, `refuse_foundry_defaults_unless_local_l2` reach, no `innerHTML`, no secrets in logs. Owns: `scripts/` **except `lib.sh` `start_bg`/`stop_bg`** (any needed change there → report, human applies), plus a findings doc `tasks/hardening-findings.md` (new).

**H2 — Dependency & vuln refresh** · model: **cheap**
`govulncheck` both (soon: three) Go modules, `npm audit` in `scripts/bridge`, forge deps, vendored-ethers version check, re-verify GO-2026-5932 stance. Owns: `go.mod`/`go.sum` in `batcher|proposer|derivation`, `scripts/bridge/package*.json`, `dapp/vendor` + copies, README "Tracked dependency advisories" section.

**H3 — Test backfill & CI tightening** · model: **mid**
Golden-vector tests for `derivation/` (real Sepolia batch fixtures), `blocks/lib.test.js` edge cases, `test-helpers.sh` additions for new scripts, CI caching/pinning review. Owns: test files across modules + CI workflow.

**H4 — Operator drill (not a worker task)**
Cold-start-under-30-min runbook drill, `replica-sync-check.sh` run, `sepolia-fund-check.sh`, dev-sleep/wake cycle, demo-checklist on live 852. You run these on the Mac; workers can't. H1's findings doc gets the results appended.

Integration order within Wave 3: **H2 → H1 → H3** (dep bumps first so H3's tests run against final deps), H4 anytime.

---

## 4. Model assignment summary

| Tier | Tasks | Why |
|---|---|---|
| **Strongest** | T2, T4, (T6/US-062 if ever approved) | OP Stack derivation spec work: wire-format edge cases, spec-vs-reference diffing, protocol judgment calls |
| **Mid** | T3, T5, H1, H3 | Pattern-following implementation with real correctness stakes; strong in-repo exemplars exist (`viewer/`, `dapp/`) |
| **Cheap** | T1, H2 | Mechanical doc sync and dependency runs with crisp acceptance criteria |

---

## 5. Commit & merge contract (every task carries this)

Embedded in each worker prompt; the worker **reports compliance in its handoff**.

1. **Branch:** `agent/<task-id>-<slug>` off the pinned `BASE_SHA` recorded in `decisions.md`. Never branch from another task's branch.
2. **Write allowlist:** exactly the "Owns" list for your task. Shared files only in your named section/rows. Anything else you think needs changing → entry in `decisions.md` under "Escalations," do not edit.
3. **Commits:** conventional commits, scope = task area (`docs(mr0):`, `spike(derivation):`, `feat(blocks):`, `feat(derivation):`, `test(...)`, `chore(deps):`). Small commits fine — the merge is squashed.
4. **Forbidden always:** committing `.env*` (non-example) or keys; editing `scripts/lib.sh` `start_bg`/`stop_bg`; anything under `deployments/sepolia/` except docs; Sepolia redeploy or spend; non-loopback binds; containers on the Mac host; CDN script tags.
5. **Tests before done:** run the AGENTS.md suite relevant to touched areas (forge / `test-helpers.sh` / `node --test` / `go test`) and paste results in the handoff. Live-stack verification you cannot run → list explicitly as "operator verification needed," never claim it.
6. **Docs rule:** behavior change → README section (yours only); roadmap/acceptance → PRD (your rows only); agent guardrails → flag for AGENTS.md via decisions doc (T1 owns AGENTS.md edits if any arise).
7. **Handoff report** (final message, exactly this shape):
   - Branch + base SHA; `git diff --stat` vs base
   - Allowlist compliance: any file outside the list, with justification (expect: none)
   - Tests run + verbatim result lines; tests skipped + why
   - PRD boxes ticked / rows edited
   - `decisions.md` entries added (IDs)
   - Anticipated conflicts with sibling tasks (file + line region)
   - Operator actions needed (verification, secrets, live-stack)
8. **No merging, no pushing to main, no tags.** Deliver the branch; integration is the VP's.

---

## 6. Integration order + residual conflict map

**Merge order:** `T1 → T2 → T3` (Wave 1), then `T4` (→ optional `T5`), then `H2 → H1 → H3`.
Rationale: T1 rewrites the doc surfaces others touch rows of — landing it first makes T2/T3 rebases trivial single-row replays. T2 before T3 only because T4 planning starts from T2; they don't conflict with each other.

**Where conflicts remain likely despite ownership:**

| File | Colliding tasks | Shape of conflict | Handling |
|---|---|---|---|
| `tasks/prd-l2-learning-chain.md` | T1 / T2 / T3 / T4 | Adjacent rows in the roadmap table + Phase 6 checkbox blocks | Trivial; resolve in merge order; each worker edits only its named rows |
| `README.md` | T1 / T3 / T4 / H2 | Adjacent-section insertion points | Each task adds a self-contained `###` section; resolve by keeping both |
| `.github/workflows/ci.yml` | T3 / T4 / H3 | Appended test steps in the same job | Append-only, one step each; keep both sides |
| `tasks/decisions.md` | everyone | Append races | Append-only protocol + per-task ID prefix (D-T3-1 …); union merge |
| `dapp/vendor` ethers copies | T3 (copies into `blocks/vendor/`) vs H2 (version bump) | Stale vendored copy | Sequencing already handles it (H2 runs after T3); H2's checklist includes "bump all three copies" |
| `batcher/` helpers | T2/T4 wanting refactors | Scope creep, not textual conflict | Contract forbids it; escalation path via decisions doc |

**Not a conflict but watch:** if T2's spike concludes the verifier should live *inside* `batcher/` rather than a new `derivation/` module, that reshapes T4's ownership — that's exactly what decision D-T2-x in the spike output is for. Don't pre-launch T4.

---

## 7. Review checklist (apply to every handoff, ~5 min)

1. `git diff --stat BASE_SHA..branch` — every path inside the task's allowlist? Outside → reject or consciously accept + note.
2. `git diff BASE_SHA..branch -- scripts/lib.sh` — must be empty (CODEOWNERS surface).
3. `git diff` grep: no `.env` (non-example), no `0x`-prefixed 64-hex strings (keys), no non-loopback bind/URL additions (`0.0.0.0`, LAN IPs), no `http://` CDN/script tags, no `innerHTML` on chain data.
4. `deployments/` untouched except `rail-interface.json` metadata (T1 only) — addresses byte-identical.
5. Run the tests the worker claims + `./scripts/test-helpers.sh`; CI green on the branch.
6. Handoff report complete per §5.7 — missing sections = bounce back, don't fill in for them.
7. PRD edits: only claimed rows/boxes changed (`git diff -- tasks/*.md` eyeball).
8. Decisions doc: entries append-only, IDs unique, no rewrites of prior entries.
9. Go tasks: `go build ./... && go test ./...` + `govulncheck ./...` in the touched module.
10. Static-app tasks (T3): serve script asserts loopback; CSP header path used (no hard-coded hosts in `index.html`); vendored ethers, not CDN; `node --test` green.
11. Skim for silent decisions: any "I chose X" in the diff that isn't in `decisions.md` → bounce.

---

## 8. What was deliberately left out (gaps, not oversights)

- **SOS-side settle demo (MR-1 acceptance)** — different repo; this plan ends at "rail ready + documented."
- **MR-3/4/5** — trigger-gated (see §1); triggers logged in `decisions.md`.
- **US-062 sequencer stub** — needs your explicit approval per PRD; prompt not written.
- **Phases 3a/3b/7/8/9** — out of both PRDs' current scope.
- **Live-chain verification** — operator-only (H4); no worker claims it.
