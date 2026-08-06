# Spike T5 — SOS write path to chain 852 (revival)

**Date:** 2026-08-05  
**Card:** `tasks/review-2026-08-05.md` §R-01 / P0-1  
**Status:** options recorded; **loopback stands**; recommendation **pending operator US-012 go/no-go**  
**Scope:** decision material only — no code, ports, binds, or `rail-interface.json` edits in this spike.

SettlementOS (SOS) must send transactions to the ForteL2 Sepolia sequencer (L2 chain **852**). Today the only write endpoint is the Mac mini’s loopback op-geth HTTP RPC. This document maps dependencies, compares five reachability options, and records a single recommendation for the operator to approve or reject under US-012.

---

## 1. Dependency map (D1–D9)

### D1 — Narrow the sequencer RPC surface (transport-independent; first deliverable)

**Grounding (verified 2026-08-05 in this tree):** `scripts/04-start-sequencer-sepolia.sh`

| Flag / surface | Line | Value |
|---|---|---|
| `--http.addr` | 37 | `127.0.0.1` |
| `--http.vhosts` | 39 | `"*"` |
| `--http.corsdomain` | 40 | `"*"` |
| `--http.api` | 41 | `eth,net,web3,debug,txpool,admin,miner` |
| `--ws.addr` | 43 | `127.0.0.1` |
| `--ws.origins` | 45 | `"*"` |
| `--ws.api` | 46 | `eth,net,web3,debug,txpool,admin,miner` |
| op-node `--rpc.addr` | 85 | `127.0.0.1` |
| op-node `--rpc.enable-admin` | 87 | present |

Safe on loopback; unacceptable the moment anything off-box can reach the EL HTTP/WS port: `admin_*`, `debug_*`, and `miner_*` are enabled and DNS-rebinding protection is off (`vhosts=*`). **Before any transport:** provide a write-facing endpoint limited to `eth,net,web3` (second op-geth HTTP listener on its own port, or a filtering reverse proxy). Do not publish op-node’s admin-enabled RPC as the SOS write URL.

### D2 — US-012 non-loopback go/no-go

**Grounding:** `tasks/prd-l2-learning-chain.md` US-012 (non-loopback policy review): before any RPC/bind/advertise leaves `127.0.0.1`/`localhost`, README must record an explicit go/no-go covering **what is exposed, to whom, auth model, and rollback**. Default remains loopback until that review is written. Operator-owned; this spike prepares the material and does not perform the review.

### D3 — `scripts/lib.sh` loopback asserts

**Grounding:** `scripts/lib.sh`

- `assert_l2_loopback_urls` — lines **304–309** (fails closed unless `L2_RPC_URL` / optional `L2_NODE_RPC_URL` are loopback; uses `assert_loopback_url` at 216–228).
- `assert_sepolia_rpc_urls` — lines **338–349** (remote L1 OK; still calls `assert_l2_loopback_urls`).
- `require_sepolia_env` — lines **352–368** (calls `assert_sepolia_rpc_urls`; every Sepolia start/script path hits this).

**Avoidable:** a tunnel or proxy daemon on the Mac that dials `127.0.0.1:<L2_EL_HTTP_PORT>` needs **no** `lib.sh` change — operator scripts keep loopback `L2_RPC_URL`. Changing the op-geth bind or making `L2_RPC_URL` non-loopback requires editing `lib.sh` (CODEOWNERS: `.github/CODEOWNERS` → `/scripts/lib.sh` @StephenForte) plus new `test-helpers.sh` cases. Each option below states which path it takes.

### D4 — Tunnel credential handling

US-022: Tailscale auth key / Cloudflare tunnel token / reverse-proxy credentials are new secrets — gitignored, never in `.env.sepolia.example`, never pasted into chat, redacted in logs (`redact_rpc_url` for any URL that embeds a token). Out of scope to implement here; any approved option must follow this.

### D5 — Availability

Nightly sleep **23:00**–wake **04:00** local (`America/Los_Angeles`, operator 2026-08-05; R-03/R-02 will publish). The sequencer RPC is dead in that window regardless of transport. Any published write URL must state the window (consumer docs / `rail-interface.json` availability — R-02, R-10).

### D6 — Gas runway

