package derivation

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/common"
)

func TestInboxScanStart(t *testing.T) {
	const (
		timeout = 300
		margin  = 1
		genesis = 11_545_587
	)
	cases := []struct {
		name    string
		origin  uint64
		timeout uint64
		margin  uint64
		genesis uint64
		want    uint64
	}{
		{
			name:    "origin well above genesis",
			origin:  genesis + 10_000,
			timeout: timeout,
			margin:  margin,
			genesis: genesis,
			want:    genesis + 10_000 - timeout - margin,
		},
		{
			name:    "clamped at genesis.l1",
			origin:  genesis + 100,
			timeout: timeout,
			margin:  margin,
			genesis: genesis,
			want:    genesis,
		},
		{
			name:    "origin below timeout+margin clamps at genesis",
			origin:  50,
			timeout: timeout,
			margin:  margin,
			genesis: genesis,
			want:    genesis,
		},
		{
			name:    "exact bound (origin - timeout - margin == genesis)",
			origin:  genesis + timeout + margin,
			timeout: timeout,
			margin:  margin,
			genesis: genesis,
			want:    genesis,
		},
		{
			name:    "one above clamp",
			origin:  genesis + timeout + margin + 1,
			timeout: timeout,
			margin:  margin,
			genesis: genesis,
			want:    genesis + 1,
		},
		{
			name:    "zero genesis.l1 (local Anvil)",
			origin:  500,
			timeout: timeout,
			margin:  margin,
			genesis: 0,
			want:    500 - timeout - margin,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := InboxScanStart(tc.origin, tc.timeout, tc.margin, tc.genesis)
			if got != tc.want {
				t.Fatalf("InboxScanStart(%d, %d, %d, %d) = %d, want %d",
					tc.origin, tc.timeout, tc.margin, tc.genesis, got, tc.want)
			}
		})
	}
}

func TestInboxScanStartMatchesResumeScanMargin(t *testing.T) {
	if ResumeScanMargin != 1 {
		t.Fatalf("ResumeScanMargin = %d, want 1 (off-by-one hedge on channel timeout)", ResumeScanMargin)
	}
}

func TestLoadRollupConfigReadsChannelTimeout(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "rollup.json")
	raw := []byte(`{
		"genesis": {"l1": {"hash": "0xaf5518e27683473d8bcc776fadc48c2af9ef1d9881ed0f62c5e3a9ffd25c0800", "number": 11545587}, "l2_time": 1, "system_config": {"batcherAddr": "0x00000000000000000000000000000000000000aa"}},
		"block_time": 2,
		"channel_timeout": 300,
		"batch_inbox_address": "0x00000000000000000000000000000000000000bb"
	}`)
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadRollupConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.ChannelTimeout != 300 {
		t.Fatalf("ChannelTimeout = %d, want 300 from rollup.json", cfg.ChannelTimeout)
	}
	if cfg.Genesis.L1.Number != 11_545_587 {
		t.Fatalf("genesis.l1 = %d", cfg.Genesis.L1.Number)
	}
}

type fakeL1InfoSrc struct {
	raw    []byte
	err    error
	gotNum uint64
}

func (f *fakeL1InfoSrc) BlockFirstTx(_ context.Context, num uint64) ([]byte, error) {
	f.gotNum = num
	return f.raw, f.err
}

