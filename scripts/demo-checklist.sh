#!/usr/bin/env bash
# Operator demo / verification checklist (Phase 1 local or Phase 2 Sepolia).
# Runs automated smoke checks, then prints a human checklist for browser steps.
#
# Usage:
#   ./scripts/demo-checklist.sh              # Phase 1 (default .env) — auto + checklist
#   ./scripts/demo-checklist.sh --auto
#   ./scripts/demo-checklist.sh --print
#   FORTEL2_ENV=.env.sepolia ./scripts/demo-checklist.sh
#   ./scripts/demo-checklist.sh --sepolia     # forces FORTEL2_ENV=.env.sepolia if unset
#   ./scripts/demo-checklist.sh --sepolia --auto
#
# Prerequisites: stack running (start-all.sh or start-all-sepolia.sh).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="all"
FORCE_SEPOLIA=0
for arg in "$@"; do
  case "$arg" in
    --auto) MODE="auto" ;;
    --print) MODE="print" ;;
    --sepolia) FORCE_SEPOLIA=1 ;;
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} /^set -euo/{exit}' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (try --auto, --print, --sepolia, or --help)" >&2
      exit 1
      ;;
  esac
done

if (( FORCE_SEPOLIA )) && [[ -z "${FORTEL2_ENV:-}" ]]; then
  export FORTEL2_ENV=.env.sepolia
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

if (( FORCE_SEPOLIA )); then
  require_sepolia_env
fi

IS_SEPOLIA=0
if [[ "${L2_CHAIN_ID:-}" == "852" ]]; then
  IS_SEPOLIA=1
fi

fail=0
pass() { echo "  PASS  $1"; }
fail_item() { echo "  FAIL  $1" >&2; fail=1; }
skip() { echo "  SKIP  $1"; }
info() { echo "  ·     $1"; }

