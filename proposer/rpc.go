package proposer

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/ethclient"
)

type rpcReq struct {
	JSONRPC string        `json:"jsonrpc"`
	ID      int           `json:"id"`
	Method  string        `json:"method"`
	Params  []interface{} `json:"params"`
}

type rpcResp struct {
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Message string `json:"message"`
	} `json:"error"`
}

// RedactRPCURL strips path, query, and userinfo — hosted RPC URLs carry API
// tokens there (same policy as scripts/lib.sh redact_rpc_url).
func RedactRPCURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return "rpc-endpoint"
	}
	return u.Scheme + "://" + u.Host
}

type redactedError struct {
	msg string
	err error
}

func (e *redactedError) Error() string { return e.msg }
func (e *redactedError) Unwrap() error { return e.err }

// RedactErr replaces raw RPC URLs in transport error text with RedactRPCURL.
func RedactErr(rawURL, redacted string, err error) error {
	if err == nil {
		return nil
	}
	if redacted == "" {
		redacted = RedactRPCURL(rawURL)
	}
	return &redactedError{msg: strings.ReplaceAll(err.Error(), rawURL, redacted), err: err}
}

// RPCCall performs a JSON-RPC call against an HTTP endpoint.
func RPCCall(ctx context.Context, rpcURL, method string, params []interface{}) (json.RawMessage, error) {
	redacted := RedactRPCURL(rpcURL)
	body, err := json.Marshal(rpcReq{JSONRPC: "2.0", ID: 1, Method: method, Params: params})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, rpcURL, bytes.NewReader(body))
	if err != nil {
		return nil, RedactErr(rpcURL, redacted, err)
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 30 * time.Second}
	res, err := client.Do(req)
	if err != nil {
		return nil, RedactErr(rpcURL, redacted, err)
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(res.Body)
	if err != nil {
		return nil, err
	}
	var resp rpcResp
	if err := json.Unmarshal(raw, &resp); err != nil {
		return nil, fmt.Errorf("decode rpc: %w", err)
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("rpc %s: %s", method, resp.Error.Message)
	}
	if string(resp.Result) == "null" || len(resp.Result) == 0 {
		return nil, fmt.Errorf("rpc %s: null result", method)
	}
	return resp.Result, nil
}

// SyncHeads is the proposeable L2 heads from optimism_syncStatus.
type SyncHeads struct {
	SafeL2      uint64
	FinalizedL2 uint64
	UnsafeL2    uint64
}

// FetchSyncHeads calls optimism_syncStatus on the rollup RPC.
func FetchSyncHeads(ctx context.Context, rollupRPC string) (SyncHeads, error) {
	raw, err := RPCCall(ctx, rollupRPC, "optimism_syncStatus", []interface{}{})
	if err != nil {
		return SyncHeads{}, err
	}
	var st struct {
		SafeL2 struct {
			Number uint64 `json:"number"`
		} `json:"safe_l2"`
		FinalizedL2 struct {
			Number uint64 `json:"number"`
		} `json:"finalized_l2"`
		UnsafeL2 struct {
			Number uint64 `json:"number"`
		} `json:"unsafe_l2"`
	}
	if err := json.Unmarshal(raw, &st); err != nil {
		return SyncHeads{}, err
	}
	return SyncHeads{
		SafeL2:      st.SafeL2.Number,
		FinalizedL2: st.FinalizedL2.Number,
		UnsafeL2:    st.UnsafeL2.Number,
	}, nil
}

// OutputAtBlock is the subset of optimism_outputAtBlock used for proposals.
type OutputAtBlock struct {
	OutputRoot  common.Hash
	BlockNumber uint64
}

