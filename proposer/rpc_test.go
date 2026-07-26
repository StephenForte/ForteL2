package proposer

import (
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/common"
)

func TestParseExactHash(t *testing.T) {
	t.Parallel()
	good := "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	want := common.HexToHash(good)

	cases := []struct {
		name    string
		in      string
		wantErr string
		want    common.Hash
	}{
		{name: "exact 32-byte", in: good, want: want},
		{name: "uppercase hex ok", in: strings.ToUpper(good), want: want},
		{name: "empty", in: "", wantErr: "empty"},
		{name: "missing 0x", in: strings.TrimPrefix(good, "0x"), wantErr: "0x-prefixed"},
		{name: "too short", in: "0xaaaa", wantErr: "32 bytes"},
		{name: "too long", in: good + "aa", wantErr: "32 bytes"},
		{name: "non-hex", in: "0xzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", wantErr: "invalid hex"},
		{name: "odd length padded by HexToHash", in: "0xabc", wantErr: "32 bytes"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got, err := ParseExactHash(tc.in)
			if tc.wantErr != "" {
				if err == nil {
					t.Fatalf("expected error containing %q, got hash %s", tc.wantErr, got.Hex())
				}
				if !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("err=%v want substring %q", err, tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got != tc.want {
				t.Fatalf("got %s want %s", got.Hex(), tc.want.Hex())
			}
		})
	}
}
