package derivation

import (
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/rlp"
)

const depositTxType = 0x7E

type depositTxRLP struct {
	SourceHash          common.Hash
	From                common.Address
	To                  *common.Address `rlp:"nil"`
	Mint                *big.Int        `rlp:"nil"`
	Value               *big.Int
	Gas                 uint64
	IsSystemTransaction bool
	Data                []byte
}

func encodeDepositTx(sourceHash common.Hash, from common.Address, to *common.Address, mint, value *big.Int, gas uint64, isSystem bool, data []byte) ([]byte, error) {
	if value == nil {
		value = new(big.Int)
	}
	payload, err := rlp.EncodeToBytes(&depositTxRLP{
		SourceHash:          sourceHash,
		From:                from,
		To:                  to,
		Mint:                mint,
		Value:               value,
		Gas:                 gas,
		IsSystemTransaction: isSystem,
		Data:                data,
	})
	if err != nil {
		return nil, err
	}
	out := append([]byte{depositTxType}, payload...)
	return out, nil
}

func encodeUserDeposit(sourceHash common.Hash, from common.Address, to *common.Address, mint, value *big.Int, gas uint64, data []byte) ([]byte, error) {
	return encodeDepositTx(sourceHash, from, to, mint, value, gas, false, data)
}
