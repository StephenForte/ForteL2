package derivation

import (
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

// stallPastDeadline holds the request longer than the client deadline so
// Call sees a timeout, then returns so httptest.Server.Close does not hang.
func stallPastDeadline(d time.Duration) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		timer := time.NewTimer(d)
		defer timer.Stop()
		select {
		case <-r.Context().Done():
		case <-timer.C:
		}
	}
}

func TestCallHTTPTimeoutNeverResponds(t *testing.T) {
	const attempt = 80 * time.Millisecond
	srv := httptest.NewServer(stallPastDeadline(3 * attempt))
	t.Cleanup(func() {
		srv.CloseClientConnections()
		srv.Close()
	})

	tokenURL := srv.URL + "/deadbeefcafe1234"
	c := NewRPCClient(tokenURL)
	c.httpTimeout = attempt

	start := time.Now()
	var out map[string]any
	err := c.Call(context.Background(), "eth_blockNumber", nil, &out)
	elapsed := time.Since(start)
	if err == nil {
		t.Fatal("expected timeout on a stalled response")
	}
	if !errors.Is(err, errHTTPTimeout) {
		t.Fatalf("want errHTTPTimeout, got %v", err)
	}
	if strings.Contains(err.Error(), "deadbeefcafe1234") {
		t.Fatalf("token leaked: %s", err.Error())
	}
	if elapsed > 3*time.Second {
		t.Fatalf("timeout took %v; should fail within the test bound", elapsed)
	}
	if elapsed < attempt {
		t.Fatalf("returned too fast (%v); deadline should have been waited", elapsed)
	}
}

func TestCallHTTPTimeoutThenSucceeds(t *testing.T) {
	const attempt = 80 * time.Millisecond
	var n atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if n.Add(1) == 1 {
			stallPastDeadline(3 * attempt).ServeHTTP(w, r)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"jsonrpc": "2.0",
			"id":      1,
			"result":  map[string]any{"number": "0x1"},
		})
	}))
	t.Cleanup(func() {
		srv.CloseClientConnections()
		srv.Close()
	})

	c := NewRPCClient(srv.URL)
	c.httpTimeout = attempt

	var out map[string]any
	if err := c.Call(context.Background(), "eth_getBlockByNumber", []any{"0x1", false}, &out); err != nil {
		t.Fatalf("retry after timeout should succeed: %v", err)
	}
	if got := n.Load(); got != 2 {
		t.Fatalf("attempts = %d, want 2", got)
	}
}

func TestCallCancelDuringStallReturnsPromptly(t *testing.T) {
	srv := httptest.NewServer(stallPastDeadline(5 * time.Second))
	t.Cleanup(func() {
		srv.CloseClientConnections()
		srv.Close()
	})

	c := NewRPCClient(srv.URL)
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
	if errors.Is(err, errHTTPTimeout) {
		t.Fatalf("cancel must win over http timeout: %v", err)
	}
	if elapsed > 2*time.Second {
		t.Fatalf("cancel took %v; should return promptly", elapsed)
	}
}
