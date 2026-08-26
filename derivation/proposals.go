package derivation

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"strconv"
	"strings"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
)

// Minimal factory + ASR + game surfaces. Kept as JSON so this module does not
// import the optimism monorepo or the proposer package.
const proposalFactoryABIJSON = `[
  {"type":"function","name":"gameCount","stateMutability":"view","inputs":[],"outputs":[{"name":"gameCount_","type":"uint256"}]},
  {"type":"function","name":"gameAtIndex","stateMutability":"view","inputs":[{"name":"_index","type":"uint256"}],"outputs":[
    {"name":"gameType_","type":"uint32"},
    {"name":"timestamp_","type":"uint64"},
    {"name":"proxy_","type":"address"}
  ]}
]`

const proposalASRABIJSON = `[
  {"type":"function","name":"respectedGameType","stateMutability":"view","inputs":[],"outputs":[{"name":"","type":"uint32"}]}
]`

const proposalGameABIJSON = `[
  {"type":"function","name":"rootClaim","stateMutability":"pure","inputs":[],"outputs":[{"name":"rootClaim_","type":"bytes32"}]},
  {"type":"function","name":"extraData","stateMutability":"pure","inputs":[],"outputs":[{"name":"extraData_","type":"bytes"}]},
  {"type":"function","name":"status","stateMutability":"view","inputs":[],"outputs":[{"name":"status_","type":"uint8"}]}
]`

var (
	proposalFactoryABI abi.ABI
	proposalASRABI     abi.ABI
	proposalGameABI    abi.ABI
)

func init() {
	var err error
	proposalFactoryABI, err = abi.JSON(strings.NewReader(proposalFactoryABIJSON))
	if err != nil {
		panic("proposal factory ABI: " + err.Error())
	}
	proposalASRABI, err = abi.JSON(strings.NewReader(proposalASRABIJSON))
	if err != nil {
		panic("proposal ASR ABI: " + err.Error())
	}
	proposalGameABI, err = abi.JSON(strings.NewReader(proposalGameABIJSON))
	if err != nil {
		panic("proposal game ABI: " + err.Error())
	}
}

// Proposal is one DisputeGameFactory game of the respected (or overridden) type.
type Proposal struct {
	Index     uint64
	GameType  uint32
	CreatedAt uint64
	Game      common.Address
	RootClaim common.Hash
	ExtraData []byte
	L2Block   uint64
	Status    uint8
}

// ParseGameTypeFlag parses -game-type. Empty means "resolve on-chain" (nil).
// There is no numeric default (D-0063 Finding 3c / D-0083).
func ParseGameTypeFlag(s string) (*uint32, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil, nil
	}
	n, err := strconv.ParseUint(s, 10, 32)
	if err != nil {
		return nil, fmt.Errorf("-game-type must be a uint32 (no silent default), got %q: %w", s, err)
	}
	u := uint32(n)
	return &u, nil
}

// ResolveProposalContracts loads factory + ASR from -deploy-state and/or flags.
// Refuse to run with neither an artifact path nor address flags.
func ResolveProposalContracts(deployStatePath, factoryFlag, asrFlag string) (factory, asr common.Address, err error) {
	deployStatePath = strings.TrimSpace(deployStatePath)
	factoryFlag = strings.TrimSpace(factoryFlag)
	asrFlag = strings.TrimSpace(asrFlag)
	if deployStatePath == "" && factoryFlag == "" && asrFlag == "" {
		return common.Address{}, common.Address{}, fmt.Errorf("proposal mode requires -factory and -asr, or -deploy-state (got neither)")
	}
	if deployStatePath != "" {
		factory, asr, err = loadProxyAddresses(deployStatePath)
		if err != nil {
			return common.Address{}, common.Address{}, err
		}
	}
	if factoryFlag != "" {
		factory, err = parseAddressFlag("-factory", factoryFlag)
		if err != nil {
			return common.Address{}, common.Address{}, err
		}
	}
	if asrFlag != "" {
		asr, err = parseAddressFlag("-asr", asrFlag)
		if err != nil {
			return common.Address{}, common.Address{}, err
		}
	}
	if factory == (common.Address{}) {
		return common.Address{}, common.Address{}, fmt.Errorf("proposal mode: DisputeGameFactory address missing (pass -factory or a -deploy-state that contains DisputeGameFactoryProxy)")
	}
	if asr == (common.Address{}) {
		return common.Address{}, common.Address{}, fmt.Errorf("proposal mode: AnchorStateRegistry address missing (pass -asr or a -deploy-state that contains AnchorStateRegistryProxy)")
	}
	return factory, asr, nil
}

