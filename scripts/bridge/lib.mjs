/**
 * Shared viem clients + ForteL2 chain descriptors for Phase 1b withdrawals.
 */
import fs from 'node:fs'
import path from 'node:path'
import {
  createPublicClient,
  createWalletClient,
  http,
  defineChain,
  parseAbi,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'

export const MESSAGE_PASSER = '0x4200000000000000000000000000000000000016'

export const disputeGameAbi = parseAbi([
  'function status() view returns (uint8)',
  'function resolve() returns (uint8)',
  'function resolveClaim(uint256 challengeIndex, uint256 numToResolve)',
  'function claimDataLen() view returns (uint256)',
  'function l2BlockNumber() view returns (uint256)',
])

export function loadEnvFromShell() {
  // Parent bash scripts export env; process.env is enough.
  const required = [
    'L1_RPC_URL',
    'L2_RPC_URL',
    'L1_CHAIN_ID',
    'L2_CHAIN_ID',
    'ADMIN_ADDRESS',
    'ADMIN_PRIVATE_KEY',
  ]
  for (const k of required) {
    if (!process.env[k]) throw new Error(`missing env ${k}`)
  }
}

export function loadDeployments(path) {
  const j = JSON.parse(fs.readFileSync(path, 'utf8'))
  const portal = j.OptimismPortalProxy
  const factory = j.DisputeGameFactoryProxy
  if (!portal || !factory) throw new Error('deployments.json missing portal/factory')
  return { portal, factory }
}

export function makeChains({ portal, factory }) {
  const l1Id = Number(process.env.L1_CHAIN_ID)
  const l2Id = Number(process.env.L2_CHAIN_ID)
  const l1 = defineChain({
    id: l1Id,
    name: 'ForteL2-L1',
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [process.env.L1_RPC_URL] } },
  })
  const l2 = defineChain({
    id: l2Id,
    name: 'ForteL2-L2',
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [process.env.L2_RPC_URL] } },
    contracts: {
      portal: { [l1Id]: { address: portal } },
      disputeGameFactory: { [l1Id]: { address: factory } },
      l2ToL1MessagePasser: { address: MESSAGE_PASSER },
    },
    sourceId: l1Id,
  })
  return { l1, l2 }
}

export function makeClients(chains) {
  const account = privateKeyToAccount(process.env.ADMIN_PRIVATE_KEY)
  const publicL1 = createPublicClient({
    chain: chains.l1,
    transport: http(process.env.L1_RPC_URL),
  })
  const publicL2 = createPublicClient({
    chain: chains.l2,
    transport: http(process.env.L2_RPC_URL),
  })
  const walletL1 = createWalletClient({
    account,
    chain: chains.l1,
    transport: http(process.env.L1_RPC_URL),
  })
  return { account, publicL1, publicL2, walletL1 }
}

export function readJson(path) {
  return JSON.parse(fs.readFileSync(path, 'utf8'))
}

export function writeJson(filePath, obj) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true })
  fs.writeFileSync(filePath, JSON.stringify(obj, null, 2) + '\n')
}

/** Anvil / Hardhat time warp helpers via raw RPC. */
export async function increaseTime(publicClient, seconds) {
  await publicClient.request({
    method: 'evm_increaseTime',
    params: [seconds],
  })
  await publicClient.request({
    method: 'evm_mine',
    params: [],
  })
}

export async function sleep(ms) {
  await new Promise((r) => setTimeout(r, ms))
}
