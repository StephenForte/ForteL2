# MR-2 — Public read path: filter, then expose `fortel2-replica`

> ⛔ **DO NOT DISPATCH YET.** This task vendors `scripts/rpc-method-filter.py` from ForteL2 and must copy the **post-round-1** version, which does not exist until PR #71 merges. #71 was OPEN with changes requested when this was written. Dispatching before it merges vendors a copy with a known blocking defect (chunked bodies). Check #71 is merged first.
>
> **DISPATCH** · Model: Opus (public exposure of an RPC; the failure mode is silent) · Order: **after** T5-D1 merges — no longer parallel with it
> Baseline: `StephenForte/fortel2-replica` @ `main` (read current HEAD)
> Host: any — the Render deploy is verified through the dashboard and Web Shell, not the Mac mini.
> Merge: closes the D8 read-path gap and gives `rail-interface.json` its first real `replica.readRpcUrl` since D-0016.
> **Repo: `StephenForte/fortel2-replica`, not the ForteL2 monorepo.** Clone it separately.

## 1. Read first

- `ForteL2/replica/README.md` — the pack/sync-check bridge and D-0016's access constraints.
- `ForteL2/tasks/decisions.md` D-0016 (private service, no reachable URL, no inbound SSH) and D-0030 (this decision).
- `ForteL2/scripts/rpc-method-filter.py` — the thing you are vendoring, **at merged `main`, not at PR #71's first commit**.
- In the replica repo: `entrypoint.sh`, `Dockerfile`, `render.yaml`, `l1_rpc_router.py`.

**Read current `main` in both repos before trusting any status claim in this prompt, including mine.**

## 2. Why this exists — three verified facts

**The replica serves `debug` today.** `entrypoint.sh:163`:

```
--http --http.addr=0.0.0.0 --http.port="$L2_HTTP_PORT"
--http.api=eth,net,web3,debug,txpool
--http.vhosts=* --http.corsdomain=*
```

Acceptable while private. The moment a public URL exists, `debug_traceTransaction` and `debug_traceBlockByNumber` against a ~908,000-block chain are free to anyone who finds it — an unauthenticated, unmetered CPU and disk sink.

**Namespace narrowing alone cannot make this endpoint read-only, and the failure is silent.** `eth_sendRawTransaction` is in the `eth` namespace, so `--http.api=eth,net,web3` still exposes it. The replica runs `--nodiscover --maxpeers=0` and `--rollup.disabletxpoolgossip=true`, and does **not** set `--rollup.sequencerhttp`. So a submitted transaction is validated against replica state, accepted into a txpool with zero peers and no gossip, and **a transaction hash is returned to the caller** — for a transaction that can never be mined anywhere. The caller sees success and waits forever. Render's edge routes HTTP and does not inspect JSON-RPC bodies, so there is no edge rule that closes this. A method filter is the only mechanism. That is why this task now vendors one instead of editing one flag.

**The replica is ~3 minutes behind and always will be.** Measured 2026-08-11: replica head 908,436 against sequencer 908,530 — 94 blocks, ~188s — corroborated by the node's own `age=3m20s` log field. It derives from L1 batches (`decoded singular batch from channel`) rather than following the sequencer, so its latency floor is batcher cadence, not block time. **This is correct verifier behaviour and must not be "fixed" in this task.**

## 3. What to build

1. **Vendor the method filter.** Copy `rpc-method-filter.py` from ForteL2 `main` **after PR #71 merges**. Mark it clearly at the top as vendored, with the source path and the commit SHA you copied from. It must include round 1's chunked-body fix — Render's edge may well chunk, so a copy taken before that fix would fail exactly the same way in front of the replica.
2. **Read-only allowlist.** Take T5-D1's final `ALLOWED_METHODS` and **remove `eth_sendRawTransaction`**. Everything else carries over, including the `eth_*Filter` methods — event watching over HTTP belongs on the read endpoint. Do not hand-retype the list; derive it from the vendored file so the two cannot drift silently.
3. **Rewire the ports.** geth moves off the Render-published port to a container-internal one and binds `127.0.0.1`, so only the filter can reach it. The filter binds the published port. Verify from `render.yaml` and `entrypoint.sh` which port Render actually publishes rather than trusting this prompt — at the time of writing that is **10000** for the EL. Port **9545 is op-node**, the control plane, and must **never** be publicly reachable.
4. **Drop `debug` and `txpool`** from geth's `--http.api` as defence in depth, so the surface is narrow even if the filter is bypassed or misconfigured.
5. **Convert the Render service** from private to public, whichever way `render.yaml` supports most simply. Keep it reversible and state the exact revert steps in the handoff.
6. **Rate limiting at the edge** — whatever Render offers natively. If Render offers nothing usable, **say so plainly rather than inventing an in-process limiter.** That is an operator decision, not yours.
7. **Document** the endpoint: URL, read-only, ~3 minutes behind, writes rejected, and the nightly **23:45–03:00** `America/Los_Angeles` sequencer window. The replica may keep serving stale reads through that window — state what actually happens, do not guess.

