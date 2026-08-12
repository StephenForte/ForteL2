# T5-D1 — Narrow the Sepolia sequencer write-facing RPC to `eth,net,web3`

> **DISPATCH** · Model: Opus (security boundary; a silently-permissive filter is the failure mode) · Order: wave 1, alone — MR-2 may run in parallel (different repo)
> Baseline `main`: `264bb4a` · Expected gate: `bash -n` 45 scripts clean · `test-helpers.sh` 88 PASS + new cases · `rail-interface-check.sh` pass
> Host: **Mac mini only** — the filter must be exercised against the live sequencer on `127.0.0.1:9545`. An agent elsewhere can write the code but cannot verify it; hand back as `blocked` rather than claiming a green gate.
> Merge: closes D1 in `tasks/spike-t5-write-path.md` §4 step 1, and unblocks the US-012 GO recorded in README.
> Directory: operator's main checkout, `/Users/steveforte/ForteL2`.

## 1. Read first

- `tasks/spike-t5-write-path.md` §1 (D1) and §4 — the sequenced plan and its invariant.
- README → "US-012 non-loopback go/no-go — Sepolia sequencer write path (2026-08-11)".
- `tasks/decisions.md` D-0030 (this decision), D-0027 (external funder), D-0016 (replica).
- `.github/CODEOWNERS`.

**Read current `main` before trusting any status claim in this prompt, including mine.** If what you find contradicts what's written here, say so — that is a finding, not an obstacle.

## 2. Branch

`agent/t5-d1-narrow-rpc`, branched from `264bb4a` on `main`.

## 3. Why this exists

`scripts/04-start-sequencer-sepolia.sh:41` currently starts op-geth with:

```
--http.addr=127.0.0.1 --http.port=${L2_EL_HTTP_PORT}   # 9545
--http.vhosts="*" --http.corsdomain="*"
--http.api=eth,net,web3,debug,txpool,admin,miner
```

That is safe today because nothing off-box can reach port 9545. US-012 has now **gone** for an authenticated Cloudflare tunnel to this host, and the invariant in the spike is absolute: **narrow first, tunnel second, never the reverse.** Publishing a URL in front of `admin_*` / `miner_*` / `debug_*` with DNS-rebinding protection disabled (`vhosts=*`) is a critical exposure, not a hardening nit.

## 4. What to build

**A method-filtering JSON-RPC proxy on the mini**, listening on loopback, forwarding to `127.0.0.1:${L2_EL_HTTP_PORT}`, and serving **only** `eth`, `net`, `web3` methods. `cloudflared` will later dial the proxy — never op-geth directly.

### The trap — read this twice

**op-geth cannot run a second HTTP listener.** There is one `--http` server per process; there is no `--http2` and no per-port namespace flag. The spike's phrase "second op-geth HTTP listener **or** a filtering proxy" reads like two options and is really one. Do **not**:

- try to start a second op-geth against the same datadir (datadir lock; corruption risk);
- narrow the existing `--http.api` globally instead — that silently removes `debug`/`txpool`/`admin` from operator tooling that depends on it, which is a different decision than the one that was approved;
- assume `--ws.api` can carry the narrow surface — SOS speaks HTTP JSON-RPC.

The existing loopback listener on 9545 **stays exactly as it is**, full namespaces, for operator tooling. You are adding a second, narrower door — not remodelling the first.

### Filter semantics — allowlist, never denylist

Reject by default. A denylist ("block `admin_*`, `debug_*`, `miner_*`") is the predictable wrong answer and it fails open on every namespace anyone adds later. Match the exact method string against an explicit allowlist and reject everything else with a JSON-RPC error.

Specific hazards, each of which has bitten someone:

- **Batch requests.** JSON-RPC allows an array of calls in one body. A filter that inspects `body.method` sees `undefined` on a batch and, depending on how you wrote the check, either rejects everything or **passes the whole batch through unfiltered**. Every element must be checked independently.
- **Prefix matching.** `startsWith("eth_")` is not an allowlist. Check full method names.
- **Case and whitespace.** Do not normalise creatively; compare exactly, reject anything that does not match.
- **Response passthrough.** Forward upstream errors as-is. Do not invent 200-OK wrappers around failures — SOS needs real JSON-RPC errors to retry correctly.

There is a working precedent for this shape in the sibling repo: `l1_rpc_router.py` in `StephenForte/fortel2-replica`. Read it before inventing a structure. Match the house style rather than introducing a new runtime or dependency if you can avoid it.

### What must not change

