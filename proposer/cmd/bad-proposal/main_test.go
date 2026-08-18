package main

import (
	"testing"

	"github.com/ethereum/go-ethereum/common"
)

func TestCorruptRoot(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		in   string
		want string
	}{
		{
			name: "all zeros last byte becomes 0xff",
			in:   "0x0000000000000000000000000000000000000000000000000000000000000000",
			want: "0x00000000000000000000000000000000000000000000000000000000000000ff",
		},
		{
			name: "all ones last byte becomes 0x00",
			in:   "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
			want: "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff00",
		},
		{
			name: "only last byte changes",
			in:   "0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
			want: "0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd10",
		},
		{
			name: "fixture last byte 0x16 xor 0xff is 0xe9",
			in:   "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa16",
			want: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaae9",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := corruptRoot(common.HexToHash(tc.in))
			want := common.HexToHash(tc.want)
			if got != want {
				t.Fatalf("corruptRoot(%s)=%s want %s", tc.in, got.Hex(), want.Hex())
			}
			if got == common.HexToHash(tc.in) {
				t.Fatal("corruptRoot must not equal the honest root")
			}
			in := common.HexToHash(tc.in)
			for i := 0; i < common.HashLength-1; i++ {
				if got[i] != in[i] {
					t.Fatalf("byte %d changed: got %02x want %02x", i, got[i], in[i])
				}
			}
			if got[common.HashLength-1] != in[common.HashLength-1]^0xFF {
				t.Fatalf("last byte: got %02x want %02x", got[common.HashLength-1], in[common.HashLength-1]^0xFF)
			}
		})
	}
}

func TestCorruptRootAlwaysDiffers(t *testing.T) {
	t.Parallel()
	roots := []common.Hash{
		{},
		common.HexToHash("0x01"),
		common.HexToHash("0xdeadbeef"),
		common.HexToHash("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
	}
	for _, r := range roots {
		if got := corruptRoot(r); got == r {
			t.Fatalf("corruptRoot(%s) was a no-op", r.Hex())
		}
	}
}

func TestConfirmRequested(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		flag bool
		env  string
		want bool
	}{
		{name: "neither", flag: false, env: "", want: false},
		{name: "flag true", flag: true, env: "", want: true},
		{name: "env true", flag: false, env: "true", want: true},
		{name: "env true trimmed", flag: false, env: "  true\n", want: true},
		{name: "flag wins over empty env", flag: true, env: "false", want: true},
		{name: "env 1 is not enough", flag: false, env: "1", want: false},
		{name: "env yes is not enough", flag: false, env: "yes", want: false},
		{name: "env TRUE is not enough", flag: false, env: "TRUE", want: false},
		{name: "env false", flag: false, env: "false", want: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := confirmRequested(tc.flag, tc.env); got != tc.want {
				t.Fatalf("confirmRequested(%v, %q)=%v want %v", tc.flag, tc.env, got, tc.want)
			}
		})
	}
}
