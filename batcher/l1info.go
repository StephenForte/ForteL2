package batcher

import (
	"encoding/binary"
	"fmt"
)

// DepositTxType is the EIP-2718 type byte for OP Stack deposit transactions.
const DepositTxType = 0x7e

// L1-info deposit selectors (cast sig / op-node derive package).
var (
	l1InfoBedrockSel = [4]byte{0x01, 0x5d, 0x8e, 0xb9} // setL1BlockValues(…)
	l1InfoEcotoneSel = [4]byte{0x44, 0x0a, 0x5e, 0x20} // setL1BlockValuesEcotone()
	l1InfoIsthmusSel = [4]byte{0x09, 0x89, 0x99, 0xbe} // setL1BlockValuesIsthmus()
	l1InfoJovianSel  = [4]byte{0x3d, 0xb6, 0xbe, 0x2b} // setL1BlockValuesJovian()
)

// L1InfoEpoch is the sequencing-epoch identity carried in the L1-info deposit.
type L1InfoEpoch struct {
	Number uint64
	Hash   [32]byte
}

// ParseL1InfoEpoch extracts epoch number + hash from an L1-info deposit calldata.
// Supports Bedrock ABI layout and packed Ecotone / Isthmus / Jovian layouts.
func ParseL1InfoEpoch(data []byte) (L1InfoEpoch, error) {
	if len(data) < 4 {
		return L1InfoEpoch{}, fmt.Errorf("l1 info too short: %d", len(data))
	}
	var sel [4]byte
	copy(sel[:], data[:4])
	switch sel {
	case l1InfoBedrockSel:
		return parseBedrockEpoch(data)
	case l1InfoEcotoneSel, l1InfoIsthmusSel, l1InfoJovianSel:
		return parseEcotoneFamilyEpoch(data)
	default:
		// Activation blocks may still use the prior format; fall back by length.
		switch {
		case len(data) == 4+32*8:
			return parseBedrockEpoch(data)
		case len(data) >= 4+32*5:
			return parseEcotoneFamilyEpoch(data)
		default:
			return L1InfoEpoch{}, fmt.Errorf("unknown l1 info selector %x len=%d", sel, len(data))
		}
	}
}

func parseBedrockEpoch(data []byte) (L1InfoEpoch, error) {
	// |4 sig|32 number|32 time|32 basefee|32 blockhash|…
	if len(data) < 4+32*4 {
		return L1InfoEpoch{}, fmt.Errorf("bedrock l1 info truncated")
	}
	var out L1InfoEpoch
	out.Number = binary.BigEndian.Uint64(data[4+24 : 4+32]) // ABI uint64 in last 8 of word
	copy(out.Hash[:], data[4+32*3:4+32*4])
	return out, nil
}

func parseEcotoneFamilyEpoch(data []byte) (L1InfoEpoch, error) {
	// After sig: baseFeeScalar(4)|blobBaseFeeScalar(4)|seq(8)|time(8)|number(8)|basefee(32)|blob(32)|hash(32)|…
	const min = 4 + 4 + 4 + 8 + 8 + 8 + 32 + 32 + 32
	if len(data) < min {
		return L1InfoEpoch{}, fmt.Errorf("ecotone-family l1 info truncated: %d", len(data))
	}
	off := 4 + 4 + 4 + 8 + 8
	var out L1InfoEpoch
	out.Number = binary.BigEndian.Uint64(data[off : off+8])
	off += 8 + 32 + 32
	copy(out.Hash[:], data[off:off+32])
	return out, nil
}
