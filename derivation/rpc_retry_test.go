package derivation

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const htmlInterstitial = `<!DOCTYPE html><html><body>Cloudflare error</body></html>`

func writeRPCOK(w http.ResponseWriter, result any) {
	_ = json.NewEncoder(w).Encode(map[string]any{
		"jsonrpc": "2.0",
		"id":      1,
		"result":  result,
	})
}

func TestCallHTTP429ThenSucceeds(t *testing.T) {
	var n atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if n.Add(1) == 1 {
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = w.Write([]byte(htmlInterstitial))
			return
		}
		writeRPCOK(w, map[string]any{"number": "0x1"})
	}))
	t.Cleanup(srv.Close)

	c := tightRPCClient(srv.URL)
	var out map[string]any
	if err := c.Call(context.Background(), "eth_getBlockByNumber", []any{"0x1", false}, &out); err != nil {
		t.Fatalf("retry after 429 should succeed: %v", err)
	}
	if got := n.Load(); got != 2 {
		t.Fatalf("attempts = %d, want 2", got)
	}
}

func TestCallHTTP503ThenSucceeds(t *testing.T) {
	var n atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if n.Add(1) == 1 {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		writeRPCOK(w, map[string]any{"number": "0x1"})
	}))
	t.Cleanup(srv.Close)

	c := tightRPCClient(srv.URL)
	var out map[string]any
	if err := c.Call(context.Background(), "eth_blockNumber", nil, &out); err != nil {
		t.Fatalf("retry after 503 should succeed: %v", err)
	}
}

func TestCallHTMLBodyThenSucceedsDoesNotEchoBody(t *testing.T) {
	var n atomic.Int32
	var logs bytes.Buffer
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if n.Add(1) == 1 {
			w.Header().Set("Content-Type", "text/html")
			_, _ = w.Write([]byte(htmlInterstitial))
			return
		}
		writeRPCOK(w, map[string]any{"number": "0x1"})
	}))
	t.Cleanup(srv.Close)

	c := tightRPCClient(srv.URL)
	c.logw = &logs
	var out map[string]any
	if err := c.Call(context.Background(), "eth_blockNumber", nil, &out); err != nil {
		t.Fatalf("retry after HTML body should succeed: %v", err)
	}
	if got := n.Load(); got != 2 {
		t.Fatalf("attempts = %d, want 2", got)
	}
	if strings.Contains(logs.String(), htmlInterstitial) || strings.Contains(logs.String(), "<html") {
		t.Fatalf("HTML body echoed in logs: %s", logs.String())
	}
}

func TestCallHTMLBodyErrorDoesNotEchoBody(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(htmlInterstitial))
	}))
	t.Cleanup(srv.Close)

	c := tightRPCClient(srv.URL)
	var out map[string]any
	err := c.Call(context.Background(), "eth_blockNumber", nil, &out)
	if err == nil {
		t.Fatal("expected non-json error")
	}
	if !errors.Is(err, errNonJSONRPC) {
		t.Fatalf("want errNonJSONRPC, got %v", err)
	}
	msg := err.Error()
	if strings.Contains(msg, htmlInterstitial) || strings.Contains(msg, "<html") || strings.Contains(msg, "Cloudflare") {
		t.Fatalf("HTML body echoed in error: %s", msg)
	}
}

func TestCallRetryAfterHonored(t *testing.T) {
	var n atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if n.Add(1) == 1 {
			w.Header().Set("Retry-After", "1")
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		writeRPCOK(w, map[string]any{"number": "0x1"})
	}))
	t.Cleanup(srv.Close)

	c := NewRPCClient(srv.URL)
	c.retryAttempts = 3
	c.backoffBase = time.Hour
	c.backoffMax = time.Hour
	c.jitter = func(d time.Duration) time.Duration { return d }
	c.logw = bytes.NewBuffer(nil)

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	t.Cleanup(cancel)
	start := time.Now()
	var out map[string]any
	if err := c.Call(ctx, "eth_blockNumber", nil, &out); err != nil {
		t.Fatalf("retry after Retry-After should succeed: %v", err)
	}
	elapsed := time.Since(start)
	if elapsed < 500*time.Millisecond {
		t.Fatalf("Retry-After not honored: elapsed %v", elapsed)
	}
	if elapsed > 2500*time.Millisecond {
		t.Fatalf("Retry-After wait too long: %v (backoff must not fall back to 1h)", elapsed)
	}
}

func TestCallCancelDuringBackoffReturnsPromptly(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	t.Cleanup(srv.Close)

	c := NewRPCClient(srv.URL)
	c.retryAttempts = 8
	c.backoffBase = 5 * time.Second
	c.backoffMax = 5 * time.Second
	c.jitter = func(d time.Duration) time.Duration { return d }
	c.logw = bytes.NewBuffer(nil)

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	time.AfterFunc(50*time.Millisecond, cancel)

	start := time.Now()
	var out map[string]any
	err := c.Call(ctx, "eth_blockNumber", nil, &out)
	elapsed := time.Since(start)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("want context.Canceled, got %v", err)
	}
	if elapsed > 2*time.Second {
		t.Fatalf("cancel during backoff took %v; should return promptly", elapsed)
	}
}

func TestCallPacingKeepsRate(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeRPCOK(w, "0x1")
	}))
	t.Cleanup(srv.Close)

	const rps = 20.0
	const n = 6
	c := tightRPCClient(srv.URL)
	c.maxRPS = rps

	start := time.Now()
	for i := 0; i < n; i++ {
		var out string
		if err := c.Call(context.Background(), "eth_blockNumber", nil, &out); err != nil {
			t.Fatalf("paced call %d: %v", i, err)
		}
	}
	elapsed := time.Since(start)
	min := time.Duration(float64(n-1) / rps * float64(time.Second))
	if elapsed < min/2 {
		t.Fatalf("pacing too fast: elapsed %v, min interval sum %v", elapsed, min)
	}
	if elapsed > 2*time.Second {
		t.Fatalf("pacing too slow: elapsed %v", elapsed)
	}
}
