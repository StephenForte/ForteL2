# Phase 4 spike notes — custom batcher

**Date:** 2026-07-24  
**PRD:** `tasks/prd-phase-4-batcher.md`  
**Code:** `batcher/`

## Specs consulted

- https://specs.optimism.io/protocol/batcher.html — minimal submit loop
- https://specs.optimism.io/protocol/derivation.html — batcher tx / frame / channel / batch encodings

## Wire format (calldata path)

```text
L1 tx.to = BatchInbox
L1 tx.from = SystemConfig batcher EOA
input = version_byte (0) ++ frame+

frame = channel_id(16) || frame_number(u16 BE) || frame_data_length(u32 BE) || frame_data || is_last(0|1)
channel bytes = zlib( rlp( concatenated singular-or-span batch encodings ) )   # pre-Fjord channel
```

Fjord adds a versioned channel encoding (possible brotli). Confirm against live `rollup.json` / fork schedule before US-041 compression work.

## Decisions (US-040)

| Question | Decision |
|---|---|
| Language | **Go** — matches OP Stack tooling; native on Apple Silicon |
| Repo layout | `batcher/` in ForteL2 (not a separate repo) |
| DA | **Calldata only** for v1 (matches `BATCHER_DA_TYPE=calldata`) |
| First batch type | **Singular batches** (version 0); span batches only if local submit fails fork checks |
| Sepolia | Decode against Sepolia history when `.env.sepolia` available; **submit** only after local US-042 |

## Done in this spike slice

- [x] Frame encode/decode + version-0 payload parse (`batcher/frame.go`)
- [x] Unit tests (`go test ./...`)
- [x] Read-only CLI `batcher/cmd/decode-l1` for one L1 tx
- [x] Operator: decode ≥1 real ForteL2 batcher tx (local Anvil L1 900) — frame summary below

## Operator follow-up (real decode) — ✅ 2026-07-24

Local Anvil stack. `cast tx` confirmed batcher → Batch Inbox; payload decoded (version 0, one frame).

```text
tx=0x97de57afb4a9c0528e3ea4002ac972468fa82a8cdd0d81a4af042e035bef01b3
from=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
to=0x00289C189bEE4E70334629f04Cd5eD602B6600eB
l1_chain_id=900
batcher_tx_version=0
frames=1
channel_ids=0x6184cc6618ec85c54b8b50ddc6d427dc
frame_number=0
data_len=294
is_last=true
notes=Decoded from cast tx input (supermini live stack). batcher/ CLI not yet on /Users/steveforte/ForteL2 until Phase 4 scaffold is committed/pushed and pulled.
```

## US-041 notes (done)

- Channel body on local ForteL2: **raw zlib** (header `78da`), not Fjord `version++compress`.
- Channel stream: `zlib( concat( rlp(typedBatchBytes)… ) )` where typedBatch = `0x00 ++ rlp(singular fields)`.
- Live fixture decompresses to **6** batches; first is singular (empty txs OK).
- Span batch encode **deferred** until US-042 proves singular-only is rejected.

## Next (US-042)

Submit loop on local Anvil with stock `op-batcher` stopped; watch safe head advance.  
