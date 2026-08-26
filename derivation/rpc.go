package derivation

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
	"time"
)

// rpcHTTPTimeout is the per-attempt deadline for a JSON-RPC HTTP call.
// Heavy methods (chunked eth_feeHistory, eth_getBlockReceipts) can take
// tens of seconds on a throttled hosted L1; a tight timeout turns a hang
// into a spurious abort. Generous deadline + retry beats a tight deadline.
const rpcHTTPTimeout = 90 * time.Second

// RPCClient is a minimal JSON-RPC 2.0 HTTP client.
type RPCClient struct {
	url         string
	redacted    string
	client      *http.Client
	httpTimeout time.Duration // per-attempt; tests shrink this
	id          atomic.Uint64
}

func NewRPCClient(rawURL string) *RPCClient {
	rawURL = strings.TrimSpace(rawURL)
	return &RPCClient{
		url:         rawURL,
		redacted:    redactRPCURL(rawURL),
		httpTimeout: rpcHTTPTimeout,
		client:      &http.Client{Timeout: rpcHTTPTimeout},
	}
}

// redactRPCURL strips path, query, and userinfo — hosted RPC URLs carry API
// tokens there (same policy as scripts/lib.sh redact_rpc_url).
func redactRPCURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return "rpc-endpoint"
	}
	return u.Scheme + "://" + u.Host
}

// redactedError rewrites the message but unwraps to the original so
// errors.Is/As (e.g. context.Canceled) still work.
type redactedError struct {
	msg string
	err error
}

func (e *redactedError) Error() string { return e.msg }
func (e *redactedError) Unwrap() error { return e.err }

func (c *RPCClient) redactErr(err error) error {
	if err == nil {
		return nil
	}
	return &redactedError{msg: strings.ReplaceAll(err.Error(), c.url, c.redacted), err: err}
}

type rpcRequest struct {
	JSONRPC string `json:"jsonrpc"`
	Method  string `json:"method"`
	Params  []any  `json:"params"`
	ID      uint64 `json:"id"`
}

type rpcResponse struct {
	Result json.RawMessage `json:"result"`
	Error  *rpcError       `json:"error"`
	ID     uint64          `json:"id"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (e *rpcError) Error() string {
	return fmt.Sprintf("rpc error %d: %s", e.Code, e.Message)
}

// errEmptyRPCResult is a valid JSON-RPC envelope with a missing or empty
// result (hosted L1 endpoints sometimes return this after a long inbox scan).
// Call retries a few times instead of json.Unmarshal("") → "unexpected end of JSON input".
var errEmptyRPCResult = errors.New("empty result")

// errHTTPTimeout is a per-attempt HTTP deadline miss. Call retries a few
// times, then fails closed — never hang on a stalled hosted-L1 response.
var errHTTPTimeout = errors.New("http timeout")

func rpcResultEmpty(result json.RawMessage) bool {
	return len(bytes.TrimSpace(result)) == 0
}

func retryableCallErr(err error) bool {
	return errors.Is(err, errEmptyRPCResult) || errors.Is(err, errHTTPTimeout)
}

func isHTTPTimeout(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	var nerr net.Error
	return errors.As(err, &nerr) && nerr.Timeout()
}

func (c *RPCClient) Call(ctx context.Context, method string, params []any, out any) error {
	const attempts = 3
	var err error
	for i := 0; i < attempts; i++ {
		err = c.callOnce(ctx, method, params, out)
		if err == nil || !retryableCallErr(err) || i == attempts-1 {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(200 * time.Millisecond):
		}
	}
	return err
}

func (c *RPCClient) callOnce(ctx context.Context, method string, params []any, out any) error {
	reqBody, err := json.Marshal(rpcRequest{
		JSONRPC: "2.0",
		Method:  method,
		Params:  params,
		ID:      c.id.Add(1),
	})
	if err != nil {
		return err
	}
	timeout := c.httpTimeout
	if timeout <= 0 {
		timeout = rpcHTTPTimeout
	}
	reqCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(reqCtx, http.MethodPost, c.url, bytes.NewReader(reqBody))
	if err != nil {
		return c.redactErr(err)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.client.Do(req)
	if err != nil {
		redacted := c.redactErr(err)
		if ctx.Err() != nil {
			return redacted
		}
		if isHTTPTimeout(err) {
			return fmt.Errorf("rpc %s: %w (%v)", method, errHTTPTimeout, redacted)
		}
		return redacted
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		if ctx.Err() != nil {
			return c.redactErr(err)
		}
		if isHTTPTimeout(err) {
			return fmt.Errorf("rpc %s: %w (%v)", method, errHTTPTimeout, err)
		}
		return err
	}
	var rpcResp rpcResponse
	if err := json.Unmarshal(body, &rpcResp); err != nil {
		return fmt.Errorf("decode rpc response: %w", err)
	}
	if rpcResp.Error != nil {
		return rpcResp.Error
	}
	if out == nil {
		return nil
	}
	if rpcResultEmpty(rpcResp.Result) {
		return fmt.Errorf("rpc %s: %w", method, errEmptyRPCResult)
	}
	return json.Unmarshal(rpcResp.Result, out)
}

func (c *RPCClient) CallRaw(ctx context.Context, method string, params []any) (json.RawMessage, error) {
	var raw json.RawMessage
	if err := c.Call(ctx, method, params, &raw); err != nil {
		return nil, err
	}
	return raw, nil
}

func decodeHexString(s string) ([]byte, error) {
	s = strings.TrimPrefix(strings.ToLower(strings.TrimSpace(s)), "0x")
	if len(s)%2 != 0 {
		return nil, fmt.Errorf("odd hex length")
	}
	out := make([]byte, len(s)/2)
	for i := 0; i < len(out); i++ {
		var b byte
		_, err := fmt.Sscanf(s[i*2:i*2+2], "%02x", &b)
		if err != nil {
			return nil, fmt.Errorf("hex decode: %w", err)
		}
		out[i] = b
	}
	return out, nil
}