print_checklist_local() {
  cat <<'EOF'

══════════════════════════════════════════════════════════════════
  ForteL2 demo checklist — Phase 1 → 1b → 1c
  Check each box as you verify. Automated smokes are marked [auto].
══════════════════════════════════════════════════════════════════

── A. Stack health (Phase 1) ─────────────────────────────────────
  [ ] [auto] All five processes running: anvil, op-geth, op-node, op-batcher, op-proposer
  [ ] [auto] L1 RPC reachable (chain 900), block number increasing
  [ ] [auto] L2 RPC reachable (chain 901), block number increasing
  [ ] [auto] op-node optimism_syncStatus returns unsafe + safe heads
  [ ] Logs look healthy (known-good lines in README “Logs & health”)

── B. Sequencer + L2 txs (Phase 1 / US-004) ──────────────────────
  [ ] [auto] ./scripts/smoke-transfer.sh — DEMO_A → DEMO_B 0.01 ETH confirms
  [ ] cast block latest on L2 shows recent activity
  [ ] Sequencer restart: ./scripts/stop-all.sh && ./scripts/start-all.sh
      (no reset) — chain resumes from prior head, no re-genesis

── C. Batcher + proposer on L1 (Phase 1 / US-005 / US-006) ───────
  [ ] [auto] Batcher L1 nonce > 0 (or rising) — batches posting
  [ ] [auto] DisputeGameFactory gameCount() ≥ 1 after a short wait
  [ ] Optional: stop batcher 2–5 min, watch unsafe−safe lag grow on viewer /
      cast rpc optimism_syncStatus; restart batcher, lag closes

── D. Guestbook dApp (Phase 1 / US-008) ──────────────────────────
  [ ] [auto] Guestbook deployed (deployments/guestbook.txt + dapp/config.js)
  [ ] ./scripts/serve-dapp.sh → http://127.0.0.1:8080 (loopback only)
  [ ] MetaMask: network ForteL2, RPC http://127.0.0.1:9545, chain 901
  [ ] Import DEMO_A (L2-funded) — not ADMIN (0 L2 at genesis)
  [ ] Connect wallet → Sign a short message → appears in Messages list
  [ ] Refresh reloads on-chain entries without reconnect
  [ ] After chain reset: MetaMask → Delete activity and nonce data if txs stick

── E. Bridging (Phase 1b / US-010 / US-011) ──────────────────────
  [ ] ./scripts/deposit-eth.sh — ADMIN L1→L2; L2 balance rises; note L1 tx hash
  [ ] Deposit narrative: cannot be censored by sequencer (derivation must include it)
  [ ] ./scripts/withdraw-initiate.sh — note withdrawal hash / proof artifacts
  [ ] ./scripts/withdraw-prove.sh — waits for dispute game + proves on L1
  [ ] ./scripts/withdraw-finalize.sh — resolve/time-warp/finalize; L1 balance rises
  [ ] ./scripts/verify-portal-delays.sh — short local delays (not 7-day mainnet)

── F. Pipeline viewer (Phase 1c / 1d) ─────────────────────────────
  [ ] ./scripts/serve-viewer.sh → http://127.0.0.1:8081
  [ ] Or: ./scripts/demo-live.sh --local  (health + talk track + open URLs)
  [ ] Page title / brand: “ForteL2” + “Pipeline viewer” (not “explorer”)
  [ ] Status line shows live polling; refresh cadence visible (~5s)
  [ ] Sequencer panel: unsafe / safe / finalized (or ages) update
  [ ] Batcher panel: recent posts / last tx hash / cadence (after batches land)
  [ ] Proposer panel: game count ≥ 1; last game age/proxy
  [ ] Aggregate panel: empty vs non-empty + tx/min + **mempool** pending/queued
  [ ] Kill viewer (Ctrl-C) — chain keeps running (status.sh still green)
  [ ] With stack stopped: panels show plain error text (not silent stale data)
  [ ] After deposit: relate L2 inclusion / sync heads on Sequencer panel
  [ ] After withdraw initiate: note prover needs proposer output (Proposer panel)

── G. Guardrails / docs (US-012 + 1d funding + runbook) ───────────
  [ ] [auto] ./scripts/test-helpers.sh passes
  [ ] [auto] node --test viewer/lib.test.js dapp/lib.test.js passes
  [ ] RPCs and HTTP servers stay on 127.0.0.1 / localhost only
  [ ] README “Pipeline viewer” + “Phase 2 funding gate” match what you see
  [ ] Hosted/Blockscout explorers still out of scope (by design)

── Suggested full demo order ─────────────────────────────────────
  1. ./scripts/start-all.sh && ./scripts/status.sh
  2. ./scripts/demo-checklist.sh --auto
  3. ./scripts/smoke-transfer.sh
  4. ./scripts/deploy-guestbook.sh   # if guestbook.txt empty / first time
  5. ./scripts/demo-live.sh --local  # or serve-dapp + serve-viewer in two terminals
  6. MetaMask guestbook sign
  7. ./scripts/deposit-eth.sh
  8. Watch viewer Sequencer + Aggregate update
  9. ./scripts/withdraw-initiate.sh && ./scripts/withdraw-prove.sh && ./scripts/withdraw-finalize.sh
 10. Confirm Proposer panel game count / last age; narrate prove path
 11. Ctrl-C demo-live / servers; ./scripts/stop-all.sh when done

══════════════════════════════════════════════════════════════════
EOF
}

