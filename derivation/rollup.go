package derivation

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/ethereum/go-ethereum/common"
)

// RollupConfig mirrors the fields we need from $DEPLOY_DIR/rollup.json.
// Spec: https://specs.optimism.io/protocol/configurability.html
type RollupConfig struct {
	Genesis struct {
		L1 struct {
			Hash   common.Hash `json:"hash"`
			Number uint64      `json:"number"`
		} `json:"l1"`
		L2Time       uint64 `json:"l2_time"`
		SystemConfig SystemConfig `json:"system_config"`
	} `json:"genesis"`
	BlockTime             uint64         `json:"block_time"`
	MaxSequencerDrift     uint64         `json:"max_sequencer_drift"`
	L1ChainID             uint64         `json:"l1_chain_id"`
	L2ChainID             uint64         `json:"l2_chain_id"`
	BatchInboxAddress     common.Address `json:"batch_inbox_address"`
	DepositContractAddress common.Address `json:"deposit_contract_address"`
	RegolithTime          *uint64        `json:"regolith_time"`
	CanyonTime            *uint64        `json:"canyon_time"`
	DeltaTime             *uint64        `json:"delta_time"`
	EcotoneTime           *uint64        `json:"ecotone_time"`
	FjordTime             *uint64        `json:"fjord_time"`
	GraniteTime           *uint64        `json:"granite_time"`
	HoloceneTime          *uint64        `json:"holocene_time"`
	IsthmusTime           *uint64        `json:"isthmus_time"`
	JovianTime            *uint64        `json:"jovian_time"`
}

// SystemConfig holds L2 system configuration carried in genesis / L1Block.
type SystemConfig struct {
	BatcherAddr          common.Address `json:"batcherAddr"`
	Overhead             hexHash        `json:"overhead"`
	Scalar               hexHash        `json:"scalar"`
	GasLimit             uint64         `json:"gasLimit"`
	EIP1559Params        hexHash        `json:"eip1559Params"`
	OperatorFeeParams    hexHash        `json:"operatorFeeParams"`
	MinBaseFee           uint64         `json:"minBaseFee"`
	DAFootprintGasScalar uint16         `json:"daFootprintGasScalar"`
}

// hexHash accepts rollup.json hash fields that may be shorter than 32 bytes.
type hexHash common.Hash

func (h *hexHash) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	s = strings.TrimPrefix(strings.ToLower(s), "0x")
	raw, err := decodeHexString(s)
	if err != nil {
		return err
	}
	var out common.Hash
	if len(raw) <= 32 {
		copy(out[32-len(raw):], raw)
	} else {
		return fmt.Errorf("hash too long: %d", len(raw))
	}
	*h = hexHash(out)
	return nil
}

func (h hexHash) Bytes() common.Hash { return common.Hash(h) }

func LoadRollupConfig(path string) (*RollupConfig, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read rollup config: %w", err)
	}
	var cfg RollupConfig
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return nil, fmt.Errorf("parse rollup config: %w", err)
	}
	if cfg.BatchInboxAddress == (common.Address{}) {
		return nil, fmt.Errorf("rollup config missing batch_inbox_address")
	}
	if cfg.BlockTime == 0 {
		cfg.BlockTime = 2
	}
	return &cfg, nil
}

func (c *RollupConfig) IsRegolith(ts uint64) bool   { return forkActive(c.RegolithTime, ts) }
func (c *RollupConfig) IsCanyon(ts uint64) bool     { return forkActive(c.CanyonTime, ts) }
func (c *RollupConfig) IsEcotone(ts uint64) bool    { return forkActive(c.EcotoneTime, ts) }
func (c *RollupConfig) IsFjord(ts uint64) bool      { return forkActive(c.FjordTime, ts) }
func (c *RollupConfig) IsHolocene(ts uint64) bool   { return forkActive(c.HoloceneTime, ts) }
func (c *RollupConfig) IsIsthmus(ts uint64) bool    { return forkActive(c.IsthmusTime, ts) }
func (c *RollupConfig) IsJovian(ts uint64) bool     { return forkActive(c.JovianTime, ts) }

func (c *RollupConfig) IsEcotoneActivationBlock(ts uint64) bool {
	return c.EcotoneTime != nil && ts == *c.EcotoneTime
}
func (c *RollupConfig) IsIsthmusActivationBlock(ts uint64) bool {
	return c.IsthmusTime != nil && ts == *c.IsthmusTime
}
func (c *RollupConfig) IsJovianActivationBlock(ts uint64) bool {
	return c.JovianTime != nil && ts == *c.JovianTime
}

func forkActive(t *uint64, ts uint64) bool {
	if t == nil {
		return false
	}
	return ts >= *t
}

func (s SystemConfig) EcotoneScalars() (baseFeeScalar, blobBaseFeeScalar uint32, err error) {
	// scalar packs baseFeeScalar (4) || blobBaseFeeScalar (4) in last 8 bytes of 32-byte word
	b := s.Scalar.Bytes().Bytes()
	if len(b) < 32 {
		padded := make([]byte, 32)
		copy(padded[32-len(b):], b)
		b = padded
	}
	baseFeeScalar = uint32(b[28])<<24 | uint32(b[29])<<16 | uint32(b[30])<<8 | uint32(b[31])
	blobBaseFeeScalar = uint32(b[24])<<24 | uint32(b[25])<<16 | uint32(b[26])<<8 | uint32(b[27])
	return baseFeeScalar, blobBaseFeeScalar, nil
}

func (s SystemConfig) OperatorFee() (scalar uint32, constant uint64) {
	b := s.OperatorFeeParams.Bytes().Bytes()
	if len(b) < 32 {
		padded := make([]byte, 32)
		copy(padded[32-len(b):], b)
		b = padded
	}
	scalar = uint32(b[0])<<24 | uint32(b[1])<<16 | uint32(b[2])<<8 | uint32(b[3])
	constant = uint64(b[4])<<56 | uint64(b[5])<<48 | uint64(b[6])<<40 | uint64(b[7])<<32 |
		uint64(b[8])<<24 | uint64(b[9])<<16 | uint64(b[10])<<8 | uint64(b[11])
	return scalar, constant
}
