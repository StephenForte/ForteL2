DISPATCH · scripts/l1-provider-preflight.sh — make the D-0123 gate executable
Repository: StephenForte/ForteL2
Baseline: origin/main @ aa26bc8 (verify: git fetch && git rev-parse origin/main —
          trust the repo over this brief)
Branch: feat/l1-provider-preflight — cut it yourself off that sha. If it already
        exists, STOP and report; do not reset it.
Host: any. macOS bash 3.2 compatible; CI runs ./scripts/test-helpers.sh on Linux.
Runtime: minutes. New tests are offline.
Landing: PR to main. Do not allocate a decision id.

## 0. Clone first — never ~/ForteL2

    SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fortel2-preflight.XXXXXX")
    git clone git@github.com:StephenForte/ForteL2.git "$SCRATCH/ForteL2"
    cd "$SCRATCH/ForteL2" && git fetch origin
    git checkout -b feat/l1-provider-preflight origin/main

Run `pwd` and confirm before any edit. Record $SCRATCH on TEMP: and delete it.
Commit this brief verbatim as tasks/worker-prompts/l1-provider-preflight.md.

## 1. Read first

- AGENTS.md — the "L1 provider preflight (D-0123)" bullet. That prose IS the spec;
  the script exists to execute it. Read it before writing anything.
- tasks/decisions.md — D-0123 (the gate), D-0124 (two independent failure causes),
  D-0135 and D-0136 (the gate was skipped twice in one day; D-0136 names this script).
- scripts/alert-watch.sh — the replica probe (~line 700) is the in-repo precedent for
  a bounded JSON-RPC call: SIGALRM total deadline, body cap, urllib not curl.
- scripts/test-helpers.sh — the replica drip tests are the precedent for testing a live
  network path offline against a throwaway local server.
- scripts/lib.sh — logging/refusal conventions, require_bin.

## 2. Why this exists

D-0123 says: before naming ANY L1 RPC provider for a derivation catch-up, run two
capability calls, paste the results, compute cost against the plan cap, and put the
number in front of the operator. It is prose. It depends on somebody remembering it
mid-incident, and on 2026-09-14 and again on 2026-09-15 nobody did — twice, during the
recovery of a 12.7 h outage. Both times the provider happened to be fine. That is luck,
not a gate.

Worse, the same week produced three distinct provider failures the gate is meant to
catch, and one it does not:

  Chainstack free : 403 on the L1 genesis header — "Archive, Debug and Trace requests
                    are not available on your current plan". Killed a recovery deploy.
  drpc free       : Sepolia not served at all on the free plan.
  rpc.sepolia.org : returns no JSON.
  PublicNode      : serves 11703707's header when asked for 11703708 — on BOTH of its
                    Sepolia hostnames, while serving 162 receipts at that same height.
                    Wedged derivation for 12.7 h.

That last one is NOT covered by the current two calls. A provider can pass both and still
hand back a header whose number is not the number you asked for. The script must catch it.

## 3. What the script must do

`scripts/l1-provider-preflight.sh` — read-only, no state, no writes outside stdout.

CHECKS, each independently reported:

1. Reachability + chain id. Must be 11155111 (Sepolia). A wrong chain id is an immediate
   hard fail — this is the cheapest way to catch a mainnet URL pasted by mistake.
2. L1 genesis origin header. `eth_getBlockByNumber(11545587)` must return data.
   (Read the number from deployments/sepolia/.deployer/rollup.json `genesis.l1.number`
   rather than hardcoding it, and say in the handoff what you found there.)
3. Historical receipts. `eth_getBlockReceipts` on a block at least 3 weeks old. COMPUTE
   that height from the current head minus three weeks of 12 s blocks; do not hardcode a
   number that rots. Must return a non-empty array. `null` / empty is the pruning failure
   (D-0124 cause 1).
4. HEADER INTEGRITY — new, and the reason this script is worth writing. Request several
   blocks by number across the range you care about and assert the RETURNED
   `result.number` equals the number requested. Sample at minimum: the genesis origin,
   the current head, and a spread in between (a few dozen is plenty — argue your sampling
   in the handoff). Any mismatch is a hard fail naming both numbers. This is the
   PublicNode 11703708 class, and no existing check sees it.
5. rpckind pairing (D-0124 cause 2). Take the intended `--l1.rpckind` as an input. If
   `quicknode`, also probe `debug_getRawReceipts` — PublicNode answers it `-32601`, which
   stalls derivation quietly. Report the pair as compatible or not.

COST ARITHMETIC, printed as a block the operator can read without doing math:
  - Take remaining L1 blocks to derive as an input (or compute head minus a given start).
  - Per-block prices are measured facts already in AGENTS.md: QuickNode ≈40 credits/L1
    block, Alchemy free ≈340 CU (30M cap ≈ 88k blocks). Keep them in one table at the top
    of the script with a comment pointing at AGENTS.md as the source of truth.
  - Print: blocks × per-block → total, in credits AND dollars where a price is known
    ($0.43/M for QuickNode PAYG), and the fraction of any stated cap.
  - If the provider is unknown to the table, print "unpriced — unverified" rather than
    guessing. "Free tier" is never a capability claim.

