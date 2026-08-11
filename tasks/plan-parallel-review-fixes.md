# Parallel-worker plan — R-01..R-10 review fixes

**Status:** **COMPLETE (2026-08-11)** — all ten tasks merged in four waves; review §4 automated QA green; CI green; see `tasks/decisions.md` D-0026. Originally proposed 2026-08-05 · **Owner:** VP Eng · **Source of truth for task content:** `tasks/review-2026-08-05.md` (the task cards; this plan does not restate them)
**Companion:** `tasks/decisions.md` (shared decisions log), `tasks/worker-prompts/R-0*.md` (ready-to-run prompts)
**Baseline:** `7d7c847` (review committed), working tree clean, all suites green — re-verified 2026-08-05 by this plan's author, not taken from the review on faith.

---

## 1. Verified state (claims re-checked 2026-08-05)

| Review claim | Verdict | Evidence |
|---|---|---|
| Baseline tests all green | **Holds** | Re-ran: `test-helpers.sh` → `All script helper tests passed.`; `node --test` viewer+dapp+blocks → fail 0; `go test ./...` derivation (incl. golden replay), batcher, proposer → ok; `python3 -m unittest scripts/test_pipeline_snapshot.py` → OK. `forge test` not re-run here (CI covers it). |
| Repo plist says 21:00, installed agent fires 23:00 (array form) | **Holds** | `launchd/com.steve.fortel2-sleep.plist` Hour=21 (dict); `~/Library/LaunchAgents/…-sleep.plist` Hour=23 (array). |
| Stale `com.steve.fortel2-dev-wake.plist` on host, not in repo | **Holds** | Present in `~/Library/LaunchAgents/`, absent from `launchd/`. |
| `rail-interface.json` v1 / 2026-07-24, replica block wrong per D-0016, no availability info | **Holds** | Read the file; `readRpcUrl` still says "operator-configured (Render private service / shell)"; `healthChecks.replica` still instructs `REPLICA_L2_RPC_URL`. |
| Sequencer RPC surface (`admin,debug,miner`, `vhosts=*`, `enable-admin`) | **Holds** | `scripts/04-start-sequencer-sepolia.sh` lines ~41/46/87 as cited. |
| `lib.sh` loopback asserts at 304/352, CODEOWNERS on `lib.sh` | **Holds** | `assert_l2_loopback_urls` line 304, `require_sepolia_env` line 352; `.github/CODEOWNERS` covers `/scripts/lib.sh`. |
| `.env.sepolia.example` missing D-0016 comment | **Holds** | grep empty. |
| `TestSepoliaGoldenSkipped` misnomer | **Holds** | `derivation/channel_test.go:74`. |
| `replica/l1_rpc_router.py` dangling reference | **Holds** | `replica/` holds only `README.md`, `config/`, `patches/`; refs in `prd-mainnet-pilot.md:27` + D-0018. |
| Chain IDs / proxies for R-04's checker | **Holds** | `.env.example` 900/901, `.env.sepolia.example` 11155111/852; all 5 `*Proxy` keys present in `deployments/sepolia/deployments.json`; `docs` repo-relative paths exist. |
| CI `guardrails` job has a `Script helper tests` step (R-04 insertion point) | **Holds** | `.github/workflows/ci.yml`. |
| `data/` gitignored (R-05 samples) | **Holds** | `.gitignore:3`. |

Live-chain health, fund floors, and the H4-004 wake firing are **not** re-verified here — they need the live stack and a calendar; they stay operator-owned (§8).

---

## 2. Branching scheme — verdict on "start from main / shared branch, merge when ~3 finish"

Wrong shape for this work, for the same reason it failed last program: 7 of the 10 tasks edit the same handful of doc surfaces (`tasks/*.md`, `README.md`, `decisions.md`, `test-helpers.sh`), so unordered batch merges guarantee conflicts no ownership split can remove. The repo already has a proven alternative (D-0007..D-0017): **trunk-based, pinned base tag per wave, serialized squash-merge integration.** Reuse it unchanged:

- **Wave 0 (operator):** commit this plan + prompts, tag **`wave8-base`**, append the dispatch entry to `decisions.md`. Wave tags never move.
- Every Wave-1 worker branches from `wave8-base` — never "latest main", never each other's branches.
- Branch naming: `agent/<task-id>-<slug>` (e.g. `agent/r01-write-path-spike`).
- **Workers never merge or push to main.** They deliver a branch + handoff report. Integrator squash-merges **one at a time in the §6 order**, runs CI, moves on. Conflicts then only ever involve one moving branch against settled main — a trivial rebase by the worker or integrator.
- Next wave branches from post-merge main, tagged `wave9-base`, `wave10-base`, `wave11-base`; each tag recorded in the wave's dispatch note.
- Squash-merge, one revertable conventional-commit per task.