// FetchOutputAtBlock calls optimism_outputAtBlock(hexBlock).
// Phase 5 v1 fetches the root from op-node rather than recomputing locally.
func FetchOutputAtBlock(ctx context.Context, rollupRPC string, blockNum uint64) (OutputAtBlock, error) {
	hexBlock := "0x" + strconv.FormatUint(blockNum, 16)
	raw, err := RPCCall(ctx, rollupRPC, "optimism_outputAtBlock", []interface{}{hexBlock})
	if err != nil {
		return OutputAtBlock{}, err
	}
	var out struct {
		OutputRoot string `json:"outputRoot"`
		BlockRef   struct {
			Number uint64 `json:"number"`
		} `json:"blockRef"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return OutputAtBlock{}, err
	}
	if out.OutputRoot == "" {
		return OutputAtBlock{}, fmt.Errorf("outputAtBlock %d: empty outputRoot", blockNum)
	}
	root, err := ParseExactHash(out.OutputRoot)
	if err != nil {
		return OutputAtBlock{}, fmt.Errorf("outputAtBlock %d: outputRoot: %w", blockNum, err)
	}
	n := out.BlockRef.Number
	if n == 0 {
		n = blockNum
	}
	return OutputAtBlock{OutputRoot: root, BlockNumber: n}, nil
}

// EthCall helper against an ethclient.
func EthCall(ctx context.Context, client *ethclient.Client, to common.Address, data []byte) ([]byte, error) {
	return client.CallContract(ctx, ethereum.CallMsg{To: &to, Data: data}, nil)
}

// GameCount reads DisputeGameFactory.gameCount().
func GameCount(ctx context.Context, client *ethclient.Client, factory common.Address) (*big.Int, error) {
	data, err := EncodeGameCount()
	if err != nil {
		return nil, err
	}
	raw, err := EthCall(ctx, client, factory, data)
	if err != nil {
		return nil, err
	}
	return DecodeGameCount(raw)
}

// GameAtIndex reads DisputeGameFactory.gameAtIndex(index).
func GameAtIndex(ctx context.Context, client *ethclient.Client, factory common.Address, index *big.Int) (GameAtIndexResult, error) {
	data, err := EncodeGameAtIndex(index)
	if err != nil {
		return GameAtIndexResult{}, err
	}
	raw, err := EthCall(ctx, client, factory, data)
	if err != nil {
		return GameAtIndexResult{}, err
	}
	return DecodeGameAtIndex(raw)
}

// InitBond reads DisputeGameFactory.initBonds(gameType).
func InitBond(ctx context.Context, client *ethclient.Client, factory common.Address, gameType uint32) (*big.Int, error) {
	data, err := EncodeInitBonds(gameType)
	if err != nil {
		return nil, err
	}
	raw, err := EthCall(ctx, client, factory, data)
	if err != nil {
		return nil, err
	}
	return DecodeInitBonds(raw)
}

// InspectedGame is a decoded dispute-game proxy view.
type InspectedGame struct {
	Index           uint64
	Proxy           common.Address
	FactoryGameType uint32
	FactoryTime     uint64
	RootClaim       common.Hash
	ExtraData       []byte
	L2Sequence      uint64
	GameType        uint32
	Status          uint8
	CreatedAt       uint64
	Creator         common.Address
}

// InspectGame loads factory metadata + game proxy fields for one index.
func InspectGame(ctx context.Context, client *ethclient.Client, factory common.Address, index uint64) (InspectedGame, error) {
	meta, err := GameAtIndex(ctx, client, factory, new(big.Int).SetUint64(index))
	if err != nil {
		return InspectedGame{}, err
	}
	g := InspectedGame{
		Index:           index,
		Proxy:           meta.Proxy,
		FactoryGameType: meta.GameType,
		FactoryTime:     meta.Timestamp,
	}
	if meta.Proxy == (common.Address{}) {
		return g, fmt.Errorf("gameAtIndex(%d): zero proxy", index)
	}

	type call struct {
		name string
		set  func([]byte) error
	}
	calls := []call{
		{"rootClaim", func(raw []byte) error {
			out, err := gameABI.Unpack("rootClaim", raw)
			if err != nil {
				return err
			}
			g.RootClaim = asHash(out[0])
			return nil
		}},
		{"extraData", func(raw []byte) error {
			out, err := gameABI.Unpack("extraData", raw)
			if err != nil {
				return err
			}
			g.ExtraData = out[0].([]byte)
			return nil
		}},
		{"l2SequenceNumber", func(raw []byte) error {
			out, err := gameABI.Unpack("l2SequenceNumber", raw)
			if err != nil {
				return err
			}
			g.L2Sequence = out[0].(*big.Int).Uint64()
			return nil
		}},
		{"gameType", func(raw []byte) error {
			out, err := gameABI.Unpack("gameType", raw)
			if err != nil {
				return err
			}
			g.GameType = out[0].(uint32)
			return nil
		}},
		{"status", func(raw []byte) error {
			out, err := gameABI.Unpack("status", raw)
			if err != nil {
				return err
			}
			g.Status = out[0].(uint8)
			return nil
		}},
		{"createdAt", func(raw []byte) error {
			out, err := gameABI.Unpack("createdAt", raw)
			if err != nil {
				return err
			}
			g.CreatedAt = out[0].(uint64)
			return nil
		}},
		{"gameCreator", func(raw []byte) error {
			out, err := gameABI.Unpack("gameCreator", raw)
			if err != nil {
				return err
			}
			g.Creator = out[0].(common.Address)
			return nil
		}},
	}
	for _, c := range calls {
		data, err := gameABI.Pack(c.name)
		if err != nil {
			return g, fmt.Errorf("pack %s: %w", c.name, err)
		}
		raw, err := EthCall(ctx, client, meta.Proxy, data)
		if err != nil {
			return g, fmt.Errorf("%s: %w", c.name, err)
		}
		if err := c.set(raw); err != nil {
			return g, fmt.Errorf("unpack %s: %w", c.name, err)
		}
	}
	return g, nil
}

// LatestGameOfType walks gameAtIndex from the end and returns the newest game
// matching gameType (or false if none).
func LatestGameOfType(ctx context.Context, client *ethclient.Client, factory common.Address, gameType uint32) (InspectedGame, bool, error) {
	count, err := GameCount(ctx, client, factory)
	if err != nil {
		return InspectedGame{}, false, err
	}
	if count.Sign() == 0 {
		return InspectedGame{}, false, nil
	}
	n := count.Uint64()
	for i := n; i > 0; i-- {
		idx := i - 1
		meta, err := GameAtIndex(ctx, client, factory, new(big.Int).SetUint64(idx))
		if err != nil {
			return InspectedGame{}, false, err
		}
		if meta.GameType != gameType {
			continue
		}
		g, err := InspectGame(ctx, client, factory, idx)
		if err != nil {
			return InspectedGame{}, false, err
		}
		return g, true, nil
	}
	return InspectedGame{}, false, nil
}

// HexOrAddress normalizes 0x addresses.
func HexOrAddress(s string) (common.Address, error) {
	s = strings.TrimSpace(s)
	if s == "" || !common.IsHexAddress(s) {
		return common.Address{}, fmt.Errorf("invalid address %q", s)
	}
	return common.HexToAddress(s), nil
}

// ParseExactHash requires a 0x-prefixed 32-byte hex hash (64 hex digits).
// Unlike common.HexToHash, it rejects truncated/padded/malformed values so we
// do not propose a silently normalized false output root.
func ParseExactHash(s string) (common.Hash, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return common.Hash{}, fmt.Errorf("empty hash")
	}
	if !strings.HasPrefix(s, "0x") && !strings.HasPrefix(s, "0X") {
		return common.Hash{}, fmt.Errorf("hash must be 0x-prefixed, got %q", s)
	}
	body := s[2:]
	if len(body) != 64 {
		return common.Hash{}, fmt.Errorf("hash must be 32 bytes (64 hex chars), got len=%d", len(body))
	}
	for _, c := range body {
		switch {
		case c >= '0' && c <= '9', c >= 'a' && c <= 'f', c >= 'A' && c <= 'F':
		default:
			return common.Hash{}, fmt.Errorf("invalid hex digit in hash")
		}
	}
	return common.HexToHash(s), nil
}

func asHash(v interface{}) common.Hash {
	switch t := v.(type) {
	case common.Hash:
		return t
	case [32]byte:
		return common.BytesToHash(t[:])
	case []byte:
		return common.BytesToHash(t)
	default:
		return common.Hash{}
	}
}
