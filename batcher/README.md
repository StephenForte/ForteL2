# Phase 4 — custom batcher (learning)

Minimal OP Stack batch submitter rebuild. Specs:

- [Batch submitter overview](https://specs.optimism.io/protocol/batcher.html)
- [Derivation / wire format](https://specs.optimism.io/protocol/derivation.html) (batcher tx, frames, channel, batches)

**PRD:** [`tasks/prd-phase-4-batcher.md`](../tasks/prd-phase-4-batcher.md)

## Status

| Story | Status |
|---|---|
| US-040 frame decode + CLI | Done |
| US-041 singular batch + zlib channel + frame split | Done (unit tests + live local fixture) |
| US-042 local submit loop | **Done** (live: safe 16→22 on Anvil 901) |
| US-043+ script switch / Sepolia demo | Not started |

**Channel encoding note (local ForteL2):** stock batches use **raw zlib** (no Fjord channel-version prefix). Span batches may appear on the wire; our builder emits **singular** batches first.

Stock `op-batcher` remains the default via `scripts/05-start-batcher*.sh`. Do not stop Sepolia stock batcher until US-042 is green on local Anvil.

## Layout

```text
batcher/
  frame.go / singular.go / channel.go / l1info.go / block.go
  cmd/decode-l1/     # fetch one L1 tx and print frame metadata
  cmd/submit-loop/   # US-042: poll syncStatus → build → post to Batch Inbox
```

## Tests

```bash
cd batcher && go test ./...
```

## Decode a real L1 batcher tx

With the local or Sepolia stack up, find a tx from the batcher EOA to the Batch Inbox (`rollup.json` → `batch_inbox_address`), then:

```bash
cd batcher
go run ./cmd/decode-l1 \
  -rpc "$L1_RPC_URL" \
  -tx 0x... \
  -inbox 0x...   # optional assert
```

Never paste private keys into this tool — it is read-only.

## US-042: local submit (stock batcher stopped)

1. Start local Anvil stack (`./scripts/start-all.sh`), confirm chain **901**.
2. Stop stock batcher only (keep sequencer/proposer):

```bash
kill "$(cat "$DATA_DIR/pids/op-batcher.pid")" && rm -f "$DATA_DIR/pids/op-batcher.pid"
```
3. Run one channel:

```bash
set -a && source .env && set +a
cd batcher
go run ./cmd/submit-loop \
  -l1 "$L1_RPC_URL" -l2 "$L2_RPC_URL" -rollup "$L2_NODE_RPC_URL" \
  -rollup-json "$DEPLOY_DIR/rollup.json" \
  -once -wait-safe=90s
```

Key comes from `BATCHER_PRIVATE_KEY` in `.env` (Foundry throwaway on chain 901 only).

**Duplicate safeguards:** in-memory `lastSubmitted` L2 number; never re-post `<= lastSubmitted`; on restart initialize from `safe` head so already-derived blocks are skipped.

**Recovery:** if the custom batcher misbehaves, stop it and restart stock with `./scripts/05-start-batcher.sh`. Safe head should resume once valid channels land on L1.

## Constraints

- Calldata DA only (no blobs) for Phase 4 v1
- No Sepolia redeploy
- Kill switch: stock `op-batcher` scripts unchanged
