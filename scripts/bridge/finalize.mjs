#!/usr/bin/env node
/**
 * Resolve dispute game if needed, Anvil time-warp past maturity/finality delays, finalize withdrawal.
 * Usage: node finalize.mjs <withdrawal.json>
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
  disputeGameAbi,
  sleep,
} from './lib.mjs'
import { finalizeWithdrawal } from 'viem/op-stack'
import { readContract, writeContract } from 'viem/actions'
import { parseAbi } from 'viem'

loadEnvFromShell()

const artifactPath = process.argv[2]
if (!artifactPath) {
  console.error('usage: node finalize.mjs <withdrawal.json>')
  process.exit(1)
}

const here = path.dirname(fileURLToPath(import.meta.url))
const deploymentsPath =
  process.env.DEPLOYMENTS_JSON ||
  path.resolve(here, '../../deployments/deployments.json')

const artifact = readJson(artifactPath)
if (!artifact.proveTxHash || !artifact.withdrawal || !artifact.gameProxy) {
  console.error('ERROR: artifact incomplete — run withdraw-prove.sh first')
  process.exit(1)
}

const { portal, factory } = loadDeployments(deploymentsPath)
const chains = makeChains({ portal, factory })
const { account, publicL1, walletL1 } = makeClients(chains)

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

const gameProxy = artifact.gameProxy
let status = await readContract(publicL1, {
  address: gameProxy,
  abi: disputeGameAbi,
  functionName: 'status',
})
// GameStatus: 0=IN_PROGRESS, 1=CHALLENGER_WINS, 2=DEFENDER_WINS
console.log('game status before resolve:', status)

if (status === 0) {
  // Chess clock / max duration — warp using the game's on-chain immutable,
  // not FAULT_GAME_MAX_CLOCK_DURATION from env (deploy overrides may have been ignored).
  let maxClock
  try {
    maxClock = await readContract(publicL1, {
      address: gameProxy,
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
  console.log(
    `game IN_PROGRESS — on-chain maxClockDuration=${maxClock.toString()}s; Anvil +${clockWarp}s then resolveClaim/resolve`,
  )
  await increaseTime(publicL1, clockWarp)
  for (let i = 0; i < 2; i++) {
    await publicL1.request({ method: 'evm_mine', params: [] })
  }
  try {
    const rcHash = await writeContract(walletL1, {
      address: gameProxy,
      abi: disputeGameAbi,
      functionName: 'resolveClaim',
      args: [0n, 0n],
      account,
      maxFeePerGas: 1_500_000_000n,
      maxPriorityFeePerGas: 1_000_000_000n,
    })
    await publicL1.waitForTransactionReceipt({ hash: rcHash })
    console.log('resolveClaim tx:', rcHash)
  } catch (e) {
    console.log('resolveClaim note:', e?.shortMessage || e?.message || e)
  }
  try {
    const rHash = await writeContract(walletL1, {
      address: gameProxy,
      abi: disputeGameAbi,
      functionName: 'resolve',
      args: [],
      account,
      maxFeePerGas: 1_500_000_000n,
      maxPriorityFeePerGas: 1_000_000_000n,
    })
    await publicL1.waitForTransactionReceipt({ hash: rHash })
    console.log('resolve tx:', rHash)
  } catch (e) {
    console.log('resolve note:', e?.shortMessage || e?.message || e)
  }
  status = await readContract(publicL1, {
    address: gameProxy,
    abi: disputeGameAbi,
    functionName: 'status',
  })
  console.log('game status after resolve:', status)
  if (status === 0) {
    console.error(
      'ERROR: dispute game still IN_PROGRESS after maxClockDuration warp — cannot finalize',
    )
    process.exit(1)
  }
}

// Warp past proof maturity + dispute-game finality air-gap (+ buffer).
const warp =
  Number(proofDelay) + Number(finalityDelay) + Number(process.env.FINALIZE_WARP_BUFFER || 30)
console.log(`Anvil time-warp +${warp}s for maturity/finality`)
await increaseTime(publicL1, warp)
// Mine a few L1 blocks so portal timestamp checks see the new time.
for (let i = 0; i < 3; i++) {
  await publicL1.request({ method: 'evm_mine', params: [] })
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

const before = await publicL1.getBalance({ address: artifact.target || withdrawal.target })
console.log('L1 target balance before:', before.toString())

let finalizeHash
try {
  finalizeHash = await finalizeWithdrawal(walletL1, {
    account,
    portalAddress: portal,
    targetChain: chains.l2,
    withdrawal,
    maxFeePerGas: 1_500_000_000n,
    maxPriorityFeePerGas: 1_000_000_000n,
  })
} catch (e) {
  console.error('finalizeWithdrawal failed:', e?.shortMessage || e?.message || e)
  // Retry once after another warp (mainnet-scale delays if overrides were ignored).
  if (Number(proofDelay) >= 86_400) {
    console.log('Long delay detected — warping +7d+3.5d buffer and retrying once')
    await increaseTime(publicL1, 604_800 + 302_400 + 120)
    for (let i = 0; i < 3; i++) {
      await publicL1.request({ method: 'evm_mine', params: [] })
    }
    finalizeHash = await finalizeWithdrawal(walletL1, {
      account,
      portalAddress: portal,
      targetChain: chains.l2,
      withdrawal,
      maxFeePerGas: 1_500_000_000n,
      maxPriorityFeePerGas: 1_000_000_000n,
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
writeJson(artifactPath, artifact)

console.log('Hashes:')
console.log('  initiate (L2):', artifact.l2TxHash)
console.log('  prove (L1):   ', artifact.proveTxHash)
console.log('  finalize (L1):', finalizeHash)
console.log('OK — withdrawal finalized.')
