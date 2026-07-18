# Phase 0 spike notes — Kurtosis `optimism-package` on Apple Silicon

**Date:** 2026-07-18  
**Host:** Apple M3 Max, macOS 26.5.2, arm64  
**Verdict:** **manual builds** (Kurtosis path abandoned on this machine; native arm64 source builds verified)

## What was attempted

1. Installed **OrbStack 2.2.1** (Docker-compatible runtime) and **Kurtosis CLI 1.20.0**.
2. Cloned `ethpandaops/optimism-package` @ `7bef190d7c0b9f619438ed08b17bd5e5f51e72ff`.
3. Started Kurtosis engine under OrbStack and began `kurtosis run` (enclave `tired-spring`).
4. Within ~1 minute the run failed with Docker/Kurtosis RPC EOFs (`unexpected EOF`, `connection reset by peer`) while the host **internet connection was disrupted**.
5. Operator stopped the spike and **removed OrbStack**. Container runtimes are out of scope on this host.
6. Completed the PRD secondary check: native source builds of `op-node` and `op-geth` on arm64 (no Docker).

## Image architectures

Not recorded for Kurtosis services (enclave never stable). Native binaries produced by the secondary check:

| Binary | Arch | Path |
|---|---|---|
| `op-node` | Mach-O arm64 | `~/src/fortel2-phase0/optimism/op-node/bin/op-node` |
| `geth` (op-geth) | Mach-O arm64 | `~/src/fortel2-phase0/op-geth/build/bin/geth` |

## Versions tested (Kurtosis attempt)

| Component | Version |
|---|---|
| Host arch | arm64 (Apple M3 Max) |
| macOS | 26.5.2 |
| OrbStack | 2.2.1 (2020100) — **removed by operator** |
| Docker client (OrbStack) | 29.4.0 (`darwin/arm64`) |
| Docker server (OrbStack VM) | 29.4.0 (`linux/arm64`) |
| Kurtosis CLI | 1.20.0 |
| optimism-package | `7bef190d7c0b9f619438ed08b17bd5e5f51e72ff` |

## Teardown

- OrbStack removed by operator; `docker` not on PATH.
- Kurtosis CLI may still be installed via Homebrew but has no engine to talk to (harmless).
- Spike build trees left at `~/src/fortel2-phase0/` (outside Dropbox; disposable).

## Secondary ARM source-build check — **PASS** (~2 minutes wall clock)

No Docker/OrbStack. Host toolchains only.

### Tooling installed for the check

| Tool | Version |
|---|---|
| Go | 1.26.5 (`darwin/arm64`) |
| just | 1.56.0 |
| yq | 4.53.3 (needed for `just build-superchain-go`) |
| zip | macOS `/usr/bin/zip` |

### Builds

| Component | Tag / commit | Command | Result |
|---|---|---|---|
| **op-geth** | `v1.101702.2` (`e8800cffe53d…`) | `make geth` | OK — `Geth Version: 1.101702.2-stable`, arch `arm64` |
| **op-node** | `op-node/v1.19.2` (monorepo `da197e45…`) | `just build-superchain-go` then `just op-node` | OK — `op-node version v1.19.2-da197e45-…`, Mach-O arm64 |

**Notes for Phase 1:**

- Building `op-node` alone fails until `just build-superchain-go` creates the gitignored `op-core/superchain/superchain-configs.zip` (needs `yq` + `zip` + `superchain-registry` submodule).
- Upstream now defaults `--l2.enginekind` to **reth** and has marked **op-geth end-of-support** for Karst-era public networks. For a private learning L1/L2, op-geth still builds and is enough to prove the manual path; Phase 1 may prefer **op-reth** once Rust tooling is installed, but that was out of this 30-minute check’s scope.

## Reasoning (verdict)

Kurtosis requires a container engine; OrbStack made this machine unusable, so that path is closed here. The secondary check shows **native arm64 builds of `op-node` and `op-geth` succeed in minutes** with only Go/`just`/`yq`. Phase 1 should use **manual native binaries** (Anvil or native L1 + `op-deployer` + `op-node` + execution client + batcher/proposer), not Kurtosis/Docker on this workstation.
