package derivation

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/rlp"
	"github.com/holiman/uint256"
)

type spanBatchTxs struct {
	totalBlockTxCount uint64

	contractCreationBits *big.Int
	yParityBits          *big.Int
	txSigs               []spanBatchSignature
	txNonces             []uint64
	txGases              []uint64
	txTos                []common.Address
	txDatas              [][]byte
	protectedBits        *big.Int

	txTypes            []int
	totalLegacyTxCount uint64
}

type spanBatchSignature struct {
	v *big.Int
	r *uint256.Int
	s *uint256.Int
}

type spanBatchTxData interface {
	txType() byte
}

type spanBatchTx struct {
	inner spanBatchTxData
}

type spanBatchLegacyTxData struct {
	Value    *big.Int
	GasPrice *big.Int
	Data     []byte
}

func (txData *spanBatchLegacyTxData) txType() byte { return types.LegacyTxType }

type spanBatchAccessListTxData struct {
	Value      *big.Int
	GasPrice   *big.Int
	Data       []byte
	AccessList types.AccessList
}

func (txData *spanBatchAccessListTxData) txType() byte { return types.AccessListTxType }

type spanBatchDynamicFeeTxData struct {
	Value      *big.Int
	GasTipCap  *big.Int
	GasFeeCap  *big.Int
	Data       []byte
	AccessList types.AccessList
}

func (txData *spanBatchDynamicFeeTxData) txType() byte { return types.DynamicFeeTxType }

type spanBatchSetCodeTxData struct {
	Value             *uint256.Int
	GasTipCap         *uint256.Int
	GasFeeCap         *uint256.Int
	Data              []byte
	AccessList        types.AccessList
	AuthorizationList []types.SetCodeAuthorization
}

func (txData *spanBatchSetCodeTxData) txType() byte { return types.SetCodeTxType }

func (tx *spanBatchTx) Type() uint8 {
	return tx.inner.txType()
}

func (tx *spanBatchTx) decodeTyped(b []byte) (spanBatchTxData, error) {
	if len(b) <= 1 {
		return nil, fmt.Errorf("typed tx too short")
	}
	switch b[0] {
	case types.AccessListTxType:
		var inner spanBatchAccessListTxData
		if err := rlp.DecodeBytes(b[1:], &inner); err != nil {
			return nil, fmt.Errorf("decode access list tx: %w", err)
		}
		return &inner, nil
	case types.DynamicFeeTxType:
		var inner spanBatchDynamicFeeTxData
		if err := rlp.DecodeBytes(b[1:], &inner); err != nil {
			return nil, fmt.Errorf("decode dynamic fee tx: %w", err)
		}
		return &inner, nil
	case types.SetCodeTxType:
		var inner spanBatchSetCodeTxData
		if err := rlp.DecodeBytes(b[1:], &inner); err != nil {
			return nil, fmt.Errorf("decode set code tx: %w", err)
		}
		return &inner, nil
	default:
		return nil, types.ErrTxTypeNotSupported
	}
}

func (tx *spanBatchTx) UnmarshalBinary(b []byte) error {
	if len(b) > 0 && b[0] > 0x7f {
		var data spanBatchLegacyTxData
		if err := rlp.DecodeBytes(b, &data); err != nil {
			return fmt.Errorf("decode legacy tx: %w", err)
		}
		tx.inner = &data
		return nil
	}
	inner, err := tx.decodeTyped(b)
	if err != nil {
		return err
	}
	tx.inner = inner
	return nil
}

func (tx *spanBatchTx) convertToFullTx(nonce, gas uint64, to *common.Address, chainID, V, R, S *big.Int) (*types.Transaction, error) {
	var inner types.TxData
	switch tx.Type() {
	case types.LegacyTxType:
		batchTxInner := tx.inner.(*spanBatchLegacyTxData)
		inner = &types.LegacyTx{
			Nonce:    nonce,
			GasPrice: batchTxInner.GasPrice,
			Gas:      gas,
			To:       to,
			Value:    batchTxInner.Value,
			Data:     batchTxInner.Data,
			V:        V,
			R:        R,
			S:        S,
		}
	case types.AccessListTxType:
		batchTxInner := tx.inner.(*spanBatchAccessListTxData)
		inner = &types.AccessListTx{
			ChainID:    chainID,
			Nonce:      nonce,
			GasPrice:   batchTxInner.GasPrice,
			Gas:        gas,
			To:         to,
			Value:      batchTxInner.Value,
			Data:       batchTxInner.Data,
			AccessList: batchTxInner.AccessList,
			V:          V,
			R:          R,
			S:          S,
		}
	case types.DynamicFeeTxType:
		batchTxInner := tx.inner.(*spanBatchDynamicFeeTxData)
		inner = &types.DynamicFeeTx{
			ChainID:    chainID,
			Nonce:      nonce,
			GasTipCap:  batchTxInner.GasTipCap,
			GasFeeCap:  batchTxInner.GasFeeCap,
			Gas:        gas,
			To:         to,
			Value:      batchTxInner.Value,
			Data:       batchTxInner.Data,
			AccessList: batchTxInner.AccessList,
			V:          V,
			R:          R,
			S:          S,
		}
	case types.SetCodeTxType:
		if to == nil {
			return nil, fmt.Errorf("to address required for SetCodeTx")
		}
		setCodeTxInner := tx.inner.(*spanBatchSetCodeTxData)
		inner = &types.SetCodeTx{
			ChainID:    uint256.MustFromBig(chainID),
			Nonce:      nonce,
			GasTipCap:  setCodeTxInner.GasTipCap,
			GasFeeCap:  setCodeTxInner.GasFeeCap,
			Gas:        gas,
			To:         *to,
			Value:      setCodeTxInner.Value,
			Data:       setCodeTxInner.Data,
			AccessList: setCodeTxInner.AccessList,
			AuthList:   setCodeTxInner.AuthorizationList,
			V:          uint256.MustFromBig(V),
			R:          uint256.MustFromBig(R),
			S:          uint256.MustFromBig(S),
		}
	default:
		return nil, fmt.Errorf("invalid tx type: %d", tx.Type())
	}
	return types.NewTx(inner), nil
}

