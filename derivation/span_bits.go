package derivation

import (
	"bytes"
	"fmt"
	"io"
	"math/big"
)

// decodeSpanBatchBits decodes a standard span-batch bitlist.
// The bitlist is encoded as big-endian integer, left-padded with zeroes to a multiple of 8 bits.
func decodeSpanBatchBits(r *bytes.Reader, bitLength uint64) (*big.Int, error) {
	bufLen := bitLength / 8
	if bitLength%8 != 0 {
		bufLen++
	}
	buf := make([]byte, bufLen)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, fmt.Errorf("failed to read bits: %w", err)
	}
	out := new(big.Int)
	out.SetBytes(buf)
	if l := uint64(out.BitLen()); l > bitLength {
		return nil, fmt.Errorf("bitfield has %d bits, but expected no more than %d", l, bitLength)
	}
	return out, nil
}

// encodeSpanBatchBits encodes a standard span-batch bitlist (used by tests).
func encodeSpanBatchBits(w io.Writer, bitLength uint64, bits *big.Int) error {
	if l := uint64(bits.BitLen()); l > bitLength {
		return fmt.Errorf("bitfield is larger than bitLength: %d > %d", l, bitLength)
	}
	bufLen := bitLength / 8
	if bitLength%8 != 0 {
		bufLen++
	}
	buf := make([]byte, bufLen)
	bits.FillBytes(buf)
	if _, err := w.Write(buf); err != nil {
		return fmt.Errorf("cannot write bits: %w", err)
	}
	return nil
}
