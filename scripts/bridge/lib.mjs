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
import { readContract } from 'viem/actions'

export const MESSAGE_PASSER = '0x4200000000000000000000000000000000000016'

/** Ethereum Sepolia L1. Real-clock prove/finalize — no Anvil warp or evm_mine. */
export const SEPOLIA_L1_CHAIN_ID = 11155111

/** GameStatus: 0=IN_PROGRESS, 1=CHALLENGER_WINS, 2=DEFENDER_WINS */
export const GAME_IN_PROGRESS = 0
export const GAME_CHALLENGER_WINS = 1
export const GAME_DEFENDER_WINS = 2

/** Default cap for Sepolia finalize polling (2h). Override FINALIZE_REAL_CLOCK_MAX_WAIT_MS. */
export const FINALIZE_REAL_CLOCK_MAX_WAIT_MS_DEFAULT = 7_200_000
export const FINALIZE_REAL_CLOCK_POLL_MS_DEFAULT = 12_000

export const disputeGameAbi = parseAbi([
  'function status() view returns (uint8)',
  'function resolve() returns (uint8)',
  'function resolveClaim(uint256 challengeIndex, uint256 numToResolve)',
  'function claimDataLen() view returns (uint256)',
  'function l2BlockNumber() view returns (uint256)',
  // Duration is a uint64 wrapper; ABI surface is uint64 seconds.
  'function maxClockDuration() view returns (uint64)',
  'function resolvedAt() view returns (uint64)',
  'function createdAt() view returns (uint64)',
])

export const portalReadAbi = parseAbi([
  'function proofMaturityDelaySeconds() view returns (uint64)',
  'function disputeGameFinalityDelaySeconds() view returns (uint64)',
  'function finalizedWithdrawals(bytes32) view returns (bool)',
  'function provenWithdrawals(bytes32, address) view returns (address disputeGameProxy, uint64 timestamp)',
  'function numProofSubmitters(bytes32) view returns (uint256)',
  'function proofSubmitters(bytes32, uint256) view returns (address)',
  'function checkWithdrawal(bytes32 withdrawalHash, address proofSubmitter) view',
])

export const portalFinalizeAbi = parseAbi([
  'function finalizeWithdrawalTransaction((uint256 nonce, address sender, address target, uint256 value, uint256 gasLimit, bytes data) _tx)',
])

