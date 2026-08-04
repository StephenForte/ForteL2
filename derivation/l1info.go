package derivation

import (
	"bytes"
	"encoding/binary"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

const (
	l1InfoDepositerAddress      = "0xdeaddeaddeaddeaddeaddeaddeaddeaddead0001"
	l1BlockAddress              = "0x4200000000000000000000000000000000000015"
	regolithSystemTxGas         = 1_000_000
	daFootprintGasScalarDefault = 400
)

var (
	l1InfoFuncBedrockBytes4 = crypto.Keccak256([]byte("setL1BlockValues(uint64,uint64,uint256,bytes32,uint64,bytes32,uint256,uint256)"))[:4]
	l1InfoFuncEcotoneBytes4  = crypto.Keccak256([]byte("setL1BlockValuesEcotone()"))[:4]
	l1InfoFuncIsthmusBytes4  = crypto.Keccak256([]byte("setL1BlockValuesIsthmus()"))[:4]
	l1InfoFuncJovianBytes4   = crypto.Keccak256([]byte("setL1BlockValuesJovian()"))[:4]
)

type l1InfoDepositSource struct {
	l1BlockHash common.Hash
	seqNumber   uint64
}

func (s l1InfoDepositSource) sourceHash() common.Hash {
	var input [64]byte
	copy(input[:32], s.l1BlockHash[:])
	binary.BigEndian.PutUint64(input[56:], s.seqNumber)
	depositID := crypto.Keccak256Hash(input[:])
	var domain [64]byte
	binary.BigEndian.PutUint64(domain[24:32], 1)
	copy(domain[32:], depositID[:])
	return crypto.Keccak256Hash(domain[:])
}

// L1InfoDepositBytes builds the first (L1-info) deposit tx for a derived block.
func L1InfoDepositBytes(cfg *RollupConfig, sys SystemConfig, seqNumber uint64, l1 *L1BlockHeader, l2Timestamp uint64) ([]byte, error) {
	data, err := marshalL1Info(cfg, sys, seqNumber, l1, l2Timestamp)
	if err != nil {
		return nil, err
	}
	src := l1InfoDepositSource{l1BlockHash: l1.Hash, seqNumber: seqNumber}
	to := common.HexToAddress(l1BlockAddress)
	gas := uint64(150_000_000)
	isSystem := true
	if cfg.IsRegolith(l2Timestamp) {
		isSystem = false
		gas = regolithSystemTxGas
	}
	return encodeDepositTx(src.sourceHash(), common.HexToAddress(l1InfoDepositerAddress), &to, nil, big.NewInt(0), gas, isSystem, data)
}

func marshalL1Info(cfg *RollupConfig, sys SystemConfig, seqNumber uint64, l1 *L1BlockHeader, l2Timestamp uint64) ([]byte, error) {
	jovian := cfg.IsJovian(l2Timestamp) && !cfg.IsJovianActivationBlock(l2Timestamp)
	isthmus := cfg.IsIsthmus(l2Timestamp) && !cfg.IsIsthmusActivationBlock(l2Timestamp)
	ecotone := cfg.IsEcotone(l2Timestamp) && !cfg.IsEcotoneActivationBlock(l2Timestamp)

	baseFee := l1.BaseFee
	if baseFee == nil {
		baseFee = big.NewInt(0)
	}
	blobBaseFee := l1.BlobBaseFee
	if blobBaseFee == nil {
		blobBaseFee = new(big.Int).Set(blobBaseFeePreCancun)
	}
	baseFeeScalar, blobBaseFeeScalar, _ := sys.EcotoneScalars()
	opScalar, opConstant := sys.OperatorFee()
	daScalar := sys.DAFootprintGasScalar
	if daScalar == 0 {
		daScalar = daFootprintGasScalarDefault
	}

	switch {
	case jovian:
		return marshalJovian(seqNumber, l1, baseFee, blobBaseFee, sys.BatcherAddr, baseFeeScalar, blobBaseFeeScalar, opScalar, opConstant, daScalar)
	case isthmus:
		return marshalIsthmus(seqNumber, l1, baseFee, blobBaseFee, sys.BatcherAddr, baseFeeScalar, blobBaseFeeScalar, opScalar, opConstant)
	case ecotone:
		return marshalEcotone(seqNumber, l1, baseFee, blobBaseFee, sys.BatcherAddr, baseFeeScalar, blobBaseFeeScalar)
	default:
		return marshalBedrock(seqNumber, l1, baseFee, sys)
	}
}

func marshalBedrock(seqNumber uint64, l1 *L1BlockHeader, baseFee *big.Int, sys SystemConfig) ([]byte, error) {
	w := bytes.NewBuffer(make([]byte, 0, 260))
	w.Write(l1InfoFuncBedrockBytes4)
	writeU64(w, l1.Number)
	writeU64(w, l1.Time)
	writeU256(w, baseFee)
	writeHash(w, l1.Hash)
	writeU64(w, seqNumber)
	writeAddress(w, sys.BatcherAddr)
	w.Write(sys.Overhead.Bytes().Bytes())
	w.Write(sys.Scalar.Bytes().Bytes())
	return w.Bytes(), nil
}

func marshalEcotone(seqNumber uint64, l1 *L1BlockHeader, baseFee, blobBaseFee *big.Int, batcher common.Address, baseScalar, blobScalar uint32) ([]byte, error) {
	w := bytes.NewBuffer(make([]byte, 0, 200))
	w.Write(l1InfoFuncEcotoneBytes4)
	marshalEcotoneBody(w, seqNumber, l1, baseFee, blobBaseFee, batcher, baseScalar, blobScalar)
	return w.Bytes(), nil
}

func marshalIsthmus(seqNumber uint64, l1 *L1BlockHeader, baseFee, blobBaseFee *big.Int, batcher common.Address, baseScalar, blobScalar, opScalar uint32, opConstant uint64) ([]byte, error) {
	w := bytes.NewBuffer(make([]byte, 0, 220))
	w.Write(l1InfoFuncIsthmusBytes4)
	marshalEcotoneBody(w, seqNumber, l1, baseFee, blobBaseFee, batcher, baseScalar, blobScalar)
	binary.Write(w, binary.BigEndian, opScalar)
	binary.Write(w, binary.BigEndian, opConstant)
	return w.Bytes(), nil
}

func marshalJovian(seqNumber uint64, l1 *L1BlockHeader, baseFee, blobBaseFee *big.Int, batcher common.Address, baseScalar, blobScalar, opScalar uint32, opConstant uint64, daScalar uint16) ([]byte, error) {
	w := bytes.NewBuffer(make([]byte, 0, 224))
	w.Write(l1InfoFuncJovianBytes4)
	marshalEcotoneBody(w, seqNumber, l1, baseFee, blobBaseFee, batcher, baseScalar, blobScalar)
	binary.Write(w, binary.BigEndian, opScalar)
	binary.Write(w, binary.BigEndian, opConstant)
	binary.Write(w, binary.BigEndian, daScalar)
	return w.Bytes(), nil
}

func marshalEcotoneBody(w *bytes.Buffer, seqNumber uint64, l1 *L1BlockHeader, baseFee, blobBaseFee *big.Int, batcher common.Address, baseScalar, blobScalar uint32) {
	binary.Write(w, binary.BigEndian, baseScalar)
	binary.Write(w, binary.BigEndian, blobScalar)
	binary.Write(w, binary.BigEndian, seqNumber)
	binary.Write(w, binary.BigEndian, l1.Time)
	binary.Write(w, binary.BigEndian, l1.Number)
	writeU256(w, baseFee)
	writeU256(w, blobBaseFee)
	writeHash(w, l1.Hash)
	writeAddress(w, batcher)
}

func writeU64(w *bytes.Buffer, v uint64) {
	var buf [32]byte
	binary.BigEndian.PutUint64(buf[24:], v)
	w.Write(buf[:])
}

func writeU256(w *bytes.Buffer, v *big.Int) {
	buf := make([]byte, 32)
	if v != nil {
		b := v.Bytes()
		copy(buf[32-len(b):], b)
	}
	w.Write(buf)
}

func writeHash(w *bytes.Buffer, h common.Hash) { w.Write(h[:]) }

func writeAddress(w *bytes.Buffer, a common.Address) {
	var buf [32]byte
	copy(buf[12:], a[:])
	w.Write(buf[:])
}