func readTxData(r *bytes.Reader) ([]byte, int, error) {
	var txData []byte
	offset, err := r.Seek(0, io.SeekCurrent)
	if err != nil {
		return nil, 0, fmt.Errorf("seek tx reader: %w", err)
	}
	b, err := r.ReadByte()
	if err != nil {
		return nil, 0, fmt.Errorf("read tx initial byte: %w", err)
	}
	txType := byte(0)
	if int(b) <= 0x7F {
		txType = b
		txData = append(txData, txType)
	} else {
		if _, err = r.Seek(offset, io.SeekStart); err != nil {
			return nil, 0, fmt.Errorf("seek tx reader: %w", err)
		}
	}
	s := rlp.NewStream(r, maxSpanBatchElementCount)
	var txPayload []byte
	kind, _, err := s.Kind()
	switch {
	case err != nil:
		if errors.Is(err, rlp.ErrValueTooLarge) {
			return nil, 0, errTooBigSpanBatchSize
		}
		return nil, 0, fmt.Errorf("read tx RLP prefix: %w", err)
	case kind == rlp.List:
		if txPayload, err = s.Raw(); err != nil {
			return nil, 0, fmt.Errorf("read tx RLP payload: %w", err)
		}
	default:
		return nil, 0, errors.New("tx RLP prefix type must be list")
	}
	txData = append(txData, txPayload...)
	return txData, int(txType), nil
}

func (btx *spanBatchTxs) contractCreationCount() (uint64, error) {
	if btx.contractCreationBits == nil {
		return 0, errors.New("contract creation bits not set")
	}
	var result uint64
	for i := 0; i < int(btx.totalBlockTxCount); i++ {
		if btx.contractCreationBits.Bit(i) == 1 {
			result++
		}
	}
	return result, nil
}

func (btx *spanBatchTxs) decodeContractCreationBits(r *bytes.Reader) error {
	if btx.totalBlockTxCount > maxSpanBatchElementCount {
		return errTooBigSpanBatchSize
	}
	bits, err := decodeSpanBatchBits(r, btx.totalBlockTxCount)
	if err != nil {
		return fmt.Errorf("decode contract creation bits: %w", err)
	}
	btx.contractCreationBits = bits
	return nil
}

func (btx *spanBatchTxs) decodeProtectedBits(r *bytes.Reader) error {
	if btx.totalLegacyTxCount > maxSpanBatchElementCount {
		return errTooBigSpanBatchSize
	}
	bits, err := decodeSpanBatchBits(r, btx.totalLegacyTxCount)
	if err != nil {
		return fmt.Errorf("decode protected bits: %w", err)
	}
	btx.protectedBits = bits
	return nil
}

func (btx *spanBatchTxs) decodeYParityBits(r *bytes.Reader) error {
	bits, err := decodeSpanBatchBits(r, btx.totalBlockTxCount)
	if err != nil {
		return fmt.Errorf("decode y-parity bits: %w", err)
	}
	btx.yParityBits = bits
	return nil
}

func (btx *spanBatchTxs) decodeTxSigsRS(r *bytes.Reader) error {
	var txSigs []spanBatchSignature
	var sigBuffer [32]byte
	for i := 0; i < int(btx.totalBlockTxCount); i++ {
		var txSig spanBatchSignature
		if _, err := io.ReadFull(r, sigBuffer[:]); err != nil {
			return fmt.Errorf("read tx sig r: %w", err)
		}
		txSig.r, _ = uint256.FromBig(new(big.Int).SetBytes(sigBuffer[:]))
		if _, err := io.ReadFull(r, sigBuffer[:]); err != nil {
			return fmt.Errorf("read tx sig s: %w", err)
		}
		txSig.s, _ = uint256.FromBig(new(big.Int).SetBytes(sigBuffer[:]))
		txSigs = append(txSigs, txSig)
	}
	btx.txSigs = txSigs
	return nil
}