func parseAddressFlag(name, s string) (common.Address, error) {
	if !common.IsHexAddress(s) {
		return common.Address{}, fmt.Errorf("%s: not an address: %s", name, s)
	}
	return common.HexToAddress(s), nil
}

func loadProxyAddresses(path string) (factory, asr common.Address, err error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return common.Address{}, common.Address{}, fmt.Errorf("read -deploy-state %s: %w", path, err)
	}
	var root any
	if err := json.Unmarshal(raw, &root); err != nil {
		return common.Address{}, common.Address{}, fmt.Errorf("parse -deploy-state %s: %w", path, err)
	}
	factory = findJSONAddress(root, "DisputeGameFactoryProxy", "disputeGameFactoryProxy")
	asr = findJSONAddress(root, "AnchorStateRegistryProxy", "anchorStateRegistryProxy")
	return factory, asr, nil
}

func findJSONAddress(node any, keys ...string) common.Address {
	switch v := node.(type) {
	case map[string]any:
		for _, k := range keys {
			if raw, ok := v[k]; ok {
				if s, ok := raw.(string); ok && common.IsHexAddress(s) {
					return common.HexToAddress(s)
				}
			}
		}
		for _, child := range v {
			if addr := findJSONAddress(child, keys...); addr != (common.Address{}) {
				return addr
			}
		}
	case []any:
		for _, child := range v {
			if addr := findJSONAddress(child, keys...); addr != (common.Address{}) {
				return addr
			}
		}
	}
	return common.Address{}
}

// DecodeL2BlockNumber reads extraData as ABI-encoded uint256. Malformed extraData
// is an error, not a skip — l2BlockNumber is not a getter shared by every game type.
func DecodeL2BlockNumber(extraData []byte) (uint64, error) {
	if len(extraData) != 32 {
		return 0, fmt.Errorf("extraData length %d, want 32-byte ABI uint256", len(extraData))
	}
	for i := 0; i < 24; i++ {
		if extraData[i] != 0 {
			n := new(big.Int).SetBytes(extraData)
			return 0, fmt.Errorf("extraData l2BlockNumber %s does not fit uint64", n)
		}
	}
	return binary.BigEndian.Uint64(extraData[24:]), nil
}

// PackExtraDataUint256 is the ABI uint256 encoding of an L2 block number (tests / fixtures).
func PackExtraDataUint256(n uint64) []byte {
	var extra [32]byte
	binary.BigEndian.PutUint64(extra[24:], n)
	return extra[:]
}

// RespectedGameType reads AnchorStateRegistry.respectedGameType().
func RespectedGameType(ctx context.Context, l1 *RPCClient, asr common.Address) (uint32, error) {
	data, err := proposalASRABI.Pack("respectedGameType")
	if err != nil {
		return 0, err
	}
	raw, err := ethCall(ctx, l1, asr, data)
	if err != nil {
		return 0, fmt.Errorf("respectedGameType: %w", err)
	}
	out, err := proposalASRABI.Unpack("respectedGameType", raw)
	if err != nil {
		return 0, fmt.Errorf("respectedGameType unpack: %w", err)
	}
	return out[0].(uint32), nil
}

// EnumerateProposals lists factory games of gameType (full factory walk; no from-index).
func EnumerateProposals(ctx context.Context, l1 *RPCClient, factory common.Address, gameType uint32) ([]Proposal, error) {
	count, err := factoryGameCount(ctx, l1, factory)
	if err != nil {
		return nil, err
	}
	var out []Proposal
	for i := uint64(0); i < count; i++ {
		meta, err := factoryGameAtIndex(ctx, l1, factory, i)
		if err != nil {
			return nil, fmt.Errorf("gameAtIndex(%d): %w", i, err)
		}
		if meta.gameType != gameType {
			continue
		}
		if meta.proxy == (common.Address{}) {
			return nil, fmt.Errorf("gameAtIndex(%d): zero proxy", i)
		}
		claim, extra, status, err := fetchGameFields(ctx, l1, meta.proxy)
		if err != nil {
			return nil, fmt.Errorf("game %s (index %d): %w", meta.proxy, i, err)
		}
		l2, err := DecodeL2BlockNumber(extra)
		if err != nil {
			return nil, fmt.Errorf("game %s (index %d) extraData: %w", meta.proxy, i, err)
		}
		out = append(out, Proposal{
			Index:     i,
			GameType:  meta.gameType,
			CreatedAt: meta.timestamp,
			Game:      meta.proxy,
			RootClaim: claim,
			ExtraData: extra,
			L2Block:   l2,
			Status:    status,
		})
	}
	return out, nil
}

