package derivation

import (
	"fmt"
	"log"
)

// blockNumberFromTimestamp maps an L2 batch timestamp to its block number.
// OP Stack L2 blocks are dense: block N time = genesis.l2_time + N * block_time.
func blockNumberFromTimestamp(cfg *RollupConfig, ts uint64) (uint64, error) {
	bt := cfg.BlockTime
	if bt == 0 {
		bt = 2
	}
	genesisTime := cfg.Genesis.L2Time
	if ts < genesisTime {
		return 0, fmt.Errorf("batch timestamp %d before genesis l2_time %d", ts, genesisTime)
	}
	delta := ts - genesisTime
	if delta%bt != 0 {
		return 0, fmt.Errorf("timestamp drift: (ts %d − l2_time %d) %% block_time %d != 0 (remainder %d)",
			ts, genesisTime, bt, delta%bt)
	}
	num := delta / bt
	if num == 0 {
		return 0, fmt.Errorf("timestamp %d maps to block 0 (genesis); batches must be >= block 1", ts)
	}
	return num, nil
}

func logDuplicateBlock(num uint64, prev, next BlockInput) {
	log.Printf("derivation: duplicate batch for block %d (last write wins): prev tx %s ts %d, new tx %s ts %d",
		num, prev.L1SourceTx, prev.Timestamp, next.L1SourceTx, next.Timestamp)
}