func (btx *spanBatchTxs) decodeTxNonces(r *bytes.Reader) error {
	var txNonces []uint64
	for i := 0; i < int(btx.totalBlockTxCount); i++ {
		txNonce, err := binary.ReadUvarint(r)
		if err != nil {
			return fmt.Errorf("read tx nonce: %w", err)
		}
		txNonces = append(txNonces, txNonce)
	}
	btx.txNonces = txNonces
	return nil
}

func (btx *spanBatchTxs) decodeTxGases(r *bytes.Reader) error {
	var txGases []uint64
	for i := 0; i < int(btx.totalBlockTxCount); i++ {
		txGas, err := binary.ReadUvarint(r)
		if err != nil {
			return fmt.Errorf("read tx gas: %w", err)
		}
		txGases = append(txGases, txGas)
	}
	btx.txGases = txGases
	return nil
}

func (btx *spanBatchTxs) decodeTxTos(r *bytes.Reader) error {
	var txTos []common.Address
	txToBuffer := make([]byte, common.AddressLength)
	contractCreationCount, err := btx.contractCreationCount()
	if err != nil {
		return err
	}
	for i := 0; i < int(btx.totalBlockTxCount-contractCreationCount); i++ {
		if _, err := io.ReadFull(r, txToBuffer); err != nil {
			return fmt.Errorf("read tx to address: %w", err)
		}
		txTos = append(txTos, common.BytesToAddress(txToBuffer))
	}
	btx.txTos = txTos
	return nil
}

func (btx *spanBatchTxs) decodeTxDatas(r *bytes.Reader) error {
	var txDatas [][]byte
	var txTypes []int
	for i := 0; i < int(btx.totalBlockTxCount); i++ {
		txData, txType, err := readTxData(r)
		if err != nil {
			return err
		}
		txDatas = append(txDatas, txData)
		txTypes = append(txTypes, txType)
		if txType == types.LegacyTxType {
			btx.totalLegacyTxCount++
		}
	}
	btx.txDatas = txDatas
	btx.txTypes = txTypes
	return nil
}

func (btx *spanBatchTxs) recoverV(chainID *big.Int) error {
	if len(btx.txTypes) != len(btx.txSigs) {
		return errors.New("tx type length and tx sigs length mismatch")
	}
	if btx.protectedBits == nil {
		return errors.New("protected bits not set")
	}
	protectedBitsIdx := 0
	for idx, txType := range btx.txTypes {
		bit := btx.yParityBits.Bit(idx)
		var v *big.Int
		switch txType {
		case types.LegacyTxType:
			protectedBit := btx.protectedBits.Bit(protectedBitsIdx)
			protectedBitsIdx++
			if protectedBit == 0 {
				v = big.NewInt(int64(27 + bit))
			} else {
				v = new(big.Int).Mul(chainID, big.NewInt(2))
				v.Add(v, big.NewInt(35))
				v.Add(v, big.NewInt(int64(bit)))
			}
		case types.AccessListTxType, types.DynamicFeeTxType, types.SetCodeTxType:
			v = big.NewInt(int64(bit))
		default:
			return fmt.Errorf("invalid tx type: %d", txType)
		}
		btx.txSigs[idx].v = v
	}
	return nil
}

func (btx *spanBatchTxs) decode(r *bytes.Reader) error {
	if err := btx.decodeContractCreationBits(r); err != nil {
		return err
	}
	if err := btx.decodeYParityBits(r); err != nil {
		return err
	}
	if err := btx.decodeTxSigsRS(r); err != nil {
		return err
	}
	if err := btx.decodeTxTos(r); err != nil {
		return err
	}
	if err := btx.decodeTxDatas(r); err != nil {
		return err
	}
	if err := btx.decodeTxNonces(r); err != nil {
		return err
	}
	if err := btx.decodeTxGases(r); err != nil {
		return err
	}
	if err := btx.decodeProtectedBits(r); err != nil {
		return err
	}
	return nil
}

func (btx *spanBatchTxs) fullTxs(chainID *big.Int) ([][]byte, error) {
	var txs [][]byte
	toIdx := 0
	for idx := 0; idx < int(btx.totalBlockTxCount); idx++ {
		var stx spanBatchTx
		if err := stx.UnmarshalBinary(btx.txDatas[idx]); err != nil {
			return nil, err
		}
		nonce := btx.txNonces[idx]
		gas := btx.txGases[idx]
		var to *common.Address
		if btx.contractCreationBits.Bit(idx) == 0 {
			if len(btx.txTos) <= toIdx {
				return nil, errors.New("tx to not enough")
			}
			to = &btx.txTos[toIdx]
			toIdx++
		}
		v := btx.txSigs[idx].v
		r := btx.txSigs[idx].r.ToBig()
		s := btx.txSigs[idx].s.ToBig()
		tx, err := stx.convertToFullTx(nonce, gas, to, chainID, v, r, s)
		if err != nil {
			return nil, err
		}
		encodedTx, err := tx.MarshalBinary()
		if err != nil {
			return nil, err
		}
		txs = append(txs, encodedTx)
	}
	return txs, nil
}