print_checklist_sepolia() {
  cat <<'EOF'

══════════════════════════════════════════════════════════════════
  ForteL2 demo checklist — Sepolia (L2 852 / L1 11155111)
  Check each box as you verify. Automated smokes are marked [auto].
══════════════════════════════════════════════════════════════════

── A. Stack health (Phase 2c) ────────────────────────────────────
  [ ] [auto] Processes: op-geth, op-node, op-batcher, op-proposer (no Anvil)
  [ ] [auto] L1 RPC reachable (Sepolia 11155111) — QuickNode or equivalent
  [ ] [auto] L2 RPC reachable on loopback (chain 852), block number increasing
  [ ] [auto] op-node optimism_syncStatus returns unsafe + safe heads
  [ ] Logs under data-sepolia look healthy; close viewer when idle (API credits)

── B. Funding + L2 activity ──────────────────────────────────────
  [ ] [auto] ./scripts/sepolia-fund-check.sh — BATCHER/PROPOSER ≥ floors
  [ ] Foundry default keys refused on 852 — do not run smoke-transfer.sh with them
  [ ] Optional: funded DEMO_A/B transfer via cast with your Sepolia role keys
  [ ] cast block latest on L2 shows recent activity

── C. Batcher + proposer on Sepolia L1 ───────────────────────────
  [ ] [auto] Batcher L1 nonce > 0 (or rising) — batches posting
  [ ] [auto] DisputeGameFactory gameCount() (may be 0 early — wait for proposer)
  [ ] Optional: watch Batcher/Proposer panels on viewer (15s refresh)

── D. Guestbook dApp ─────────────────────────────────────────────
  [ ] Guestbook is a Phase 1 local demo — usually SKIP on Sepolia
  [ ] If you deployed Guestbook on 852: serve-dapp + MetaMask chain 852 / :9545
  [ ] Else use pipeline viewer + cast for the live demo surface

── E. Bridging (Sepolia) ─────────────────────────────────────────
  [ ] FORTEL2_ENV=.env.sepolia ./scripts/deposit-eth-sepolia.sh
  [ ] Deposit narrative: L1 inclusion → L2 derivation (cannot be censored by sequencer)
  [ ] Withdraw prove/finalize: real Sepolia finality (no Anvil time-warp) — long waits
  [ ] Do not reset-sepolia without full cutover (redeploy + pack + wipe both datadirs)

── F. Pipeline viewer ────────────────────────────────────────────
  [ ] FORTEL2_ENV=.env.sepolia ./scripts/serve-viewer.sh → http://127.0.0.1:8081
  [ ] Or: FORTEL2_ENV=.env.sepolia ./scripts/demo-live.sh --sepolia
  [ ] Lede shows Sepolia mode; refresh ~15s
  [ ] Sequencer + Aggregate (loopback L2); Batcher + Proposer (L1 HTTPS)
  [ ] Close the viewer tab when not demoing (QuickNode credit budget)
  [ ] Kill serve-viewer (Ctrl-C) — chain keeps running

── G. Guardrails / replica ───────────────────────────────────────
  [ ] [auto] ./scripts/test-helpers.sh passes
  [ ] [auto] node --test viewer/lib.test.js dapp/lib.test.js passes
  [ ] L2 / dApp / viewer stay on loopback; L1 may be remote HTTPS
  [ ] Optional: fortel2-replica sync check when a verifier is up

── Suggested Sepolia demo order ──────────────────────────────────
  1. FORTEL2_ENV=.env.sepolia ./scripts/start-all-sepolia.sh
  2. FORTEL2_ENV=.env.sepolia ./scripts/status.sh
  3. FORTEL2_ENV=.env.sepolia ./scripts/demo-checklist.sh --auto
  4. FORTEL2_ENV=.env.sepolia ./scripts/sepolia-fund-check.sh
  5. FORTEL2_ENV=.env.sepolia ./scripts/demo-live.sh --sepolia
  6. Narrate Sequencer → Batcher → Proposer on the viewer
  7. Optional: deposit-eth-sepolia.sh; watch Sequencer / Aggregate
  8. Ctrl-C demo-live; FORTEL2_ENV=.env.sepolia ./scripts/stop-all-sepolia.sh when done

══════════════════════════════════════════════════════════════════
EOF
}

print_checklist() {
  if (( IS_SEPOLIA )); then
    print_checklist_sepolia
  else
    print_checklist_local
  fi
}

