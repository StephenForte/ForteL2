#!/usr/bin/env node
/**
 * Resolve dispute game if needed, Anvil time-warp past maturity/finality delays, finalize withdrawal.
 * L1_CHAIN_ID=11155111: real-clock poll (no evm_mine / warp). --dry-run sends nothing.
 * Usage: node finalize.mjs <withdrawal.json> [--dry-run]
 */
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  loadEnvFromShell,
  loadDeployments,
  makeChains,
  makeClients,
  readJson,
  writeJson,
  increaseTime,
  mineBlocks,
  refuseAnvilWarp,
  isRealClockL1,
  disputeGameAbi,
  portalReadAbi,
  portalFinalizeAbi,
  sleep,
  resolveGameProxy,
  readProofTimestamp,
  parseBridgeArgs,
  assertArtifactChainIds,
  stampArtifactChainIds,
  classifyFinalizeReadiness,
  dryRunExitCode,
  waitUntilRealClockReady,
  realClockMaxWaitMs,
  realClockPollMs,
  GAME_IN_PROGRESS,
  GAME_CHALLENGER_WINS,
} from './lib.mjs'
import { finalizeWithdrawal } from 'viem/op-stack'
import { readContract, writeContract } from 'viem/actions'
import { parseAbi } from 'viem'

loadEnvFromShell()

function l1Fees() {
  return {
    maxFeePerGas: BigInt(process.env.L1_MAX_FEE_PER_GAS || 1_500_000_000),
    maxPriorityFeePerGas: BigInt(process.env.L1_MAX_PRIORITY_FEE_PER_GAS || 1_000_000_000),
  }
}

const { dryRun, artifactPath } = parseBridgeArgs(process.argv)
if (!artifactPath) {
  console.error('usage: node finalize.mjs <withdrawal.json> [--dry-run]')
  process.exit(1)
}

const here = path.dirname(fileURLToPath(import.meta.url))
const deploymentsPath =
  process.env.DEPLOYMENTS_JSON ||
  path.resolve(here, '../../deployments/deployments.json')

let artifact = readJson(artifactPath)
assertArtifactChainIds(artifact, process.env.L1_CHAIN_ID, process.env.L2_CHAIN_ID)
if (!artifact.proveTxHash || !artifact.withdrawal) {
  console.error('ERROR: artifact incomplete — run withdraw-prove.sh first')
  process.exit(1)
}

const { portal, factory } = loadDeployments(deploymentsPath)
const chains = makeChains({ portal, factory })
const { account, publicL1, walletL1 } = makeClients(chains)

// Older proves omitted gameProxy (viem getGame has no proxy field) — recover from index.
if (!artifact.gameProxy) {
  if (artifact.gameIndex == null) {
    console.error('ERROR: artifact missing gameProxy and gameIndex — re-run withdraw-prove.sh')
    process.exit(1)
  }
  artifact.gameProxy = await resolveGameProxy(publicL1, factory, artifact.gameIndex)
  if (!dryRun) {
    writeJson(artifactPath, artifact)
    console.log('recovered gameProxy from gameAtIndex:', artifact.gameProxy)
  }
}

const portalAbi = parseAbi([
  'function proofMaturityDelaySeconds() view returns (uint64)',
  'function disputeGameFinalityDelaySeconds() view returns (uint64)',
])

const proofDelay = await readContract(publicL1, {
  address: portal,
  abi: portalAbi,
  functionName: 'proofMaturityDelaySeconds',
})
const finalityDelay = await readContract(publicL1, {
  address: portal,
  abi: portalAbi,
  functionName: 'disputeGameFinalityDelaySeconds',
})
console.log(
  'portal delays: proofMaturityDelaySeconds=',
  proofDelay.toString(),
  'disputeGameFinalityDelaySeconds=',
  finalityDelay.toString(),
)

const withdrawalHash = artifact.withdrawal.withdrawalHash
const gameProxy = artifact.gameProxy

async function readGameFields() {
  const status = await readContract(publicL1, {
    address: gameProxy,
    abi: disputeGameAbi,
    functionName: 'status',
  })
  let resolvedAt = 0n
  let createdAt = 0n
  let maxClock = 0n
  try {
    resolvedAt = await readContract(publicL1, {
      address: gameProxy,
      abi: disputeGameAbi,
      functionName: 'resolvedAt',
    })
  } catch {
    resolvedAt = 0n
  }
  try {
    createdAt = await readContract(publicL1, {
      address: gameProxy,
      abi: disputeGameAbi,
      functionName: 'createdAt',
    })
  } catch {
    createdAt = 0n
  }
  try {
    maxClock = await readContract(publicL1, {
      address: gameProxy,
      abi: disputeGameAbi,
      functionName: 'maxClockDuration',
    })
  } catch {
    maxClock = 0n
  }
  return { status, resolvedAt, createdAt, maxClock }
}

