# Spike US-070 — Phase 7 fault-game immutables, chosen

**Date:** 2026-08-18
**Status:** Values confirmed by operator. `.env.sepolia` update and notice date are still **operator-pending** — this file records the decision, it does not execute it. No `FORCE_SEPOLIA_REDEPLOY`, no pack/publish, no datadir wipe has happened.

---

## 1. Chosen values

All six are the PRD's proposed defaults (`tasks/prd-phase-7-fault-proofs.md` § "Proposed immutable defaults"), confirmed as-is after walking through what each one does operationally. Nothing here is a new number — this is the record of the confirmation, not a re-derivation.

| Env var | Value | What it controls |
|---|---|---|
| `FAULT_GAME_CLOCK_EXTENSION` | `600` (10 min) | Per-move chess-clock top-up in the dispute game — each response to a claim bumps the clock by this much if it's running low. Long enough to type a `cast` command by hand per move. |
| `FAULT_GAME_MAX_CLOCK_DURATION` | `7200` (2 h) | Total clock budget **per side** across the whole game (total chess time, not per-move). Caps a full dispute at a couple hours of game-clock, not days. |
| `PREIMAGE_ORACLE_CHALLENGE_PERIOD` | `3600` (1 h) | Sixth constructor immutable (D-0046). Separate window for disputing a large-preimage claim inside Cannon's execution trace, if the dispute goes that deep. Mostly a deploy-time math input unless the bad-proposal exercise (US-074) actually forces a large-preimage step. |
| `PROOF_MATURITY_DELAY_SECONDS` | `1800` (30 min) | After a game resolves, how long before that output root is mature enough to *prove* a withdrawal against. |
| `DISPUTE_GAME_FINALITY_DELAY_SECONDS` | `1800` (30 min) | Portal-level buffer after a game resolves, independent of and on top of the game's own clock — extra room for the guardian role to react to a bad game even after its clock expired. |
| `FAULT_GAME_WITHDRAWAL_DELAY` | `3600` (1 h) | End-to-end delay from "game resolved" to "withdrawal can actually finalize." The number `withdraw-finalize.sh` would watch if the exercise extends into withdrawals. |

## 2. Why these satisfy `initialize`

`PermissionedDisputeGame.initialize` requires:

```
maxClockDuration >= max(2 * clockExtension, clockExtension + preimageOracleChallengePeriod)
```

`max(2*600, 600+3600) = max(1200, 4200) = 4200`. `7200 >= 4200` ✓. This is the same check `02-deploy-contracts-sepolia.sh` enforces before apply (D-0046) — the script will refuse to write `intent.toml` and exit if this ever goes false, so a bad combination fails closed at deploy time rather than after a network-wide wipe.

The old pinned values (`clockExtension=5`, `maxClockDuration=10`, implicit `preimageOracleChallengePeriod=86400`) fail this check (`10 < 5+86400`) — they could never `create()` a game at all. That is *why* a redeploy is mandatory for Phase 7, not just why longer clocks are nicer to play with.

## 3. Net operator experience

A full dispute (US-073 happy path or US-074 bad-proposal path) plays out in one sitting — on the order of the 2 h game clock plus up to ~1 h of layered finality/maturity delay if the exercise extends into withdrawal finalization. Not seconds (the old pinned values), not mainnet's multi-day windows. This matches the PRD's stated intent: minutes-to-hours, sized for a human to actually play by hand.

## 4. Notice date — rule, not a date

Per operator direction (2026-08-18): the ≥1-day SOS/Render/friends notice (D-0028) does not start on a calendar date chosen now. **The notice goes out only after all Phase 7 coding/config work is complete and reviewed.** At that point the operator sends notice and sets the actual date; step 2 of the Operator sequence (stop Mac writers) may not begin until **≥24 h after that notice is sent**, per the PRD's Operator sequence and README Network reset procedure. No specific calendar date is recorded here — recording one now, before the work it gates is even done, would misstate readiness to SOS and every Phase 3b friend.

## 5. What is still pending (not done by this file)

- [ ] Operator hand-edits local `.env.sepolia` (gitignored, contains signing keys — not touched by this brief or any agent) to set all six values above. Two of the six (`FAULT_GAME_CLOCK_EXTENSION`, `PREIMAGE_ORACLE_CHALLENGE_PERIOD`) are currently **absent** from the file and fall back to script defaults (`5`, `86400`) until added; the other four are still at old pinned values (`12`, `6`, `10`, `1`).
- [ ] Notice to SOS + Render + every Phase 3b friend, ≥1 day ahead, sent only once the operator is actually ready (§4).
- [ ] Everything from US-071 onward (redeploy gate, coordinated wipe, challenger runs) — all operator-executed per the Operator sequence table; not started.

## References

- `tasks/prd-phase-7-fault-proofs.md` § "Proposed immutable defaults", § "Operator sequence", US-070
- `tasks/decisions.md` D-0041, D-0046, D-0048, D-0049
- `scripts/02-deploy-contracts-sepolia.sh` (initialize-inequality guard)
- `.env.sepolia.example` (names documented, pinned example values unchanged per D-0046)
