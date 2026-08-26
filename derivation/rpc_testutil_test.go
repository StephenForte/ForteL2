package derivation

import (
	"io"
	"os"
	"testing"
	"time"
)

func TestMain(m *testing.M) {
	_ = os.Unsetenv("DERIVATION_RPC_MAX_RPS")
	os.Exit(m.Run())
}

// tightRPCClient shrinks retry/backoff so fixture tests do not sleep production
// patience (1s…30s exponential) in CI.
func tightRPCClient(rawURL string) *RPCClient {
	c := NewRPCClient(rawURL)
	c.retryAttempts = 3
	c.backoffBase = time.Millisecond
	c.backoffMax = 2 * time.Millisecond
	c.jitter = func(d time.Duration) time.Duration { return d }
	c.logw = io.Discard
	return c
}
