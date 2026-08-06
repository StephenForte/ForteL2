# Worker prompt — R-01: SOS write-path decision spike (T5 revival)

Copy everything below the line into the worker. **Strongest model tier.** Wave 1; R-03/R-05/R-06 run in parallel — your allowlist is exclusive, respect theirs. R-06 also appends to `decisions.md`; expect a trivial append-side merge handled by the integrator.

---

You are a spike worker on the ForteL2 repo. Your task card is **`tasks/review-2026-08-05.md` §R-01** — read it in full first; it is the spec and its success criteria are your acceptance gate. This prompt adds the coordination contract; where they differ, the card wins on content, this prompt wins on process.

## Task in one line

Produce the written decision material for how SettlementOS reaches the chain-852 sequencer to write — a new `tasks/spike-t5-write-path.md` (dependency map D1–D9 + non-dependencies, five-option table, one recommendation marked **pending operator go/no-go**, sequenced plan, rail-interface delta section) plus one appended `decisions.md` entry. **No code, no infrastructure, no ports, no bind changes — a document.**

## Required reading before writing

`tasks/review-2026-08-05.md` §R-01 (all of it, including the D1–D9 map) · `tasks/prd-money-rail.md` §"When SettlementOS may come on the L2" + open questions · `tasks/prd-l2-learning-chain.md` US-012 + US-032 · `tasks/coordination-settlementos.md` · `tasks/decisions.md` D-0016 (why SSH tunneling to Render is dead — do not re-propose it) and D-0018 · `scripts/04-start-sequencer-sepolia.sh` (verify the D1 flag list yourself — cite the line numbers you actually see, not the ones the card quotes) · `scripts/lib.sh` lines ~304–360 (`assert_l2_loopback_urls`, `require_sepolia_env`) for D3.

## Ground rules the card implies — made explicit

- The operator position is **loopback stands for now**. Your recommendation informs a *future* go/no-go; do not write as if approval exists.
- The options table needs all five rows (colocate SOS on the mini; Tailscale tailnet-only; `cloudflared` + access policy; authenticating reverse proxy; relocate sequencer) × all seven columns (exposed / to-whom / auth / rollback / cost / effort / US-012 satisfaction), **plus** the per-row `lib.sh` answer. No "TBD" in exposure, auth, or rollback.
- Sequenced plan order is fixed by the card: D1 (narrow RPC namespace to `eth,net,web3`) → D2 (US-012 review) → transport → R-02 publish → SOS registry entry.
- The "what changes in `rail-interface.json` if approved" section lists exact JSON keys — you do not edit that file (R-02 owns it, next wave).
- `decisions.md` entry is `### D-0019 — SOS write-path options recorded (T5 revival)`, using the template at the bottom of that file, appended at the very end of §Decisions. Three lines: Context / Decision / Consequence. The Decision line records that options are documented, loopback stands, go/no-go is the operator's.

## Write allowlist (exclusive)

`tasks/spike-t5-write-path.md` (new) · `tasks/decisions.md` (append D-0019 only — never edit above it)

Do NOT touch: any `.sh`, `.go`, `.json`, `.env*`, `README.md`, PRDs, `launchd/`. If the spike surfaces something needing a change elsewhere, append an `E-R01-<n>` escalation to `decisions.md` instead.

## Contract

- Branch `agent/r01-write-path-spike` off tag `wave8-base`. Conventional commits, `docs(t5): …`. Squash-merged first in Wave 1.
- You have no live stack, no `.env.sepolia`, no secrets — you need none. Never construct or request an RPC URL.
- Checks before done: `git diff --stat wave8-base..HEAD` shows exactly the two allowlisted files; `git diff wave8-base..HEAD -- tasks/decisions.md` shows additions only, at the end; every §R-01 success criterion self-audited line by line.
- No merging, no pushing to main, no tags.

## Handoff report — REQUIRED as your final chat message

One copy-pasteable markdown block, exactly these sections:

1. Branch + base tag; `git diff --stat wave8-base..HEAD`
2. Allowlist compliance (expect: none outside)
3. Card success criteria — each one: met / not-met, with evidence (quote the doc line or grep)
4. Checks run + verbatim output
5. `decisions.md` entries appended (expect: D-0019, plus any E-R01-n)
6. Anticipated conflicts with siblings (expect: `decisions.md` append vs R-06)
7. Operator actions needed (expect: the US-012 go/no-go itself)
