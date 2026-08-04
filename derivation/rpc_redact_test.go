package derivation

import (
	"context"
	"errors"
	"fmt"
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
