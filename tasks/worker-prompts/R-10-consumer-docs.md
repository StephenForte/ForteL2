# Worker prompt — R-10: availability + write-path in the consumer-facing docs

Copy everything below the line into the worker. **Cheap model tier.** Wave 4 — the **last task** in the R-programme. Runs alone; nothing else is in flight.

---

You are a docs worker on the ForteL2 repo. Your task card is **`tasks/review-2026-08-05.md` §R-10** — read it in full; it is the spec. This prompt adds the coordination contract, the settled facts from the eight merged tasks, and one escalation you are inheriting.

## Task in one line

Everything R-01…R-09 established is true in the repo but invisible to the person who matters: a SettlementOS integrator reading `README.md`. Tell them, in the consumer-facing docs, that the chain sleeps nightly and where writes stand today.

## Settled facts you are writing from (all merged; do not re-derive or contradict)

- **Availability:** sleep **23:00**, wake **04:00**, `America/Los_Angeles`. Now identical in `launchd/*.plist`, `launchd/README.md`, `README.md`, and `deployments/rail-interface.json` (`availability` object). Your edits must not introduce a fifth spelling of the hour.
- **Write path:** loopback only. `tasks/spike-t5-write-path.md` (D-0019) documents five options and recommends Tailscale **after** narrowing the sequencer RPC namespace — but it is explicitly **pending operator US-012 go/no-go**. Nothing is approved. Say exactly that, and link the spike.
- **Reads:** per D-0016 there is no Mac-reachable replica URL; `rail-interface.json` now has `replica.readRpcUrl: null` and an `accessModel` of Render Web Shell. Interim reads land on the same sequencer endpoint as writes (spike §6).
- **No uptime commitment.** This is a personal L2 on a Mac mini; a reboot without auto-login leaves it down silently (spike D7).

## The three edits (card steps 1–3)

1. `README.md` §"SettlementOS money-rail track", SOS onboarding list: add a **step 0** stating the nightly window (23:00–04:00 local), that the sequencer RPC is down during it, and that SOS retry/backoff must assume a nightly outage. Add one line on the write path reflecting R-01's outcome — loopback today, operator go/no-go outstanding, link `tasks/spike-t5-write-path.md`. **A reader who opens only `README.md` must learn both facts without following a link.**
2. `tasks/coordination-settlementos.md` §"SOS onboarding gate": replace *"writes use Mac sequencer RPC until a write tunnel exists"* with a precise statement of today's reality plus a pointer to the spike doc, and add the availability window.
3. `tasks/prd-money-rail.md`: add availability to **FR-2**'s list of what `rail-interface.json` must carry, so a future rewrite cannot drop it.

## Inherited escalation — E-R02-1 (sanctioned scope extension)

`deployments/rail-interface.json` → `networks["fortel2-sepolia"].notes` still ends *"Reads: prefer replica when reachable."* That contradicts `replica.readRpcUrl: null` in the same file. R-02 flagged it and correctly left it (outside its nine card steps); it is yours.

Fix **only that sentence** — e.g. reads today land on the sequencer endpoint; the replica has no reachable URL (D-0016). Constraints, non-negotiable:
- Change **no** address, chain ID, port, or RPC URL value. `scripts/rail-interface-check.sh` must still exit 0 — run it.
- Do **not** bump `version`/`updated` (the v2 contract is unchanged in substance; this is a wording correction). If you believe a bump is warranted, say so in the handoff instead of doing it.

## Write allowlist (exclusive)

`README.md` **SettlementOS section only** · `tasks/coordination-settlementos.md` (onboarding gate section) · `tasks/prd-money-rail.md` (**FR-2 list only**) · `deployments/rail-interface.json` (**the one `notes` sentence, per E-R02-1**) · `tasks/decisions.md` (append **D-0025** only — record that consumer docs now carry availability + write-path status, and that E-R02-1 is closed)

Do NOT touch: `launchd/`, `scripts/`, other PRD sections, any other part of `rail-interface.json`.

## Contract

- Branch `agent/r10-consumer-docs` off tag `wave12-base`. Commits: `docs(sos): …`. Merged alone; the review's §4 Final QA runs after it.
- Checks before done (paste verbatim):
  - `./scripts/rail-interface-check.sh; echo exit=$?` → exit 0
  - `python3 -c "import json;json.load(open('deployments/rail-interface.json'));print('JSON-OK')"`
  - `grep -rn "23:00" README.md tasks/coordination-settlementos.md deployments/rail-interface.json launchd/README.md launchd/*.plist` → the hour is identical in all five places
  - `git diff wave12-base..HEAD -- deployments/rail-interface.json` → only the `notes` line changed; no `0x…`, chain ID, URL, `version`, or `updated` line touched
  - `grep -n "prefer replica when reachable" deployments/rail-interface.json` → empty
  - `git diff --stat wave12-base..HEAD` → exactly the five allowlisted files
- No merging, no pushing to main, no tags.

## Handoff report — REQUIRED as your final chat message

1. Branch + base tag; `git diff --stat wave12-base..HEAD`
2. Allowlist compliance
3. Card success criteria + E-R02-1 — each: met, with evidence
4. Checks run + verbatim output
5. `decisions.md` entries appended (expect: D-0025)
6. Anticipated conflicts with siblings (expect: none — you run alone)
7. Operator actions needed (expect: none from this task; the outstanding US-012 go/no-go from R-01 is unchanged and should be restated so it is not forgotten)