Real SOS writes → more non-empty L2 blocks → more batcher calldata → faster L1 burn (batcher ~0.1986 ETH vs 0.15 floor as of review). Measurement is R-05; this spike only notes the coupling: approving a write path without a runway readout risks “tx succeeds on L2, never reaches safe/finalized.”

### D7 — Unattended uptime

User LaunchAgents need a logged-in session; reboot without auto-login leaves the rail down silently. Publishing a stable URL raises the cost of that failure mode — document it next to availability, do not pretend HA.

### D8 — MR-2 / reads entangled with T5

**Grounding:** `tasks/decisions.md` D-0016 — Render replica is a private service with **no Mac-reachable read URL** (SSH tunnel to Render failed; Web Shell only). `deployments/rail-interface.json` still describes a reachable replica read path that does not exist. Until a replica URL exists, SOS heavy reads and any explorer that needs JSON-RPC will land on the **same** sequencer-facing endpoint as writes. Scope the read path in the same decision: the write-facing `eth,net,web3` surface is also the interim read surface; do not promise a separate replica RPC in the consumer contract until one exists.

**Do not re-propose inbound SSH tunneling to Render** (D-0016). Outbound-initiated tunnels **from** the Mac to a cloud edge (Tailscale, cloudflared) remain a different, viable mechanism.

### D9 — Consumer contract

Any published endpoint goes into `deployments/rail-interface.json` with a version bump (R-02 owns the next structural truth-up; a later bump after US-012 go publishes the URL). SOS must confirm the `networkId` string (`fortel2-sepolia` vs `forte-l2`) for their registry. Redeploy-gate discipline: a Phase 7 / mainnet-pilot redeploy invalidates genesis, addresses, and any published RPC identity — coordinated wipe (Mac + replica + SOS redeploy).

### Explicit non-dependencies

These do **not** block T5 and must not gate the write-path decision:

- Phase 3b (friend replicas)
- Fault proofs / op-challenger (learning Phase 7)
- Custom `batcher/` / `proposer/` modules (stock path remains default; D-0018)
- Canonical USDC / paymaster (MR-3/MR-4)
- Any Sepolia or mainnet redeploy
- Inbound SSH / port-forward **to** Render (ruled out by D-0016; not a write-path option)

---

## 2. Options table

US-012’s four review items = exposed / to-whom / auth / rollback (also columns below). “US-012 sat.” = whether this row already supplies a complete draft of those four for a README go/no-go.

