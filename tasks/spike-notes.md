# Phase 0 spike notes — Kurtosis `optimism-package` on Apple Silicon

**Date:** 2026-07-18  
**Host:** Apple M3 Max, macOS 26.5.2, arm64  
**Verdict:** **manual builds** (Kurtosis path abandoned on this machine)

## What was attempted

1. Installed **OrbStack 2.2.1** (Docker-compatible runtime) and **Kurtosis CLI 1.20.0**.
2. Cloned `ethpandaops/optimism-package` @ `7bef190d7c0b9f619438ed08b17bd5e5f51e72ff`.
3. Started Kurtosis engine under OrbStack and began `kurtosis run` (enclave `tired-spring`).
4. Within ~1 minute the run failed with Docker/Kurtosis RPC EOFs (`unexpected EOF`, `connection reset by peer`) while the host **internet connection was disrupted**.
5. Operator stopped the spike: container runtime must not break host networking. OrbStack was quit; Kurtosis processes killed. **No further Docker/OrbStack use on this host for this project unless networking impact is fixed.**

## Image architectures

Not recorded. The enclave never reached a stable set of running OP Stack services before the runtime/network failure. No per-service `arm64` vs `amd64` inventory was possible.

## Versions tested

| Component | Version |
|---|---|
| Host arch | arm64 (Apple M3 Max) |
| macOS | 26.5.2 |
| OrbStack | 2.2.1 (2020100) |
| Docker client (OrbStack) | 29.4.0 (`darwin/arm64`) |
| Docker server (OrbStack VM) | 29.4.0 (`linux/arm64`) |
| Kurtosis CLI | 1.20.0 |
| optimism-package | `7bef190d7c0b9f619438ed08b17bd5e5f51e72ff` |

## Teardown

- OrbStack quit / not running; `docker.sock` absent.
- Kurtosis CLI/engine processes killed.
- Full `kurtosis clean -a` could not be re-run after the daemon was stopped (daemon already down). Residual images/volumes may remain in OrbStack data dirs if OrbStack is started again later — delete via OrbStack UI or `orbctl` only when networking is known-safe.

## Secondary ARM source-build check

**Not run.** Blocked by the same session constraint: do not risk further host-network disruption while recovering from OrbStack. Before Phase 1 commits to manual builds, spend ≤30 minutes verifying `op-geth` and `op-node` build from source on arm64 **without** starting Docker/OrbStack (Go toolchain + git clone only).

## Reasoning (verdict)

Kurtosis + OrbStack is the supported OP Stack devnet path in theory, but on this Mac it immediately destabilized host networking and the Kurtosis engine itself (daemon EOFs mid-`kurtosis run`). That fails the operator constraint for a learning machine that must stay online. Phase 1 should proceed with **manual / native OP Stack binaries** (or a container runtime proven not to hijack networking — e.g. a separate always-on Mac mini / remote host), not Kurtosis-on-OrbStack on this workstation.
