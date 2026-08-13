# 12 August 2026 — authenticated write path (end of day)

Easy recap of what landed. Secrets are named, not pasted.

Canonical decision: **D-0035** in `tasks/decisions.md`.

## In one paragraph

ForteL2 writes from SettlementOS on Render now go through Cloudflare Access to the Mac mini write filter on port 9555. Unauthenticated callers get 403. The service token (held by Steve) returns chain ID 852. Reads stay on the private replica. The write hostname is live in Render env and **not** published in `rail-interface.json`.

## Proven today

| Check | Result |
|---|---|
| No token → `https://fortel2-write.ente.ltd` `eth_chainId` | **403** Cloudflare Access HTML |
| Token from the mini | `{"jsonrpc":"2.0","id":1,"result":"0x354"}` (852) |
| Same call from **settlementos** Render Shell using live env | `{"jsonrpc":"2.0","id":1,"result":"0x354"}` |

That is Render → Access → `:9555` → op-geth. Not yet a signed settlement transaction (SOS UI has no ForteL2 network until the overlay Secret File is mounted).

## Live values

### Cloudflare (dashboard-managed, not the LaunchAgent)

| What | Value | Where it lives |
|---|---|---|
| Org | Zero Trust **Free** | Cloudflare, Steve |
| Tunnel name | `SuperForteL2_mini` | Cloudflare → Networks → Tunnels |
| Tunnel ID | `64c3a080-44fa-4af6-9591-aba07d849757` | same |
| Connector | `supermini.local`, darwin_arm64, **Healthy** | same |
| Origin | `http://127.0.0.1:9555` only | Tunnel public hostname. Never `:9545` or op-node `:9547` |
| Public hostname | `https://fortel2-write.ente.ltd` | DNS + tunnel |
| Access app | `fortel2-write` | Zero Trust → Access → Applications |
| Policy | `settlementos` (Service Auth, not Allow/Everyone/Bypass) | same |

**Do not** bootstrap `com.steve.fortel2-cloudflared` while that connector is Healthy. A second `cloudflared` fights it. PR 73 yaml/LaunchAgent is the optional local-config alternate after the dashboard connector is stopped.

### Access token (Steve only)

| What | Where |
|---|---|
| `CF_ACCESS_CLIENT_ID` | Cloudflare Access → Service credentials, **and** Render → settlementos → Environment |
| `CF_ACCESS_CLIENT_SECRET` | same. **Not** in git, chat, `.env.example`, or any `VITE_*` var |

### SettlementOS on Render

| What | Value |
|---|---|
| Service | `settlementos` `srv-d9tafn3m8hqs73cks7cg` (Oregon, env `evm-d9h424715fvs73cq2gl0`) |
| PR | [#65](https://github.com/StephenForte/settlementos/pull/65) squash-merged `785a9ae` |
| Live deploy | `dep-d9uhmgvqj5pc73fk5hdg` (manual, after Blueprint sync) |
| `FORTEL2_SEPOLIA_RPC_URL` | `https://fortel2-write.ente.ltd` |
| `FORTEL2_SEPOLIA_READ_RPC_URL` | `http://fortel2-replica:10000` |
| `CF_ACCESS_*` | set (`sync: false`) |
| Code | `writeHttp` attaches Access headers **only** when `networkId === "fortel2-sepolia"`. Base Sepolia / Amoy do not get the token. `readClientFor` never does. |

### Replica (unchanged posture)

| What | Value |
|---|---|
| Service | Private Service `fortel2-replica` `srv-d9fsgi3rjlhs73ceh6tg` |
| RPC | `http://fortel2-replica:10000` (method filter). geth/op-node loopback |
| Disk | 50 GB. Do not convert to Web. Do not apply `render.yaml` as a **new** Blueprint (would create a 20 GB empty disk) |
| Public URL | **none** (D-0031). `rail-interface.json` `replica.readRpcUrl` stays `null` |
| Writes | `eth_sendRawTransaction` → `-32601 method not allowed` |
| Lag | ~3 min vs sequencer (L1 batches). `confirm()` must use the write RPC |

### Mini sequencer (operator)

| What | Value |
|---|---|
| Full RPC | `http://127.0.0.1:9545` (`admin,debug,miner,txpool` — operator only) |
| Write filter | `http://127.0.0.1:9555` (`eth,net,web3` allowlist) |
| `L2_RPC_URL` | stays loopback. Do not point it at `ente.ltd` |
| Nightly window | **23:45–03:00** `America/Los_Angeles`. Tunnel stays up; origin goes dark |

## What we did not do

- Publish `https://fortel2-write.ente.ltd` in ForteL2 `deployments/rail-interface.json` (other clients have no Access headers).
- Mount SOS overlay `deployments.fortel2-sepolia.json` on Render (why ForteL2 is missing from the SOS UI).
- Run a signed `eth_sendRawTransaction` / settlement from Render.
- Start the ForteL2 LaunchAgent tunnel (dashboard connector already owns it).

## Parked for later (Steve)

1. Cursor Bugbot findings on PR 65 (or elsewhere) — investigate independently.
2. SOS UI: upload `deployments.fortel2-sepolia.json` as a Render Secret File, then a real 852 settlement write.
3. Optional: signed raw tx from Render Shell once the overlay exists.
4. Optional later: publish the write URL in `rail-interface.json` only if consumers can send Access headers.

## Repos touched today

| Repo | What |
|---|---|
| ForteL2 | Tunnel/Access ops (dashboard). Docs: D-0035, coordination, README, spike T5, launchd, replica README. Recap: this file. |
| settlementos | PR 65 merged (Access headers on ForteL2 writes only). Render env + deploy. |
| fortel2-replica | No code. README/AGENTS corrected: live service is Private, not public Web. |

## Rollback (no chain wipe)

1. Revoke the Cloudflare Access service token, and/or stop the `SuperForteL2_mini` connector.
2. Sequencer bind, `:9545`, and chain state are untouched.

## Docs updated with this recap

- ForteL2 `tasks/decisions.md` (D-0035)
- ForteL2 `tasks/coordination-settlementos.md`
- ForteL2 `README.md` (onboarding, tunnel, US-012)
- ForteL2 `tasks/spike-t5-write-path.md`
- ForteL2 `launchd/README.md`
- ForteL2 `replica/README.md`
- fortel2-replica `README.md` / `AGENTS.md`
- settlementos `README.md` / `tasks/prd-fortel2-integration.md`

These doc edits are **uncommitted** as of this file. Commit in each repo when you are ready.
