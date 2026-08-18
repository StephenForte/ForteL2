# Phase 3b — Friend-operated verifier runbook

Hand this file to a friend (or a VPS you rent for them). They run a **stock verifier** for ForteL2 chain **852**. They do **not** run the sequencer, batcher, proposer, or hold operator keys.

Runtime lives in a separate repo: **https://github.com/StephenForte/fortel2-replica**  
Full laptop/VPS walkthrough there: [`RUNNING.md`](https://github.com/StephenForte/fortel2-replica/blob/main/RUNNING.md)

Recruiting two geographically distributed operators is **operator-owned**. This file is the onboarding artifact; it does not itself stand up those nodes.

## What you are running

| You run | You do not run |
|---|---|
| `op-geth` + `op-node` in **verifier** mode | Sequencer, batcher, proposer |
| Derivation from **Ethereum Sepolia L1** | Anything that needs a ForteL2 private key |
| Optional local RPC on your loopback | A public unauthenticated JSON-RPC (unless you later choose to) |

Docker is **fine on your machine**. The “no containers” rule is only for the operator Mac mini.

## Requirements

- Docker Compose and about **2 GB RAM** (512 MB OOMs)
- Your own Sepolia **L1** RPC URL (public endpoint is OK for a smoke; a dedicated provider if you leave it up)
- Disk for the L2 datadir (tens of GB over time; Render’s live replica uses 50 GB)
- Ability to wipe and resync when the operator announces a **redeploy gate** (Phase 7)

## Quick start

```bash
git clone https://github.com/StephenForte/fortel2-replica.git
cd fortel2-replica
cp .env.example .env
# .env ships a public Sepolia URL for smoke tests. Replace L1_RPC_URL
# with your own provider if this will stay up.
openssl rand -hex 32 > jwt.txt && chmod 600 jwt.txt
docker compose up -d
```

- L2 execution RPC: `http://127.0.0.1:9545`
- op-node RPC: `http://127.0.0.1:9547`

```bash
curl -s http://127.0.0.1:9545 -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}'
# → {"result":"0x354"}  (852)

curl -s http://127.0.0.1:9547 -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"optimism_syncStatus","params":[]}'
```

`current_l1` should climb toward `head_l1`. `safe_l2` staying `0` until derivation catches posted batches is normal.

## What “healthy” looks like

| Check | Expect |
|---|---|
| `eth_chainId` | `0x354` (852) |
| `safe_l2` | Eventually advances; may trail the sequencer by ~3 minutes (L1 batches, not P2P tip-follow) |
| Nightly window | The **sequencer** sleeps **23:45–03:00** `America/Los_Angeles`. Your replica keeps serving the tip it already derived; new L2 progress pauses until new L1 batches land after wake |
| Writes | You cannot (and must not) accept `eth_sendRawTransaction` as a public writer |

Send the operator, once sync looks live:

- Your **region / city** (enough to show geographic spread; no home address required)
- `safe_l2.number` + `safe_l2.hash` at a chosen block
- How you run it (laptop Docker vs VPS)

The operator compares that hash to the Mac sequencer at the same number. Matching hashes = you are on the same chain.

## Keys and secrets

- **Never** accept a ForteL2 role private key, `.env.sepolia`, or JWT from the operator.
- Generate your own `jwt.txt` (above). It is local to your node.
- Do not commit `.env` or `jwt.txt`.

## Redeploy gate (you will be told)

While the 2026-07-22 Sepolia deploy is pinned, **do not** expect a wipe. The next genesis change is the Phase 7 / mainnet-pilot **redeploy gate**. The operator must give **≥1 day** notice.

When that mail/message arrives:

1. Stop your compose stack.
2. Wait until they publish new `genesis.json` / `rollup.json` to `fortel2-replica`.
3. `git pull`, replace local `config/` if your clone is stale, **wipe your datadir**, start again.
4. Send a new matching-hash pair.

Wiping only your node while the Mac/Render still run the old genesis (or the reverse) forks chain 852. Follow the operator’s order; do not get creative.

## What this is not

- Not a sequencer. Not a way to submit L2 transactions for other people.
- Not Blockscout. Not a public RPC commitment.
- Not independent “honesty” auditing yet — `derivation/` still needs a counterparty-owned anchor (see `derivation/README.md` Limitations). Matching the operator hash proves you derived the same chain they did.

## Operator checklist (not for friends)

Recruiting is out of band. Close Phase 3b only when all of these are true:

- [ ] Two friends (or friend-owned VPS) in **different regions**
- [ ] Each followed this runbook (or `RUNNING.md`) without operator keys
- [ ] Each reported a `safe_l2` hash that matched the Mac sequencer
- [ ] Both are on the notify list for the redeploy gate (README Network reset step 1)