| Option | What is exposed | To whom | Auth model | Rollback | Ongoing cost | Effort | US-012 sat. | `lib.sh` (D3)? |
|---|---|---|---|---|---|---|---|---|
| **1. Colocate SOS on the Mac mini** (status quo) | Nothing off-box. SOS process on the mini calls loopback EL HTTP (`L2_RPC_URL` → `127.0.0.1`). Full current API namespace remains local-only until D1. | Only processes on the Mac mini (operator / colocated SOS). No remote SOS host. | OS login + filesystem permissions on the mini; no network auth to RPC. | Stop SOS on the mini; leave sequencer unchanged. No tunnel to tear down. | $0 incremental network. SOS compute shares the mini. | Low (ops/process placement only). | Satisfied **by not leaving loopback** — US-012 non-loopback review is not triggered. Does not unblock remote SOS. | **No** — keep loopback `L2_RPC_URL`. |
| **2. Tailscale tailnet-only** | Tailnet MagicDNS or `100.x` HTTP(S) to a **D1-narrowed** `eth,net,web3` listener (or Tailscale serve → `127.0.0.1`). op-geth stays `--http.addr=127.0.0.1`. Not on the public Internet. | Devices/users on the operator’s Tailscale tailnet (ACL-scoped to SOS hosts/identities). | Tailscale node identity + ACL; optional Tailscale HTTPS serve. Auth key is a US-022 secret. | Remove ACL / disable serve / uninstall Tailscale node; sequencer bind unchanged. Immediate loss of remote reachability. | Free/personal Tailscale tier typical for a learning rail; or paid if org ACL required. | Medium (install Tailscale on mini + SOS host, ACL, D1 listener, document URL). | **Yes** — four items filled in this row; ready for README go/no-go text. | **No** — daemon dials loopback; scripts keep loopback `L2_RPC_URL`. |
| **3. `cloudflared` + Cloudflare Access policy** | Cloudflare hostname → tunnel to loopback **D1-narrowed** `eth,net,web3` only. Public DNS name exists; Access sits in front. | Identities allowed by the Access policy (SSO/email/service token) — not the open Internet if policy is deny-by-default. | Cloudflare Access (IdP or service token). Tunnel token is a US-022 secret. | Disable Access app / stop `cloudflared` / revoke tunnel token; DNS can remain but origin is dark. | Cloudflare tunnel + Access (often free tier for small use; Access seats may cost). | Medium–high (tunnel, Access app, cert/hostname, D1, runbook). | **Yes** — four items filled; Access policy must be named in the README go/no-go. | **No** — `cloudflared` dials `127.0.0.1`; no `L2_RPC_URL` change. |
| **4. Authenticating reverse proxy** (e.g. Caddy/nginx with mTLS or bearer) fronting sequencer | Proxy listen address (LAN or public — **must** be stated in go/no-go) → upstream loopback **D1-narrowed** RPC. Raw op-geth never bound off loopback. | Holders of client certs or bearer tokens issued by the operator. | mTLS and/or HTTP bearer; secrets US-022. Deny unauthenticated methods if proxy also filters JSON-RPC. | Stop proxy process / revoke certs/tokens; op-geth remains loopback-only. | Low–medium host resources; cert issuance/renewal ops. | Medium (proxy config, cert lifecycle, D1, hardening review). | **Yes** if README names bind address, audience, auth, rollback before enable — this row is the draft. | **No** if proxy binds separately and upstream is loopback. **Yes (CODEOWNERS)** only if someone instead rebinds op-geth or sets non-loopback `L2_RPC_URL`. Prefer proxy-without-`lib.sh`. |
| **5. Relocate sequencer** off the Mac (cloud VM / always-on host) | Sequencer EL RPC on the new host’s network per that host’s security model; Mac ceases to be the write origin. | Whoever can reach the new host’s write endpoint (defined at relocate time). | Host firewall + (recommended) same class as opt. 2–4 on the new host; plus cloud IAM for the VM. | Revert DNS/`rail-interface` to prior publish; restore Mac sequencer from pinned genesis only via coordinated runbook — **high blast radius**. | Cloud VM + L1 RPC + disk + ops (material $/mo vs mini). | **High** — migrate datadir/keys, rewrite start scripts/env, replica coordination, likely touches `lib.sh` / Sepolia runbooks. | Only after a **full** US-012 rewrite for the new host; this row alone is insufficient until relocate design exists. | **Likely yes** — non-loopback or new topology almost certainly needs `lib.sh` escape hatch + `test-helpers.sh` (CODEOWNERS). |

---

## 3. Recommendation — **pending operator go/no-go**

**Recommend option 2 (Tailscale tailnet-only) when the operator chooses to leave loopback**, after D1 narrows the write-facing namespace to `eth,net,web3`. Reasoning: it keeps the sequencer bound to `127.0.0.1` (no `lib.sh` / CODEOWNERS round-trip), limits exposure to ACL-scoped tailnet identities rather than a public hostname, and matches the tunnel class already contemplated by US-032 — while D-0016’s failed *inbound* Render SSH path is not reused. Until that US-012 go/no-go is written in README, **loopback / option 1 (colocate) remains the only approved write path**; this recommendation is decision material, not authorization to expose anything.

---

## 4. Sequenced plan (fixed order)

