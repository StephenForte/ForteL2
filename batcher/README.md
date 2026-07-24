# Phase 4 — custom batcher (learning)

Minimal OP Stack batch submitter rebuild. Specs:

- [Batch submitter overview](https://specs.optimism.io/protocol/batcher.html)
- [Derivation / wire format](https://specs.optimism.io/protocol/derivation.html) (batcher tx, frames, channel, batches)

**PRD:** [`tasks/prd-phase-4-batcher.md`](../tasks/prd-phase-4-batcher.md)

## Status

| Story | Status |
|---|---|
| US-040 frame decode + CLI | In progress (unit tests + `decode-l1`) |
| US-041+ channel build / submit | Not started |

Stock `op-batcher` remains the default via `scripts/05-start-batcher*.sh`. Do not stop Sepolia stock batcher until US-042 is green on local Anvil.

## Layout

```text
batcher/
  frame.go          # version-0 batcher tx + frame encode/decode
  cmd/decode-l1/    # fetch one L1 tx and print frame metadata
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

## Constraints

- Calldata DA only (no blobs) for Phase 4 v1
- No Sepolia redeploy
- Kill switch: stock `op-batcher` scripts unchanged
