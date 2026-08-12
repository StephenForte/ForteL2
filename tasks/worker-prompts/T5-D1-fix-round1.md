# T5-D1-fix — Review round 1: chunked bodies, port preflight, batch edge cases

> **DISPATCH** · Model: Opus · Order: immediately, same branch `agent/t5-d1-narrow-rpc`, same PR #71
> Baseline: branch HEAD `4383473` · Gate: `bash -n` 46 · `test-helpers.sh` 92 + new · `--self-test` ok
> Host: **Mac mini only** — items 1 and 2 need the live filter and a real start-all run.
> Directory: operator's main checkout.

Five verified defects from review of #71. **Fix in severity order**; 1 and 2 are the ones that matter. All evidence below was reproduced by the reviewer — you should not have to re-derive it, but do confirm each before fixing.

Your original work was sound and the allowlist held under adversarial probing, including a duplicate-key parser-differential attempt. Items 3–5 are edge cases; item 1 was invisible without a raw-socket test and item 2 without reading the trap ordering.

## 1. BLOCKING — chunked request bodies are silently rejected

`do_POST` reads exactly `Content-Length` bytes. A request using `Transfer-Encoding: chunked` has no `Content-Length`, so `length` is 0, the body is empty, `json.loads("null")` yields `None`, and it is rejected as `-32600 invalid request`. Reproduced with a raw socket:

```
A  Content-Length + body          → {"result":"0xde14a"}                     ✅
B  Transfer-Encoding: chunked,    → {"error":{"code":-32600,
   byte-identical body                    "message":"invalid request"}}      ✗
```

**Why this is blocking:** cloudflared proxies to origin over HTTP/1.1 and emits chunked when the inbound body length is unknown — the normal case for an HTTP/2 client. Spike step 3 puts cloudflared directly in front of this proxy. If it chunks, *every* SOS call fails while the filter passes every local test, which is a brutal thing to debug at tunnel bring-up.

Fix: in `do_POST`, if the `Transfer-Encoding` header contains `chunked`, read the chunked body properly (size line, chunk, CRLF, until a 0-length chunk); otherwise use `Content-Length` as today. Reject bodies over a sane maximum rather than reading unbounded — an unbounded read on a public-facing path is its own problem. Do **not** simply return a clearer error; the path must work.

Tests: a chunked request with an allowed method succeeds and reaches upstream; a chunked request with a denied method is still rejected. Both are needed — a fix that reads chunked bodies but skips filtering them would be far worse than the bug.

## 2. Port preflight — `:9555` and distinctness (Cursor #2 Medium, Codex #4 P2)

Two findings, one fix.

`scripts/start-all-sepolia.sh:10` calls `assert_l2_ports_free`, which covers `L2_EL_HTTP_PORT`, `L2_EL_WS_PORT`, `L2_EL_AUTH_PORT`, `L2_NODE_RPC_PORT`, `BATCHER_RPC_PORT`, `PROPOSER_RPC_PORT` — **not** `L2_WRITE_RPC_PORT`. The ERR trap is armed at line 44, before `07-start-rpc-filter-sepolia.sh` at line 49. So a foreign process on `:9555` fails the filter start, fires `sepolia_start_cleanup`, and **tears down a sequencer that had just come up healthy.** This is the exact mid-start failure the preflight exists to prevent, and it is worse at the 03:00 launchd wake, where the whole stack fails to return.

Separately: if `L2_WRITE_RPC_PORT` is configured equal to `BATCHER_RPC_PORT` (8548) or `PROPOSER_RPC_PORT` (8560), the filter binds it first and the batcher or proposer then dies on its bind. The comment at `start-all-sepolia.sh:15` already records that these start scripts do not health-check, so **`start-all` reports a complete stack while the batcher is absent** — L2 keeps producing blocks and nothing reaches L1. That is the D-0027 failure mode.

Fix, **in `start-all-sepolia.sh`, after line 10 and before the trap at line 44**:
- fail closed if `L2_WRITE_RPC_PORT` is already bound, with the same message shape `assert_l2_ports_free` uses;
- fail closed if it equals any of the six ports that function already checks.

**`scripts/lib.sh` remains off-limits** (CODEOWNERS). Do not "fix this properly" by adding the port to `assert_l2_ports_free` — that is a separate operator-owned change. If you believe the check genuinely belongs in `lib.sh`, say so in the handoff and leave it in `start-all`.

## 3. Mixed-batch collapses upstream HTTP status to 200 (Codex #3 P2)

In `handle_jsonrpc_body`, the mixed-batch path discards `status` from each `_forward` and returns a literal `200`. The single-request path returns `_forward`'s status directly. So an upstream 429 or 5xx is visible on a single call and invisible inside a mixed batch, which contradicts the response-passthrough rule in the original prompt and can hide transient upstream failure from client retry logic.

Fix: propagate a non-2xx upstream status out of the mixed-batch path. If several elements fail with different statuses, pick the first non-2xx and say in a comment why. Test with a stub upstream returning 503.

## 4. Empty batch drops its error (Cursor #1 Low)

Verified: `[]` in, `[]` out, HTTP 200. `classify_body` returns `items=[]` with a one-element `rejects`, and `zip([], [err])` in the batch loop truncates to nothing, so the synthesized `-32600` never ships. Per JSON-RPC an empty array should return a single error object. Fails closed, so this is conformance, not security.

Fix it in `classify_body`/`handle_jsonrpc_body` so the reject actually reaches the client — and be careful the fix does not depend on `zip` length matching anywhere else.

## 5. Server banner leaks the runtime version

Responses carry `Server: BaseHTTP/0.6 Python/3.14.6`. Override `server_version` and `sys_version` on the handler. One line; this endpoint is about to be tunnel-facing.

## Not in scope

- Filter methods (`eth_newFilter` / `eth_getFilterChanges` / `getFilterLogs` / `uninstallFilter`) are currently rejected. That is an **operator decision** pending, not a defect — do not add them to the allowlist in this task.
- cloudflared, Access, `rail-interface.json` — still spike steps 3–4.
- Rate limiting — still edge, not proxy.
- Notification (`id`-less) response semantics — known minor deviation, deliberately left.

## Gate

Rebase onto current `main` at handoff. Then `bash -n` (46 scripts), `test-helpers.sh` (92 + your new cases), `--self-test`, `rail-interface-check.sh`.

Live on the mini, pasted into the handoff:
- chunked allowed method → succeeds; chunked denied method → rejected;
- `[]` → returns a `-32600` error object, not `[]`;
- a full `start-all-sepolia.sh` cold start still brings up all four processes;
- with a dummy process squatting `:9555`, `start-all` fails **before** starting the sequencer and leaves nothing running;
- the previously-verified deny cases (`admin_peers`, `debug_traceBlockByNumber`, `miner_start`, `txpool_status`) still return `-32601`.

Note: a filter instance from the previous round may still be running (pid 79016 at review time). Stop it before testing so you are not measuring stale code.

## Disagreement

If you think any of these five is wrong — particularly the chunked diagnosis, which rests on an assumption about cloudflared's behaviour rather than an observed tunnel — argue it with evidence rather than implementing around it.

## Hand back

Same format as before, plus one line per item 1–5 stating fixed / not-fixed and why.
