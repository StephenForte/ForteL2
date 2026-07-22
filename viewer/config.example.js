/** Example viewer config — copy via: ./scripts/gen-viewer-config.sh
 *  (or FORTEL2_ENV=.env.sepolia ./scripts/gen-viewer-config.sh)
 *  Generated viewer/config.js is gitignored (may contain private L1 RPC URLs).
 */
export const L1_CHAIN_ID = 900;
export const L2_CHAIN_ID = 901;
export const L1_RPC_URL = "http://127.0.0.1:8545";
export const L2_RPC_URL = "http://127.0.0.1:9545";
export const L2_NODE_RPC_URL = "http://127.0.0.1:9547";

export const BATCHER_ADDRESS = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
export const PROPOSER_ADDRESS = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC";
export const BATCH_INBOX_ADDRESS = "0x0000000000000000000000000000000000000000";
export const DISPUTE_GAME_FACTORY = "0x0000000000000000000000000000000000000000";

export const DISPUTE_GAME_FACTORY_ABI = [
  "function gameCount() view returns (uint256)",
  "function gameAtIndex(uint256 index) view returns (uint32 gameType_, uint64 timestamp_, address proxy_)",
];

export const REFRESH_MS = 5000;