type factoryGameMeta struct {
	gameType  uint32
	timestamp uint64
	proxy     common.Address
}

func factoryGameCount(ctx context.Context, l1 *RPCClient, factory common.Address) (uint64, error) {
	data, err := proposalFactoryABI.Pack("gameCount")
	if err != nil {
		return 0, err
	}
	raw, err := ethCall(ctx, l1, factory, data)
	if err != nil {
		return 0, fmt.Errorf("gameCount: %w", err)
	}
	out, err := proposalFactoryABI.Unpack("gameCount", raw)
	if err != nil {
		return 0, fmt.Errorf("gameCount unpack: %w", err)
	}
	n := out[0].(*big.Int)
	if n.Sign() < 0 || !n.IsUint64() {
		return 0, fmt.Errorf("gameCount %s does not fit uint64", n)
	}
	return n.Uint64(), nil
}

func factoryGameAtIndex(ctx context.Context, l1 *RPCClient, factory common.Address, index uint64) (factoryGameMeta, error) {
	data, err := proposalFactoryABI.Pack("gameAtIndex", new(big.Int).SetUint64(index))
	if err != nil {
		return factoryGameMeta{}, err
	}
	raw, err := ethCall(ctx, l1, factory, data)
	if err != nil {
		return factoryGameMeta{}, err
	}
	out, err := proposalFactoryABI.Unpack("gameAtIndex", raw)
	if err != nil {
		return factoryGameMeta{}, err
	}
	return factoryGameMeta{
		gameType:  out[0].(uint32),
		timestamp: out[1].(uint64),
		proxy:     out[2].(common.Address),
	}, nil
}

func fetchGameFields(ctx context.Context, l1 *RPCClient, game common.Address) (claim common.Hash, extra []byte, status uint8, err error) {
	claimData, err := proposalGameABI.Pack("rootClaim")
	if err != nil {
		return common.Hash{}, nil, 0, err
	}
	raw, err := ethCall(ctx, l1, game, claimData)
	if err != nil {
		return common.Hash{}, nil, 0, fmt.Errorf("rootClaim: %w", err)
	}
	claimOut, err := proposalGameABI.Unpack("rootClaim", raw)
	if err != nil {
		return common.Hash{}, nil, 0, fmt.Errorf("rootClaim unpack: %w", err)
	}
	switch v := claimOut[0].(type) {
	case common.Hash:
		claim = v
	case [32]byte:
		claim = v
	default:
		return common.Hash{}, nil, 0, fmt.Errorf("rootClaim: unexpected type %T", claimOut[0])
	}

	extraData, err := proposalGameABI.Pack("extraData")
	if err != nil {
		return common.Hash{}, nil, 0, err
	}
	raw, err = ethCall(ctx, l1, game, extraData)
	if err != nil {
		return common.Hash{}, nil, 0, fmt.Errorf("extraData: %w", err)
	}
	extraOut, err := proposalGameABI.Unpack("extraData", raw)
	if err != nil {
		return common.Hash{}, nil, 0, fmt.Errorf("extraData unpack: %w", err)
	}
	extra = extraOut[0].([]byte)

	statusData, err := proposalGameABI.Pack("status")
	if err != nil {
		return common.Hash{}, nil, 0, err
	}
	raw, err = ethCall(ctx, l1, game, statusData)
	if err != nil {
		return common.Hash{}, nil, 0, fmt.Errorf("status: %w", err)
	}
	statusOut, err := proposalGameABI.Unpack("status", raw)
	if err != nil {
		return common.Hash{}, nil, 0, fmt.Errorf("status unpack: %w", err)
	}
	status = statusOut[0].(uint8)
	return claim, extra, status, nil
}

func ethCall(ctx context.Context, rpc *RPCClient, to common.Address, data []byte) ([]byte, error) {
	var out string
	arg := map[string]string{
		"to":   to.Hex(),
		"data": hexutil.Encode(data),
	}
	if err := rpc.Call(ctx, "eth_call", []any{arg, "latest"}, &out); err != nil {
		return nil, err
	}
	return hexutil.Decode(out)
}
