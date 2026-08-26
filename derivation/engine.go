package derivation

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/ethereum/go-ethereum/beacon/engine"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/node"
	"github.com/ethereum/go-ethereum/rpc"
)

// SealingEL manages a separate loopback op-geth for Engine API block sealing.
type SealingEL struct {
	authRPC *rpc.Client
	httpRPC *RPCClient
	head    common.Hash
}

func StartSealingEL(ctx context.Context, authURL string, jwtPath string, httpURL string) (*SealingEL, error) {
	secret, err := os.ReadFile(jwtPath)
	if err != nil {
		return nil, fmt.Errorf("read jwt: %w", err)
	}
	var jwtSecret [32]byte
	b, err := decodeHexString(trimSpace(string(secret)))
	if err != nil || len(b) != 32 {
		return nil, fmt.Errorf("jwt secret must be 32 bytes hex")
	}
	copy(jwtSecret[:], b)

	authClient, err := rpc.DialOptions(ctx, authURL, rpc.WithHTTPAuth(node.NewJWTAuth(jwtSecret)))
	if err != nil {
		return nil, fmt.Errorf("dial engine api: %w", err)
	}

	el := &SealingEL{authRPC: authClient, httpRPC: NewRPCClient(httpURL)}
	var genesis struct {
		Hash common.Hash `json:"hash"`
	}
	if err := el.httpRPC.Call(ctx, "eth_getBlockByNumber", []any{"0x0", false}, &genesis); err != nil {
		authClient.Close()
		return nil, err
	}
	el.head = genesis.Hash
	return el, nil
}

func trimSpace(s string) string {
	for len(s) > 0 && (s[0] == ' ' || s[0] == '\n') {
		s = s[1:]
	}
	for len(s) > 0 && (s[len(s)-1] == ' ' || s[len(s)-1] == '\n') {
		s = s[:len(s)-1]
	}
	if len(s) >= 2 && s[0:2] == "0x" {
		return s[2:]
	}
	return s
}

func (el *SealingEL) Close() {
	if el.authRPC != nil {
		el.authRPC.Close()
	}
}

// Head returns the sealing EL forkchoice head tracked by this client.
func (el *SealingEL) Head() common.Hash { return el.head }

// SetHead updates the tracked forkchoice head (additive helper for US-062 stub).
func (el *SealingEL) SetHead(h common.Hash) { el.head = h }

// LoadLatestHead reads the sealing EL tip via eth_getBlockByNumber("latest").
func (el *SealingEL) LoadLatestHead(ctx context.Context) (hash common.Hash, number uint64, timestamp uint64, err error) {
	var blk struct {
		Hash      common.Hash    `json:"hash"`
		Number    string         `json:"number"`
		Timestamp hexutil.Uint64 `json:"timestamp"`
	}
	if err := el.httpRPC.Call(ctx, "eth_getBlockByNumber", []any{"latest", false}, &blk); err != nil {
		return common.Hash{}, 0, 0, err
	}
	n, err := hexutil.DecodeUint64(blk.Number)
	if err != nil {
		return common.Hash{}, 0, 0, err
	}
	return blk.Hash, n, uint64(blk.Timestamp), nil
}

// BlockMeta returns hash/parent/time/txCount for a sealed block by number.
func (el *SealingEL) BlockMeta(ctx context.Context, num uint64) (hash, parent common.Hash, timestamp uint64, txCount int, err error) {
	var blk struct {
		Hash         common.Hash    `json:"hash"`
		ParentHash   common.Hash    `json:"parentHash"`
		Timestamp    hexutil.Uint64 `json:"timestamp"`
		Transactions []any          `json:"transactions"`
	}
	tag := fmt.Sprintf("0x%x", num)
	if err := el.httpRPC.Call(ctx, "eth_getBlockByNumber", []any{tag, false}, &blk); err != nil {
		return common.Hash{}, common.Hash{}, 0, 0, err
	}
	return blk.Hash, blk.ParentHash, uint64(blk.Timestamp), len(blk.Transactions), nil
}

// BlockFirstTx returns the raw first transaction bytes of a block.
func (el *SealingEL) BlockFirstTx(ctx context.Context, num uint64) ([]byte, error) {
	var blk struct {
		Transactions []struct {
			Hash common.Hash `json:"hash"`
		} `json:"transactions"`
	}
	tag := fmt.Sprintf("0x%x", num)
	if err := el.httpRPC.Call(ctx, "eth_getBlockByNumber", []any{tag, true}, &blk); err != nil {
		return nil, err
	}
	if len(blk.Transactions) == 0 {
		return nil, fmt.Errorf("block %d has no transactions", num)
	}
	var raw hexutil.Bytes
	if err := el.httpRPC.Call(ctx, "eth_getRawTransactionByHash", []any{blk.Transactions[0].Hash}, &raw); err != nil {
		return nil, err
	}
	return []byte(raw), nil
}

var isthmusEmptyWithdrawalsRoot = common.HexToHash("0x8ed4baae3a927be3dea54996b4d5899f8c01e7594bf50b17dc1e741388ce3d12")