async function readPortalFlags() {
  let finalized = false
  try {
    finalized = await readContract(publicL1, {
      address: portal,
      abi: portalReadAbi,
      functionName: 'finalizedWithdrawals',
      args: [withdrawalHash],
    })
  } catch (e) {
    console.log('finalizedWithdrawals note:', e?.shortMessage || e?.message || e)
  }
  return { finalized, proven: Boolean(artifact.proveTxHash) }
}

async function l1HeadTimestamp() {
  const block = await publicL1.getBlock()
  return Number(block.timestamp)
}

async function snapshot() {
  const { status, resolvedAt, createdAt, maxClock } = await readGameFields()
  const { finalized, proven } = await readPortalFlags()
  const head = await l1HeadTimestamp()
  const proofTimestamp = await readProofTimestamp(
    publicL1,
    portal,
    withdrawalHash,
    account.address,
  )
  return {
    finalized,
    proven,
    gameStatus: Number(status),
    resolvedAt: Number(resolvedAt),
    finalityDelaySeconds: Number(finalityDelay),
    l1HeadTimestamp: head,
    createdAt: Number(createdAt),
    maxClockDuration: Number(maxClock),
    proofTimestamp: proofTimestamp ?? (artifact.provenAt != null ? Number(artifact.provenAt) : null),
    proofMaturityDelaySeconds: Number(proofDelay),
  }
}

const w = artifact.withdrawal
const withdrawal = {
  nonce: BigInt(w.nonce),
  sender: w.sender,
  target: w.target,
  value: BigInt(w.value),
  gasLimit: BigInt(w.gasLimit),
  data: w.data,
  withdrawalHash: w.withdrawalHash,
}

async function simulatePortalFinalize() {
  try {
    await publicL1.simulateContract({
      address: portal,
      abi: portalFinalizeAbi,
      functionName: 'finalizeWithdrawalTransaction',
      args: [
        {
          nonce: withdrawal.nonce,
          sender: withdrawal.sender,
          target: withdrawal.target,
          value: withdrawal.value,
          gasLimit: withdrawal.gasLimit,
          data: withdrawal.data,
        },
      ],
      account: account.address,
    })
    console.log('portal eth_call: finalizeWithdrawalTransaction would succeed')
    return true
  } catch (e) {
    console.log('portal eth_call: finalizeWithdrawalTransaction revert:', e?.shortMessage || e?.message || e)
    return false
  }
}

if (dryRun) {
  const snap = await snapshot()
  const classification = classifyFinalizeReadiness(snap)
  console.log(
    'dry-run: no transaction sent; game status=',
    snap.gameStatus,
    'resolvedAt=',
    snap.resolvedAt,
    'l1Head=',
    snap.l1HeadTimestamp,
  )
  await simulatePortalFinalize()
  console.log('readiness:', classification.verdict)
  process.exit(dryRunExitCode(classification.verdict, 'finalizable'))
}

