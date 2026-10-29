#!/usr/bin/env node
/**
 * Wait for a dispute game covering the withdrawal, build proof, prove on OptimismPortal.
 * Usage: node prove.mjs <withdrawal.json> [--dry-run]
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
  sleep,
  resolveGameProxy,
  parseBridgeArgs,
  assertArtifactChainIds,
  assertRemoteL1ChainId,
  stampArtifactChainIds,
  selectCoveringGame,
  SUPER_ROOT_GAME_TYPE,
  classifyProveReadiness,
  classifyFinalizeReadiness,
  dryRunExitCode,
  portalReadAbi,
  disputeGameAbi,
  readProofTimestamp,
} from './lib.mjs'
import {
  buildProveWithdrawal,
  getWithdrawals,
  proveWithdrawal,
} from 'viem/op-stack'
import { getBlock, getTransactionReceipt, readContract } from 'viem/actions'
import { parseAbi } from 'viem'

loadEnvFromShell()

const { dryRun, artifactPath } = parseBridgeArgs(process.argv)
if (!artifactPath) {
  console.error('usage: node prove.mjs <withdrawal.json> [--dry-run]')
  process.exit(1)
}

const here = path.dirname(fileURLToPath(import.meta.url))
const deploymentsPath =
  process.env.DEPLOYMENTS_JSON ||
  path.resolve(here, '../../deployments/deployments.json')

const artifact = readJson(artifactPath)
assertRemoteL1ChainId(process.env.L1_CHAIN_ID, process.env.L1_RPC_URL)
assertArtifactChainIds(artifact, process.env.L1_CHAIN_ID, process.env.L2_CHAIN_ID)
const { portal, factory } = loadDeployments(deploymentsPath)
const chains = makeChains({ portal, factory })
const { account, publicL1, publicL2, walletL1 } = makeClients(chains)

const l2Tx = artifact.l2TxHash
if (!l2Tx) throw new Error('withdrawal artifact missing l2TxHash')

const respectedGameTypeAbi = parseAbi([
  'function respectedGameType() view returns (uint32)',
])
const factoryScanAbi = parseAbi([
  'function gameCount() view returns (uint256)',
  'function gameAtIndex(uint256) view returns (uint32 gameType, uint64 timestamp, address proxy)',
])
const sequenceAbi = parseAbi([
  'function l2SequenceNumber() view returns (uint256)',
])

/**
 * Newest-first games of one type. eth_call only: viem getGames multicalls,
 * and our chain object does not advertise multicall3.
 */
async function listRecentGames(gameType, limit = 100) {
  const count = await readContract(publicL1, {
    address: factory,
    abi: factoryScanAbi,
    functionName: 'gameCount',
  })
  const games = []
  const start = count > BigInt(limit) ? count - BigInt(limit) : 0n
  for (let i = count; i > start; i--) {
    const index = i - 1n
    const row = await readContract(publicL1, {
      address: factory,
      abi: factoryScanAbi,
      functionName: 'gameAtIndex',
      args: [index],
    })
    if (Number(row[0]) !== gameType) continue
    const sequence = await readContract(publicL1, {
      address: row[2],
      abi: sequenceAbi,
      functionName: 'l2SequenceNumber',
    })
    games.push({
      index,
      gameType,
      l2BlockNumber: sequence,
      usesSuperRoots: gameType === SUPER_ROOT_GAME_TYPE,
    })
  }
  return games
}

async function readRespectedGameType() {
  try {
    const value = await readContract(publicL1, {
      address: portal,
      abi: respectedGameTypeAbi,
      functionName: 'respectedGameType',
    })
    return Number(value)
  } catch {
    return null
  }
}

/**
 * Type 9: compare the game timestamp to the withdrawal block's timestamp and
 * let viem build the proof at the L2 block for that timestamp (usesSuperRoots).
 * Any other respected type uses the same strict-greater block comparison as viem getGame.
 */
