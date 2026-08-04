package derivation

import (
	"testing"
)

func TestValidateL2OriginTimestamp(t *testing.T) {
	maxDrift := uint64(1800)
	cases := []struct {
		name    string
		l2Ts    uint64
		l1Ts    uint64
		wantErr bool
	}{
		{"equal", 1000, 1000, false},
		{"within drift", 1500, 1000, false},
		{"at drift cap", 2800, 1000, false},
		{"l2 before l1", 999, 1000, true},
		{"past drift", 2801, 1000, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := ValidateL2OriginTimestamp(tc.l2Ts, tc.l1Ts, maxDrift)
			if (err != nil) != tc.wantErr {
				t.Fatalf("ValidateL2OriginTimestamp(%d,%d,%d) err=%v wantErr=%v", tc.l2Ts, tc.l1Ts, maxDrift, err, tc.wantErr)
			}
		})
	}
}

func TestValidateL2OriginTimestampRejectsFutureL1Tip(t *testing.T) {
	cfg := testRollupConfig()
	zero := uint64(0)
	cfg.FjordTime = &zero
	cfg.Genesis.L2Time = 1_700_000_000
	firstL2Ts := cfg.Genesis.L2Time + cfg.BlockTime

	// Old stub default: L1 tip timestamp far ahead of the first planned L2 block.
	futureL1Time := firstL2Ts + 3600
	maxDrift := cfg.EffectiveMaxSequencerDrift(firstL2Ts)
	if err := ValidateL2OriginTimestamp(firstL2Ts, futureL1Time, maxDrift); err == nil {
		t.Fatal("expected rejection when l1 origin timestamp is in the future relative to l2")
	}
}

func TestEffectiveMaxSequencerDriftFjord(t *testing.T) {
	cfg := testRollupConfig()
	zero := uint64(0)
	cfg.FjordTime = &zero
	cfg.MaxSequencerDrift = 600
	if got := cfg.EffectiveMaxSequencerDrift(cfg.Genesis.L2Time + 2); got != fjordMaxSequencerDrift {
		t.Fatalf("Fjord drift = %d want %d", got, fjordMaxSequencerDrift)
	}
}
