package derivation

import (
	"bytes"
	"encoding/binary"
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/rlp"
	"github.com/holiman/uint256"
)

func TestDecodeSpanBatchEmptyBlock(t *testing.T) {
	const (
		genesisTS  = uint64(1_700_000_000)
		blockTime  = uint64(2)
		relTS      = uint64(100)
		l1Origin   = uint64(42)
		blockCount = uint64(2)
	)
	parentCheck := [20]byte{0x11, 0x22, 0x33}
	l1OriginCheck := [20]byte{0xaa, 0xbb, 0xcc}

	encoded := encodeTestSpanBatch(testSpanBatchParams{
		relTimestamp:  relTS,
		l1OriginNum:   l1Origin,
		parentCheck:   parentCheck,
		l1OriginCheck: l1OriginCheck,
		blockCount:    blockCount,
		originBits:    big.NewInt(0),
		blockTxCounts: []uint64{0, 0},
	})

	chainID := big.NewInt(901)
	elements, err := DecodeSpanBatch(encoded, genesisTS, blockTime, chainID)
	if err != nil {
		t.Fatalf("DecodeSpanBatch: %v", err)
	}
	if len(elements) != 2 {
		t.Fatalf("got %d elements, want 2", len(elements))
	}

	wantTS0 := genesisTS + relTS
	wantTS1 := genesisTS + relTS + blockTime
	if elements[0].Timestamp != wantTS0 {
		t.Errorf("block 0 timestamp: got %d want %d", elements[0].Timestamp, wantTS0)
	}
	if elements[1].Timestamp != wantTS1 {
		t.Errorf("block 1 timestamp: got %d want %d", elements[1].Timestamp, wantTS1)
	}
	if elements[0].EpochNumber != l1Origin || elements[1].EpochNumber != l1Origin {
		t.Errorf("epoch numbers: got [%d, %d] want [%d, %d]", elements[0].EpochNumber, elements[1].EpochNumber, l1Origin, l1Origin)
	}
	var wantParent [32]byte
	copy(wantParent[:20], parentCheck[:])
	if elements[0].ParentHash != wantParent {
		t.Errorf("block 0 parent check prefix mismatch")
	}
	if elements[1].ParentHash != ([32]byte{}) {
		t.Errorf("block 1 parent hash should be zero")
	}
}

func TestDecodeSpanBatchWithLegacyTx(t *testing.T) {
	chainID := big.NewInt(901)
	key, err := crypto.GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	to := common.HexToAddress("0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
	tx := types.NewTx(&types.LegacyTx{
		Nonce:    7,
		GasPrice: big.NewInt(1_000_000_000),
		Gas:      21_000,
		To:       &to,
		Value:    big.NewInt(0),
	})
	signer := types.LatestSignerForChainID(chainID)
	signed, err := types.SignTx(tx, signer, key)
	if err != nil {
		t.Fatal(err)
	}
	rawTx, err := signed.MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}

	sbtxs, err := newTestSpanBatchTxs([][]byte{rawTx}, chainID)
	if err != nil {
		t.Fatalf("build span txs: %v", err)
	}

	const (
		genesisTS = uint64(1_700_000_000)
		blockTime = uint64(2)
		relTS     = uint64(50)
		l1Origin  = uint64(99)
	)
	parentCheck := first20(crypto.Keccak256Hash([]byte("parent")).Bytes())
	l1OriginCheck := first20(crypto.Keccak256Hash([]byte("origin")).Bytes())

	encoded := encodeTestSpanBatch(testSpanBatchParams{
		relTimestamp:  relTS,
		l1OriginNum:   l1Origin,
		parentCheck:   parentCheck,
		l1OriginCheck: l1OriginCheck,
		blockCount:    1,
		originBits:    big.NewInt(0),
		blockTxCounts: []uint64{1},
		txs:           sbtxs,
	})

	elements, err := DecodeSpanBatch(encoded, genesisTS, blockTime, chainID)
	if err != nil {
		t.Fatalf("DecodeSpanBatch: %v", err)
	}
	if len(elements) != 1 || len(elements[0].Transactions) != 1 {
		t.Fatalf("got %+v", elements)
	}

	decodedTx := new(types.Transaction)
	if err := decodedTx.UnmarshalBinary(elements[0].Transactions[0]); err != nil {
		t.Fatalf("unmarshal decoded tx: %v", err)
	}
	from, err := signer.Sender(decodedTx)
	if err != nil {
		t.Fatalf("recover sender: %v", err)
	}
	wantFrom := crypto.PubkeyToAddress(key.PublicKey)
	if from != wantFrom {
		t.Errorf("sender: got %s want %s", from, wantFrom)
	}
	if decodedTx.Nonce() != 7 {
		t.Errorf("nonce: got %d want 7", decodedTx.Nonce())
	}
}

