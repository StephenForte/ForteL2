package derivation

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRedactRPCURL(t *testing.T) {
	got := redactRPCURL("https://example.quiknode.pro/deadbeefcafe1234/")
	if got != "https://example.quiknode.pro" {
		t.Fatalf("redactRPCURL = %q", got)
	}
	if redactRPCURL("::not a url") != "rpc-endpoint" {
		t.Fatalf("bad URL should redact to placeholder")
	}
}

func TestRedactErrHidesTokenAndUnwraps(t *testing.T) {
	c := NewRPCClient("https://example.quiknode.pro/deadbeefcafe1234/")
	orig := fmt.Errorf("Post %q: %w", "https://example.quiknode.pro/deadbeefcafe1234/", context.Canceled)
	red := c.redactErr(orig)
	if strings.Contains(red.Error(), "deadbeefcafe1234") {
		t.Fatalf("token leaked: %s", red.Error())
	}
	if !errors.Is(red, context.Canceled) {
		t.Fatalf("unwrap chain broken")
	}
}

// Empty JSON-RPC result (missing "result") used to hit json.Unmarshal("") in
// Call → BlockHeader died with "unexpected end of JSON input" after the L1 inbox scan.
func TestCallEmptyResultIsRPCError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1}`))
	}))
	t.Cleanup(srv.Close)

	c := tightRPCClient(srv.URL)
	var out map[string]any
	err := c.Call(context.Background(), "eth_getBlockByNumber", []any{"0x1", false}, &out)
	if err == nil {
		t.Fatal("expected error on empty result")
	}
	if strings.Contains(err.Error(), "unexpected end of JSON input") {
		t.Fatalf("empty result must not be unmarshaled: %v", err)
	}
	if !errors.Is(err, errEmptyRPCResult) {
		t.Fatalf("want errEmptyRPCResult, got %v", err)
	}
}

func TestBlockHeaderEmptyResultIsRPCError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1}`))
	}))
	t.Cleanup(srv.Close)

	l1 := NewL1Client(tightRPCClient(srv.URL))
	_, err := l1.BlockHeader(context.Background(), 1)
	if err == nil {
		t.Fatal("expected error on empty result")
	}
	if strings.Contains(err.Error(), "unexpected end of JSON input") {
		t.Fatalf("BlockHeader must not die on json.Unmarshal of empty result: %v", err)
	}
	if !errors.Is(err, errEmptyRPCResult) {
		t.Fatalf("want errEmptyRPCResult, got %v", err)
	}
}

func TestCallEmptyResultRetriesThenSucceeds(t *testing.T) {
	var n int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n++
		if n < 2 {
			_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1}`))
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"jsonrpc": "2.0",
			"id":      1,
			"result":  map[string]any{"number": "0x1"},
		})
	}))
	t.Cleanup(srv.Close)

	c := tightRPCClient(srv.URL)
	var out map[string]any
	if err := c.Call(context.Background(), "eth_getBlockByNumber", []any{"0x1", false}, &out); err != nil {
		t.Fatalf("retry should succeed: %v", err)
	}
	if n != 2 {
		t.Fatalf("attempts = %d, want 2", n)
	}
}
