package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/StephenForte/ForteL2/batcher"
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

func rpcCall(ctx context.Context, rpcURL, method string, params []interface{}) (json.RawMessage, error) {
	redacted := batcher.RedactRPCURL(rpcURL)
	body, err := json.Marshal(rpcReq{JSONRPC: "2.0", ID: 1, Method: method, Params: params})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, rpcURL, bytes.NewReader(body))
	if err != nil {
		return nil, batcher.RedactErr(rpcURL, redacted, err)
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 30 * time.Second}
	res, err := client.Do(req)
	if err != nil {
		return nil, batcher.RedactErr(rpcURL, redacted, err)
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

func syncHeads(ctx context.Context, rollupRPC string) (safe, unsafe uint64, err error) {
	raw, err := rpcCall(ctx, rollupRPC, "optimism_syncStatus", []interface{}{})
	if err != nil {
		return 0, 0, err
	}
	var st struct {
		SafeL2 struct {
			Number uint64 `json:"number"`
		} `json:"safe_l2"`
		UnsafeL2 struct {
			Number uint64 `json:"number"`
		} `json:"unsafe_l2"`
	}
	if err := json.Unmarshal(raw, &st); err != nil {
		return 0, 0, err
	}
	return st.SafeL2.Number, st.UnsafeL2.Number, nil
}

type rpcBlock struct {
	Hash       string          `json:"hash"`
	ParentHash string          `json:"parentHash"`
	Number     string          `json:"number"`
	Timestamp  string          `json:"timestamp"`
	Txs        []rpcBlockTx    `json:"transactions"`
}

type rpcBlockTx struct {
	Hash  string `json:"hash"`
	Type  string `json:"type"`
	Input string `json:"input"`
}

func loadSingularBatches(ctx context.Context, l2RPC string, from, to uint64) ([]batcher.SingularBatch, error) {
	out := make([]batcher.SingularBatch, 0, to-from+1)
	for n := from; n <= to; n++ {
		b, err := fetchBlock(ctx, l2RPC, n)
		if err != nil {
			return nil, fmt.Errorf("block %d: %w", n, err)
		}
		parent, err := hash32(b.ParentHash)
		if err != nil {
			return nil, err
		}
		ts, err := parseHexUint(b.Timestamp)
		if err != nil {
			return nil, err
		}
		if len(b.Txs) == 0 {
			return nil, fmt.Errorf("block %d has no txs", n)
		}
		firstType, err := parseHexUint(b.Txs[0].Type)
		if err != nil {
			return nil, err
		}
		if byte(firstType) != batcher.DepositTxType {
			return nil, fmt.Errorf("block %d first tx type 0x%x not deposit", n, firstType)
		}
		l1Info, err := decodeHex(b.Txs[0].Input)
		if err != nil {
			return nil, fmt.Errorf("block %d l1 info input: %w", n, err)
		}
		var userTxs [][]byte
		for i, tx := range b.Txs {
			ty, err := parseHexUint(tx.Type)
			if err != nil {
				return nil, err
			}
			if byte(ty) == batcher.DepositTxType {
				continue
			}
			raw, err := ethGetRawTransaction(ctx, l2RPC, tx.Hash)
			if err != nil {
				return nil, fmt.Errorf("block %d tx[%d] %s: %w", n, i, tx.Hash, err)
			}
			userTxs = append(userTxs, raw)
		}
		sb, err := batcher.BuildSingularBatch(parent, ts, l1Info, userTxs)
		if err != nil {
			return nil, fmt.Errorf("block %d batch: %w", n, err)
		}
		out = append(out, sb)
	}
	return out, nil
}

func fetchBlock(ctx context.Context, l2RPC string, number uint64) (rpcBlock, error) {
	raw, err := rpcCall(ctx, l2RPC, "eth_getBlockByNumber", []interface{}{fmt.Sprintf("0x%x", number), true})
	if err != nil {
		return rpcBlock{}, err
	}
	var b rpcBlock
	if err := json.Unmarshal(raw, &b); err != nil {
		return rpcBlock{}, err
	}
	return b, nil
}

func ethGetRawTransaction(ctx context.Context, rpcURL, txHash string) ([]byte, error) {
	raw, err := rpcCall(ctx, rpcURL, "eth_getRawTransactionByHash", []interface{}{txHash})
	if err != nil {
		return nil, err
	}
	var hexStr string
	if err := json.Unmarshal(raw, &hexStr); err != nil {
		return nil, err
	}
	return decodeHex(hexStr)
}

func decodeHex(s string) ([]byte, error) {
	s = strings.TrimPrefix(strings.ToLower(s), "0x")
	if len(s)%2 != 0 {
		return nil, fmt.Errorf("odd hex length")
	}
	return hex.DecodeString(s)
}

func hash32(s string) ([32]byte, error) {
	var out [32]byte
	b, err := decodeHex(s)
	if err != nil {
		return out, err
	}
	if len(b) != 32 {
		return out, fmt.Errorf("want 32 bytes, got %d", len(b))
	}
	copy(out[:], b)
	return out, nil
}

func parseHexUint(s string) (uint64, error) {
	s = strings.TrimPrefix(strings.ToLower(s), "0x")
	if s == "" {
		return 0, fmt.Errorf("empty hex")
	}
	return strconv.ParseUint(s, 16, 64)
}