func TestDecodeSpanBatchRejectsWrongType(t *testing.T) {
	_, err := DecodeSpanBatch([]byte{0x00, 0x01}, 0, 2, big.NewInt(901))
	if err == nil {
		t.Fatal("expected error for singular type byte")
	}
}

func TestDecodeSpanBatchOriginBits(t *testing.T) {
	const (
		genesisTS  = uint64(0)
		blockTime  = uint64(2)
		relTS      = uint64(10)
		l1Origin   = uint64(100)
		blockCount = uint64(3)
	)
	originBits := big.NewInt(0)
	originBits.SetBit(originBits, 1, 1)

	encoded := encodeTestSpanBatch(testSpanBatchParams{
		relTimestamp:  relTS,
		l1OriginNum:   l1Origin,
		parentCheck:   first20([]byte{1}),
		l1OriginCheck: first20([]byte{2}),
		blockCount:    blockCount,
		originBits:    originBits,
		blockTxCounts: []uint64{0, 0, 0},
	})

	elements, err := DecodeSpanBatch(encoded, genesisTS, blockTime, big.NewInt(901))
	if err != nil {
		t.Fatalf("DecodeSpanBatch: %v", err)
	}
	wantEpochs := []uint64{99, 100, 100}
	for i, want := range wantEpochs {
		if elements[i].EpochNumber != want {
			t.Errorf("block %d epoch: got %d want %d", i, elements[i].EpochNumber, want)
		}
	}
}

type testSpanBatchParams struct {
	relTimestamp  uint64
	l1OriginNum   uint64
	parentCheck   [20]byte
	l1OriginCheck [20]byte
	blockCount    uint64
	originBits    *big.Int
	blockTxCounts []uint64
	txs           *spanBatchTxs
}

func encodeTestSpanBatch(p testSpanBatchParams) []byte {
	var buf bytes.Buffer
	buf.WriteByte(BatchTypeSpan)
	writeUvarint(&buf, p.relTimestamp)
	writeUvarint(&buf, p.l1OriginNum)
	buf.Write(p.parentCheck[:])
	buf.Write(p.l1OriginCheck[:])
	writeUvarint(&buf, p.blockCount)
	_ = encodeSpanBatchBits(&buf, p.blockCount, p.originBits)
	for _, c := range p.blockTxCounts {
		writeUvarint(&buf, c)
	}
	if p.txs != nil {
		_ = p.txs.encodeTest(&buf)
	}
	return buf.Bytes()
}

func writeUvarint(w *bytes.Buffer, v uint64) {
	var scratch [binary.MaxVarintLen64]byte
	n := binary.PutUvarint(scratch[:], v)
	w.Write(scratch[:n])
}

func first20(b []byte) [20]byte {
	var out [20]byte
	copy(out[:], b)
	return out
}

