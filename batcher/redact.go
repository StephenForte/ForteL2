package batcher

import (
	"net/url"
	"strings"
)

// RedactRPCURL strips path, query, and userinfo — hosted RPC URLs carry API
// tokens there (same policy as scripts/lib.sh redact_rpc_url).
func RedactRPCURL(raw string) string {
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

// RedactErr replaces raw RPC URLs in transport error text with RedactRPCURL.
func RedactErr(rawURL, redacted string, err error) error {
	if err == nil {
		return nil
	}
	if redacted == "" {
		redacted = RedactRPCURL(rawURL)
	}
	return &redactedError{msg: strings.ReplaceAll(err.Error(), rawURL, redacted), err: err}
}
