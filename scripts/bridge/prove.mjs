#!/usr/bin/env node
/**
 * Wait for a dispute game covering the withdrawal, build proof, prove on OptimismPortal.
 * Usage: node prove.mjs <withdrawal.json>
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
} from './lib.mjs'
import {
  buildProveWithdrawal,
  getGame,
  getWithdrawals,
  proveWithdrawal,
} from 'viem/op-stack'
import { getTransactionReceipt } from 'viem/actions'

loadEnvFromShell()

const artifactPath = process.argv[2]
if (!artifactPath) {
  console.error('usage: node prove.mjs <withdrawal.json>')
  process.exit(1)
}

const here = path.dirname(fileURLToPath(import.meta.url))
const deploymentsPath =
  process.env.DEPLOYMENTS_JSON ||
  path.resolve(here, '../../deployments/deployments.json')

const artifact = readJson(artifactPath)
const { portal, factory } = loadDeployments(deploymentsPath)
const chains = makeChains({ portal, factory })
const { account, publicL1, publicL2, walletL1 } = makeClients(chains)

const l2Tx = artifact.l2TxHash
if (!l2Tx) throw new Error('withdrawal artifact missing l2TxHash')

const receipt = await getTransactionReceipt(publicL2, { hash: l2Tx })
const withdrawals = getWithdrawals({ logs: receipt.logs })
if (!withdrawals.length) throw new Error('no withdrawals in L2 receipt logs')
const withdrawal = withdrawals[0]

console.log('withdrawalHash', withdrawal.withdrawalHash)
console.log('l2BlockNumber', receipt.blockNumber.toString())
console.log('Waiting for dispute game after L2 block', receipt.blockNumber.toString(), '...')

const deadline = Date.now() + Number(process.env.PROVE_WAIT_MS || 180_000)
let game
while (Date.now() < deadline) {
  try {
    game = await getGame(publicL1, {
      l2BlockNumber: receipt.blockNumber,
      limit: 200,
      portalAddress: portal,
      disputeGameFactoryAddress: factory,
      targetChain: chains.l2,
      strategy: 'latest',
    })
    break
  } catch {
    await sleep(3000)
  }
}
if (!game) {
  console.error('ERROR: timed out waiting for dispute game (is op-proposer running?)')
  process.exit(1)
}

// viem Game type has no proxy; resolve via DisputeGameFactory.gameAtIndex.
const gameProxy = await resolveGameProxy(publicL1, factory, game.index)
console.log(
  'game index',
  game.index.toString(),
  'l2Block',
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
  maxFeePerGas: 1_500_000_000n,
  maxPriorityFeePerGas: 1_000_000_000n,
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
writeJson(artifactPath, artifact)
console.log('OK — proved. Updated', artifactPath)
