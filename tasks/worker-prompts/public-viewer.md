# Worker brief — public-viewer: hosted read-only pipeline viewer on the D-0047 gateways

```
DISPATCH · Model: Sonnet 5 · Order: standalone; nothing in flight touches viewer/
Surface: Claude Code worker session, launched by the operator via the desktop app (branch dropdown)
Baseline: main @ 1943ce8 · branch feat/public-viewer (pre-created off that sha — use it, do not cut your own)
Host: the operator's Mac only — the local-mode regression check needs the live deploy tree
      ($DEPLOY_DIR artifacts) that exists nowhere else
Working directory: /Users/steveforte/ForteL2
Landing: PR to main. The reviewer commits decision D-0094 onto this branch. Deploying the
Render static site itself is an operator step after merge — not this task.
```

Copy everything below the line into the worker.

---

## Task

Make the Phase 1c pipeline viewer (`viewer/`, currently loopback-only on :8081) buildable as a
**public, read-only, static page** that talks exclusively to already-public endpoints: the two
D-0047 read gateways and a public L1 RPC. The local loopback mode must keep working exactly as
it does today.

**Read first** (these govern the work; trust the repo over this brief — every status claim
here is a snapshot from dispatch time, 2026-08-25):

- `tasks/decisions.md` — **D-0045** (the two public read URLs), **D-0047** (scoped exception:
  those two URLs only; no third public RPC without a new go/no-go), **D-0048** (rail-interface
  stays v6).
- `scripts/gen-viewer-config.sh` + `scripts/serve-viewer.sh` — how local config/CSP are
  generated today. Note the file-header warnings: `viewer/config.js` is gitignored because it
  can carry the **private QuickNode L1 URL**.
- `viewer/app.js` — the four panels and which RPC each one calls.
- `README.md` § US-012 / public reads — published gateway semantics (replica ~3 min lag;
  sequencer gateway down nightly 23:45–03:00).

## Evidence — why this is feasible (probed 2026-08-24/25 from the operator's Mac)

CORS is already open on the gateways — a browser page hosted anywhere can call them directly:

```
$ curl -X OPTIONS https://fortel2-replica-rpc.onrender.com -H 'Origin: https://example.com' ...
HTTP/2 204
access-control-allow-origin: *
access-control-allow-methods: GET, POST, OPTIONS
```

The method allowlist blocks two calls the viewer makes today:

```
txpool_status:        {"error":{"code":-32601,"message":"method not allowed: txpool_status"}}
optimism_syncStatus:  {"error":{"code":-32601,"message":"method not allowed: optimism_syncStatus"}}
eth_blockNumber:      {"result":"0x17d25"}          (sequencer gateway)
```

But block tags work on the replica gateway, which is enough to rebuild the sequencer panel:

```
eth_getBlockByNumber latest    → 97606
eth_getBlockByNumber safe      → 97606
eth_getBlockByNumber finalized → 97132
```

## Outcome — the properties that must hold

1. A **public build** of the viewer exists in the repo: static files a Render static site can
   serve with no server code. In public mode the page uses only these origins:
   `https://fortel2-replica-rpc.onrender.com`, `https://fortel2-sequencer-rpc.onrender.com`,
   and `https://ethereum-sepolia-rpc.publicnode.com` (L1). Nothing else, ever.
2. All four panels render in public mode:
   - **Sequencer** — unsafe tip from the sequencer gateway (`latest`), safe/finalized from the
     replica gateway block tags; `optimism_syncStatus` is never called in public mode. During
     the nightly sequencer-gateway window the panel degrades visibly (stale/unavailable label),
     the page does not break.
   - **Batcher / Proposer** — unchanged logic, pointed at the public L1 RPC.
   - **Aggregate** — unchanged block-window scan against the replica gateway; the **Mempool**
     cell shows "n/a" (or is hidden) in public mode; `txpool_status` is never called.
3. **Local mode is untouched**: `./scripts/serve-viewer.sh` behaves exactly as today, including
   its generated config and CSP.
4. The public build's CSP restricts `connect-src` to exactly the three origins above (Render
   static sites can set headers; if header delivery is an operator dashboard step, document the
   exact header value in the README subsection).
5. **A guard makes secret leakage impossible**: the public artifact is generated from public
   constants, never from `.env.sepolia` or the local `viewer/config.js`, and an automated check
   fails (test or build-time assertion) if the public bundle contains any origin outside the
   allowlist in (1).
6. Public-mode default poll interval ≥ 30 s (both gateways are free-tier Render; the aggregate
   scan is several calls per refresh).
7. README gains one short subsection: what the public viewer is, the two known degradations
   (mempool, sync-status detail), the nightly window, and the operator's deploy runbook for the
   Render static site (publish dir, build/copy step if any, CSP header).

Mechanism is yours: a committed `viewer/config.public.js` + copy step, a generator script, a
build flag in `app.js` — whatever is simplest and testable. The addresses (batch inbox,
DisputeGameFactory, batcher/proposer EOAs) are already public on-chain and in the README;
hard-coding them in a committed public config is fine.

## The trap

**The private QuickNode L1 URL reaching the public bundle.** Locally, `L1_RPC_URL` in
`.env.sepolia` is a token-bearing, metered QuickNode endpoint, and `viewer/config.js` on the
operator's disk currently contains it — that is exactly why the file is gitignored. If the
public build path reuses `gen-viewer-config.sh`, reads `.env.sepolia`, or a Render static site
is pointed at a directory where the local `config.js` sits, the token becomes world-readable:
anyone can burn the QuickNode credit budget and the key must be rotated. This generalizes:
**anything derived from `.env.sepolia` or the deploy tree is suspect for the public artifact** —
build it from committed public constants and let the allowlist guard in Outcome 5 be the
backstop.

