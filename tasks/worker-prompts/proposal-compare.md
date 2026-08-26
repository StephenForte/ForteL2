# Worker prompt — T2: feat/proposal-compare (US-P7-005)

Copy everything below the line into the worker. Model: Sonnet. Codex review: YES on this PR (metered budget approved, FRD §5).

---

DISPATCH · Model: Sonnet · Order: wave 2, alone (#157 merged) — but do not start while T1's follow-up W1/W2
  live measurement is still running in the checkout (one shared working tree; contention has
  bitten before). · Codex review: YES on this PR (metered budget approved, FRD §5).
Surface: Claude Code on the operator's Mac
Baseline: main @ 7facf0eee35095c216572e3e89f52b8b71e58888
Host: the operator's Mac (live shakeout reads Sepolia L1 + the seal EL; CI runs fixture tests only)
Working directory: /Users/steveforte/ForteL2 · Landing: PR to main; review takes the next free decision id

# T2 — feat/proposal-compare: audit derived output roots against on-chain proposals (US-P7-005)

## Read first (repo over brief — verify every claim here against the checkout)

- `tasks/frd-us-p7-005-independent-derivation.md` — governing spec; you are T2. Note §4 T2
  was corrected post-merge (#155): **no silent game-type default** — read it as merged.
- `tasks/decisions.md` D-0094 (path choice), D-0097 (T1 review — you now own `derivation/*.go`
  including the rpc.go empty-result retries it accepted; two notes there are addressed to you),
  D-0063 Finding 3c + D-0083 (game-type policy),
  D-0077 (type-8 registration), D-0049 (env rules), D-T2-3 (hash-diff contract).
- `derivation/README.md` — module layout, the `batcher` import-only rule, CLI flags.
- `derivation/verify.go`, `derivation/cmd/verify/main.go` — what you are extending.

Everything below was true at `7facf0e` on 2026-08-25. Trust the repository over this brief.

## Branch

Cut `feat/proposal-compare` off main at `7facf0e` yourself. If it already exists, stop and
ask. First commit: this brief, verbatim, as `tasks/worker-prompts/proposal-compare.md`.

## Why this task exists

`cmd/verify`'s expected value comes from `-ref-l2` — the operator's own EL (`ref.BlockHash`,
verify.go:84). The oracle being audited supplies the answer key, so today the tool proves
consistency, not honesty. T2 switches the comparison oracle to the operator's **staked
claims on L1**: the root claims of dispute games in the DisputeGameFactory. Derived-from-L1
output root vs claimed root is exactly the audit a counterparty needs.

## Outcome (properties, not implementation)

1. **Proposal enumeration** (new code in `derivation/`, e.g. `proposals.go`): list factory
   games of the **respected game type resolved on-chain** — `AnchorStateRegistry.
   respectedGameType()` (read precedent: `scripts/resolve-games-sepolia.sh:701`) — with an
   explicit flag to override the type for auditing a previously-respected one. **No numeric
   default anywhere** (D-0063 3c / D-0083; same policy `create-bad-proposal-sepolia.sh`
   enforces). Decode each game's `rootClaim` and `l2BlockNumber` (extraData). Factory and
   ASR addresses come from the deploy artifacts (`deployments/sepolia/.deployer/state.json`),
   each overridable by flag; refuse to run with neither.
2. **Output-root computation** (e.g. `outputroot.go`): at a proposal height, compute the
   version-0 output root from the **seal EL** — `keccak256(version ‖ stateRoot ‖
   messagePasserStorageRoot ‖ blockHash)`, storage root via `eth_getProof` of the
   L2ToL1MessagePasser predeploy (`0x4200000000000000000000000000000000000016`).
3. **New mode** in `cmd/verify` (e.g. `-compare proposals`): for every enumerated proposal
   whose height falls inside the derived window, report MATCH/MISMATCH of derived vs
   claimed root, plus the game's address, index, creation time, and resolution status
   (status is context, never a gate — an unresolved game with a matching claim is MATCH).
   Per D-0097: the self-anchor resume head-hash check and the safe_l2 bound consult the
   reference node — in *your* mode any such reference consultation must be informational,
   never a gate; proposal mode runs without the operator node as an authority anywhere.
   Any MISMATCH ⇒ nonzero exit (this alarm is the tool's purpose; it must fail closed).
   Proposal mode must run **without `-ref-l2`**; the legacy consistency mode keeps it and
   is otherwise unchanged.
4. **Tests**: fixture-driven `go test` — synthetic game lists, known output-root preimages
   (assert the exact keccak against a hand-computed vector), extraData decode, respected-
   type resolution, the no-default refusal, MISMATCH ⇒ error. No live-chain dependency in
   `go test`.

## Scope

- **Freely changeable:** new files under `derivation/` and `derivation/cmd/verify/`
  (flag wiring, mode dispatch). Minimal edits to existing `derivation/*.go` where the new
  mode must hook in (verify.go / cmd wiring); keep them surgical.
- **Additive only:** `scripts/test-helpers.sh` (append only — every task appends here), `derivation/README.md` CLI table/flags rows only (Limitations
  rewrite is T3's), `tasks/worker-prompts/proposal-compare.md` (this brief, first commit).
- **Do not touch:** `scripts/derivation-check.sh` (T1's file, merged in #157 — its follow-up
  measurement work may still land there),
  `batcher/**` (import-only rule), `scripts/lib.sh`, `.github/workflows/**`,
  `tasks/decisions.md` (planner-owned).
- Stop and report rather than widening scope.

## The trap

`eth_getProof` against the seal EL only works for heights whose **state** the seal EL still
has. A proposal height outside the derived window — or inside it but pruned — yields an
error, or worse, a proof for a non-existent account that produces a *plausible-looking but
wrong* storage root and therefore a false MISMATCH against an honest operator. Handle the
three cases distinctly and loudly: height not in derived window ⇒ SKIPPED (named, counted,
nonzero-neutral — not silently dropped); proof error ⇒ hard error; proof returned ⇒ verify
the account proof is for an existing account before using the storage root. A false alarm
from a counterparty audit tool is almost as bad as a false pass — both destroy the trust
the tool exists to create.

Second: `l2BlockNumber` lives in extraData (ABI-encoded uint256), not in a getter shared by
every game type — decode defensively and error on malformed extraData rather than skipping.

## What must survive

- Legacy consistency mode byte-identical in behavior: same flags, same report lines, same
  exit semantics (D-T2-3). All existing `go test ./...` green, zero modified assertions.
- The kill switch: nothing here runs unless invoked; the reference stack is never written
  to; proposal mode adds only read-only L1/seal-EL calls.
- Expected on main at `7facf0e`: `./scripts/test-helpers.sh` 307 PASS 0 FAIL;
  `./scripts/phase7-gate-parity.sh` 60 PASS exit 0; `cd derivation && go test ./...` green.
  Unexplained count movement is a finding — report it, don't absorb it. (Unrelated merges may raise counts; re-measure after merging main and say so.)
- `batcher` module wiring: import decode helpers only, never edit `batcher/*.go`.
- D-0049: never read or print `.env.sepolia` values; no secrets on argv.

## Unresolved decisions stay unresolved

None known. If implementation surfaces one (e.g. how far back to enumerate games), report
it under DECISIONS NEEDED with what you did in the interim — do not decide silently.

## Verification (run at hand-back, after merging current main into your branch)

```
cd derivation && go test ./...
bash -n scripts/test-helpers.sh
./scripts/test-helpers.sh
./scripts/phase7-gate-parity.sh
FORTEL2_ENV=.env.sepolia <the live shakeout: run -compare proposals against the real Sepolia factory over a derived window; paste the per-proposal lines>
```

The live shakeout is required (never-run-live scripts break live): at least one real
proposal must be enumerated, its type shown as the on-chain respected type, and its
MATCH/SKIPPED status reported with the game address. State plainly what was verified by
hand vs by test.

## Out of scope, with reasons

- Self-anchor / replay mechanics — T1 (#157).
- README Limitations rewrite + counterparty runbook — T3, after T1+T2 merge.
- Historical audits of previously-respected game types beyond the override flag — future.
- Replica pack — separately blocked on T3.

If you believe the approach is wrong — flag design, the SKIPPED semantics, the proof
validation — argue it with evidence in your report rather than implementing it
half-heartedly. The brief's author has been wrong before (see #155) and the repo is the
authority.

## Return format (verbatim, these labels, this order)

TASK:        T2 proposal-compare — <one line>
LINE OF WORK: feat/proposal-compare
REVIEW ARTIFACT: <PR url>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: <each check named> — pass/fail, with counts
              (run against main merged in as of hand-back)
LIVE SHAKEOUT: <proposals enumerated n, respected type t (on-chain), MATCH x / SKIPPED y /
               MISMATCH z, game addresses; or why it could not run>
MIGRATION:   none

SHARED FILES TOUCHED: <path> — what changed, why it is additive   (or: none)
IDENTIFIERS USED:     none (review allocates the next decision id)
EXISTING CHECKS MODIFIED: <path> — <before> → <after>; why this strengthens
                          rather than weakens                      (or: none)
DECISIONS NEEDED:    none | <the question, and what you did in the interim>
RESIDUAL GAPS:       what this does not cover; hand-verified vs automated; risk plainly

Disclosure in the last three fields counts as diligence, not failure.