func (btx *spanBatchTxs) encodeTest(w *bytes.Buffer) error {
	if err := encodeSpanBatchBits(w, btx.totalBlockTxCount, btx.contractCreationBits); err != nil {
		return err
	}
	if err := encodeSpanBatchBits(w, btx.totalBlockTxCount, btx.yParityBits); err != nil {
		return err
	}
	for _, txSig := range btx.txSigs {
		rBuf := txSig.r.Bytes32()
		w.Write(rBuf[:])
		sBuf := txSig.s.Bytes32()
		w.Write(sBuf[:])
	}
	for _, txTo := range btx.txTos {
		w.Write(txTo.Bytes())
	}
	for _, txData := range btx.txDatas {
		w.Write(txData)
	}
	for _, txNonce := range btx.txNonces {
		writeUvarint(w, txNonce)
	}
	for _, txGas := range btx.txGases {
		writeUvarint(w, txGas)
	}
	return encodeSpanBatchBits(w, btx.totalLegacyTxCount, btx.protectedBits)
}

func newTestSpanBatchTxs(txs [][]byte, chainID *big.Int) (*spanBatchTxs, error) {
	sbtxs := &spanBatchTxs{
		contractCreationBits: big.NewInt(0),
		yParityBits:          big.NewInt(0),
		protectedBits:        big.NewInt(0),
	}
	if err := sbtxs.addTestTxs(txs, chainID); err != nil {
		return nil, err
	}
	return sbtxs, nil
}

func (sbtx *spanBatchTxs) addTestTxs(txs [][]byte, chainID *big.Int) error {
	offset := sbtx.totalBlockTxCount
	for idx, rawTx := range txs {
		tx := new(types.Transaction)
		if err := tx.UnmarshalBinary(rawTx); err != nil {
			return err
		}
		if tx.Type() == types.LegacyTxType {
			protectedBit := uint(0)
			if tx.Protected() {
				protectedBit = 1
			}
			sbtx.protectedBits.SetBit(sbtx.protectedBits, int(sbtx.totalLegacyTxCount), protectedBit)
			sbtx.totalLegacyTxCount++
		}
		v, r, s := tx.RawSignatureValues()
		R, _ := uint256.FromBig(r)
		S, _ := uint256.FromBig(s)
		sbtx.txSigs = append(sbtx.txSigs, spanBatchSignature{v: v, r: R, s: S})

		contractCreationBit := uint(1)
		if tx.To() != nil {
			sbtx.txTos = append(sbtx.txTos, *tx.To())
			contractCreationBit = 0
		}
		sbtx.contractCreationBits.SetBit(sbtx.contractCreationBits, idx+int(offset), contractCreationBit)

		yParity, err := testConvertVToYParity(v, int(tx.Type()))
		if err != nil {
			return err
		}
		sbtx.yParityBits.SetBit(sbtx.yParityBits, idx+int(offset), yParity)

		sbtx.txNonces = append(sbtx.txNonces, tx.Nonce())
		sbtx.txGases = append(sbtx.txGases, tx.Gas())

		txData, err := rlp.EncodeToBytes(&spanBatchLegacyTxData{
			GasPrice: tx.GasPrice(),
			Value:    tx.Value(),
			Data:     tx.Data(),
		})
		if err != nil {
			return err
		}
		sbtx.txDatas = append(sbtx.txDatas, txData)
		sbtx.txTypes = append(sbtx.txTypes, int(tx.Type()))
	}
	sbtx.totalBlockTxCount += uint64(len(txs))
	return nil
}

func testConvertVToYParity(v *big.Int, txType int) (uint, error) {
	switch txType {
	case types.LegacyTxType:
		if v.Cmp(big.NewInt(27)) != 0 && v.Cmp(big.NewInt(28)) != 0 {
			vMinus35 := new(big.Int).Sub(v, big.NewInt(35))
			return uint(vMinus35.Bit(0)), nil
		}
		return uint(v.Uint64() - 27), nil
	case types.AccessListTxType, types.DynamicFeeTxType, types.SetCodeTxType:
		return uint(v.Uint64()), nil
	default:
		return 0, nil
	}
}
