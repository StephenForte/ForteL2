# Worker prompt — R-09: small-fixes bundle

Copy everything below the line into the worker. **Cheap model tier.** Wave 3. **Run after R-04 has been merged** — serial, not parallel; that keeps `test-helpers.sh`/CI conflict-free and means your `derivation` test run happens on settled ground.

---

You are a worker on the ForteL2 repo. Your task card is **`tasks/review-2026-08-05.md` §R-09** — read it in full; it is the spec. Three unrelated one-liners plus one integrator addition. This prompt adds the coordination contract.

## The four items

1. **Dangling path reference.** `tasks/prd-mainnet-pilot.md:27` cites `replica/l1_rpc_router.py` as an in-repo pattern. It does not exist here — `replica/` holds only `README.md`, `config/`, `patches/`; the router lives in the sibling `fortel2-replica` repo. Reword to name the sibling repo explicitly, e.g. *"the L1 RPC router in the `fortel2-replica` repo (not in this tree)"*. **Leave D-0018 in `decisions.md` untouched** (append-only history).
2. **`.env.sepolia.example` lost the D-0016 note.** The live `.env.sepolia` carries a comment the committed example does not, so a fresh clone rediscovers the SSH-tunnel dead end from scratch. Add, near the replica/QuickNode comment block:
   `# REPLICA_L2_RPC_URL unset — replica is a Render private service with no Mac-reachable URL; sync drill runs via the Render Web Shell (see tasks/decisions.md D-0016)`
   **Comment lines only — no `=` assignment, no URL, no key.**
3. **Test misnomer.** `derivation/channel_test.go:74` defines `TestSepoliaGoldenSkipped`, which actually replays 50 blocks. Rename to `TestSepoliaGoldenReplay`. Update any mention in `derivation/README.md` — **note that R-08 recently added a `## Limitations — independent verification` section to that file; check whether the old name appears anywhere in the current README before and after your edit.** Do **not** edit `tasks/decisions.md` D-H3-2, which names the old test.
4. **Integrator addition (found during Wave-2 review).** `tasks/prd-mainnet-pilot.md:48` reads *"the chain no longer sleeps at 21:00"*. That hour is stale — the reconciled schedule is **23:00** sleep / 04:00 wake (merged R-03, and now `rail-interface.json` `availability`). Change `21:00` → `23:00` in that line only. This is a sanctioned one-line extension of the card; cite it in your handoff.

## Write allowlist (exclusive)

`tasks/prd-mainnet-pilot.md` (items 1 and 4 — those two lines only) · `.env.sepolia.example` (comment lines only) · `derivation/channel_test.go` (rename only) · `derivation/README.md` (test-name mention only, if one exists)

Do NOT touch: `tasks/decisions.md` (nothing here warrants an entry; propose `E-R09-<n>` in the handoff if you disagree), any other `.go` file, any other PRD, `scripts/`, `.github/`.

## Contract

- Branch `agent/r09-small-fixes` off the tag named in your dispatch message (`wave10-base`, or a later tag if R-04 merged first — confirm before branching). Commits: `chore(review): …`. Merged last in Wave 3.
- Checks before done (paste verbatim):
  - `cd derivation && go test ./... -run TestSepoliaGoldenReplay -v` → shows `matched=50 mismatched=0` and PASS
  - `cd derivation && go test ./...` → all green (proves the rename broke nothing)
  - `grep -rn "TestSepoliaGoldenSkipped" .` → only the untouched `tasks/decisions.md` D-H3-2 hit (and the review/prompt docs)
  - `grep -rn "l1_rpc_router" tasks/` → the corrected repo-qualified reference plus the untouched D-0018 line
  - `git diff .env.sepolia.example` → added lines all start with `#`, zero lines containing `=`
  - `grep -n "21:00" tasks/prd-mainnet-pilot.md` → empty
- No merging, no pushing to main, no tags.

## Handoff report — REQUIRED as your final chat message

1. Branch + base tag; `git diff --stat <base>..HEAD`
2. Allowlist compliance
3. Card success criteria + the integrator item — each: met, with evidence
4. Checks run + verbatim output (including both `go test` runs)
5. `decisions.md` entries (expect: none)
6. Anticipated conflicts with siblings (expect: none if run after R-04)
7. Operator actions needed (expect: none)