Not an integration branch (defers the same conflicts and adds a second merge); not stacked branches (in-wave tasks are genuinely disjoint — stacking would serialize work that doesn't need it).

---

## 3. Task tree: waves, ownership, model tier

Ownership = **exclusive write allowlist**; a file outside it is a review rejection even if the change is "helpful" (escalate via `decisions.md` §Escalations instead). Task content, instructions, and success criteria live in the review card — the card is the spec; this table is the coordination layer.

Dependency edges (from the review, honored): R-01→R-02 (spike content referenced), R-02→R-04 (checker guards the v2 file), R-03→R-10 and R-01/R-02→R-10 (R-10 runs last), plus file-ownership edges R-06→R-07/R-08 (same PRDs), R-08→R-09 (same `derivation/README.md`).

### Wave 1 — off `wave8-base` (4 workers, parallel)

| Task | Model | Branch | Exclusive write allowlist | Never touch |
|---|---|---|---|---|
| **R-01** write-path spike | **strongest** | `agent/r01-write-path-spike` | `tasks/spike-t5-write-path.md` (new); `tasks/decisions.md` (append D-0019 only) | Any `.sh`/`.go`/`.json`/`.env*`; anything that binds off loopback |
| **R-03** launchd reconcile + drift check | mid | `agent/r03-launchd-reconcile` | `launchd/com.steve.fortel2-sleep.plist`; `launchd/README.md`; `README.md` **launchd schedule paragraph only** (~line 668); `scripts/check-launchd.sh` (new) | `launchd/*-wake.plist`, `*-health.plist`; `scripts/lib.sh`; `launchctl` state |
| **R-05** gas runway readout | mid | `agent/r05-gas-runway` | `scripts/gas-runway.sh` (new); `scripts/test-helpers.sh` **append at end only**; `README.md` **Phase 3 batcher-funding paragraph only** | Live RPC calls; `.env.sepolia`; committing anything under `data/` |
| **R-06** Phase-7 glossary | cheap | `agent/r06-phase-glossary` | `tasks/prd-l2-learning-chain.md` (glossary + one roadmap row); `tasks/prd-mainnet-pilot.md` (title, §2 row 5, §3 note); `tasks/prd-money-rail.md` (replica row + FR-4 wording); `tasks/decisions.md` (append D-0021 only) | `P7-x` block IDs; PRD content beyond the named edits; D-0018 |

### Wave 2 — off `wave9-base` (3 workers, parallel)

| Task | Model | Branch | Exclusive write allowlist | Never touch |
|---|---|---|---|---|
| **R-02** rail-interface v2 | mid | `agent/r02-rail-interface-v2` | `deployments/rail-interface.json`; `tasks/decisions.md` (append D-0020 only) | Any `0x…` address, chain ID, port, or `l2RpcUrl`/`l2NodeRpcUrl`/`l1RpcUrl` string (byte-identical; `replica.readRpcUrl`→`null` is the one sanctioned URL-field change, per card step 4) |
| **R-07** PRD status hygiene | cheap | `agent/r07-prd-hygiene` | `tasks/prd-l2-learning-chain.md` (Open Questions / Resolved decisions / US-030 / Phase 6 row); `tasks/prd-money-rail.md` (MR-2 status row, D-0017 closure note) | Everything else — diff must touch only these two files |
| **R-08** verification-limitation doc | cheap | `agent/r08-verify-limitation` | `derivation/README.md` (new Limitations section); `tasks/prd-mainnet-pilot.md` (P7-2 sub-bullet only) | Any `.go` file; D-0018 |

### Wave 3 — off `wave10-base` (2 workers, parallel)

| Task | Model | Branch | Exclusive write allowlist | Never touch |
|---|---|---|---|---|
| **R-04** rail-interface drift guard | mid | `agent/r04-rail-drift-guard` | `scripts/rail-interface-check.sh` (new); `.github/workflows/ci.yml` (one step after `Script helper tests`); `scripts/test-helpers.sh` **append at end only** | Pinned action SHAs; network calls in the checker |
| **R-09** small-fixes bundle | cheap | `agent/r09-small-fixes` | `tasks/prd-mainnet-pilot.md` (line-27 router reference only); `.env.sepolia.example` (comment lines only); `derivation/channel_test.go` (rename only); `derivation/README.md` (test-name mention only) | D-0018 / D-H3-2 in `decisions.md`; any `=` assignment in `.env.sepolia.example` |

### Wave 4 — off `wave11-base` (1 worker)

| Task | Model | Branch | Exclusive write allowlist | Never touch |
|---|---|---|---|---|
| **R-10** consumer-facing availability docs | cheap | `agent/r10-consumer-docs` | `README.md` **SettlementOS section only**; `tasks/coordination-settlementos.md` (SOS onboarding gate section); `tasks/prd-money-rail.md` (FR-2 list only) | `rail-interface.json` (read-only; R-04's checker must still pass) |

**Model-tier rationale.** Strongest only for R-01: it is the one task requiring security/architecture judgment (RPC-surface analysis, five-option trade-off table, and the discipline to produce a decision *for* the operator without making it or touching infra). R-02/R-03/R-04/R-05 are mid: real correctness stakes (byte-identity on a consumer contract, plist normalization semantics, cross-file compare logic, burn-rate edge cases) but fully specified by their cards. R-06/R-07/R-08/R-09/R-10 are cheap: editorial work with grep-checkable acceptance; the cards leave no judgment calls. If a cheap-tier worker stalls or hedges on R-08's prose ("a non-engineer can follow it"), bump that one to mid — it is the only cheap task with a quality bar a grep can't check.

**Critical path:** R-01 → R-02 → R-04 → R-10 (four serial merges). R-06 → R-08 → R-09 is the other four-step chain but R-09 rides Wave 3 in parallel with R-04. Everything else is slack; a Wave-1 straggler (likely R-01, the thinking task) holds up only Wave 2, not R-03/R-05 integration.

---

## 4. Commit & merge contract (embedded in every prompt; worker reports compliance)

1. **Branch:** `agent/<task-id>-<slug>` off the wave's pinned base tag. Never branch from another task's branch.
2. **Write allowlist:** exactly the §3 row. Shared files only in your named section/rows/append-point. Anything else you believe needs changing → append an Escalation (`E-R<nn>-<n>`) to `decisions.md`, do not edit.
3. **Commits:** conventional commits, task-scoped: `docs(t5):` R-01 · `docs(rail):` R-02 · `fix(launchd):`/`feat(scripts):` R-03 · `test(rail):`/`ci:` R-04 · `feat(scripts):` R-05 · `docs(prd):` R-06/R-07 · `docs(derivation):` R-08 · `chore(review):` R-09 · `docs(sos):` R-10. Small commits fine — the merge squashes.
4. **Forbidden always:** committing `.env*` (non-example) or keys; editing `scripts/lib.sh`; anything under `deployments/sepolia/`; Sepolia spend or redeploy; non-loopback binds or port opens; `launchctl` mutations; running scripts against the live stack or any RPC (workers have no `.env.sepolia` and must not construct one); committing under `data/`; new shell must be macOS bash-3.2-compatible (no `declare -A`, no `${var,,}`, no `$VAR`-adjacent en-dashes — see `ede2ddf`).
5. **decisions.md protocol:** append-only, entries only at the end of their section, IDs from §5's reservation table. Never renumber, never edit an existing entry.
6. **Tests before done:** run every §7 global check that applies to your touched areas + your card's success criteria that are runnable off-host; paste verbatim result lines. Anything needing the live stack, `~/Library/LaunchAgents`, or a QuickNode URL → list under "Operator actions needed", never claim it.
7. **Handoff report — your final chat message must BE the report** (a PR description or repo file does not satisfy this). Sections, exactly:
   1. Branch + base tag; `git diff --stat <base>..HEAD`
   2. Allowlist compliance (expect: none outside)
   3. Card success criteria: each one — met / met-by-test-shown / operator-verification-needed, with evidence
   4. Tests run + verbatim result lines; tests skipped + why
   5. `decisions.md` entries appended (IDs)
   6. Anticipated conflicts with sibling branches (file + region)
   7. Operator actions needed
8. **No merging, no pushing to main, no tags.**

---

## 5. Shared decisions doc

`tasks/decisions.md` already carries the format (see its §Template). This wave adds a **reservation table** so parallel appenders can't collide on IDs:

| ID | Task | Content (fixed by the review card) |
|---|---|---|
| `D-0022` | Wave 0 (operator) | Dispatch entry: plan adopted, `wave8-base` tagged, review = task spec |
| `D-0019` | R-01 | SOS write-path options recorded (T5 revival); loopback stands; go/no-go with operator |
| `D-0020` | R-02 | rail-interface v2 bump; no addresses changed |
| `D-0021` | R-06 | Phase-7 vocabulary (learning phase / redeploy gate / mainnet pilot) |
| `E-R<nn>-<n>` | any | Escalations: out-of-allowlist needs, worker-discovered issues |

Two IDs are deliberately non-sequential in file order: D-0022 (Wave 0) and D-0021 (Wave 1) land before D-0020 (Wave 2). That's fine — the file already interleaves task-prefixed IDs (D-H1-1, D-H3a-1…); **append order = merge order, IDs are stable names, not positions.** The review assigned 0019/0020/0021 and the committed review text is not being edited to renumber them.

Entry template (verbatim from `decisions.md`):

```
### D-<id> — <short title>
- **Context:** <one line>
- **Decision:** <one line>
- **Consequence:** <what other tasks must now assume>
```

---

## 6. Integration order + residual conflict map

**Merge order (one at a time, CI green between each):**

> Wave 1: **R-01 → R-06 → R-03 → R-05** · retag `wave9-base`
> Wave 2: **R-02 → R-07 → R-08** · retag `wave10-base`
> Wave 3: **R-04 → R-09** · retag `wave11-base`
> Wave 4: **R-10** · run §7 full QA + review §4 checklist

R-01 before R-06 keeps D-0019 ahead of D-0021 in the append order; R-02 first in Wave 2 so the v2 JSON is settled history before anything else lands on top (R-07/R-08 share no files with it — their relative order is free); R-04 before R-09 because R-04 adds the CI step R-10's card says must still pass.

**Wave 0 (operator, ~5 min):** commit this plan + the four Wave-1 prompts · `git tag wave8-base` · append the D-0022 dispatch entry to `decisions.md` (part of the tagged commit or immediately after — record the tag name in the entry, prior art D-0015). Prompts for Waves 2–4 are written by the integrator at each wave boundary from the same template — Wave-2's R-02 prompt should quote R-01's merged spike doc by section, which is why they aren't pre-written here.

**Where conflicts remain likely despite the ownership split:**

| Surface | Colliding tasks | Shape | Handling |
|---|---|---|---|
| `tasks/decisions.md` | R-01 + R-06 (same wave), R-02 later | Both append at end of §Decisions | The one *expected* in-wave conflict. Union-merge in merge order; IDs pre-reserved so content never collides |
| `README.md` | R-03 (schedule ¶, ~line 668) + R-05 (Phase 3 funding ¶) same wave; R-10 (SOS section) later | Distant sections; conflict only if a worker reflows surrounding text | Prompts forbid reflow outside the named paragraph; if git still complains, keep both hunks |
| `scripts/test-helpers.sh` | R-05 (Wave 1) then R-04 (Wave 3) | Both append a case at the end | Sequenced across waves — R-04 branches from a base that already has R-05's case; no textual conflict left |
| `tasks/prd-money-rail.md` | R-06 (W1) → R-07 (W2) → R-10 (W4) | Same phase table (different rows/cells), FR list | Sequenced; each wave rebases onto settled text. Watch R-07's MR-2 row vs R-06's replica-row wording — same table |
| `tasks/prd-mainnet-pilot.md` | R-06 (W1) → R-08 (W2) → R-09 (W3) | Title/§2/§3 vs P7-2 bullet vs line 27 | Sequenced; disjoint lines |
| `derivation/README.md` | R-08 (W2) → R-09 (W3) | New section vs test-name mention | Sequenced; R-09's grep for the old test name runs *after* R-08's section exists — R-09 must update any mention R-08 introduced |
| The literal hour `23:00` | R-02 (JSON) / R-03 (plist+2 READMEs) / R-10 (coordination doc) | Not a git conflict — a semantic-drift risk across 5 files owned by 3 tasks in 3 waves | §7 cross-file grep is the gate; R-10's card re-checks it last |

---

## 7. Review checklist per handoff (~5 min each)

**Global — every task:**

1. `git diff --stat <base>..branch` — every path inside the §3 allowlist; outside → bounce or consciously accept + note.
2. `git diff <base>..branch -- scripts/lib.sh deployments/sepolia/` — empty.
3. Diff grep: no non-example `.env`, no 64-hex key-shaped strings, no `0.0.0.0`/LAN-IP binds, no CDN/script tags, no unredacted `quiknode`.
4. `decisions.md`: additions only at section end; `git diff` shows zero modified lines above them; IDs match §5 reservations.
5. Run what the worker claims: `./scripts/test-helpers.sh`; `bash -n` over touched scripts; suite(s) for touched modules; CI green on the branch.
6. Handoff report complete per §4.7 — missing sections = bounce, don't fill in for them.
7. Card success criteria walked one by one against the diff (the card, not the worker's summary, is the spec).
8. Silent decisions: any "I chose X" visible in the diff but absent from `decisions.md` → bounce.

**Sharpest per-task checks (beyond the card):**

| Task | Check |
|---|---|
| R-01 | Doc gives the operator a decision to *make*, not made — recommendation marked pending go/no-go; no row's `lib.sh` column says "TBD"; diff = exactly 2 files |
| R-02 | `git diff` on the JSON shows zero changed characters inside any `0x…` value or chain ID; `python3 -c "import json,sys;json.load(open('deployments/rail-interface.json'))"`; grep old phrases gone ("pinned through learning Phase 6", `REPLICA_L2_RPC_URL`) |
| R-03 | Script contains no `launchctl bootout|bootstrap|kickstart` and no `rm`; `grep -rn 21:00 README.md launchd/` empty; plist still dict-form, wake plist untouched |
| R-04 | Flip one hex digit locally → checker exits 1 naming the key; `grep -cE 'cast |curl|wget' scripts/rail-interface-check.sh` = 0; CI diff touches one step, no SHA changes |
| R-05 | Fixture math: 0.01 ETH/hour → ~0.24 ETH/day; top-up fixture yields no negative burn; captured output greps clean for `private|quiknode`; nothing under `data/` staged |
| R-06 | `grep -n "Phase 7" tasks/*.md` — every hit is fault-proof phase or "redeploy gate (Phase 7 …)"; `P7-0..P7-5` intact |
| R-07 | No question in both Open Questions and Resolved; each remaining open question has no answering decision ID; diff = exactly 2 files |
| R-08 | Limitation section names both `-ref-*` flags and the anchor-datadir copy; consequence readable by a non-engineer; `go test ./...` in `derivation/` untouched-green |
| R-09 | `go test ./... -run TestSepoliaGoldenReplay -v` → `matched=50 mismatched=0`; `.env.sepolia.example` diff adds comments only (no `=`) |
| R-10 | README alone teaches the nightly window + write-path status; hour identical across all 5 files; `./scripts/rail-interface-check.sh` exits 0 |

After R-10 merges, run the review's §4 Final QA checklist in full — automated section by integrator, live/host section by operator.

---

## 8. Feasibility pushback + flagged assumptions

1. **Worker environment assumption:** workers can clone, build, and run offline tests, but have no `.env.sepolia`, no QuickNode URL, no live stack, and no access to this Mac's `~/Library/LaunchAgents`. Consequence: R-03's "run it on this host" and R-05's live sampling success criteria are **build-by-worker, verify-by-operator** — the prompts say so explicitly. If your agents actually run *on* the mini, keep the same rule anyway: parallel agents mutating host state / hitting live RPC with secrets in env is exactly what D-0016's access-model caution exists for.
2. **This plan does not unblock MR-1.** R-01 produces decision material; the operator go/no-go (US-012) is a human stop after Wave 1. Budget for that pause before promising SOS anything.
3. **H4-004 stays open until a calendar event:** the 04:00 wake proof is a log check the morning after the plists are reconciled. No task can close it; it's on the operator list.
4. **R-02's "byte-identical RPC URLs" clause** conflicts on its face with its own step 4 (`readRpcUrl` → `null`). Resolution written into the prompt: byte-identity binds `l2RpcUrl`, `l2NodeRpcUrl`, `l1RpcUrl` in both networks; `replica.readRpcUrl` is the one sanctioned change. Flagged here so the integrator checks that interpretation, not just the diff.
5. **Review's "do not batch" honored** even where one worker could take two cards (R-06+R-07, R-08+R-09 share files). The wave sequencing gets the same throughput without violating the card.
6. **Prompt-file namespace:** `tasks/worker-prompts/` already contains `R1-`/`R2-`/`R3-` (codex rounds). New prompts use the zero-padded `R-0x-` prefix; don't confuse them.
7. **Not planned here (gaps, not oversights):** SOS-side settle demo (different repo); T5 *implementation* (post-decision); operator drills in review §4 "Live / host checks"; stale `dev-wake` plist removal (operator, after R-03's script flags it); any Phase 7 / mainnet-pilot expansion (next plan, per D-0018).