### Traps

**The vendored copy will drift.** Two copies of a security filter in two repos is a real maintenance hazard, and the fix for a future bug will land in one of them. Record the duplication explicitly: a header comment in the vendored file naming its origin and SHA, and a line in the replica README saying fixes must be applied in both. If you see a clean way to avoid the duplication that does not add a package-publishing step, propose it in the handoff rather than implementing it unilaterally.

**Filters die on every restart.** The `eth_*Filter` methods are per-node in-memory state with an idle timeout. Every Render deploy or container restart invalidates every filter ID a client holds. Document that consumers must re-create on filter-not-found and must not treat it as an outage — same note the sequencer side is getting.

**Do not add `eth_newPendingTransactionFilter`.** It exposes mempool contents. Excluded deliberately on both sides.

### What must not change

- Do **not** switch the replica to P2P-follow mode to reduce the lag. Separate decision, trades away verifier independence, explicitly out of scope.
- Do not touch genesis, `rollup.json`, or anything under `config/` — operator-packed by `pack-replica-artifacts.sh` in ForteL2.
- Do not expose op-node or the Engine API under any circumstances.
- Do not set `--rollup.sequencerhttp`. It would turn the public read endpoint into a write path to the sequencer, which is the opposite of this task.
- Do not weaken existing tests or healthchecks. `healthcheck.sh` and the geth-recovery patch exist for documented reasons (`ForteL2/replica/patches/`); if one must change, justify it in the handoff.

## 4. File scope

**Owned** (in `fortel2-replica`)
- `entrypoint.sh` — namespace narrowing, port rewiring, filter startup.
- `render.yaml` — service type and port configuration.
- the vendored filter file.
- `README.md` / `RUNNING.md` — endpoint documentation.

**Shared, additive only**
- `tests/` — append cases; do not restructure.

**Off-limits**
- `config/` — operator-packed artifacts.
- The **ForteL2 monorepo entirely.** `rail-interface.json` gets its `replica.readRpcUrl` from the integrator after this lands and the URL exists — not from this task. **If you find yourself needing to change something in ForteL2, stop and report rather than widening scope.**

## 5. Out of scope, with reasons

- The sequencer write path — T5-D1, already merged by the time you start.
- Cloudflare — the replica sits behind Render's edge, not a tunnel. Do not introduce one.
- Publishing the URL in `rail-interface.json` — integrator step; needs a version bump and an SOS-facing note.
- Fixing the 3-minute lag — see above.

## 6. Gate

Run the repo's own suite at handoff time (read the Makefile and use what is actually there), rebased onto current `main`. State the counts; unexplained movement is a finding.

Live verification against the deployed service, pasted into the handoff:

- `eth_blockNumber`, `eth_chainId`, `net_version` succeed on the public URL.
- `debug_traceBlockByNumber` and `txpool_status` are **rejected**.
- **`eth_sendRawTransaction` is rejected** — show the actual response. This is the headline check for this task.
- A batch mixing an allowed and a disallowed method rejects only the disallowed element.
- A **chunked** request with an allowed method succeeds — proving you vendored the fixed filter.
- `eth_newFilter` succeeds and `eth_newPendingTransactionFilter` is rejected.
- op-node's port is **not** reachable from outside. Show how you established this.
- geth's own port is **not** reachable from outside; only the filter is.
- The replica is still syncing after the change: head advancing, and state the observed lag against the sequencer.

Per D-0016 the image has no `curl` — use the Render **Web Shell** with `python3`/`urllib`, as `replica/README.md` documents.

## 7. Disagreement

**If you think this is the wrong approach, say so and argue it rather than implementing it half-heartedly.** Specifically: if you conclude the replica should not be public at all until the lag story or the rate-limiting story is better, the operator wants to hear that *before* the URL exists, not after.

## 8. Hand back

```
TASK:        MR-2 — public read path via fortel2-replica
BRANCH:      <branch>
PR:          <url>
STATUS:      complete | complete-with-caveats | blocked

VENDORED:    rpc-method-filter.py from ForteL2 <sha> — includes chunked fix: yes/no
GATE:        <suite> <N> passed
             live: reads ✅  debug denied ✅  sendRawTransaction denied ✅
                   chunked ✅  batch ✅  op-node unreachable ✅  geth unreachable ✅
PUBLIC URL:  <the URL, or: not exposed and why>
REVERT:      <exact steps to make the service private again>

SHARED FILES TOUCHED:
  <path> — what changed, why additive

EXISTING TESTS MODIFIED:
  <path> — <old> → <new>; why this is a strengthening
  (or: none)

DECISIONS NEEDED FROM OPERATOR:
  none | <question, and what you did meanwhile>

RISKS AND FOLLOW-UPS:
  What rate limiting exists, if any. Observed lag. How the vendored-copy
  drift risk is recorded. What was hand-verified vs automated.
```