// patchIsthmusWithdrawalsRoot injects withdrawalsRoot for op-geth Isthmus blocks.
// Vanilla go-ethereum ExecutableData lacks the field; op-geth getPayload omits it but newPayload requires it.
// SyncHeadFromLatest reads the sealing EL tip and updates the tracked forkchoice head.
func (el *SealingEL) SyncHeadFromLatest(ctx context.Context) error {
	hash, _, _, err := el.LoadLatestHead(ctx)
	if err != nil {
		return err
	}
	el.head = hash
	return nil
}

// DebugSetHead rolls the sealing EL back to blockNum via debug_setHead (copy only).
func (el *SealingEL) DebugSetHead(ctx context.Context, blockNum uint64) error {
	tag := fmt.Sprintf("0x%x", blockNum)
	var ok bool
	if err := el.httpRPC.Call(ctx, "debug_setHead", []any{tag}, &ok); err != nil {
		return fmt.Errorf("debug_setHead: %w", err)
	}
	hash, _, _, err := el.LoadLatestHead(ctx)
	if err != nil {
		return err
	}
	el.head = hash
	return nil
}

func patchIsthmusWithdrawalsRoot(payload *engine.ExecutableData) (any, error) {
	raw, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, err
	}
	if _, ok := m["withdrawalsRoot"]; !ok && len(payload.Withdrawals) == 0 {
		wr, err := json.Marshal(isthmusEmptyWithdrawalsRoot)
		if err != nil {
			return nil, err
		}
		m["withdrawalsRoot"] = wr
	}
	return m, nil
}

func (el *SealingEL) SealBlock(ctx context.Context, attrs *OpPayloadAttributes) (common.Hash, error) {
	fc := engine.ForkchoiceStateV1{
		HeadBlockHash:      el.head,
		SafeBlockHash:      el.head,
		FinalizedBlockHash: el.head,
	}
	var fcu engine.ForkChoiceResponse
	if err := el.authRPC.CallContext(ctx, &fcu, "engine_forkchoiceUpdatedV3", fc, attrs); err != nil {
		return common.Hash{}, fmt.Errorf("forkchoiceUpdated: %w", err)
	}
	if fcu.PayloadStatus.Status != engine.VALID {
		return common.Hash{}, fmt.Errorf("forkchoiceUpdated status %s", fcu.PayloadStatus.Status)
	}
	if fcu.PayloadID == nil {
		return common.Hash{}, fmt.Errorf("nil payload id")
	}

	time.Sleep(50 * time.Millisecond)

	var envelope engine.ExecutionPayloadEnvelope
	if err := el.authRPC.CallContext(ctx, &envelope, "engine_getPayloadV4", *fcu.PayloadID); err != nil {
		if err2 := el.authRPC.CallContext(ctx, &envelope, "engine_getPayloadV3", *fcu.PayloadID); err2 != nil {
			return common.Hash{}, fmt.Errorf("getPayload: %w", err)
		}
	}
	if envelope.ExecutionPayload == nil {
		return common.Hash{}, fmt.Errorf("nil execution payload")
	}
	execPayload, err := patchIsthmusWithdrawalsRoot(envelope.ExecutionPayload)
	if err != nil {
		return common.Hash{}, fmt.Errorf("patch execution payload: %w", err)
	}

	var status engine.PayloadStatusV1
	if err := el.authRPC.CallContext(ctx, &status, "engine_newPayloadV4",
		execPayload, []common.Hash{}, attrs.ParentBeaconBlockRoot, []hexutil.Bytes{}); err != nil {
		if err2 := el.authRPC.CallContext(ctx, &status, "engine_newPayloadV3",
			execPayload, []common.Hash{}, attrs.ParentBeaconBlockRoot); err2 != nil {
			return common.Hash{}, fmt.Errorf("newPayload: %w", err)
		}
	}
	if status.Status != engine.VALID && status.Status != engine.ACCEPTED {
		msg := ""
		if status.ValidationError != nil {
			msg = *status.ValidationError
		}
		return common.Hash{}, fmt.Errorf("newPayload status %s validation=%q", status.Status, msg)
	}

	newHead := envelope.ExecutionPayload.BlockHash
	fc2 := engine.ForkchoiceStateV1{HeadBlockHash: newHead, SafeBlockHash: newHead, FinalizedBlockHash: newHead}
	var fcu2 engine.ForkChoiceResponse
	if err := el.authRPC.CallContext(ctx, &fcu2, "engine_forkchoiceUpdatedV3", fc2, nil); err != nil {
		return common.Hash{}, fmt.Errorf("finalize forkchoice: %w", err)
	}
	el.head = newHead
	return newHead, nil
}

func InitSealingELDatadir(opGethBin, genesisPath, datadir string) error {
	if _, err := os.Stat(datadir + "/geth/chaindata"); err == nil {
		return nil
	}
	return runCmd("init-sealing-el", opGethBin, "init", "--datadir="+datadir, "--state.scheme=hash", genesisPath)
}