run_auto() {
  echo
  if (( IS_SEPOLIA )); then
    echo "=== Automated checks (Sepolia L2=${L2_CHAIN_ID}) ==="
    require_bin cast
    require_bin jq
    assert_sepolia_rpc_urls
  else
    echo "=== Automated checks (local L2=${L2_CHAIN_ID:-901}) ==="
    require_bin cast
    require_bin jq
    assert_local_rpc_urls
  fi

  echo
  echo "-- Processes --"
  local name
  local any_proc_missing=0
  local procs=(op-geth op-node op-batcher op-proposer)
  if (( ! IS_SEPOLIA )); then
    procs=(anvil "${procs[@]}")
  fi
  for name in "${procs[@]}"; do
    if is_running "$name"; then
      pass "$name running (pid $(cat "$PID_DIR/$name.pid"))"
    else
      any_proc_missing=1
      echo "  WARN  $name: no pidfile under $PID_DIR (RPC may still be up)"
    fi
  done
  if (( any_proc_missing )); then
    info "If RPCs below pass, stack is fine — pidfiles only matter for stop scripts"
  fi

  echo
  echo "-- L1 / L2 RPC --"
  local l1_block l2_block l1_chain l2_chain
  # Guard chain-id with || echo "": under set -e, a bare failing assignment after a
  # successful block-number aborts run_auto before fail_item (and in --all mode can
  # skip the printed checklist / bypass fail aggregation).
  if l1_block=$(cast block-number --rpc-url "$L1_RPC_URL" 2>/dev/null); then
    l1_chain=$(cast chain-id --rpc-url "$L1_RPC_URL" 2>/dev/null || echo "")
    if [[ -n "$l1_chain" && "$l1_chain" == "${L1_CHAIN_ID}" ]]; then
      pass "L1 block=$l1_block chain=$l1_chain"
    elif [[ -n "$l1_chain" ]]; then
      fail_item "L1 chain-id=$l1_chain expected ${L1_CHAIN_ID}"
    else
      fail_item "L1 chain-id unread at $(redact_rpc_url "$L1_RPC_URL")"
    fi
  else
    fail_item "L1 RPC unreachable at $(redact_rpc_url "$L1_RPC_URL")"
  fi

  if l2_block=$(cast block-number --rpc-url "$L2_RPC_URL" 2>/dev/null); then
    l2_chain=$(cast chain-id --rpc-url "$L2_RPC_URL" 2>/dev/null || echo "")
    if [[ -n "$l2_chain" && "$l2_chain" == "${L2_CHAIN_ID}" ]]; then
      pass "L2 block=$l2_block chain=$l2_chain"
    elif [[ -n "$l2_chain" ]]; then
      fail_item "L2 chain-id=$l2_chain expected ${L2_CHAIN_ID}"
    else
      fail_item "L2 chain-id unread at $L2_RPC_URL"
    fi
  else
    fail_item "L2 RPC unreachable at $L2_RPC_URL"
  fi

  echo
  echo "-- Sync status (op-node) --"
  if [[ -n "${L2_NODE_RPC_URL:-}" ]] && cast rpc optimism_syncStatus --rpc-url "$L2_NODE_RPC_URL" >/tmp/fortel2-sync-$$.json 2>/dev/null; then
    local unsafe safe
    unsafe=$(jq -r '.unsafe_l2.number // empty' /tmp/fortel2-sync-$$.json)
    safe=$(jq -r '.safe_l2.number // empty' /tmp/fortel2-sync-$$.json)
    rm -f /tmp/fortel2-sync-$$.json
    if [[ -n "$unsafe" && -n "$safe" ]]; then
      pass "syncStatus unsafe=$unsafe safe=$safe (lag=$((unsafe - safe)))"
    else
      fail_item "optimism_syncStatus missing unsafe/safe fields"
    fi
  else
    fail_item "optimism_syncStatus failed at ${L2_NODE_RPC_URL:-unset}"
  fi

  if (( IS_SEPOLIA )); then
    echo
    echo "-- Sepolia fund check --"
    # Exit 1 only when BATCHER/PROPOSER are below floors (ADMIN/HARVEST are advisory).
    if "$SCRIPT_DIR/sepolia-fund-check.sh"; then
      pass "sepolia-fund-check: BATCHER/PROPOSER ≥ floors"
    else
      fail_item "sepolia-fund-check: BATCHER/PROPOSER NEED — top up from harvest before long demos"
    fi
  fi

  echo
  echo "-- Batcher / proposer on L1 --"
  if [[ -n "${BATCHER_ADDRESS:-}" ]] && is_eth_address "$BATCHER_ADDRESS"; then
    local nonce
    nonce=$(cast nonce "$BATCHER_ADDRESS" --rpc-url "$L1_RPC_URL" 2>/dev/null || echo "")
    if [[ -n "$nonce" ]]; then
      if [[ "$nonce" != "0" ]]; then
        pass "batcher L1 nonce=$nonce"
      else
        skip "batcher L1 nonce=0 (wait for first batch, then re-run)"
      fi
    else
      fail_item "could not read batcher nonce"
    fi
  else
    skip "BATCHER_ADDRESS unset"
  fi

  local factory deployments
  deployments="$(deployments_json_path)"
  factory=$(jq -r '.DisputeGameFactoryProxy // empty' "$deployments" 2>/dev/null || true)
  if is_eth_address "${factory:-}"; then
    local games
    games=$(cast call "$factory" "gameCount()(uint256)" --rpc-url "$L1_RPC_URL" 2>/dev/null || echo "")
    if [[ -n "$games" ]]; then
      local games_dec
      games_dec=$(python3 -c "import sys; v=sys.argv[1].strip(); print(int(v,0) if v else 0)" "$games" 2>/dev/null || echo "0")
      if (( games_dec >= 1 )); then
        pass "DisputeGameFactory gameCount=$games_dec"
      else
        skip "gameCount=0 (wait for proposer interval ~${PROPOSER_INTERVAL:-12s}, re-run)"
      fi
    else
      fail_item "gameCount() call failed on $factory"
    fi
  else
    fail_item "DisputeGameFactoryProxy missing in $deployments"
  fi

  echo
  echo "-- Guestbook deploy artifact --"
  if (( IS_SEPOLIA )); then
    skip "Guestbook is Phase 1 local demo UI — optional on Sepolia"
  else
    local gb=""
    if [[ -f "$FORTEL2_ROOT/deployments/guestbook.txt" ]]; then
      gb=$(tr -d '[:space:]' < "$FORTEL2_ROOT/deployments/guestbook.txt")
    fi
    if is_eth_address "$gb"; then
      local count
      count=$(cast call "$gb" "count()(uint256)" --rpc-url "$L2_RPC_URL" 2>/dev/null || echo "")
      if [[ -n "$count" ]]; then
        pass "Guestbook $gb count=$count"
      else
        fail_item "Guestbook at $gb not readable on L2 — redeploy?"
      fi
    else
      skip "Guestbook not deployed — ./scripts/deploy-guestbook.sh"
    fi
  fi

  echo
  echo "-- Viewer config --"
  if [[ -f "$FORTEL2_ROOT/viewer/config.js" ]] \
    && grep -q 'BATCH_INBOX_ADDRESS = "0x' "$FORTEL2_ROOT/viewer/config.js" \
    && grep -q 'DISPUTE_GAME_FACTORY = "0x' "$FORTEL2_ROOT/viewer/config.js"; then
    pass "viewer/config.js has inbox + factory addresses"
  else
    skip "viewer/config.js incomplete — ./scripts/gen-viewer-config.sh (or demo-live / serve-viewer)"
  fi

  echo
  echo "-- Unit / helper tests (no chain required beyond env) --"
  if "$SCRIPT_DIR/test-helpers.sh" >/tmp/fortel2-helpers-$$.log 2>&1; then
    pass "scripts/test-helpers.sh"
  else
    fail_item "scripts/test-helpers.sh (see /tmp/fortel2-helpers-$$.log)"
  fi
  if node --test "$FORTEL2_ROOT/viewer/lib.test.js" "$FORTEL2_ROOT/dapp/lib.test.js" \
    >/tmp/fortel2-viewer-$$.log 2>&1; then
    pass "viewer + dapp lib.test.js"
  else
    fail_item "viewer/dapp lib.test.js (see /tmp/fortel2-viewer-$$.log)"
  fi
  if [[ -d "$FORTEL2_ROOT/scripts/bridge/node_modules" ]]; then
    if (cd "$FORTEL2_ROOT/scripts/bridge" && node --test lib.test.js) \
      >/tmp/fortel2-bridge-$$.log 2>&1; then
      pass "scripts/bridge/lib.test.js"
    else
      fail_item "scripts/bridge/lib.test.js (see /tmp/fortel2-bridge-$$.log)"
    fi
  else
    skip "bridge unit tests — run: (cd scripts/bridge && npm ci && node --test lib.test.js)"
  fi

  echo
  if (( fail )); then
    echo "Automated checks: FAILED (fix stack items above, then re-run)"
    if (( IS_SEPOLIA )); then
      echo "Tip: FORTEL2_ENV=.env.sepolia ./scripts/status.sh && ./scripts/start-all-sepolia.sh"
    else
      echo "Tip: ./scripts/status.sh && ./scripts/start-all.sh"
    fi
    return 1
  fi
  echo "Automated checks: all critical items passed (SKIPs are optional waits)."
  if (( IS_SEPOLIA )); then
    info "Next: FORTEL2_ENV=.env.sepolia ./scripts/demo-checklist.sh --print"
    info "Or: FORTEL2_ENV=.env.sepolia ./scripts/demo-live.sh --sepolia"
  else
    info "Next: print checklist with ./scripts/demo-checklist.sh --print"
    info "Or: ./scripts/demo-live.sh --local"
  fi
  return 0
}

case "$MODE" in
  print)
    print_checklist
    ;;
  auto)
    run_auto
    ;;
  all)
    run_auto || true
    print_checklist
    if (( fail )); then
      exit 1
    fi
    ;;
esac