async function findCoveringGame(receipt) {
  const respected = await readRespectedGameType()
  if (respected == null) throw new Error('could not read portal.respectedGameType')
  if (respected !== SUPER_ROOT_GAME_TYPE) {
    const games = await listRecentGames(respected)
    const game = games.find((item) => item.l2BlockNumber > receipt.blockNumber)
    if (!game) {
      const err = new Error('no dispute game covers the withdrawal block')
      err.name = 'GameNotFoundError'
      throw err
    }
    return game
  }
  const block = await getBlock(publicL2, { blockNumber: receipt.blockNumber })
  const games = await listRecentGames(SUPER_ROOT_GAME_TYPE)
  const game = selectCoveringGame(games, {
    gameType: SUPER_ROOT_GAME_TYPE,
    withdrawalBlock: receipt.blockNumber,
    withdrawalTimestamp: block.timestamp,
  })
  if (!game) {
    const err = new Error('no type-9 game covers the withdrawal timestamp')
    err.name = 'GameNotFoundError'
    throw err
  }
  return game
}

const receipt = await getTransactionReceipt(publicL2, { hash: l2Tx })
const withdrawals = getWithdrawals({ logs: receipt.logs })
if (!withdrawals.length) throw new Error('no withdrawals in L2 receipt logs')
const withdrawal = withdrawals[0]

console.log('withdrawalHash', withdrawal.withdrawalHash)

if (dryRun) {
  let finalized = false
  try {
    finalized = await readContract(publicL1, {
      address: portal,
      abi: portalReadAbi,
      functionName: 'finalizedWithdrawals',
      args: [withdrawal.withdrawalHash],
    })
  } catch (e) {
    console.log('finalizedWithdrawals note:', e?.shortMessage || e?.message || e)
  }
  const proven = Boolean(artifact.proveTxHash)
  let classification = classifyProveReadiness({ finalized, proven })
  if (proven && !finalized && artifact.gameProxy) {
    try {
      const status = await readContract(publicL1, {
        address: artifact.gameProxy,
        abi: disputeGameAbi,
        functionName: 'status',
      })
      let resolvedAt = 0n
      try {
        resolvedAt = await readContract(publicL1, {
          address: artifact.gameProxy,
          abi: disputeGameAbi,
          functionName: 'resolvedAt',
        })
      } catch {
        resolvedAt = 0n
      }
      const finalityDelay = await readContract(publicL1, {
        address: portal,
        abi: portalReadAbi,
        functionName: 'disputeGameFinalityDelaySeconds',
      })
      const proofMaturity = await readContract(publicL1, {
        address: portal,
        abi: portalReadAbi,
        functionName: 'proofMaturityDelaySeconds',
      })
      const proofTimestamp = await readProofTimestamp(
        publicL1,
        portal,
        withdrawal.withdrawalHash,
        account.address,
      )
      const block = await publicL1.getBlock()
      classification = classifyFinalizeReadiness({
        finalized,
        proven,
        gameStatus: Number(status),
        resolvedAt: Number(resolvedAt),
        finalityDelaySeconds: Number(finalityDelay),
        l1HeadTimestamp: Number(block.timestamp),
        proofTimestamp: proofTimestamp ?? (artifact.provenAt != null ? Number(artifact.provenAt) : null),
        proofMaturityDelaySeconds: Number(proofMaturity),
      })
    } catch (e) {
      console.log('game/portal classify note:', e?.shortMessage || e?.message || e)
    }
  }
  try {
    const game = await findCoveringGame(receipt)
    const proveArgs = await buildProveWithdrawal(publicL2, {
      account,
      game,
      withdrawal,
    })
    await publicL1.simulateContract({
      account: account.address,
      address: portal,
      abi: [
        {
          type: 'function',
          name: 'proveWithdrawalTransaction',
          stateMutability: 'nonpayable',
          inputs: [
            {
              name: '_tx',
              type: 'tuple',
              components: [
                { name: 'nonce', type: 'uint256' },
                { name: 'sender', type: 'address' },
                { name: 'target', type: 'address' },
                { name: 'value', type: 'uint256' },
                { name: 'gasLimit', type: 'uint256' },
                { name: 'data', type: 'bytes' },
              ],
            },
            { name: '_disputeGameIndex', type: 'uint256' },
            {
              name: '_outputRootProof',
              type: 'tuple',
              components: [
                { name: 'version', type: 'bytes32' },
                { name: 'stateRoot', type: 'bytes32' },
                { name: 'messagePasserStorageRoot', type: 'bytes32' },
                { name: 'latestBlockhash', type: 'bytes32' },
              ],
            },
            { name: '_withdrawalProof', type: 'bytes[]' },
          ],
          outputs: [],
        },
      ],
      functionName: 'proveWithdrawalTransaction',
      args: [
        {
          nonce: proveArgs.withdrawal.nonce,
          sender: proveArgs.withdrawal.sender,
          target: proveArgs.withdrawal.target,
          value: proveArgs.withdrawal.value,
          gasLimit: proveArgs.withdrawal.gasLimit,
          data: proveArgs.withdrawal.data,
        },
        proveArgs.l2OutputIndex,
        proveArgs.outputRootProof,
        proveArgs.withdrawalProof,
      ],
    })
    console.log('portal eth_call: proveWithdrawalTransaction would succeed')
  } catch (e) {
    console.log(
      'portal eth_call: proveWithdrawalTransaction revert:',
      e?.shortMessage || e?.message || e,
    )
  }
  console.log('dry-run: no transaction sent')
  console.log('readiness:', classification.verdict)
  process.exit(dryRunExitCode(classification.verdict, 'not-proven'))
}
console.log('l2BlockNumber', receipt.blockNumber.toString())
console.log('Waiting for dispute game after L2 block', receipt.blockNumber.toString(), '...')

