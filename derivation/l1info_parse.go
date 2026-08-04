package derivation

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/rlp"
)

// L1InfoFromDeposit holds L1 origin fields decoded from an L1-info deposit tx.
type L1InfoFromDeposit struct {
	L1OriginNumber uint64
	L1OriginHash   common.Hash
	SeqNumber      uint64
}

// ParseL1InfoDeposit decodes the L1-info deposit (first tx of every L2 block).
func ParseL1InfoDeposit(rawTx []byte) (L1InfoFromDeposit, error) {
	if len(rawTx) == 0 {
		return L1InfoFromDeposit{}, fmt.Errorf("empty raw tx")
	}
	if rawTx[0] != depositTxType {
		return L1InfoFromDeposit{}, fmt.Errorf("not a deposit tx (type 0x%x)", rawTx[0])
	}
	var dep depositTxRLP
	if err := rlp.DecodeBytes(rawTx[1:], &dep); err != nil {
		return L1InfoFromDeposit{}, fmt.Errorf("decode deposit tx: %w", err)
	}
	if dep.To == nil || !bytes.EqualFold(dep.To.Bytes(), common.HexToAddress(l1BlockAddress).Bytes()) {
		return L1InfoFromDeposit{}, fmt.Errorf("deposit to is not L1Block contract")
	}
	if !bytes.EqualFold(dep.From.Bytes(), common.HexToAddress(l1InfoDepositerAddress).Bytes()) {
		return L1InfoFromDeposit{}, fmt.Errorf("deposit from is not L1-info depositer")
	}
	return parseL1InfoCalldata(dep.Data)
}

func parseL1InfoCalldata(data []byte) (L1InfoFromDeposit, error) {
	if len(data) < 4 {
		return L1InfoFromDeposit{}, fmt.Errorf("calldata too short")
	}
	sel := data[:4]
	body := data[4:]

	switch {
	case bytes.Equal(sel, l1InfoFuncBedrockBytes4):
		return parseBedrockL1Info(body)
	case bytes.Equal(sel, l1InfoFuncEcotoneBytes4),
		bytes.Equal(sel, l1InfoFuncIsthmusBytes4),
		bytes.Equal(sel, l1InfoFuncJovianBytes4):
		return parseEcotoneFamilyL1Info(body)
	default:
		return L1InfoFromDeposit{}, fmt.Errorf("unknown L1-info selector 0x%x", sel)
	}
}

func parseBedrockL1Info(body []byte) (L1InfoFromDeposit, error) {
	// ABI: setL1BlockValues(uint64 l1Number, uint64 l1Time, uint256 baseFee,
	//      bytes32 l1BlockHash, uint64 seqNumber, ...)
	if len(body) < 32*5 {
		return L1InfoFromDeposit{}, fmt.Errorf("bedrock calldata too short (%d bytes)", len(body))
	}
	l1Num := readABIU64(body[0:32])
	l1Hash := common.BytesToHash(body[96:128])
	seq := readABIU64(body[128:160])
	return L1InfoFromDeposit{
		L1OriginNumber: l1Num,
		L1OriginHash:   l1Hash,
		SeqNumber:      seq,
	}, nil
}

func parseEcotoneFamilyL1Info(body []byte) (L1InfoFromDeposit, error) {
	// marshalEcotoneBody: baseScalar(4) blobScalar(4) seqNumber(8) l1Time(8) l1Number(8)
	// baseFee(32) blobBaseFee(32) l1Hash(32) batcher(32)
	if len(body) < 8+8+8+8+32+32+32 {
		return L1InfoFromDeposit{}, fmt.Errorf("ecotone-family calldata too short (%d bytes)", len(body))
	}
	off := 8 // skip baseScalar + blobScalar
	seq := binary.BigEndian.Uint64(body[off : off+8])
	off += 8 + 8 // skip l1Time
	l1Num := binary.BigEndian.Uint64(body[off : off+8])
	off += 8 + 32 + 32 // skip baseFee + blobBaseFee
	l1Hash := common.BytesToHash(body[off : off+32])
	return L1InfoFromDeposit{
		L1OriginNumber: l1Num,
		L1OriginHash:   l1Hash,
		SeqNumber:      seq,
	}, nil
}

func readABIU64(word []byte) uint64 {
	if len(word) < 32 {
		return 0
	}
	return binary.BigEndian.Uint64(word[24:32])
}

// readU256 is kept for potential future parsing needs.
func readU256(word []byte) *big.Int {
	if len(word) < 32 {
		return big.NewInt(0)
	}
	return new(big.Int).SetBytes(word)
}