func resumeTestDeposit(t *testing.T, origin uint64) []byte {
	t.Helper()
	cfg := testRollup901()
	l1 := &L1BlockHeader{
		Number: origin,
		Time:   999,
		Hash:   common.BytesToHash([]byte("resume-scan-l1-origin-hash!!")),
	}
	raw, err := L1InfoDepositBytes(cfg, cfg.Genesis.SystemConfig, 3, l1, 1_700_000_010)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestResolveResumeInboxScanDerivesBound(t *testing.T) {
	const (
		origin  = 11_545_587 + 5_000
		timeout = 300
		genesis = 11_545_587
	)
	src := &fakeL1InfoSrc{raw: resumeTestDeposit(t, origin)}
	cfg := testRollup901()
	cfg.ChannelTimeout = timeout
	cfg.Genesis.L1.Number = genesis
	opts := VerifyOptions{ResumeL1Bound: true, StartL2: 201}
	if err := resolveResumeInboxScan(context.Background(), src, cfg, &opts); err != nil {
		t.Fatal(err)
	}
	want := InboxScanStart(origin, timeout, ResumeScanMargin, genesis)
	if opts.FromL1Block != want {
		t.Fatalf("FromL1Block = %d, want %d", opts.FromL1Block, want)
	}
	if src.gotNum != 200 {
		t.Fatalf("read L1-info from block %d, want 200 (StartL2-1)", src.gotNum)
	}
}

func TestResolveResumeInboxScanGenesisUnchanged(t *testing.T) {
	src := &fakeL1InfoSrc{raw: resumeTestDeposit(t, 99)}
	cfg := testRollup901()
	cfg.ChannelTimeout = 300
	opts := VerifyOptions{ResumeL1Bound: true, StartL2: 1}
	if err := resolveResumeInboxScan(context.Background(), src, cfg, &opts); err != nil {
		t.Fatal(err)
	}
	if opts.FromL1Block != 0 {
		t.Fatalf("genesis start must not set FromL1Block (got %d); shell supplies rollup genesis.l1", opts.FromL1Block)
	}
	if src.gotNum != 0 {
		t.Fatal("must not read sealing EL on StartL2<=1")
	}
}

func TestResolveResumeInboxScanExplicitFromL1Wins(t *testing.T) {
	src := &fakeL1InfoSrc{raw: resumeTestDeposit(t, 99)}
	cfg := testRollup901()
	cfg.ChannelTimeout = 300
	opts := VerifyOptions{ResumeL1Bound: true, StartL2: 50, FromL1Block: 42}
	if err := resolveResumeInboxScan(context.Background(), src, cfg, &opts); err != nil {
		t.Fatal(err)
	}
	if opts.FromL1Block != 42 {
		t.Fatalf("explicit -from-l1 must win, got %d", opts.FromL1Block)
	}
}

func TestResolveResumeInboxScanRequiresChannelTimeout(t *testing.T) {
	src := &fakeL1InfoSrc{raw: resumeTestDeposit(t, 99)}
	cfg := testRollup901() // ChannelTimeout stays 0
	opts := VerifyOptions{ResumeL1Bound: true, StartL2: 50}
	err := resolveResumeInboxScan(context.Background(), src, cfg, &opts)
	if err == nil || !strings.Contains(err.Error(), "channel_timeout is 0") {
		t.Fatalf("want fail-closed on missing channel_timeout, got %v", err)
	}
}

func TestResolveResumeInboxScanNoOpWhenFlagOff(t *testing.T) {
	src := &fakeL1InfoSrc{raw: resumeTestDeposit(t, 99)}
	cfg := testRollup901()
	cfg.ChannelTimeout = 300
	opts := VerifyOptions{StartL2: 50}
	if err := resolveResumeInboxScan(context.Background(), src, cfg, &opts); err != nil {
		t.Fatal(err)
	}
	if opts.FromL1Block != 0 {
		t.Fatalf("legacy path must not derive a resume bound, got %d", opts.FromL1Block)
	}
}

func TestRollupJSONChannelTimeoutRoundTrip(t *testing.T) {
	// Guard: we read the field by name, never a hard-coded 300 in InboxScanStart.
	var cfg RollupConfig
	if err := json.Unmarshal([]byte(`{"channel_timeout": 300}`), &cfg); err != nil {
		t.Fatal(err)
	}
	if cfg.ChannelTimeout != 300 {
		t.Fatalf("got %d", cfg.ChannelTimeout)
	}
	got := InboxScanStart(10_000, cfg.ChannelTimeout, 1, 100)
	if got != 10_000-300-1 {
		t.Fatalf("got %d", got)
	}
}