const deadline = Date.now() + Number(process.env.PROVE_WAIT_MS || 180_000)
let game
let lastGameError = ''
while (Date.now() < deadline) {
  try {
    game = await findCoveringGame(receipt)
    break
  } catch (err) {
    lastGameError = err?.shortMessage || err?.message || String(err)
    await sleep(3000)
  }
}
if (!game) {
  console.error('ERROR: timed out waiting for dispute game (is op-proposer running?)')
  if (lastGameError) console.error(lastGameError)
  process.exit(1)
}

// viem Game type has no proxy; resolve via DisputeGameFactory.gameAtIndex.
const gameProxy = await resolveGameProxy(publicL1, factory, game.index)
console.log(
  'game index',
  game.index.toString(),
  game.usesSuperRoots ? 'l2Timestamp' : 'l2Block',
  game.l2BlockNumber.toString(),
  'proxy',
  gameProxy,
)

const proveArgs = await buildProveWithdrawal(publicL2, {
  account,
  game,
  withdrawal,
})

const proveHash = await proveWithdrawal(walletL1, {
  account,
  portalAddress: portal,
  targetChain: chains.l2,
  l2OutputIndex: proveArgs.l2OutputIndex,
  outputRootProof: proveArgs.outputRootProof,
  withdrawalProof: proveArgs.withdrawalProof,
  withdrawal: proveArgs.withdrawal,
  // Local Anvil fees can be zero; pin a floor so the tx is accepted.
  // Sepolia: override L1_MAX_FEE_PER_GAS / L1_MAX_PRIORITY_FEE_PER_GAS if base fee is higher.
  maxFeePerGas: BigInt(process.env.L1_MAX_FEE_PER_GAS || 1_500_000_000),
  maxPriorityFeePerGas: BigInt(process.env.L1_MAX_PRIORITY_FEE_PER_GAS || 1_000_000_000),
})

console.log('L1 prove tx:', proveHash)
const proveReceipt = await publicL1.waitForTransactionReceipt({ hash: proveHash })
if (proveReceipt.status !== 'success') {
  console.error('ERROR: prove tx reverted')
  process.exit(1)
}

artifact.withdrawal = {
  nonce: withdrawal.nonce.toString(),
  sender: withdrawal.sender,
  target: withdrawal.target,
  value: withdrawal.value.toString(),
  gasLimit: withdrawal.gasLimit.toString(),
  data: withdrawal.data,
  withdrawalHash: withdrawal.withdrawalHash,
}
artifact.l2BlockNumber = receipt.blockNumber.toString()
artifact.gameIndex = game.index.toString()
artifact.gameProxy = gameProxy
artifact.proveTxHash = proveHash
artifact.provenAt = Math.floor(Date.now() / 1000)
Object.assign(
  artifact,
  stampArtifactChainIds(artifact, process.env.L1_CHAIN_ID, process.env.L2_CHAIN_ID),
)
writeJson(artifactPath, artifact)
console.log('OK — proved. Updated', artifactPath)