| Step | Work | Reversible? | Owner |
|---|---|---|---|
| **1. D1** | Add write-facing RPC limited to `eth,net,web3` (second listener or filtering proxy). Leave admin/debug/miner/txpool on the existing loopback-only full surface for operator tooling, or strip them globally only with a conscious ops trade-off. Do **not** publish op-node `--rpc.enable-admin`. | **Yes** — revert start-script flags / stop second listener; no chain wipe. | ForteL2 (future task; not this spike) |
| **2. D2** | Operator US-012 README go/no-go using the four items from the chosen row (exposed / to-whom / auth / rollback), plus D5 availability and D7 unattended-uptime notes. | **Yes** — a “no-go” leaves loopback; a later “go” can still pick a different row. | **Operator** |
| **3. Transport** | Implement the approved option (recommended: Tailscale → D1 port). Apply D4 secrets hygiene. Still no change to committed `L2_RPC_URL` if the daemon dials loopback. | **Yes** for opts 2–4 (disable tunnel/proxy). Opt 5 relocate is only weakly reversible. | ForteL2 ops |
| **4. R-02 publish** | After go: version-bump `rail-interface.json` with the write URL keys (§5). (R-02’s imminent v2 truth-up does **not** publish a non-loopback URL while loopback stands.) | URL publish is reversible by bumping again to loopback/`null` + SOS notice; chain state unchanged. | R-02 / follow-on |
| **5. SOS registry entry** | SOS confirms `networkId` and points their fortel2-sepolia (or chosen id) write RPC at the published URL; settle demo path unblocked for MR-1. | SOS-side config revert. | SettlementOS |

**Invariant:** never run step 3 before steps 1–2. Publishing a URL (step 4) before D1 is a security regression on the current API surface.

---

## 5. What changes in `rail-interface.json` if approved

Do **not** edit the file in this task (R-02 owns the next edit). After an operator US-012 **go** and transport bring-up, a **later** version bump would set or add approximately these keys under the Sepolia network object (and top-level metadata):

| JSON key / path | Role if approved |
|---|---|
| `version` | Bump (e.g. beyond R-02’s `"2"`) when the write URL changes. |
| `updated` | Date of the publish. |
| `networks.fortel2-sepolia.l2RpcUrl` | Either remains loopback documentation for on-mini operators, **or** is replaced only if the published consumer write URL is intended to be the primary field — prefer an explicit write field (next row) to avoid breaking colocated scripts. |
| `networks.fortel2-sepolia.writeRpcUrl` **(add)** | Published Tailscale (or other) write URL for SOS; `null` while loopback-only. |
| `networks.fortel2-sepolia.writeAccess` **(add)** | Object: `model` (`tailscale-tailnet` / `cloudflare-access` / `mtls-proxy` / `colocate`), `audience`, `auth`, `rollback` summary strings mirroring the US-012 README. |
| `networks.fortel2-sepolia.notes` | Update write-path sentence (today: loopback). |
| `networks.fortel2-sepolia.replica.readRpcUrl` | Remains `null` per D-0016 until a real replica URL exists; optional note that interim reads may use `writeRpcUrl`’s D1 surface (D8). |
| `networks.fortel2-sepolia.replica.writeRpcUrl` | Stay `null` (replica must not accept writes). |
| `availability` (top-level or per-network; R-02 shape) | Must already state sleep/wake; write-path publish does not remove it. |
| `openQuestions[]` | Keep/resolve `networkId` string confirmation with SOS. |
| `sosGate` | Unchanged unless SOS onboarding text needs a write-path pointer. |

Exact string values are operator-local after go — never commit tunnel tokens or keyed URLs.

---

## 6. Read path (D8) — scoped with writes

| Consumer need | Today | After recommended Tailscale go |
|---|---|---|
| SOS writes | Colocate / loopback only | Tailnet URL → D1 `eth,net,web3` |
| SOS / explorer heavy reads | No Mac-reachable replica (D-0016); Web Shell only for operator drills | Same D1 endpoint as interim read RPC; document as best-effort, nightly downtime applies |
| Replica as preferred read (MR-2) | Blocked until a reachable replica URL exists | Still a separate deliverable; do not block T5 write decision on it |

---

## 7. Operator decision checklist (US-012)

When ready to leave loopback, record in README:

1. **Exposed:** D1-narrowed JSON-RPC only (`eth,net,web3`); not op-node admin; not Engine/JWT.
2. **To whom:** Tailnet ACL principals (or the chosen row’s audience).
3. **Auth:** Tailscale identity/ACL (or Access / mTLS per chosen row).
4. **Rollback:** disable tunnel/serve; sequencer remains loopback-bound.
5. **Availability:** 23:00–04:00 local downtime (D5).
6. **Unattended:** LaunchAgent / login-session caveat (D7).
7. **Gas:** watch R-05 runway before sustained SOS load (D6).

Until that checklist is written as a go, **no transport is authorized**.
