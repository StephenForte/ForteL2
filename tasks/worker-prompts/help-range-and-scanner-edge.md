# Worker brief — help-range-and-scanner-edge: funding-watch --help truncation + lib.sh multi-line-value scanner edge

```
DISPATCH · Model: Sonnet 5 · Order: standalone; nothing else in flight
Surface: Claude Code worker session, launched by the operator via the desktop app (branch dropdown)
Baseline: main @ a27c625 · branch chore/help-range-and-scanner-edge (the operator creates it — if it does not exist in the dropdown, stop and ask; do not cut your own)
Host: the operator's Mac (darwin) — the harness runs here
Working directory: /Users/steveforte/ForteL2 (app-isolated; leave `main` checked out when you finish and never leave the tree dirty — an hourly launchd agent runs scripts from this checkout)
Landing: PR to main. The reviewer writes decision D-0093; do not touch tasks/decisions.md or allocate a decision id.
```

Copy everything below the line into the worker.

---

## Task

Two recorded micro-defects, one small PR. Trust the repo over this brief.

### 1. `funding-watch.sh --help` stops before the env-key table (D-0091 Finding 3a)

The help path is `sed -n '2,30p' "$0"` (~line 60). The header's Usage line is line 30, so
`--help` prints everything *up to* Usage and omits the env-key table right below it
(lines ~31–39: `FUNDING_POLICY_MIN_ETH` … `FUNDING_HEALTH_TIMEOUT`) — the part an operator
actually needs. Fix so `--help` prints the Usage line **and** the full env-key table.
Prefer a content-anchored bound over a new hard-coded line number — this project has been
bitten by stale line ranges four separate times (D-0065 Finding 4 class); e.g. print header
comment lines until the first non-comment line. Property test: `--help` output contains
`FUNDING_STALE_HOURS` and `FUNDING_HEALTH_TIMEOUT`, exit 0.

While there, **measure** (do not assume) whether `alert-watch.sh --help` (`sed -n '2,50p'`)
has the same truncation against its own header length. If it does, apply the same fix and
test; if it does not, say so in the report and leave it.

### 2. `lib.sh` `_scan_env_assignments` miscounts multi-line quoted values (D-0090 Finding 2)

A continuation line of a quoted multi-line value that happens to look like `name=value` is
counted as an assignment of `name`. Two dups of that shape → **false refusal**, and a false
refusal from the loader bricks every script simultaneously, including the hourly
bond-recovery agent. Neither committed example nor (per the operator's live preflight runs)
the real env files have multi-line values today — this closes the recorded edge before it
can bite.

Outcome: lines inside an unclosed quoted value are not counted as assignments. Mechanism is
your choice, but the loader runs on every script start — keep it small and obvious, bash-3.2
compatible, and bias against cleverness: full shell-quoting emulation is out of proportion;
tracking unclosed single/double quotes across lines is about the right size. The refusal's
existing behavior must not weaken: all 281 current tests stay green, and the D-0090-probed
properties (export-prefixed dup refused, `=`-in-value accepted, names-only output) still hold.

Property tests (append to `test-helpers.sh`): a double-quoted multi-line value whose
continuation lines look like `name=value` (including the same name twice) → accepted, loads,
no refusal; same with single quotes; a real duplicate in a file that *also* contains a
multi-line value → still refused naming the real dup only.

## Scope

- **Freely changeable:** the `--help` slice of `scripts/funding-watch.sh` (nothing else in
  that proven script), the `# >>> env-dup` block of `scripts/lib.sh` (nothing else — note
  `phase7-preflight.sh` extracts that block by its markers; keep the markers intact), and
  the same-class `--help` slice of `scripts/alert-watch.sh` only if measured truncated.
- **Additive only:** `scripts/test-helpers.sh` (append; do not reorder; currently **281
  PASS 0 FAIL** on main).
- **Do not touch:** everything else; `tasks/decisions.md` is reviewer-owned (D-0093 is
  pre-assigned to the review — do not derive an id).
- Stop and report rather than widening scope.

## The trap

Both fixes sit on paths where the failure mode is silent or total: a wrong `--help` bound
prints part of a `set -euo` script to the operator's terminal or nothing at all, and a
scanner regression is not a broken test — it is either a false refusal that bricks every
script at once, or a lost refusal that silently re-opens the D-0065 last-assignment-wins
hole. Test the accept and refuse directions with equal force, and run the preflight's
extraction path (`scripts/phase7-preflight.sh` against a fixture root, or the existing
harness tests that cover it) to prove the marker-extracted block still works standalone.

## Verification — run at hand-back against main merged in

```
bash -n scripts/funding-watch.sh scripts/lib.sh scripts/alert-watch.sh
FORTEL2_ENV=.env.sepolia.example ./scripts/funding-watch.sh --help   # full env table visible, exit 0
./scripts/test-helpers.sh          # 281 + N additive PASS, 0 FAIL — state N
./scripts/phase7-gate-parity.sh    # 60 PASS, exit 0
```

## Return format — verbatim

```
TASK:        help-range-and-scanner-edge — --help truncation + multi-line-value scanner edge
LINE OF WORK: chore/help-range-and-scanner-edge
REVIEW ARTIFACT: <PR URL>
STATUS:      complete | complete-with-caveats | blocked
VERIFICATION: <each check named> — pass/fail, with counts (against main merged in at hand-back; re-state the counts if you push after writing this report)
SHARED FILES TOUCHED: <path> — what changed, why additive   (or: none)
EXISTING CHECKS MODIFIED: <path> — <before> → <after>; why this strengthens (or: none)
DECISIONS NEEDED:    none | <question + interim choice>
RESIDUAL GAPS:       <plain statement, incl. the alert-watch measurement result>
```

If you believe either fix is wrong-sized — the scanner edge should stay a documented
limitation, or the help fix needs a different shape — argue it with evidence in the report
rather than implementing it half-heartedly.
