package proposer

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"math"
	"math/big"
	"sort"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

const (
	// SuperRootVersionV1 is Encoding.sol / op-service SuperRootVersionV1 (0x01).
	SuperRootVersionV1 byte = 0x01
	// GameTypeSuperCannonKona is GameTypes.SUPER_CANNON_KONA in op-contracts v8.
	// Its extraData is a super-root preimage and l2SequenceNumber() is an L2 timestamp.
	GameTypeSuperCannonKona uint32 = 9
	// SuperRootOneChainLen is version ‖ uint64 timestamp ‖ uint256 chainId ‖ bytes32 outputRoot.
	SuperRootOneChainLen = 73
	// chainOutputLen is uint256 chainId ‖ bytes32 output root.
	chainOutputLen = 64
)

// ChainOutput is one chain's output root inside a super-root preimage.
type ChainOutput struct {
	ChainID    uint64
	OutputRoot common.Hash
}

// SuperRoot is the preimage DisputeGameFactory.create expects for a type-9 game
// and the keccak the game stores as rootClaim.
type SuperRoot struct {
	Timestamp uint64
	Chains    []ChainOutput
	Preimage  []byte
	Hash      common.Hash
}

// RollupClock is the L2 time base. Both fields come from rollup.json or
// optimism_rollupConfig — never a baked-in block time.
type RollupClock struct {
	GenesisTime uint64
	BlockTime   uint64
	L2ChainID   uint64
}

// EncodeSuperRoot builds the v1 super-root preimage and its keccak.
// Chains are sorted by chain id, matching op-node NewSuperV1 and
// Encoding.encodeSuperRootProof. One chain is 73 bytes; a list is supported.
func EncodeSuperRoot(timestamp uint64, chains []ChainOutput) (SuperRoot, error) {
	if len(chains) == 0 {
		return SuperRoot{}, fmt.Errorf("super root requires at least one chain")
	}
	sorted := append([]ChainOutput(nil), chains...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].ChainID < sorted[j].ChainID })
	for i := 1; i < len(sorted); i++ {
		if sorted[i].ChainID == sorted[i-1].ChainID {
			return SuperRoot{}, fmt.Errorf("duplicate chain id %d", sorted[i].ChainID)
		}
	}
	buf := make([]byte, 0, 9+len(sorted)*chainOutputLen)
	buf = append(buf, SuperRootVersionV1)
	var ts [8]byte
	binary.BigEndian.PutUint64(ts[:], timestamp)
	buf = append(buf, ts[:]...)
	for _, c := range sorted {
		var cid [32]byte
		binary.BigEndian.PutUint64(cid[24:], c.ChainID)
		buf = append(buf, cid[:]...)
		buf = append(buf, c.OutputRoot[:]...)
	}
	pre := append([]byte(nil), buf...)
	return SuperRoot{
		Timestamp: timestamp,
		Chains:    sorted,
		Preimage:  pre,
		Hash:      crypto.Keccak256Hash(pre),
	}, nil
}

// DecodeSuperRoot parses a v1 super-root preimage. A 32-byte output-root
// extraData does not decode. The returned hash is keccak256(preimage).
func DecodeSuperRoot(preimage []byte) (SuperRoot, error) {
	if len(preimage) < 9+chainOutputLen {
		return SuperRoot{}, fmt.Errorf("super root preimage length %d, want at least %d", len(preimage), 9+chainOutputLen)
	}
	if preimage[0] != SuperRootVersionV1 {
		return SuperRoot{}, fmt.Errorf("super root version 0x%02x, want 0x%02x", preimage[0], SuperRootVersionV1)
	}
	if (len(preimage)-9)%chainOutputLen != 0 {
		return SuperRoot{}, fmt.Errorf("super root preimage length %d is not 9+n*64", len(preimage))
	}
	ts := binary.BigEndian.Uint64(preimage[1:9])
	var chains []ChainOutput
	for i := 9; i < len(preimage); i += chainOutputLen {
		cidWord := preimage[i : i+32]
		for _, b := range cidWord[:24] {
			if b != 0 {
				return SuperRoot{}, fmt.Errorf("chain id does not fit uint64")
			}
		}
		var root common.Hash
		copy(root[:], preimage[i+32:i+64])
		chains = append(chains, ChainOutput{
			ChainID:    binary.BigEndian.Uint64(cidWord[24:]),
			OutputRoot: root,
		})
	}
	pre := append([]byte(nil), preimage...)
	return SuperRoot{
		Timestamp: ts,
		Chains:    chains,
		Preimage:  pre,
		Hash:      crypto.Keccak256Hash(pre),
	}, nil
}

