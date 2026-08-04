package derivation

import (
	"encoding/binary"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
)

var (
	depositEventABIHash    = crypto.Keccak256Hash([]byte("TransactionDeposited(address,address,uint256,bytes)"))
	depositEventVersion0   = common.Hash{}
)

// UserDepositsFromReceipts extracts user deposit txs from L1 receipts.
// Spec: https://specs.optimism.io/protocol/deposits.html
func UserDepositsFromReceipts(receipts types.Receipts, portal common.Address) ([][]byte, error) {
	var out [][]byte
	var result error
	for i, rec := range receipts {
		if rec.Status != types.ReceiptStatusSuccessful {
			continue
		}
		for j, log := range rec.Logs {
			if log.Address != portal || len(log.Topics) == 0 || log.Topics[0] != depositEventABIHash {
				continue
			}
			encoded, err := encodeDepositFromLog(log)
			if err != nil {
				result = fmt.Errorf("receipt %d log %d: %w", i, j, err)
				continue
			}
			out = append(out, encoded)
		}
	}
	return out, result
}

func encodeDepositFromLog(ev *types.Log) ([]byte, error) {
	if len(ev.Topics) != 4 {
		return nil, fmt.Errorf("expected 4 topics, got %d", len(ev.Topics))
	}
	from := common.BytesToAddress(ev.Topics[1][12:])
	to := common.BytesToAddress(ev.Topics[2][12:])
	version := ev.Topics[3]
	if version != depositEventVersion0 {
		return nil, fmt.Errorf("unsupported deposit version")
	}
	if len(ev.Data) < 64 {
		return nil, fmt.Errorf("bad log data")
	}
	opaqueLen := new(big.Int).SetBytes(ev.Data[32:64]).Uint64()
	if opaqueLen+64 > uint64(len(ev.Data)) {
		return nil, fmt.Errorf("opaque length overflow")
	}
	opaque := ev.Data[64 : 64+opaqueLen]
	mint, value, gas, toAddr, data, err := parseDepositOpaque(to, opaque)
	if err != nil {
		return nil, err
	}
	return encodeUserDeposit(userDepositSourceHash(ev.BlockHash, uint64(ev.Index)), from, toAddr, mint, value, gas, data)
}

func parseDepositOpaque(fallbackTo common.Address, opaque []byte) (mint, value *big.Int, gas uint64, to *common.Address, data []byte, err error) {
	if len(opaque) < 73 {
		return nil, nil, 0, nil, nil, fmt.Errorf("opaque too short")
	}
	mint = new(big.Int).SetBytes(opaque[0:32])
	if mint.Sign() == 0 {
		mint = nil
	}
	value = new(big.Int).SetBytes(opaque[32:64])
	gas = binary.BigEndian.Uint64(opaque[64:72])
	if opaque[72] == 0 {
		to = &fallbackTo
	}
	data = opaque[73:]
	return mint, value, gas, to, data, nil
}

func userDepositSourceHash(l1Block common.Hash, logIndex uint64) common.Hash {
	var input [64]byte
	copy(input[:32], l1Block[:])
	binary.BigEndian.PutUint64(input[56:], logIndex)
	depositID := crypto.Keccak256Hash(input[:])
	var domain [64]byte
	copy(domain[32:], depositID[:])
	return crypto.Keccak256Hash(domain[:])
}
