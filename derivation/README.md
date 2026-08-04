# derivation — Phase 6 derivation verifier (US-061)

Minimal OP Stack derivation **verifier**: reads L1 batch inbox txs and Portal deposits, derives L2 payload attributes for a bounded window, seals block hashes via a **separate** loopback `op-geth` (Engine API), and diffs against the reference stack.

**Spec:** [Derivation pipeline](https://specs.optimism.io/protocol/derivation.html) · **PRD:** `tasks/prd-phase-6-derivation.md` · **Spike:** `tasks/spike-phase-6-derivation.md`

## What this implements

| Stage | Package files | Notes |
|---|---|---|
| L1 batch inbox scan | `l1.go` | Filter txs to inbox from authorized batcher |
| Frames → channel → batches | `l1.go` | Imports `batcher` decode helpers (`ParseBatcherTxPayload`, zlib, singular `0x00`) |
| Span batches (`0x01`) | `span.go`, `span_bits.go`, `span_txs.go` | Required decoder; local history is singular-only |
| Portal deposits | `deposit.go`, `deposit_tx.go` | User deposit inclusion on L1-origin change |
| L1-info deposit | `l1info.go` | Bedrock → Jovian calldata variants |
| Payload attributes | `attrs.go`, `rollup.go` | Fork-aware attrs from rollup config |
| Engine API sealing | `engine.go` | Separate EL only — never the reference stack |
| Hash diff | `verify.go`, `cmd/verify/` | `derivedHash == eth_getBlockByNumber(n).hash` (D-T2-3) |

## Runbook

Reference stack must be running (`./scripts/start-all.sh` or Sepolia equivalent).

```bash
./scripts/derivation-check.sh                    # local 901, blocks 1–20
./scripts/derivation-check.sh --start-l2 1 --end-l2 20
./scripts/derivation-check.sh --channel-tx 0x…   # single L1 batcher tx window
FORTEL2_ENV=.env.sepolia ./scripts/derivation-check.sh --sepolia
```

**Pass:** every block in the window prints `OK`; exit 0; summary `derivation-check: PASS`.

**Fail:** first hash mismatch or RPC/derivation error; exit 1; stderr shows expected vs derived hash.

**Kill switch:** do not run `derivation-check.sh` — stock `op-node` derivation is unchanged.

### Separate sealing EL (D-R1-1)

The runbook starts its own `op-geth` under `$DATA_DIR/l2/derivation-op-geth` with dedicated ports (`DERIV_EL_HTTP_PORT=19645`, `DERIV_EL_AUTH_PORT=19651`, P2P `--port=30323`) and JWT (`$DATA_DIR/jwt/derivation-jwt.txt`). The reference `op-geth` / `op-node` are **read-only** oracles (`eth_getBlockByNumber`, `optimism_syncStatus`).

## CLI

```bash
cd derivation
go run ./cmd/verify \
  -rollup "$DEPLOY_DIR/rollup.json" \
  -l1 "$L1_RPC_URL" \
  -ref-l2 "$L2_RPC_URL" \
  -ref-node "$L2_NODE_RPC_URL" \
  -seal-auth http://127.0.0.1:19651 \
  -seal-http http://127.0.0.1:19645 \
  -jwt "$DATA_DIR/jwt/derivation-jwt.txt" \
  -start-l2 1 -end-l2 20
```

## Tests

```bash
cd derivation && go test ./...
```

Fixtures: `testdata/local901/batcher_tx.hex` (15 singular batches from local 901). Sepolia golden slot: `testdata/sepolia/window.json` (load-if-present; skipped until operator capture).

## Module wiring

```go
require github.com/StephenForte/ForteL2/batcher v0.0.0
replace github.com/StephenForte/ForteL2/batcher => ../batcher
```

Do **not** edit `batcher/*.go`; import decode helpers only.
