package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
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

func ethGetTransaction(ctx context.Context, rpcURL, txHash string) (to, from string, input []byte, err error) {
	redacted := batcher.RedactRPCURL(rpcURL)
	body, _ := json.Marshal(rpcReq{
		JSONRPC: "2.0",
		ID:      1,
		Method:  "eth_getTransactionByHash",
		Params:  []interface{}{txHash},
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, rpcURL, bytes.NewReader(body))
	if err != nil {
		return "", "", nil, batcher.RedactErr(rpcURL, redacted, err)
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 30 * time.Second}
	res, err := client.Do(req)
	if err != nil {
		return "", "", nil, batcher.RedactErr(rpcURL, redacted, err)
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(res.Body)
	if err != nil {
		return "", "", nil, err
	}
	var resp rpcResp
	if err := json.Unmarshal(raw, &resp); err != nil {
		return "", "", nil, fmt.Errorf("decode rpc: %w", err)
	}
	if resp.Error != nil {
		return "", "", nil, fmt.Errorf("rpc error: %s", resp.Error.Message)
	}
	if string(resp.Result) == "null" || len(resp.Result) == 0 {
		return "", "", nil, fmt.Errorf("transaction not found")
	}
	var tx struct {
		To    string `json:"to"`
		From  string `json:"from"`
		Input string `json:"input"`
	}
	if err := json.Unmarshal(resp.Result, &tx); err != nil {
		return "", "", nil, err
	}
	in := strings.TrimPrefix(strings.ToLower(tx.Input), "0x")
	input, err = hexDecode(in)
	if err != nil {
		return "", "", nil, fmt.Errorf("input hex: %w", err)
	}
	return tx.To, tx.From, input, nil
}

func hexDecode(s string) ([]byte, error) {
	if len(s)%2 != 0 {
		return nil, fmt.Errorf("odd hex length")
	}
	out := make([]byte, len(s)/2)
	for i := 0; i < len(out); i++ {
		var v byte
		for j := 0; j < 2; j++ {
			c := s[i*2+j]
			var n byte
			switch {
			case c >= '0' && c <= '9':
				n = c - '0'
			case c >= 'a' && c <= 'f':
				n = c - 'a' + 10
			default:
				return nil, fmt.Errorf("bad hex %q", c)
			}
			v = v<<4 | n
		}
		out[i] = v
	}
	return out, nil
}
