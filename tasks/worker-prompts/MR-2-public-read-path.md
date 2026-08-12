# MR-2 — Public read path: narrow, then expose `fortel2-replica`

> **DISPATCH** · Model: Opus (public exposure of an RPC; the failure mode is silent) · Order: wave 1, parallel with T5-D1 — **different repo, no file overlap**
> Baseline: `StephenForte/fortel2-replica` @ `main` (read current HEAD; this prompt was written against ForteL2 `264bb4a`)
> Host: any — Render deploy is verified through the dashboard/Web Shell, not the Mac mini.
> Merge: closes the D8 read-path gap and gives `rail-interface.json` a real `replica.readRpcUrl` for the first time since D-0016.
> **Repo: `StephenForte/fortel2-replica`, not the ForteL2 monorepo.** Clone it separately.

## 1. Read first

- `ForteL2/replica/README.md` — the pack/sync-check bridge and the D-0016 access constraints.
- `ForteL2/tasks/decisions.md` D-0016 (private service, no reachable URL, no inbound SSH) and D-0030 (this decision).
- In the replica repo: `entrypoint.sh`, `Dockerfile`, `render.yaml`, `l1_rpc_router.py`.

**Read current `main` in both repos before trusting any status claim in this prompt, including mine.**

## 2. Why this exists

Two facts, both verified 2026-08-11.

**The replica serves `debug` today.** `entrypoint.sh:163`:

```
--http --http.addr=0.0.0.0 --http.port="$L2_HTTP_PORT"
--http.api=eth,net,web3,debug,txpool
--http.vhosts=* --http.corsdomain=*
```

That is acceptable while the service is private. The moment a public URL exists, `debug_traceTransaction` and `debug_traceBlockByNumber` against a ~908,000-block chain are free to anyone who finds it — an unauthenticated, unmetered CPU and disk sink. This is the whole reason narrowing precedes exposure.

**The replica is ~3 minutes behind and always will be.** Measured: replica head 908,436 while the sequencer was at 908,530 — 94 blocks, ~188s — corroborated by the node's own `age=3m20s` log field. It derives from L1 batches (`decoded singular batch from channel`) rather than following the sequencer, so its latency floor is batcher cadence, not block time. **This is correct behaviour for a verifier and must not be "fixed" as part of this task.** It does mean the public endpoint cannot serve read-your-own-write, which the documentation must say plainly.

## 3. What to build

1. **Narrow** `--http.api` to `eth,net,web3`. Same allowlist discipline as the sequencer: remove `debug` and `txpool`.
2. **Expose the EL only.** Port **10000** is the EL RPC and is the port Render publishes. Port **9545 is op-node** — the control plane — and must **never** be publicly reachable. Verify which port your change actually exposes rather than trusting this prompt; `entrypoint.sh` and `render.yaml` are the authority.
3. **Convert the Render service** from private to a public web service, or front it — whichever the repo's `render.yaml` supports most simply. Keep the change reversible and say in the handoff exactly how to revert it.
4. **Rate limiting at the edge.** Whatever Render offers natively. If Render offers nothing usable, say so plainly rather than inventing an in-process limiter — that is an operator decision, not yours.
5. **Document** the endpoint: URL, that it is read-only, that it is ~3 minutes behind, that writes are not accepted, and the nightly **23:45–03:00** `America/Los_Angeles` sequencer window (the replica may keep serving stale reads through it — state what actually happens, do not guess).

### The trap

A replica **must never accept writes.** `eth_sendRawTransaction` lives in the `eth` namespace, so an `eth,net,web3` allowlist **still exposes it**. Narrowing namespaces does not close the write path. Decide deliberately how `eth_sendRawTransaction` is handled — rejecting it at the edge is the safe answer — and state what you did. A replica that silently accepts and drops transactions is worse than one that rejects them loudly: the sender believes the transaction is pending.

Related: `eth_call` and `eth_estimateGas` are legitimate reads but can be expensive. Note them as a rate-limiting consideration; do not block them.

### What must not change

- Do **not** switch the replica to P2P-follow mode to reduce the lag. That is a separate decision that trades away verifier independence; it is explicitly out of scope.
- Do not touch genesis, `rollup.json`, or anything under `config/` — those come from `pack-replica-artifacts.sh` in ForteL2 and are operator-owned.
- Do not expose op-node (9545) or the Engine API under any circumstances.
- Do not weaken existing tests or healthchecks. `healthcheck.sh` and the geth-recovery patch exist for reasons documented in `ForteL2/replica/patches/`; if one must change, justify it in the handoff.

## 4. File scope

**Owned** (in `fortel2-replica`)
- `entrypoint.sh` — the `--http.api` change and any port/exposure wiring.
- `render.yaml` — service type / port configuration.
- `README.md` / `RUNNING.md` — the endpoint documentation.

**Shared, additive only**
- `tests/` — append cases; do not restructure.

**Off-limits**
- `config/` — operator-packed artifacts.
- The **ForteL2 monorepo entirely.** `rail-interface.json` gets its `replica.readRpcUrl` from the integrator after this lands and the URL is known — not from this task. **If you find yourself needing to change something in ForteL2, stop and report rather than widening scope.**

## 5. Out of scope, with reasons

- The sequencer write path — that is T5-D1 in the other repo, running in parallel.
- Cloudflare — the replica sits behind Render's edge, not a tunnel. Do not introduce one.
- Publishing the URL in `rail-interface.json` — integrator step, needs a version bump and an SOS-facing note.
- Fixing the 3-minute lag — see above.

## 6. Gate

Run the repo's own suite (`make test` / `tests/` — read the Makefile and use what is actually there) at handoff time, rebased onto current `main`. State the counts; unexplained movement is a finding.

Live verification against the deployed service, with output pasted into the handoff:

- `eth_blockNumber`, `eth_chainId`, `net_version` succeed on the public URL.
- `debug_traceBlockByNumber` and `txpool_status` are **rejected**.
- A batch mixing an allowed and a disallowed method rejects the disallowed element.
- `eth_sendRawTransaction` behaves as you designed — show the actual response.
- op-node's port is **not** reachable from outside. Show how you established this.
- The replica is still syncing after the change: chain head advancing, and state the observed lag versus the sequencer.

Per D-0016 the image has no `curl` — use the Render **Web Shell** with `python3`/`urllib`, as `replica/README.md` documents.

## 7. Disagreement

**If you think this is the wrong approach, say so and argue it rather than implementing it half-heartedly.** Specifically: if you conclude the replica should not be public at all until the lag or the write-rejection story is better, that is a legitimate finding and the operator wants to hear it before the URL exists, not after.

## 8. Hand back

```
TASK:        MR-2 — public read path via fortel2-replica
BRANCH:      <branch>
PR:          <url>
STATUS:      complete | complete-with-caveats | blocked

GATE:        <suite> <N> passed
             live: allowed ✅  denied ✅  batch ✅  op-node unreachable ✅
MIGRATION:   none

PUBLIC URL:  <the URL, or: not yet exposed and why>
REVERT:      <exact steps to make the service private again>

SHARED FILES TOUCHED:
  <path> — what changed, why additive

EXISTING TESTS MODIFIED:
  <path> — <old> → <new>; why this is a strengthening
  (or: none)

DECISIONS NEEDED FROM OPERATOR:
  none | <question, and what you did meanwhile>

RISKS AND FOLLOW-UPS:
  How eth_sendRawTransaction is handled. What rate limiting exists, if any.
  Observed lag. What was hand-verified vs automated.
```
