# Worker prompt — R-02: `rail-interface.json` v2 — truthful, dated, availability-aware

Copy everything below the line into the worker. **Mid model tier.** Wave 2; R-07/R-08 run in parallel — allowlists are exclusive. You are the only Wave-2 task touching `deployments/` or appending to `decisions.md`.

---

You are a worker on the ForteL2 repo. Your task card is **`tasks/review-2026-08-05.md` §R-02** — read it in full; it is the spec and its 9 instruction steps are to be followed exactly. This prompt adds the coordination contract and two clarifications.

## Task in one line

`deployments/rail-interface.json` is the contract SettlementOS consumes, and it is stale in three ways the review card enumerates: the reset-policy text predates Phase 6 completion and D-0018, the replica block describes a read URL that does not exist (D-0016), and nothing mentions the nightly 23:00–04:00 downtime. Produce v2: same addresses, true words.

## Required reading before editing

`tasks/review-2026-08-05.md` §R-02 (all 9 steps + success criteria) · the current `deployments/rail-interface.json` · `tasks/decisions.md` D-0016, D-0018, **D-0019** (merged R-01 outcome: loopback stands, no write URL is being published) · `tasks/spike-t5-write-path.md` **§5** ("What changes in rail-interface.json if approved") — your v2 must stay consistent with that section's future shape but must NOT add a write URL or any key it reserves for the post-go/no-go bump.

## Two clarifications (integrator-settled; the card is ambiguous here)

1. **"Both RPC URLs byte-identical" vs step 4's `readRpcUrl: null`:** byte-identity binds `l2RpcUrl`, `l2NodeRpcUrl`, and `l1RpcUrl` in **both** network objects. `networks["fortel2-sepolia"].replica.readRpcUrl` → `null` is the one sanctioned URL-field change (card step 4). `replica.writeRpcUrl` stays `null`.
2. **The availability hours are settled and now live:** sleep 23:00 / wake 04:00 `America/Los_Angeles` — already reconciled in `launchd/` and both READMEs by merged R-03. Use the exact `availability` object text from card step 6.

## Write allowlist (exclusive)

`deployments/rail-interface.json` · `tasks/decisions.md` (append **D-0020** only — never edit above it)

Do NOT touch: any other file. PRD/README availability text is R-10's (Wave 4). Anything else you believe needs changing → append an `E-R02-<n>` escalation.

## Contract

- Branch `agent/r02-rail-interface-v2` off tag `wave9-base`. Commits: `docs(rail): …`. Squash-merged first in Wave 2.
- Checks before done (paste verbatim):
  - `python3 -c "import json; json.load(open('deployments/rail-interface.json'))" && echo JSON-OK`
  - `git diff wave9-base..HEAD -- deployments/rail-interface.json | grep -E "^[-+].*0x[0-9a-fA-F]{40}"` → **empty** (no address line touched)
  - `git diff wave9-base..HEAD -- deployments/rail-interface.json | grep -E "^[-+].*(l2ChainId|l1ChainId)"` → **empty**
  - `grep -c "pinned through learning Phase 6" deployments/rail-interface.json` → 0
  - `grep -c "REPLICA_L2_RPC_URL" deployments/rail-interface.json` → 0
  - `grep -n "23:00" deployments/rail-interface.json` → shows `sleepLocal`; `grep -n "04:00"` → shows `wakeLocal`
  - `git diff --stat wave9-base..HEAD` → exactly the two allowlisted files
- No live stack, no RPC, no secrets — you need none.
- No merging, no pushing to main, no tags.

## Handoff report — REQUIRED as your final chat message

1. Branch + base tag; `git diff --stat wave9-base..HEAD`
2. Allowlist compliance
3. Card success criteria — each of the 6, met/not-met with evidence
4. Checks run + verbatim output
5. `decisions.md` entries appended (expect: D-0020)
6. Anticipated conflicts with siblings (expect: none — exclusive files)
7. Operator actions needed (expect: none; R-04's drift guard lands next wave)
