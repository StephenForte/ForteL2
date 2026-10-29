package proposer

import (
	"fmt"
	"math/big"
	"strings"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
)

// Minimal DisputeGameFactory + FaultDisputeGame surfaces used by Phase 5.
// Kept as JSON so we do not import the optimism monorepo.
const disputeGameFactoryABIJSON = `[
  {"type":"function","name":"gameCount","stateMutability":"view","inputs":[],"outputs":[{"name":"gameCount_","type":"uint256"}]},
  {"type":"function","name":"gameAtIndex","stateMutability":"view","inputs":[{"name":"_index","type":"uint256"}],"outputs":[
    {"name":"gameType_","type":"uint32"},
    {"name":"timestamp_","type":"uint64"},
    {"name":"proxy_","type":"address"}
  ]},
  {"type":"function","name":"initBonds","stateMutability":"view","inputs":[{"name":"_gameType","type":"uint32"}],"outputs":[{"name":"bond_","type":"uint256"}]},
  {"type":"function","name":"gameImpls","stateMutability":"view","inputs":[{"name":"_gameType","type":"uint32"}],"outputs":[{"name":"impl_","type":"address"}]},
  {"type":"function","name":"create","stateMutability":"payable","inputs":[
    {"name":"_gameType","type":"uint32"},
    {"name":"_rootClaim","type":"bytes32"},
    {"name":"_extraData","type":"bytes"}
  ],"outputs":[{"name":"proxy_","type":"address"}]},
  {"type":"function","name":"games","stateMutability":"view","inputs":[
    {"name":"_gameType","type":"uint32"},
    {"name":"_rootClaim","type":"bytes32"},
    {"name":"_extraData","type":"bytes"}
  ],"outputs":[
    {"name":"proxy_","type":"address"},
    {"name":"timestamp_","type":"uint64"}
  ]}
]`

const disputeGameABIJSON = `[
  {"type":"function","name":"rootClaim","stateMutability":"pure","inputs":[],"outputs":[{"name":"rootClaim_","type":"bytes32"}]},
  {"type":"function","name":"extraData","stateMutability":"pure","inputs":[],"outputs":[{"name":"extraData_","type":"bytes"}]},
  {"type":"function","name":"l2SequenceNumber","stateMutability":"pure","inputs":[],"outputs":[{"name":"l2SequenceNumber_","type":"uint256"}]},
  {"type":"function","name":"gameType","stateMutability":"view","inputs":[],"outputs":[{"name":"gameType_","type":"uint32"}]},
  {"type":"function","name":"status","stateMutability":"view","inputs":[],"outputs":[{"name":"status_","type":"uint8"}]},
  {"type":"function","name":"createdAt","stateMutability":"view","inputs":[],"outputs":[{"name":"createdAt_","type":"uint64"}]},
  {"type":"function","name":"gameCreator","stateMutability":"pure","inputs":[],"outputs":[{"name":"creator_","type":"address"}]},
  {"type":"function","name":"rootClaimByChainId","stateMutability":"pure","inputs":[{"name":"_chainId","type":"uint256"}],"outputs":[{"name":"outputRootClaim_","type":"bytes32"}]}
]`

var (
	factoryABI abi.ABI
	gameABI    abi.ABI
)

func init() {
	var err error
	factoryABI, err = abi.JSON(strings.NewReader(disputeGameFactoryABIJSON))
	if err != nil {
		panic(fmt.Sprintf("factory ABI: %v", err))
	}
	gameABI, err = abi.JSON(strings.NewReader(disputeGameABIJSON))
	if err != nil {
		panic(fmt.Sprintf("game ABI: %v", err))
	}
}

// FactoryABI returns the parsed DisputeGameFactory ABI.
func FactoryABI() abi.ABI { return factoryABI }

// GameABI returns the parsed minimal DisputeGame ABI.
func GameABI() abi.ABI { return gameABI }

// EncodeCreate packs DisputeGameFactory.create(gameType, rootClaim, extraData) calldata.
func EncodeCreate(gameType uint32, rootClaim common.Hash, extraData []byte) ([]byte, error) {
	return factoryABI.Pack("create", gameType, rootClaim, extraData)
}

// EncodeGameCount packs gameCount() calldata.
func EncodeGameCount() ([]byte, error) {
	return factoryABI.Pack("gameCount")
}

// EncodeGameAtIndex packs gameAtIndex(index) calldata.
func EncodeGameAtIndex(index *big.Int) ([]byte, error) {
	return factoryABI.Pack("gameAtIndex", index)
}

// EncodeInitBonds packs initBonds(gameType) calldata.
func EncodeInitBonds(gameType uint32) ([]byte, error) {
	return factoryABI.Pack("initBonds", gameType)
}

// EncodeGameImpls packs gameImpls(gameType) calldata.
func EncodeGameImpls(gameType uint32) ([]byte, error) {
	return factoryABI.Pack("gameImpls", gameType)
}

// EncodeRootClaimByChainID packs rootClaimByChainId(chainId) calldata.
func EncodeRootClaimByChainID(chainID *big.Int) ([]byte, error) {
	return gameABI.Pack("rootClaimByChainId", chainID)
}

// EncodeGames packs games(gameType, rootClaim, extraData) calldata.
func EncodeGames(gameType uint32, rootClaim common.Hash, extraData []byte) ([]byte, error) {
	return factoryABI.Pack("games", gameType, rootClaim, extraData)
}

// DecodeGameCount unpacks a gameCount eth_call result.
func DecodeGameCount(data []byte) (*big.Int, error) {
	out, err := factoryABI.Unpack("gameCount", data)
	if err != nil {
		return nil, err
	}
	return out[0].(*big.Int), nil
}

// GameAtIndexResult is the decoded gameAtIndex return.
type GameAtIndexResult struct {
	GameType  uint32
	Timestamp uint64
	Proxy     common.Address
}

// DecodeGameAtIndex unpacks a gameAtIndex eth_call result.
func DecodeGameAtIndex(data []byte) (GameAtIndexResult, error) {
	out, err := factoryABI.Unpack("gameAtIndex", data)
	if err != nil {
		return GameAtIndexResult{}, err
	}
	return GameAtIndexResult{
		GameType:  out[0].(uint32),
		Timestamp: out[1].(uint64),
		Proxy:     out[2].(common.Address),
	}, nil
}

// DecodeInitBonds unpacks an initBonds eth_call result.
func DecodeInitBonds(data []byte) (*big.Int, error) {
	out, err := factoryABI.Unpack("initBonds", data)
	if err != nil {
		return nil, err
	}
	return out[0].(*big.Int), nil
}

// DecodeGameImpls unpacks a gameImpls eth_call result.
func DecodeGameImpls(data []byte) (common.Address, error) {
	out, err := factoryABI.Unpack("gameImpls", data)
	if err != nil {
		return common.Address{}, err
	}
	return out[0].(common.Address), nil
}

// DecodeRootClaimByChainID unpacks a rootClaimByChainId eth_call result.
func DecodeRootClaimByChainID(data []byte) (common.Hash, error) {
	out, err := gameABI.Unpack("rootClaimByChainId", data)
	if err != nil {
		return common.Hash{}, err
	}
	return asHash(out[0]), nil
}