- **`scripts/lib.sh` is off-limits** (CODEOWNERS `@StephenForte`). The proxy dials loopback, so `L2_RPC_URL` stays loopback and `assert_l2_loopback_urls` / `assert_sepolia_rpc_urls` / `require_sepolia_env` keep passing untouched. **If you find yourself needing to change `lib.sh`, stop and report rather than widening scope** — needing it means the design drifted.
- Do not bind op-geth off `127.0.0.1`. Do not touch `--authrpc.*`.
- Do not publish, start, or configure `cloudflared`. That is step 3 of the spike's plan and is **not** in this task. Shipping a tunnel here would violate the sequencing invariant.
- Do not edit `deployments/rail-interface.json`. No URL is published by this task.
- Do not remove op-node's `--rpc.enable-admin` — it is loopback-only and out of scope; flag it if you disagree.
- **Do not weaken existing tests.** If one must change because it encoded old behaviour, call it out in the handoff with reasoning.

## 5. File scope

**Owned**
- `scripts/` — the new proxy script/entry and its start/stop wiring (name it consistently with the existing `NN-start-*.sh` convention; pick the next free number and say which you chose).
- `scripts/test-helpers.sh` — new cases (append).
- `.env.sepolia.example` — the new port variable, documented, defaulted.

**Shared, additive only** (append, do not restructure; list every one in the handoff)
- `README.md` — an ops note on starting/stopping the filter and which port is which.
- `tasks/spike-t5-write-path.md` — mark §4 step 1 done.

**Off-limits**
- `scripts/lib.sh` — CODEOWNERS.
- `deployments/` — no published URL from this task.
- `tasks/decisions.md` — the integrator appends decisions, not workers.

## 6. Out of scope, with reasons

- Cloudflare tunnel setup — spike step 3, gated on operator sign-off after this lands.
- Rate limiting — belongs at the Cloudflare edge, not in this proxy.
- Auth — Access sits in front; the proxy is a method filter, not an authenticator. Do not add bearer-token logic.
- The replica's namespaces — same problem, different repo, dispatched separately as MR-2.

## 7. Gate — run after rebasing onto current `main` at handoff time

```bash
git fetch origin && git rebase origin/main
for f in scripts/*.sh; do bash -n "$f" || echo "SYNTAX FAIL $f"; done
bash scripts/test-helpers.sh
bash scripts/rail-interface-check.sh
```

Expected: 45 scripts syntax-clean (plus any you add), `test-helpers.sh` **88 PASS plus your new cases**, `rail-interface-check.sh` pass. **Unexplained movement in those counts is itself a finding** — report it rather than adjusting the expectation.

Live verification on the mini, with output pasted into the handoff:

- Against the filter port: `eth_blockNumber`, `eth_chainId`, `net_version`, `web3_clientVersion` all succeed.
- Against the filter port: `admin_peers`, `debug_traceBlockByNumber`, `miner_start`, `txpool_status` are all **rejected**.
- A **batch** body mixing `eth_blockNumber` with `admin_peers` — the `admin_peers` element must be rejected. Show the actual response.
- Against 9545 directly: the full namespace still works, i.e. operator tooling is unbroken.

## 8. Tests that matter

Assert the *property*, not the implementation:

- a method outside the allowlist is rejected **even if its namespace prefix is allowed**;
- a batch containing one disallowed method does not pass that method through;
- a newly-invented method name (`foo_bar`) is rejected by default, proving allowlist rather than denylist semantics;
- the filter listener is bound to loopback.

No new test harness — extend `scripts/test-helpers.sh`. Where a case can only be checked against a live node, say so and hand-verify it, disclosing exactly what you ran.

## 9. Disagreement

**If you think this is the wrong approach, say so and argue it rather than implementing it half-heartedly.** In particular: if you conclude a filtering proxy is the wrong mechanism, or that op-geth can in fact do this natively in the version pinned here, that is worth more than a completed task built on a false premise. Bring evidence.

## 10. Hand back

```
TASK:        T5-D1 — narrow sequencer write-facing RPC to eth,net,web3
BRANCH:      agent/t5-d1-narrow-rpc
PR:          <url>
STATUS:      complete | complete-with-caveats | blocked

GATE:        bash -n ✅   test-helpers <N> passed   rail-interface-check ✅
MIGRATION:   none

SHARED FILES TOUCHED:
  <path> — what changed, and why it is additive

CONTRACTS PUBLISHED / CHANGED:
  none  (this task publishes no URL)

EXISTING TESTS MODIFIED:
  <path> — <old> → <new>; why this is a strengthening
  (or: none)

DECISIONS NEEDED FROM OPERATOR:
  none | <question, and what you did meanwhile>

RISKS AND FOLLOW-UPS:
  What this does NOT cover. What was hand-verified vs automated. Residual risk
  stated plainly.
```
