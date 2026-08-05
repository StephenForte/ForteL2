package batcher

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
)

func TestRedactRPCURL(t *testing.T) {
	got := RedactRPCURL("https://example.quiknode.pro/deadbeefcafe1234/")
	if got != "https://example.quiknode.pro" {
		t.Fatalf("RedactRPCURL = %q", got)
	}
	if RedactRPCURL("::not a url") != "rpc-endpoint" {
		t.Fatalf("bad URL should redact to placeholder")
	}
}

func TestRedactErrHidesTokenAndUnwraps(t *testing.T) {
	raw := "https://example.quiknode.pro/deadbeefcafe1234/"
	red := RedactRPCURL(raw)
	orig := fmt.Errorf("Post %q: %w", raw, context.Canceled)
	got := RedactErr(raw, red, orig)
	if strings.Contains(got.Error(), "deadbeefcafe1234") {
		t.Fatalf("token leaked: %s", got.Error())
	}
	if !errors.Is(got, context.Canceled) {
		t.Fatalf("unwrap chain broken")
	}
}
