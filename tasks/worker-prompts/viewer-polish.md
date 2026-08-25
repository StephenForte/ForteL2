# Worker brief — viewer-polish: four small riders on the live public viewer

```
DISPATCH · Model: Sonnet 5 · Order: standalone; nothing in flight touches viewer/
Surface: Claude Code worker session, launched by the operator via the desktop app (branch dropdown)
Baseline: main @ c4d00ab · branch feat/viewer-polish (pre-created off that sha — use it, do not cut your own)
Host: any — no local stack needed (all verification is unit tests + the public build + a loopback static server)
Working directory: /Users/steveforte/ForteL2
Landing: PR to main. The reviewer commits decision D-0096 onto this branch. The public site
(https://fortel2-viewer.onrender.com) deploys manually after merge — not your step.
```

Copy everything below the line into the worker.

---

## Task

Four small improvements to the pipeline viewer, now live publicly at
https://fortel2-viewer.onrender.com (Render static site, auto-deploy off). PR #154 / D-0095
established the architecture — this task polishes it. Trust the repo over this brief; every
status claim is a snapshot from dispatch time, 2026-08-25.

**Read first:** `tasks/decisions.md` D-0095 (public build rules — committed constants only,
origin allowlist, forbidden methods), `scripts/build-public-viewer.sh` (meta-CSP injection and
origin guard), `viewer/lib.js` (`viewerL1ScanBlocks`, `PUBLIC_VIEWER_CSP`), `viewer/app.js`,
`viewer/index.html`, `viewer/styles.css`.

## The four items

**1. Above-the-fold UX (operator request).** The hero (brand, headline, long lede paragraph,
live bar) plus the stage nav eat so much vertical space that the four status panels sit below
the fold. Outcome: **at 1366×768 and 1440×900, all four panels' titles and their metric rows
are visible without scrolling**, in both local and public modes. Mechanism is yours — condense
the lede to one short line with the full explainer moved somewhere unobtrusive (a
`<details>` toggle, a footer, a title attribute), shrink hero type, tighten panel padding,
whatever works. Keep the live pill and refresh meta visible; keep the nightly-window and
"~3 min lag" facts reachable from the page (they answer "why does this look stale", the most
likely visitor question).

**2. Batcher panel scan window (public mode only).** The public batcher panel scans
`viewerL1ScanBlocks(852)` = 12 L1 blocks (~2.4 min), but the live batcher posts every ~5 min
(measured 2026-08-25: inbox posts at L1 blocks 11565828 / 11565852 / 11565877 — 25-block
spacing; batcher nonce 9406), so the panel reads "0 / none yet" about half the time against a
perfectly healthy batcher. Outcome: **in public mode the scan window covers at least one full
batching interval** (~30 L1 blocks; pick the number, justify it in the code) so the latest
post and its age are essentially always shown. **Local mode keeps 12** — the local :8081
viewer's L1 scans hit the operator's metered QuickNode endpoint, and widening there raises
that spend; public mode hits free publicnode. Unit-test the mode split in `viewer/lib.test.js`.