if (isRealClockL1()) {
  if (refuseAnvilWarp() !== true) {
    console.error('ERROR: Sepolia path must refuse Anvil warp')
    process.exit(1)
  }
  const maxWait = realClockMaxWaitMs()
  console.log(
    `real-clock mode (L1_CHAIN_ID=11155111): no evm_mine/warp; polling until DEFENDER_WINS and resolvedAt+delay (max ${maxWait}ms)`,
  )
  let classification
  try {
    classification = await waitUntilRealClockReady({
      getSnapshot: snapshot,
      maxWaitMs: maxWait,
      pollMs: realClockPollMs(),
    })
  } catch (e) {
    console.error('ERROR:', e?.message || e)
    process.exit(1)
  }
  console.log('readiness:', classification.verdict)
  // Send path: only finalizable. unknown-resolvedAt / waiting / already-finalized all refuse.
  if (classification.verdict !== 'finalizable') {
    console.error(
      `ERROR: refuse finalize — need DEFENDER_WINS + disputeGameFinalityDelaySeconds (got ${classification.verdict})`,
    )
    process.exit(1)
  }
} else {
  const gameProxyAnvil = artifact.gameProxy
  let status = await readContract(publicL1, {
    address: gameProxyAnvil,
    abi: disputeGameAbi,
    functionName: 'status',
  })
  // GameStatus: 0=IN_PROGRESS, 1=CHALLENGER_WINS, 2=DEFENDER_WINS
  console.log('game status before resolve:', status)

  if (status === GAME_IN_PROGRESS) {
    // Chess clock / max duration — warp using the game's on-chain immutable,
    // not FAULT_GAME_MAX_CLOCK_DURATION from env (deploy overrides may have been ignored).
    let maxClock
    try {
      maxClock = await readContract(publicL1, {
        address: gameProxyAnvil,
        abi: disputeGameAbi,
        functionName: 'maxClockDuration',
      })
    } catch (e) {
      const fallback = BigInt(process.env.FAULT_GAME_MAX_CLOCK_DURATION || 10)
      console.log(
        'maxClockDuration() unavailable — falling back to env FAULT_GAME_MAX_CLOCK_DURATION=',
        fallback.toString(),
        '(',
        e?.shortMessage || e?.message || e,
        ')',
      )
      maxClock = fallback
    }
    const clockBuffer = Number(process.env.FAULT_GAME_CLOCK_WARP_BUFFER || 30)
    const clockWarp = Number(maxClock) + clockBuffer
    if (refuseAnvilWarp()) {
      console.error(
        'ERROR: game IN_PROGRESS and Anvil warp is refused on this L1 — wait for the clock, then re-run',
      )
      process.exit(1)
    }
    console.log(
      `game IN_PROGRESS — on-chain maxClockDuration=${maxClock.toString()}s; Anvil +${clockWarp}s then resolveClaim/resolve`,
    )
    await increaseTime(publicL1, clockWarp)
    await mineBlocks(publicL1, 2)
    try {
      const rcHash = await writeContract(walletL1, {
        address: gameProxyAnvil,
        abi: disputeGameAbi,
        functionName: 'resolveClaim',
        args: [0n, 0n],
        account,
        ...l1Fees(),
      })
      await publicL1.waitForTransactionReceipt({ hash: rcHash })
      console.log('resolveClaim tx:', rcHash)
    } catch (e) {
      console.log('resolveClaim note:', e?.shortMessage || e?.message || e)
    }
    try {
      const rHash = await writeContract(walletL1, {
        address: gameProxyAnvil,
        abi: disputeGameAbi,
        functionName: 'resolve',
        args: [],
        account,
        ...l1Fees(),
      })
      await publicL1.waitForTransactionReceipt({ hash: rHash })
      console.log('resolve tx:', rHash)
    } catch (e) {
      console.log('resolve note:', e?.shortMessage || e?.message || e)
    }
    status = await readContract(publicL1, {
      address: gameProxyAnvil,
      abi: disputeGameAbi,
      functionName: 'status',
    })
    console.log('game status after resolve:', status)
    if (status === GAME_IN_PROGRESS) {
      console.error(
        'ERROR: dispute game still IN_PROGRESS after maxClockDuration warp — cannot finalize',
      )
      process.exit(1)
    }
  }

  if (status === GAME_CHALLENGER_WINS) {
    console.error('ERROR: dispute game CHALLENGER_WINS — cannot finalize')
    process.exit(1)
  }

  // Warp past proof maturity + dispute-game finality air-gap (+ buffer).
  // Sepolia / SKIP_ANVIL_WARP=1: wait real portal clocks (D-0116).
  const warp =
    Number(proofDelay) + Number(finalityDelay) + Number(process.env.FINALIZE_WARP_BUFFER || 30)
  if (refuseAnvilWarp()) {
    console.log('skipping Anvil time-warp (Sepolia or SKIP_ANVIL_WARP=1); using wall-clock delays')
  } else {
    console.log(`Anvil time-warp +${warp}s for maturity/finality`)
    await increaseTime(publicL1, warp)
    await mineBlocks(publicL1, 3)
  }
}

const before = await publicL1.getBalance({ address: artifact.target || withdrawal.target })
console.log('L1 target balance before:', before.toString())

let finalizeHash
try {
  finalizeHash = await finalizeWithdrawal(walletL1, {
    account,
    portalAddress: portal,
    targetChain: chains.l2,
    withdrawal,
    ...l1Fees(),
  })
} catch (e) {
  console.error('finalizeWithdrawal failed:', e?.shortMessage || e?.message || e)
  // Retry once after another warp (mainnet-scale delays if overrides were ignored).
  if (Number(proofDelay) >= 86_400 && !refuseAnvilWarp()) {
    console.log('Long delay detected — warping +7d+3.5d buffer and retrying once')
    await increaseTime(publicL1, 604_800 + 302_400 + 120)
    await mineBlocks(publicL1, 3)
    finalizeHash = await finalizeWithdrawal(walletL1, {
      account,
      portalAddress: portal,
      targetChain: chains.l2,
      withdrawal,
      ...l1Fees(),
    })
  } else {
    process.exit(1)
  }
}

console.log('L1 finalize tx:', finalizeHash)
const finReceipt = await publicL1.waitForTransactionReceipt({ hash: finalizeHash })
if (finReceipt.status !== 'success') {
  console.error('ERROR: finalize tx reverted')
  process.exit(1)
}

// Give Anvil a beat; balance should include withdrawn ETH (minus gas paid by ADMIN if same addr).
await sleep(500)
const after = await publicL1.getBalance({ address: withdrawal.target })
console.log('L1 target balance after:', after.toString())

artifact.finalizeTxHash = finalizeHash
artifact.finalizedAt = Math.floor(Date.now() / 1000)
artifact = stampArtifactChainIds(artifact, process.env.L1_CHAIN_ID, process.env.L2_CHAIN_ID)
writeJson(artifactPath, artifact)

console.log('Hashes:')
console.log('  initiate (L2):', artifact.l2TxHash)
console.log('  prove (L1):   ', artifact.proveTxHash)
console.log('  finalize (L1):', finalizeHash)
console.log('OK — withdrawal finalized.')