EXIT CODES — distinct, so callers and tests can tell failures apart:
  0 all checks pass
  2 unreachable / no JSON
  3 wrong chain id
  4 missing genesis header
  5 pruned receipts
  6 header integrity mismatch
  7 rpckind mismatch
  (pick your own numbering if you prefer, but document it in --help and test each one.)

## 4. Secrets — the hard requirement

The URL will usually contain a provider token.

- **Never accept it as a command-line argument.** `ps -ww -o command=` exposes argv to
  every local process; that is literally how the reviewer read the live QuickNode URL off
  the running op-node today. Take it from an environment variable, or prompt-read it
  (`printf 'Paste the URL: ' && read -r URL`), which also keeps it out of shell history.
- Never echo the URL. Print only the scheme+host, with the path and query redacted —
  `https://red-dimensional-dream.ethereum-sepolia.quiknode.pro/<redacted>` is the shape
  alert-watch already uses in its log lines. Copy that convention.
- Never write the URL to a file, a log, or the alert state.
- Nothing in the script may end up in .env.sepolia.example with a real value.

Add a test that greps the script's own output for the token portion and fails if present.
That test is the point of this section.

## 5. Bounded calls

Reuse the alert-watch pattern: a total deadline (SIGALRM or equivalent) plus a response
body cap, not just a socket timeout. A socket timeout alone does not bound a trickling
response — measured this week at >600 s against a 15 s "timeout". A preflight that hangs
during an incident is worse than no preflight.

Keep the call count small and say what it is in --help. This may be run against a metered
endpoint; a few dozen calls at 40 credits is negligible, a few thousand is not.

## 6. Scope

New:               scripts/l1-provider-preflight.sh
                   tasks/worker-prompts/l1-provider-preflight.md (this brief)
Additive only:     scripts/test-helpers.sh (append; do not reorder existing tests)
                   README.md — one entry in the scripts table + a short usage note
                   AGENTS.md — the D-0123 bullet gains a pointer to the script. Do NOT
                   rewrite the rule; add "Run scripts/l1-provider-preflight.sh and paste
                   its output" and leave the measured provider facts intact.
Do not touch:      alert-watch.sh, lib.sh, deploy-agents.sh, resolve-games-sepolia.sh,
                   any start/stop script, launchd/, deployments/, gateway/, replica/,
                   tasks/decisions.md (planner-owned; no id), .env.sepolia (ever).

If the task appears to need something outside this surface, stop and report.

## 7. Tests — offline, always

Stand up a throwaway local HTTP server per case (high port, NOT 9545-9551; kill it in a
trap so a failing test cannot leave it listening). Cover:

  - all checks pass                          -> exit 0
  - connection refused / non-JSON body       -> exit 2
  - chain id 1 instead of 11155111           -> exit 3
  - genesis header returns null              -> exit 4
  - receipts return null, and return []      -> exit 5 (both)
  - header integrity: server returns block N-1 when asked for N  -> exit 6,
    and the message must name both the requested and returned numbers
  - rpckind=quicknode + debug_getRawReceipts -32601  -> exit 7
  - a trickling response cannot exceed the deadline
  - the token never appears in stdout or stderr
  - cost block prints the right arithmetic for a known provider, and "unpriced" for an
    unknown one

The header-integrity and token-redaction tests are the two that justify this script.
Make them the strongest.

## 8. Mutation-test and paste results

At minimum: drop the integrity comparison; drop the redaction; drop the deadline. Name
the specific test that goes red for each. A guard whose tests pass against broken code is
worse than no guard.

## 9. Return block

TASK / REVIEW ARTIFACT / STATUS as usual, plus:
VERIFICATION: ./scripts/test-helpers.sh counts with and without a local .env, and the sha
              you compared to. Say whether you ran the script against any REAL provider;
              if you did, name the provider and the call count, and confirm no URL was
              printed.
MUTATION:     three breaks, named test red for each
EXIT CODES:   the table you implemented
SHARED FILES TOUCHED / EXISTING CHECKS MODIFIED / DECISIONS NEEDED
CLONE:        deleted <path>
TEMP:         every path outside the repo — deleted: yes/no
RESIDUAL GAPS: must include — merge is not deploy (./scripts/deploy-agents.sh updates
              /Users/steveforte/fortel2-agents, which is what launchd runs); the block
              you chose for the receipts check and why; your header sampling strategy;
              and the fact that this script cannot preflight the Render replica's own
              endpoint, because that uses the L2_Render token which lives only in the
              Render dashboard — that limitation is exactly why the gate was skipped
              twice and it should be stated, not hidden.

/goal keep this PR merge-ready: fix failing CI checks and bot review comments until everything passes.