**3. Favicon.** The live site 404s on `/favicon.ico` (console noise on every visit). Ship a
favicon both modes serve — an inline `data:` SVG link tag in `index.html` is fine (public CSP
`img-src` already allows `data:`), or a small committed file the build copies. Must not add
any network origin (the build's origin guard stays the arbiter).

**4. Silence the meta-CSP warning.** Browsers ignore `frame-ancestors` delivered via
`<meta>` and log a warning on every load. Outcome: the public page loads with **zero CSP
console warnings** while `viewer/public/Content-Security-Policy.txt` keeps the **full** policy
(it's the copy-paste source for a future Render dashboard header, where `frame-ancestors` does
work). The obvious shape: the build's meta injection strips meta-ignored directives; the .txt
stays complete. Do not weaken any other directive in either copy.

## Scope

**Freely changeable:** `viewer/app.js`, `viewer/lib.js`, `viewer/lib.test.js`,
`viewer/index.html`, `viewer/styles.css`, `viewer/config.public.js`,
`scripts/build-public-viewer.sh` (items 3–4 only — the destructive-path refusals and the
origin guard added by #154 may not be loosened; the test-helpers probes enforce this).

**Additive only:** `scripts/test-helpers.sh` (append; currently 297 PASS / 0 FAIL on the
baseline — do not reorder or renumber), `README.md` (only if a documented number like the scan
window changes).

**Do not touch, with reasons:** `scripts/gen-viewer-config.sh`, `scripts/serve-viewer.sh`,
`scripts/lib.sh` (proven local flow; CODEOWNERS), `deployments/rail-interface.json`,
`tasks/decisions.md`, `tasks/prd-*.md` (reviewer-owned; **D-0096 is pre-assigned to this
task's review and the reviewer writes it** — do not add an entry or derive highest+1; stop and
ask if the id looks wrong).

**Escape hatch:** anything outside this surface → stop and report; do not widen scope.

## What must survive

- The D-0095 invariants: public bundle from committed constants only; origins exactly the
  three allowlisted; `txpool_status` / `optimism_syncStatus` never called in public mode;
  30 s public poll floor; build-script destructive-path refusals.
- Local :8081 behavior unchanged except where an item explicitly says both modes (UX, favicon).
- `viewer/lib.test.js` (41/0) and `scripts/test-helpers.sh` (297/0) — existing assertions may
  not be weakened or deleted; declare any legitimate change with before/after and why it
  strengthens.

## The trap

**Item 2's cost boundary.** The scan-window constant is shared code; widening it for both
modes silently multiplies the local viewer's QuickNode L1 calls per refresh — a metered spend
increase nobody asked for that shows up only on the operator's bill. Keep the widening keyed
on public mode and prove it with a unit test, not a comment.

## Verification (run against main merged in, at hand-back)

```
node --test viewer/lib.test.js dapp/lib.test.js     # baseline 49/0 — expect additions, 0 fail
./scripts/test-helpers.sh                            # baseline 297/0 — expect additions, 0 fail
./scripts/build-public-viewer.sh                     # allowlist OK; meta CSP has no frame-ancestors
```

Manual (no browser harness in CI — do not build one; state exactly what you exercised):
serve `viewer/public` on a loopback static server, load it in a browser and report: (a) all
four panels visible without scrolling at 1366×768 and 1440×900 (say how you checked the
viewport), (b) zero console errors/warnings including favicon and CSP, (c) the batcher panel
showing a post with its age.

## Out of scope, with reasons

- Deploying the live site — auto-deploy is off by design; the operator/planner triggers it
  after merge.
- The Render dashboard CSP header itself — dashboard-only setting; the .txt is its source.
- Post-wipe address updates in `config.public.js` — separate, wipe-gated (D-0095).
- Any new public RPC or gateway method — capped by D-0047.

## Unresolved decisions

None. If the ~30-block window still misses posts because the cadence on the live chain has
changed, report the measured cadence under DECISIONS NEEDED rather than cranking the number.

If you think any of this is wrong — the mode-split window, the meta-strip approach, the UX
budget — argue it with evidence in your report rather than implementing it half-heartedly.

## Return format — verbatim, these labels, this order

```
TASK:        viewer-polish — four riders: fold UX, batcher window, favicon, CSP warning
LINE OF WORK: feat/viewer-polish
REVIEW ARTIFACT: <PR URL>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: <each check named> — pass/fail, with counts
              (run against main merged in as of hand-back)
MIGRATION:   none

SHARED FILES TOUCHED: <path> — what changed, why it is additive   (or: none)
IDENTIFIERS USED:     D-0096 reserved for the reviewer — not consumed by me
EXISTING CHECKS MODIFIED: <path> — <before> → <after>; why this strengthens
                          rather than weakens                      (or: none)
DECISIONS NEEDED:    none | <the question, and what you did in the interim>
RESIDUAL GAPS:       what this does not cover; what was verified by hand vs
                     automatically; risk stated plainly
```

Disclosure in the last three fields counts as diligence, not failure.

/goal keep this PR merge-ready: fix failing CI checks and bot review comments until everything passes.
