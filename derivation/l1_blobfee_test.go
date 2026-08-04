package derivation

import (
	"context"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
)

// Method-not-found (-32601) is the ONE error that may fall back to the legacy
// constant 1 (pre-Cancun / non-supporting node).
func TestBlobBaseFeeMethodNotFoundFallsBackToOne(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			ID uint64 `json:"id"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"jsonrpc": "2.0",
			"id":      req.ID,
			"error":   map[string]any{"code": -32601, "message": "method not found"},
		})
	}))
	defer srv.Close()

	c := NewL1Client(NewRPCClient(srv.URL))
	fee, err := c.blobBaseFeeAt(context.Background(), 42)
	if err != nil {
		t.Fatalf("expected fallback, got error: %v", err)
	}
	if fee.Cmp(big.NewInt(1)) != 0 {
		t.Fatalf("expected fallback fee 1, got %s", fee)
	}
}

// Any other failure (transport error, malformed body, rate limit) must
// propagate — a silent 1 would intermittently corrupt L1-info bytes.
func TestBlobBaseFeeTransportErrorPropagates(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest) // empty body, like an unhandled method
	}))
	defer srv.Close()

	c := NewL1Client(NewRPCClient(srv.URL))
	if _, err := c.blobBaseFeeAt(context.Background(), 42); err == nil {
		t.Fatal("expected transport/decode error to propagate, got nil")
	}
}
