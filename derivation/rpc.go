package derivation

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// rpcHTTPTimeout is the per-attempt deadline for a JSON-RPC HTTP call.
// Heavy methods (chunked eth_feeHistory, eth_getBlockReceipts) can take
// tens of seconds on a throttled hosted L1; a tight timeout turns a hang
// into a spurious abort. Generous deadline + retry beats a tight deadline.
const rpcHTTPTimeout = 90 * time.Second

// Patient retry defaults for a throttled hosted L1 (Alchemy free-tier 429s).
// More generous than 3×200ms; capped so backoff cannot look like a hang.
const (
	rpcRetryAttempts = 10
	rpcBackoffBase   = 1 * time.Second
	rpcBackoffMax    = 30 * time.Second
)

// RPCClient is a minimal JSON-RPC 2.0 HTTP client.
type RPCClient struct {
	url           string
	redacted      string
	client        *http.Client
	httpTimeout   time.Duration // per-attempt; tests shrink this
	retryAttempts int
	backoffBase   time.Duration
	backoffMax    time.Duration
	jitter        func(time.Duration) time.Duration
	maxRPS        float64 // 0 = unpaced (today's default)
	logw          io.Writer
	id            atomic.Uint64

	paceMu sync.Mutex
	last   time.Time
}

func NewRPCClient(rawURL string) *RPCClient {
	rawURL = strings.TrimSpace(rawURL)
	return &RPCClient{
		url:           rawURL,
		redacted:      redactRPCURL(rawURL),
		httpTimeout:   rpcHTTPTimeout,
		retryAttempts: rpcRetryAttempts,
		backoffBase:   rpcBackoffBase,
		backoffMax:    rpcBackoffMax,
		maxRPS:        parseMaxRPS(os.Getenv("DERIVATION_RPC_MAX_RPS")),
		logw:          os.Stderr,
		client:        &http.Client{Timeout: rpcHTTPTimeout},
	}
}

func parseMaxRPS(s string) float64 {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	v, err := strconv.ParseFloat(s, 64)
	if err != nil || v < 0 {
		return 0
	}
	return v
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

// errHTTPRetryable is HTTP 429 or 5xx. Call retries (honoring Retry-After).
var errHTTPRetryable = errors.New("http retryable")

// errNonJSONRPC is a response body that is not a JSON-RPC envelope (HTML
// interstitial pages). Call retries; the body is never echoed.
var errNonJSONRPC = errors.New("non-json rpc response")

// retryHint carries an optional Retry-After wait for the retryable class.
type retryHint struct {
	err        error
	retryAfter time.Duration
}

func (e *retryHint) Error() string { return e.err.Error() }
func (e *retryHint) Unwrap() error { return e.err }

func rpcResultEmpty(result json.RawMessage) bool {
	return len(bytes.TrimSpace(result)) == 0
}

func retryableCallErr(err error) bool {
	return errors.Is(err, errEmptyRPCResult) ||
		errors.Is(err, errHTTPTimeout) ||
		errors.Is(err, errHTTPRetryable) ||
		errors.Is(err, errNonJSONRPC)
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

func parseRetryAfter(h http.Header, now time.Time) time.Duration {
	v := strings.TrimSpace(h.Get("Retry-After"))
	if v == "" {
		return 0
	}
	if secs, err := strconv.Atoi(v); err == nil && secs >= 0 {
		return time.Duration(secs) * time.Second
	}
	t, err := http.ParseTime(v)
	if err != nil {
		return 0
	}
	d := t.Sub(now)
	if d < 0 {
		return 0
	}
	return d
}

func jitterDuration(d time.Duration) time.Duration {
	if d <= 0 {
		return 0
	}
	half := d / 2
	n, err := rand.Int(rand.Reader, big.NewInt(int64(half)+1))
	if err != nil {
		return half
	}
	return half + time.Duration(n.Int64())
}

func expBackoff(base, max time.Duration, attempt int) time.Duration {
	if base <= 0 {
		base = rpcBackoffBase
	}
	if max <= 0 {
		max = rpcBackoffMax
	}
	wait := base
	for i := 0; i < attempt; i++ {
		if wait > max/2 {
			return max
		}
		wait *= 2
	}
	if wait > max {
		return max
	}
	return wait
}

func (c *RPCClient) applyJitter(d time.Duration) time.Duration {
	if c.jitter != nil {
		return c.jitter(d)
	}
	return jitterDuration(d)
}

func (c *RPCClient) attempts() int {
	if c.retryAttempts > 0 {
		return c.retryAttempts
	}
	return rpcRetryAttempts
}

func (c *RPCClient) writer() io.Writer {
	if c.logw != nil {
		return c.logw
	}
	return os.Stderr
}

func (c *RPCClient) logRetry(attempt, total int, err error, wait time.Duration) {
	fmt.Fprintf(c.writer(), "rpc retry %d/%d %s: %s; backing off %s\n",
		attempt, total, c.redacted, err.Error(), wait)
}

func (c *RPCClient) waitPace(ctx context.Context) error {
	if c.maxRPS <= 0 {
		return nil
	}
	interval := time.Duration(float64(time.Second) / c.maxRPS)
	if interval <= 0 {
		return nil
	}
	c.paceMu.Lock()
	var wait time.Duration
	if !c.last.IsZero() {
		wait = interval - time.Since(c.last)
	}
	c.paceMu.Unlock()
	if wait > 0 {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(wait):
		}
	}
	c.paceMu.Lock()
	c.last = time.Now()
	c.paceMu.Unlock()
	return nil
}

func (c *RPCClient) Call(ctx context.Context, method string, params []any, out any) error {
	attempts := c.attempts()
	var err error
	for i := 0; i < attempts; i++ {
		err = c.callOnce(ctx, method, params, out)
		if err == nil || !retryableCallErr(err) || i == attempts-1 {
			return err
		}
		wait := c.applyJitter(expBackoff(c.backoffBase, c.backoffMax, i))
		var hint *retryHint
		if errors.As(err, &hint) && hint.retryAfter > 0 {
			wait = hint.retryAfter
			max := c.backoffMax
			if max <= 0 {
				max = rpcBackoffMax
			}
			if wait > max {
				wait = max
			}
		}
		c.logRetry(i+1, attempts, err, wait)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(wait):
		}
	}
	return err
}

func (c *RPCClient) callOnce(ctx context.Context, method string, params []any, out any) error {
	if err := c.waitPace(ctx); err != nil {
		return err
	}
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
	status := resp.StatusCode
	if status == http.StatusTooManyRequests || status >= 500 {
		hint := &retryHint{
			err: fmt.Errorf("rpc %s: %w (http %d)", method, errHTTPRetryable, status),
		}
		if ra := parseRetryAfter(resp.Header, time.Now()); ra > 0 {
			hint.retryAfter = ra
		}
		return hint
	}
	if status < 200 || status >= 300 {
		return fmt.Errorf("rpc %s: http %d", method, status)
	}
	var rpcResp rpcResponse
	if err := json.Unmarshal(body, &rpcResp); err != nil {
		return fmt.Errorf("rpc %s: %w", method, errNonJSONRPC)
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
