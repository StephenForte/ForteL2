# Phase 4 — custom batcher (learning)

Minimal OP Stack batch submitter rebuild. Specs:

- [Batch submitter overview](https://specs.optimism.io/protocol/batcher.html)
- [Derivation / wire format](https://specs.optimism.io/protocol/derivation.html) (batcher tx, frames, channel, batches)

**PRD:** [`tasks/prd-phase-4-batcher.md`](../tasks/prd-phase-4-batcher.md)

## Status

| Story | Status |
|---|---|
| US-040 frame decode + CLI | Done |
| US-041 singular batch + zlib channel + frame split | Done |
| US-042 local submit loop | Done (live: safe 16→22 on Anvil 901) |
| US-043 `USE_CUSTOM_BATCHER=1` local start | Done |
| US-044 Sepolia demo window (optional) | Documented (confirm gate; stock remains default) |
| US-045 learning write-up | Done — see spike notes |

**Channel encoding note (local ForteL2):** stock batches use **raw zlib** (no Fjord channel-version prefix). Span batches may appear on the wire; our builder emits **singular** batches first.

Stock `op-batcher` remains the **default** via `scripts/05-start-batcher*.sh`.

## Layout

```text
batcher/
  frame.go / singular.go / channel.go / l1info.go / block.go
  cmd/decode-l1/     # fetch one L1 tx and print frame metadata
  cmd/submit-loop/   # poll syncStatus → build → post to Batch Inbox
```

## Tests

```bash
cd batcher && go test ./...
```

## Decode a real L1 batcher tx

```bash
cd batcher
go run ./cmd/decode-l1 \
  -rpc "$L1_RPC_URL" \
  -tx 0x... \
  -inbox 0x...   # optional assert
```

Never paste private keys into this tool — it is read-only.

## US-043: local switch + kill switch

Default (unchanged):

```bash
./scripts/05-start-batcher.sh
```

Custom (learning demo):

```bash
USE_CUSTOM_BATCHER=1 ./scripts/05-start-batcher.sh
```

Builds `$BIN_DIR/fortel2-batcher` from `cmd/submit-loop` and starts it under the same `op-batcher` pid name so `./scripts/stop-all.sh` still works. No `lib.sh` `start_bg`/`stop_bg` edits. Refuses to start if that pid is already alive (avoids a false “started” while stock still holds the slot).

Kill switch back to stock:

```bash
kill "$(cat "$DATA_DIR/pids/op-batcher.pid")" && rm -f "$DATA_DIR/pids/op-batcher.pid"
./scripts/05-start-batcher.sh   # USE_CUSTOM_BATCHER unset/0
```

## US-042: one-shot submit (manual)

1. Start local Anvil stack (`./scripts/start-all.sh`), confirm chain **901**.
2. Stop stock batcher only:

```bash
kill "$(cat "$DATA_DIR/pids/op-batcher.pid")" && rm -f "$DATA_DIR/pids/op-batcher.pid"
```

3. One channel:

```bash
set -a && source .env && set +a
cd batcher
go run ./cmd/submit-loop \
  -l1 "$L1_RPC_URL" -l2 "$L2_RPC_URL" -rollup "$L2_NODE_RPC_URL" \
  -rollup-json "$DEPLOY_DIR/rollup.json" \
  -once -wait-safe=90s
```

**Duplicate safeguards:** in-memory `lastSubmitted` L2 number; never re-post `<= lastSubmitted`; on restart initialize from `safe` head.

**Recovery:** restart stock with `./scripts/05-start-batcher.sh`.

## US-044: Sepolia demo window (optional)

Only after local US-042 is green. Stock remains the default forever unless you explicitly confirm.

```bash
# 1) Stop stock Sepolia batcher only
kill "$(cat "$DATA_DIR/pids/op-batcher.pid")" && rm -f "$DATA_DIR/pids/op-batcher.pid"

# 2) Start custom (credit-budget poll default 12s; L1 confirmations default 2 like stock)
FORTEL2_ENV=.env.sepolia \
  USE_CUSTOM_BATCHER=1 CONFIRM_CUSTOM_BATCHER_SEPOLIA=1 \
  ./scripts/05-start-batcher-sepolia.sh
# submit-loop waits for SEPOLIA_BATCHER_NUM_CONFIRMATIONS before advancing lastSubmitted
# so a single receipt that later reorgs away is not treated as submitted.

# 3) Max ~15 minutes. Watch safe/unsafe via cast rpc optimism_syncStatus.

# 4) Revert immediately if anything looks wrong
kill "$(cat "$DATA_DIR/pids/op-batcher.pid")" && rm -f "$DATA_DIR/pids/op-batcher.pid"
FORTEL2_ENV=.env.sepolia ./scripts/05-start-batcher-sepolia.sh
```

- Replica keeps deriving from L1 calldata — no genesis pack / Phase 7 redeploy.
- If unsafe: abort, leave stock as default, fix locally before another attempt.

## Constraints

- Calldata DA only (no blobs) for Phase 4 v1
- No Sepolia redeploy
- Kill switch: unset `USE_CUSTOM_BATCHER` and run stock start scripts
