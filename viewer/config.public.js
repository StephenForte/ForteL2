/**
 * Public read-only pipeline viewer — committed constants only.
 * Never generate this file from .env, .env.sepolia, or viewer/config.js.
 * Origins must stay inside viewer/lib.js PUBLIC_VIEWER_ALLOWED_ORIGINS (D-0047).
 */
export const PUBLIC_MODE = true;

export const L1_CHAIN_ID = 11155111;
export const L2_CHAIN_ID = 852;

export const L1_RPC_URL = "https://ethereum-sepolia-rpc.publicnode.com";
export const L2_RPC_URL = "https://fortel2-replica-rpc.onrender.com";
export const L2_SEQUENCER_RPC_URL = "https://fortel2-sequencer-rpc.onrender.com";
/** Unused in public mode (op-node is not a D-0047 origin). */
export const L2_NODE_RPC_URL = "";

// Public on-chain roles (rollup.json / DisputeGameFactory / rail-interface.json).
export const BATCHER_ADDRESS = "0x3d54fd6353cd66d143fb94d178c9eeb1ae98a31d";
export const PROPOSER_ADDRESS = "0x350A0F7becCE56598962C501CaA02f900F256803";
export const BATCH_INBOX_ADDRESS = "0x007238ac625e3e5369739fa5b9cdbf61320b237c";
export const DISPUTE_GAME_FACTORY = "0x67f9e427c716586ecc0dc0b62baa8cd05e43262f";

export const DISPUTE_GAME_FACTORY_ABI = [
  "function gameCount() view returns (uint256)",
  "function gameAtIndex(uint256 index) view returns (uint32 gameType_, uint64 timestamp_, address proxy_)",
];

/** Free-tier gateways; floor is also enforced by viewerRefreshMs(..., publicMode). */
export const REFRESH_MS = 30000;