func RunSealingELProcess(opGethBin, datadir, jwtPath string, httpPort, authPort int) (*os.Process, error) {
	args := []string{
		"--datadir=" + datadir,
		"--port=30323",
		"--http", "--http.addr=127.0.0.1", fmt.Sprintf("--http.port=%d", httpPort),
		"--http.api=eth,net,web3,debug",
		"--authrpc.addr=127.0.0.1", fmt.Sprintf("--authrpc.port=%d", authPort),
		"--authrpc.jwtsecret=" + jwtPath,
		"--syncmode=full", "--gcmode=archive",
		"--nodiscover", "--maxpeers=0",
		"--rollup.disabletxpoolgossip=true",
	}
	return startCmd(opGethBin, args...)
}

type ReferenceClient struct {
	l2   *RPCClient
	node *RPCClient
}

func NewReferenceClient(l2URL, nodeURL string) *ReferenceClient {
	return &ReferenceClient{l2: NewRPCClient(l2URL), node: NewRPCClient(nodeURL)}
}

func (r *ReferenceClient) BlockHash(ctx context.Context, num uint64) (common.Hash, error) {
	var blk struct {
		Hash common.Hash `json:"hash"`
	}
	tag := fmt.Sprintf("0x%x", num)
	if err := r.l2.Call(ctx, "eth_getBlockByNumber", []any{tag, false}, &blk); err != nil {
		return common.Hash{}, err
	}
	return blk.Hash, nil
}

func (r *ReferenceClient) BlockMeta(ctx context.Context, num uint64) (hash common.Hash, timestamp uint64, err error) {
	var blk struct {
		Hash      common.Hash    `json:"hash"`
		Timestamp hexutil.Uint64 `json:"timestamp"`
	}
	tag := fmt.Sprintf("0x%x", num)
	if err := r.l2.Call(ctx, "eth_getBlockByNumber", []any{tag, false}, &blk); err != nil {
		return common.Hash{}, 0, err
	}
	return blk.Hash, uint64(blk.Timestamp), nil
}

func (r *ReferenceClient) BlockFirstTx(ctx context.Context, num uint64) ([]byte, error) {
	var blk struct {
		Transactions []struct {
			Hash common.Hash `json:"hash"`
		} `json:"transactions"`
	}
	tag := fmt.Sprintf("0x%x", num)
	if err := r.l2.Call(ctx, "eth_getBlockByNumber", []any{tag, true}, &blk); err != nil {
		return nil, err
	}
	if len(blk.Transactions) == 0 {
		return nil, fmt.Errorf("block %d has no transactions", num)
	}
	var raw hexutil.Bytes
	if err := r.l2.Call(ctx, "eth_getRawTransactionByHash", []any{blk.Transactions[0].Hash}, &raw); err != nil {
		return nil, err
	}
	return []byte(raw), nil
}

type SyncStatus struct {
	SafeL2   L2Ref `json:"safe_l2"`
	UnsafeL2 L2Ref `json:"unsafe_l2"`
}

func (r *ReferenceClient) SyncStatus(ctx context.Context) (*SyncStatus, error) {
	raw, err := r.node.CallRaw(ctx, "optimism_syncStatus", []any{})
	if err != nil {
		return nil, err
	}
	var status SyncStatus
	if err := json.Unmarshal(raw, &status); err != nil {
		return nil, err
	}
	return &status, nil
}

type BlockResult struct {
	Number       uint64      `json:"number"`
	DerivedHash  common.Hash `json:"derivedHash"`
	ExpectedHash common.Hash `json:"expectedHash"`
	TxCount      int         `json:"txCount"`
	Source       string      `json:"source"`
	Match        bool        `json:"match"`
}

type VerifyReport struct {
	Matched           int           `json:"matched"`
	Mismatched        int           `json:"mismatched"`
	WindowStart       uint64        `json:"windowStart"`
	WindowEnd         uint64        `json:"windowEnd"`
	ReferenceSafeL2   L2Ref         `json:"referenceSafeL2"`
	ReferenceUnsafeL2 L2Ref         `json:"referenceUnsafeL2"`
	Blocks            []BlockResult `json:"blocks"`
	// Proposal-mode fields. Pointers + omitempty keep legacy JSON fixtures
	// unchanged while still emitting game type 0 and zero MATCH/SKIPPED/MISMATCH
	// counts (those are valid audit outcomes, not "absent").
	Compare            string           `json:"compare,omitempty"`
	RespectedGameType  *uint32          `json:"respectedGameType,omitempty"`
	GameTypeOverridden bool             `json:"gameTypeOverridden,omitempty"`
	Factory            *common.Address  `json:"factory,omitempty"`
	ASR                *common.Address  `json:"asr,omitempty"`
	Proposals          []ProposalResult `json:"proposals,omitempty"`
	ProposalMatched    *int             `json:"proposalMatched,omitempty"`
	ProposalMismatched *int             `json:"proposalMismatched,omitempty"`
	ProposalSkipped    *int             `json:"proposalSkipped,omitempty"`
}