Second boundary: getting `optimism_syncStatus` or `txpool_status` back by widening the gateway
allowlists or adding any new public proxy is **out of bounds** — D-0047 caps public RPC surface
at the two URLs. Degrade instead; if degradation seems unacceptable, report it as an operator
decision.

## What must survive

- Loopback guardrails (`assert_sepolia_rpc_urls`, `assert_l2_loopback_urls`) keep their current
  semantics — do not loosen them to make a public config pass; the public path must not go
  through them at all.
- The local viewer flow (`gen-viewer-config.sh` → `serve-viewer.sh` → :8081) byte-for-byte in
  behavior.
- `viewer/lib.test.js` currently **29 pass / 0 fail** on the baseline — existing tests may not
  be weakened or deleted; any legitimate change is declared in the return report with
  before/after and why it strengthens.

## Coverage, as properties

- The origin-allowlist guard (Outcome 5) is asserted by an automated check: feed it a config
  containing a QuickNode-shaped URL and it must fail.
- Sequencer-panel derivation from block tags is unit-tested in `viewer/lib.test.js` (pure
  functions in `viewer/lib.js`), including the gateway-down degradation path.
- Public mode never calls `txpool_status` / `optimism_syncStatus` — asserted, not assumed.

## Scope

**Freely changeable:** `viewer/app.js`, `viewer/lib.js`, `viewer/lib.test.js`,
`viewer/index.html`, `viewer/styles.css`, plus new files for the public config/build (in
`viewer/` and/or one new script in `scripts/`).

**Additive only:**
- `README.md` — the one new subsection; other tasks touch this file between waves.
- `.github/workflows/ci.yml` — only if wiring the new guard/tests in; do not restructure jobs.

**Do not touch, with reasons:**
- `scripts/gen-viewer-config.sh`, `scripts/serve-viewer.sh`, `scripts/lib.sh` — the local flow
  is proven and in production; `lib.sh` is CODEOWNERS-gated. If the cleanest design genuinely
  needs a hook in one of them, stop and report first.
- `rail-interface.json` — frozen at v6 until post-wipe proxies (D-0048); publishing the viewer
  URL there is a later reviewer/operator step.
- `.env.sepolia.example` — no new env keys should be needed; the public build takes no secrets.
- `tasks/decisions.md`, `tasks/prd-*.md` — reviewer-owned. **D-0094 is pre-assigned to this
  task's review and the reviewer writes it.** Do not add an entry or derive "highest + 1";
  this assignment overrides that convention. If the id looks wrong, stop and ask.

**Escape hatch:** if the task appears to require changing anything outside this surface, stop
and report — do not widen scope.

## Verification (run against main merged in, at hand-back)

```
node --test viewer/lib.test.js          # baseline 29 pass / 0 fail — expect additions, 0 fail
node --test viewer/lib.test.js dapp/lib.test.js   # CI's exact invocation still green
./scripts/serve-viewer.sh               # local mode regression: :8081 renders as before
```

Manual (no browser harness exists in CI — **do not build one for this task**; state exactly
what you exercised by hand):
- Serve the public build locally (any static file server on loopback is fine) and load it in a
  browser against the **real** gateways. Report which panels rendered, with the head numbers
  you saw.
- Confirm in the browser network tab that only the three allowlisted origins are contacted.

Unexplained movement in any test count is itself a finding.

## Out of scope, with reasons

- **Creating the Render static site** — operator step after merge (account access); the task
  delivers the buildable artifact and the runbook.
- Custom domain — default `*.onrender.com` is fine for a learning-chain toy.
- Restoring mempool / full sync-status publicly — capped by D-0047.
- Guestbook (:8080) and block viewer (:8082) — separate surfaces, separate decisions.
- PRD/roadmap rows and rail-interface publication — reviewer-owned docs, post-merge.

## Unresolved decisions

None — host (Render static site), domain (default onrender), deployer (operator, post-merge),
and the degradation approach (no new public RPC) are operator-settled. One conditional: if the
gateway allowlist turns out to block some other method a panel needs (e.g. an `eth_*` call not
probed above), do not proxy around it — degrade that cell and put it under DECISIONS NEEDED.

If you believe any part of this approach is wrong — the config mechanism, the 30 s poll, the
block-tag derivation — argue it with evidence in your report rather than implementing it
half-heartedly. The brief's author is sometimes wrong, including about things stated
confidently above.

## Return format — verbatim, these labels, this order

```
TASK:        public-viewer — hosted read-only pipeline viewer on the D-0047 gateways
LINE OF WORK: feat/public-viewer
REVIEW ARTIFACT: <PR URL>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: <each check named> — pass/fail, with counts
              (run against main merged in as of hand-back)
MIGRATION:   none

SHARED FILES TOUCHED: <path> — what changed, why it is additive   (or: none)
IDENTIFIERS USED:     D-0094 reserved for the reviewer — not consumed by me
EXISTING CHECKS MODIFIED: <path> — <before> → <after>; why this strengthens
                          rather than weakens                      (or: none)
DECISIONS NEEDED:    none | <the question, and what you did in the interim>
RESIDUAL GAPS:       what this does not cover; what was verified by hand vs
                     automatically; risk stated plainly
```

Disclosure in the last three fields counts as diligence, not failure: a declared gap gets
checked; a silent one becomes an incident.

/goal keep this PR merge-ready: fix failing CI checks and bot review comments until everything passes.