/** DisputeGameFactory — used to resolve game proxy (viem getGame does not return it). */
export const disputeGameFactoryAbi = parseAbi([
  'function gameAtIndex(uint256 index) view returns (uint32 gameType_, uint64 timestamp_, address proxy_)',
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
export function refuseAnvilWarp() {
  return (
    process.env.SKIP_ANVIL_WARP === '1' ||
    process.env.L1_CHAIN_ID === String(SEPOLIA_L1_CHAIN_ID)
  )
}

/** True when L1 is Ethereum Sepolia — poll real clocks, never evm_mine / warp. */
export function isRealClockL1(chainId = process.env.L1_CHAIN_ID) {
  return String(chainId) === String(SEPOLIA_L1_CHAIN_ID)
}

export function realClockMaxWaitMs() {
  return Number(process.env.FINALIZE_REAL_CLOCK_MAX_WAIT_MS || FINALIZE_REAL_CLOCK_MAX_WAIT_MS_DEFAULT)
}

export function realClockPollMs() {
  return Number(process.env.FINALIZE_REAL_CLOCK_POLL_MS || FINALIZE_REAL_CLOCK_POLL_MS_DEFAULT)
}

export async function increaseTime(publicClient, seconds) {
  if (refuseAnvilWarp()) {
    throw new Error(
      'refusing evm_increaseTime (SKIP_ANVIL_WARP=1 or L1_CHAIN_ID=11155111)',
    )
  }
  await publicClient.request({
    method: 'evm_increaseTime',
    params: [seconds],
  })
  await publicClient.request({
    method: 'evm_mine',
    params: [],
  })
}

export async function mineBlocks(publicClient, count) {
  if (refuseAnvilWarp()) {
    throw new Error(
      'refusing evm_mine (SKIP_ANVIL_WARP=1 or L1_CHAIN_ID=11155111)',
    )
  }
  for (let i = 0; i < count; i++) {
    await publicClient.request({
      method: 'evm_mine',
      params: [],
    })
  }
}

export function parseBridgeArgs(argv) {
  const rest = argv.slice(2)
  let dryRun = false
  const positional = []
  for (const a of rest) {
    if (a === '--dry-run') dryRun = true
    else positional.push(a)
  }
  return { dryRun, artifactPath: positional[0] }
}

export function readArtifactChainIds(artifact) {
  const l1 = artifact?.l1ChainId ?? artifact?.l1_chain_id
  const l2 = artifact?.l2ChainId ?? artifact?.l2_chain_id
  return {
    l1: l1 == null || l1 === '' ? null : Number(l1),
    l2: l2 == null || l2 === '' ? null : Number(l2),
  }
}

/**
 * Refuse a 901 artifact on 852 and vice versa when the artifact carries chain ids.
 * Missing both ids is allowed (legacy Anvil artifacts). One-of-two is incomplete.
 */
export function assertArtifactChainIds(artifact, envL1, envL2) {
  const { l1, l2 } = readArtifactChainIds(artifact)
  const hasAny = l1 != null || l2 != null
  const hasBoth = l1 != null && l2 != null
  if (hasAny && !hasBoth) {
    throw new Error('artifact has incomplete chain ids (need l1ChainId and l2ChainId)')
  }
  if (hasBoth && (l1 !== Number(envL1) || l2 !== Number(envL2))) {
    throw new Error(
      `artifact chain mismatch: artifact L1=${l1} L2=${l2} vs env L1=${envL1} L2=${envL2}`,
    )
  }
}

export function stampArtifactChainIds(artifact, envL1, envL2) {
  return {
    ...artifact,
    l1ChainId: Number(envL1),
    l2ChainId: Number(envL2),
  }
}

/** resolvedAt (unix s) + on-chain disputeGameFinalityDelaySeconds. */
export function finalizeReadyAt(resolvedAt, finalityDelaySeconds) {
  return Number(resolvedAt) + Number(finalityDelaySeconds)
}

export function realClockReached(l1HeadTimestamp, readyAt) {
  return Number(l1HeadTimestamp) >= Number(readyAt)
}

/**
 * Classify withdrawal readiness for --dry-run.
 * Verdicts: not-proven | proven-waiting-until-<ts> | finalizable | already-finalized
 */
export function classifyFinalizeReadiness({
  finalized,
  proven,
  gameStatus,
  resolvedAt,
  finalityDelaySeconds,
  l1HeadTimestamp,
  proofTimestamp,
  proofMaturityDelaySeconds,
  createdAt,
  maxClockDuration,
}) {
  if (finalized) {
    return { verdict: 'already-finalized', readyAt: null }
  }
  if (!proven) {
    return { verdict: 'not-proven', readyAt: null }
  }
  if (Number(gameStatus) === GAME_CHALLENGER_WINS) {
    return { verdict: 'not-proven', readyAt: null, error: 'CHALLENGER_WINS' }
  }

  let readyAt
  if (Number(gameStatus) !== GAME_DEFENDER_WINS) {
    if (createdAt != null && maxClockDuration != null) {
      readyAt = finalizeReadyAt(
        Number(createdAt) + Number(maxClockDuration),
        finalityDelaySeconds,
      )
    } else {
      readyAt = 0
    }
    return { verdict: `proven-waiting-until-${readyAt}`, readyAt }
  }

  readyAt = finalizeReadyAt(resolvedAt, finalityDelaySeconds)
  if (proofTimestamp != null && proofMaturityDelaySeconds != null) {
    const proofReady = Number(proofTimestamp) + Number(proofMaturityDelaySeconds)
    if (proofReady > readyAt) readyAt = proofReady
  }
  if (!realClockReached(l1HeadTimestamp, readyAt)) {
    return { verdict: `proven-waiting-until-${readyAt}`, readyAt }
  }
  return { verdict: 'finalizable', readyAt }
}

/** Prove --dry-run expected next step is not-proven. */
export function classifyProveReadiness({ finalized, proven }) {
  if (finalized) return { verdict: 'already-finalized', readyAt: null }
  if (proven) return { verdict: 'proven-waiting-until-0', readyAt: 0 }
  return { verdict: 'not-proven', readyAt: null }
}

export function dryRunExitCode(verdict, expectedVerdict) {
  return verdict === expectedVerdict ? 0 : 1
}

/**
 * Poll until DEFENDER_WINS and resolvedAt + finality delay have passed.
 * Inject getSnapshot / sleepFn / nowFn so tests can go red without RPC.
 */
export async function waitUntilRealClockReady({
  getSnapshot,
  maxWaitMs,
  pollMs,
  sleepFn = sleep,
  nowFn = Date.now,
}) {
  const deadline = nowFn() + Number(maxWaitMs)
  let last
  while (true) {
    const snap = await getSnapshot()
    last = classifyFinalizeReadiness(snap)
    if (last.verdict === 'finalizable') return last
    if (last.verdict === 'already-finalized' || last.verdict === 'not-proven') {
      return last
    }
    if (last.error === 'CHALLENGER_WINS') return last
    if (nowFn() >= deadline) {
      throw new Error(
        `real-clock wait exceeded ${maxWaitMs}ms (max FINALIZE_REAL_CLOCK_MAX_WAIT_MS); last verdict ${last.verdict}`,
      )
    }
    await sleepFn(Number(pollMs))
  }
}

export async function sleep(ms) {
  await new Promise((r) => setTimeout(r, ms))
}

/**
 * Normalize gameAtIndex return value (named object or positional tuple).
 * viem may return either shape depending on version.
 */
export function proxyFromGameAtIndexResult(result, gameIndex = 0) {
  const proxy = result?.proxy_ ?? result?.[2]
  if (!proxy || proxy === '0x0000000000000000000000000000000000000000') {
    throw new Error(`gameAtIndex(${gameIndex}) returned empty proxy`)
  }
  return proxy
}

/**
 * Resolve dispute-game proxy address from factory index.
 * viem getGame()/findLatestGames do not include `proxy` — only gameAtIndex does.
 */
export async function resolveGameProxy(publicClient, factoryAddress, gameIndex) {
  const result = await readContract(publicClient, {
    address: factoryAddress,
    abi: disputeGameFactoryAbi,
    functionName: 'gameAtIndex',
    args: [BigInt(gameIndex)],
  })
  return proxyFromGameAtIndexResult(result, gameIndex)
}
