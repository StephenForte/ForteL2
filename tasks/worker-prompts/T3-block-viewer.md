# Worker prompt — T3: Blockchair-style block viewer (US-063)

Copy everything below the line into the worker. Mid-tier model is sufficient.

---

You are a frontend/ops-tooling worker on the ForteL2 repo (personal OP Stack learning L2; local chain 901, Sepolia-backed chain 852). Your task is **T3** in `tasks/plan-parallel-integration.md`. Read that plan's §5 (commit & merge contract), `tasks/decisions.md`, and **AGENTS.md** (dApp/viewer conventions + security expectations) before starting; all three bind you.

## Goal

Build the Phase 6 **block viewer** (US-063 in `tasks/prd-l2-learning-chain.md`): a loopback-only static app with (a) a latest-first list of recent L2 blocks and (b) a per-block detail view. It is *not* an explorer — no search, no address pages, no indexer, no Blockscout.

Location decision is already made (`decisions.md` D-0003): a **sibling app under `blocks/`**, not an extension of `viewer/`. You may read and pattern-copy from `viewer/` and `dapp/` but must not edit them.

## Read first

- `tasks/prd-l2-learning-chain.md` — US-063 acceptance criteria (your spec) + Phase 6 non-goals
- `viewer/` — `index.html`, `app.js`, `lib.js`, `lib.test.js`, `config.example.js`: your structural template (static ESM, client-side RPC polls, plain-status failure states, gitignored `config.js`)
- `scripts/serve-viewer.sh` + `scripts/gen-viewer-config.sh` + `scripts/lib.sh` (read-only) — the serve/config pattern, `serve_static_loopback`, CSP header mechanism (`viewer/.csp-header`)
- `dapp/vendor/README.md` — vendored ethers rules (copy, never symlink, never CDN)
- AGENTS.md — `textContent` not `innerHTML`, loopback-only, ESM no bundler

## Work items

1. `blocks/` static app: `index.html`, `app.js`, `lib.js`, `lib.test.js`, `config.example.js`, vendored ethers copied per `dapp/vendor/README.md`, and a `.csp-header` if you follow the viewer's CSP mechanism (do).
   - **Blocks list:** recent L2 blocks newest-first — height, short hash, timestamp, tx count; "load more" pagination is enough. No search.
   - **Block detail:** by number (or hash): header fields + simple tx rows (hash, from/to when available, value or type). Client-side route/param, no server logic.
   - RPC failures surface as plain status text; no silent stale panels. Render all chain-derived strings with `textContent`.
   - Works against 901 and 852 via the existing `FORTEL2_ENV` / generated-config pattern.
2. `scripts/gen-blocks-config.sh` + `scripts/serve-blocks.sh` (new): follow the viewer scripts' shape — source `scripts/lib.sh`, use `serve_static_loopback`, assert loopback, pick a new port (viewer uses 8081; use 8082 and document it). **Do not modify `scripts/lib.sh`** — if it lacks something you need, escalate (`E-T3-n` in `decisions.md`) and work around locally.
3. Pure logic (formatting, pagination windowing, hex/number parsing) lives in `lib.js` with `node --test` coverage in `lib.test.js`, mirroring `viewer/lib.test.js` granularity.
4. `README.md`: add one new subsection "Block viewer (Phase 6)" — start command, port, what each view shows, explicit "not an explorer" note, link to/from the pipeline-viewer section wording. Touch no other README section.
5. `tasks/prd-l2-learning-chain.md`: tick the US-063 boxes you satisfied; update the Phase 6 roadmap row status fragment for the viewer track only. Leave anything requiring a live-stack check unticked and flag it.
6. `.github/workflows/ci.yml`: append `blocks/lib.test.js` to the existing node --test step (or add one step). Append-only.

## Write allowlist (exclusive)

`blocks/` (new) · `scripts/serve-blocks.sh` (new) · `scripts/gen-blocks-config.sh` (new) · `README.md` (new Block-viewer subsection only) · `tasks/prd-l2-learning-chain.md` (US-063 + Phase 6 row only) · `.github/workflows/ci.yml` (append test step only) · `tasks/decisions.md` (append-only) · `.gitignore` (add `blocks/config.js` line only)

Forbidden: `viewer/`, `dapp/`, `scripts/lib.sh`, all other scripts, Go modules, `deployments/`.

## Contract

- Branch `agent/t3-block-viewer` off BASE_SHA (decisions.md D-0001).
- Commits: `feat(blocks): <what>` (`test(blocks):`, `docs(blocks):` as fitting).
- Tests before done: `node --test blocks/lib.test.js viewer/lib.test.js dapp/lib.test.js` (yours green, existing untouched-but-verified) and `./scripts/test-helpers.sh`. If your VM has a runnable local stack, a manual smoke against 901 is welcome; otherwise list live verification for the operator.
- No merging, no pushing to main.

## Handoff report (final message, exactly these sections)

1. Branch + base SHA; `git diff --stat`
2. Allowlist compliance
3. What works where: list/detail against which chain(s); screenshots or textual walk-through
4. Tests run + verbatim results; live checks deferred to operator
5. US-063 boxes ticked vs left open (with why)
6. `decisions.md` entries / escalations
7. Anticipated conflicts with T1/T2 (expected: README + PRD-table adjacency, CI step)
8. Operator actions needed (e.g. verify on live 852, run gen-blocks-config after deploy)
