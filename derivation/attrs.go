package derivation

import (
	"context"
	"fmt"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/core/types"
)

const sequencerFeeVault = "0x4200000000000000000000000000000000000011"

// OpPayloadAttributes matches op-geth Engine API PayloadAttributes JSON.
type OpPayloadAttributes struct {
	Timestamp             hexutil.Uint64  `json:"timestamp"`
	PrevRandao            common.Hash     `json:"prevRandao"`
	SuggestedFeeRecipient common.Address  `json:"suggestedFeeRecipient"`
	Transactions          []hexutil.Bytes `json:"transactions,omitempty"`
	NoTxPool              bool            `json:"noTxPool,omitempty"`
	GasLimit              *hexutil.Uint64 `json:"gasLimit,omitempty"`
	Withdrawals           []*types.Withdrawal `json:"withdrawals"`
	ParentBeaconBlockRoot *common.Hash    `json:"parentBeaconBlockRoot,omitempty"`
	EIP1559Params         hexutil.Bytes   `json:"eip1559Params,omitempty"`
	MinBaseFee            *uint64         `json:"minBaseFee,omitempty"`
}

type DerivationState struct {
	SysConfig    SystemConfig
	L1OriginNum  uint64
	L1OriginHash common.Hash
	SeqNumber    uint64
	ParentHash   common.Hash
	ParentTime   uint64
}

func NewDerivationState(cfg *RollupConfig) DerivationState {
	return DerivationState{
		SysConfig:  cfg.Genesis.SystemConfig,
		ParentTime: cfg.Genesis.L2Time,
	}
}

func BuildPayloadAttributes(ctx context.Context, cfg *RollupConfig, l1 *L1Client, st *DerivationState, in BlockInput) (*OpPayloadAttributes, error) {
	l1Header, err := l1.BlockHeaderByHash(ctx, in.EpochHash)
	if err != nil || in.EpochHash == (common.Hash{}) {
		l1Header, err = l1.BlockHeader(ctx, in.EpochNumber)
		if err != nil {
			return nil, err
		}
	}

	var depositTxs [][]byte
	if st.L1OriginNum != in.EpochNumber {
		receipts, err := l1.BlockReceipts(ctx, l1Header.Hash)
		if err != nil {
			return nil, err
		}
		depositTxs, err = UserDepositsFromReceipts(receipts, cfg.DepositContractAddress)
		if err != nil {
			return nil, err
		}
		st.L1OriginNum = in.EpochNumber
		st.L1OriginHash = l1Header.Hash
		st.SeqNumber = 0
	} else {
		st.SeqNumber++
	}

	if cfg.IsEcotone(in.Timestamp) && !cfg.IsEcotoneActivationBlock(in.Timestamp) {
		if err := l1.EnrichBlobBaseFee(ctx, l1Header); err != nil {
			return nil, fmt.Errorf("l1 blob base fee block %d: %w", l1Header.Number, err)
		}
	}

	l1Info, err := L1InfoDepositBytes(cfg, st.SysConfig, st.SeqNumber, l1Header, in.Timestamp)
	if err != nil {
		return nil, err
	}

	txs := make([]hexutil.Bytes, 0, 1+len(depositTxs)+len(in.Transactions))
	txs = append(txs, l1Info)
	for _, d := range depositTxs {
		txs = append(txs, d)
	}
	for _, u := range in.Transactions {
		txs = append(txs, u)
	}

	gasLimit := hexutil.Uint64(st.SysConfig.GasLimit)
	attrs := &OpPayloadAttributes{
		Timestamp:             hexutil.Uint64(in.Timestamp),
		PrevRandao:            l1Header.MixDigest,
		SuggestedFeeRecipient: common.HexToAddress(sequencerFeeVault),
		Transactions:          txs,
		NoTxPool:              true,
		GasLimit:              &gasLimit,
	}
	if cfg.IsCanyon(in.Timestamp) {
		attrs.Withdrawals = []*types.Withdrawal{}
	}
	if cfg.IsEcotone(in.Timestamp) && !cfg.IsEcotoneActivationBlock(in.Timestamp) {
		// Ecotone+: the L1 origin's parentBeaconBlockRoot, written into the
		// EIP-4788 beacon-roots contract at block start — a zero here changes
		// the state root even with identical transactions. Zero-valued on
		// beacon-less L1s (Anvil), preserving local-901 behavior.
		root := l1Header.ParentBeaconRoot
		attrs.ParentBeaconBlockRoot = &root
	}
	if cfg.IsHolocene(in.Timestamp) {
		h := st.SysConfig.EIP1559Params.Bytes()
		raw := h.Bytes()
		if len(raw) > 8 {
			raw = raw[len(raw)-8:]
		}
		attrs.EIP1559Params = raw
	}
	if cfg.IsJovian(in.Timestamp) && !cfg.IsJovianActivationBlock(in.Timestamp) {
		m := st.SysConfig.MinBaseFee
		attrs.MinBaseFee = &m
	}
	return attrs, nil
}
