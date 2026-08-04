package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
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

func ethGetTransaction(rpcURL, txHash string) (to, from string, input []byte, err error) {
	body, _ := json.Marshal(rpcReq{
		JSONRPC: "2.0",
		ID:      1,
		Method:  "eth_getTransactionByHash",
		Params:  []interface{}{txHash},
	})
	req, err := http.NewRequest(http.MethodPost, rpcURL, bytes.NewReader(body))
	if err != nil {
		return "", "", nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 30 * time.Second}
	res, err := client.Do(req)
	if err != nil {
		return "", "", nil, err
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
	input, err = decodeHex(in)
	if err != nil {
		return "", "", nil, fmt.Errorf("input hex: %w", err)
	}
	return tx.To, tx.From, input, nil
}
