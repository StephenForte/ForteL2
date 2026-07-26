package proposer

import (
	"encoding/binary"
	"fmt"
)

// ExtraDataSize is the DisputeGameFactory proposal extraData length used by
// stock op-proposer for single-chain (non-super) output roots: 32 bytes with
// the L2 sequence number in the last 8 bytes (big-endian).
const ExtraDataSize = 32

// PackExtraData encodes an L2 sequence number (typically block number) into
// the 32-byte extraData blob expected by DisputeGameFactory.create.
func PackExtraData(sequenceNum uint64) []byte {
	var extra [ExtraDataSize]byte
	binary.BigEndian.PutUint64(extra[24:], sequenceNum)
	return extra[:]
}

// UnpackExtraData reads the L2 sequence number from a 32-byte proposal extraData.
func UnpackExtraData(extraData []byte) (uint64, error) {
	if len(extraData) != ExtraDataSize {
		return 0, fmt.Errorf("extraData length %d, want %d", len(extraData), ExtraDataSize)
	}
	return binary.BigEndian.Uint64(extraData[24:]), nil
}