// L2BlockForTimestamp maps an L2 timestamp to a block number.
// A timestamp that is not an exact block boundary is an error, not a round.
func L2BlockForTimestamp(genesisTime, blockTime, timestamp uint64) (uint64, error) {
	if blockTime == 0 {
		return 0, fmt.Errorf("block time is zero")
	}
	if timestamp < genesisTime {
		return 0, fmt.Errorf("timestamp %d is before L2 genesis %d", timestamp, genesisTime)
	}
	delta := timestamp - genesisTime
	if delta%blockTime != 0 {
		return 0, fmt.Errorf("timestamp %d is not on a block boundary (genesis %d, block time %d)", timestamp, genesisTime, blockTime)
	}
	return delta / blockTime, nil
}

// TimestampForL2Block is the inverse of L2BlockForTimestamp.
func TimestampForL2Block(genesisTime, blockTime, block uint64) (uint64, error) {
	if blockTime == 0 {
		return 0, fmt.Errorf("block time is zero")
	}
	if block > 0 && block > (math.MaxUint64-genesisTime)/blockTime {
		return 0, fmt.Errorf("timestamp overflow for block %d", block)
	}
	return genesisTime + block*blockTime, nil
}

// FetchRollupClock reads genesis l2_time, block_time, and l2_chain_id from
// op-node optimism_rollupConfig.
func FetchRollupClock(ctx context.Context, rollupRPC string) (RollupClock, error) {
	raw, err := RPCCall(ctx, rollupRPC, "optimism_rollupConfig", []interface{}{})
	if err != nil {
		return RollupClock{}, err
	}
	var cfg struct {
		Genesis struct {
			L2Time uint64 `json:"l2_time"`
		} `json:"genesis"`
		BlockTime uint64 `json:"block_time"`
		L2ChainID uint64 `json:"l2_chain_id"`
	}
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return RollupClock{}, fmt.Errorf("rollup config: %w", err)
	}
	if cfg.BlockTime == 0 {
		return RollupClock{}, fmt.Errorf("rollup config missing block_time")
	}
	if cfg.L2ChainID == 0 {
		return RollupClock{}, fmt.Errorf("rollup config missing l2_chain_id")
	}
	return RollupClock{
		GenesisTime: cfg.Genesis.L2Time,
		BlockTime:   cfg.BlockTime,
		L2ChainID:   cfg.L2ChainID,
	}, nil
}

// SuperRootForBlock fetches the output root at block and encodes the super root
// at that block's timestamp. block > nodeHead is an error (nodeHead 0 skips the
// head check; the output RPC error still surfaces a timestamp the node cannot serve).
func SuperRootForBlock(ctx context.Context, rollupRPC string, clock RollupClock, block, nodeHead uint64) (SuperRoot, error) {
	if nodeHead > 0 && block > nodeHead {
		return SuperRoot{}, fmt.Errorf("L2 block %d is ahead of node head %d", block, nodeHead)
	}
	ts, err := TimestampForL2Block(clock.GenesisTime, clock.BlockTime, block)
	if err != nil {
		return SuperRoot{}, err
	}
	out, err := FetchOutputAtBlock(ctx, rollupRPC, block)
	if err != nil {
		return SuperRoot{}, err
	}
	if out.BlockNumber != block {
		return SuperRoot{}, fmt.Errorf("output block mismatch: got %d want %d", out.BlockNumber, block)
	}
	return EncodeSuperRoot(ts, []ChainOutput{{
		ChainID:    clock.L2ChainID,
		OutputRoot: out.OutputRoot,
	}})
}

// FetchSuperRootAtTimestamp reads op-node superroot_atTimestamp and returns the
// super_root hash. A timestamp the node does not serve is an error.
func FetchSuperRootAtTimestamp(ctx context.Context, rollupRPC string, timestamp uint64) (common.Hash, error) {
	raw, err := RPCCall(ctx, rollupRPC, "superroot_atTimestamp", []interface{}{fmt.Sprintf("0x%x", timestamp)})
	if err != nil {
		return common.Hash{}, err
	}
	var resp struct {
		Data *struct {
			SuperRoot string `json:"super_root"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return common.Hash{}, fmt.Errorf("superroot_atTimestamp(%d): %w", timestamp, err)
	}
	if resp.Data == nil || resp.Data.SuperRoot == "" {
		return common.Hash{}, fmt.Errorf("superroot_atTimestamp(%d): no super root (timestamp not served)", timestamp)
	}
	h, err := ParseExactHash(resp.Data.SuperRoot)
	if err != nil {
		return common.Hash{}, fmt.Errorf("superroot_atTimestamp(%d): %w", timestamp, err)
	}
	return h, nil
}

// ChainIDArg is a uint256 ABI argument for rootClaimByChainId.
func ChainIDArg(chainID uint64) *big.Int {
	return new(big.Int).SetUint64(chainID)
}
