// Package batcher implements a learning OP Stack batch submitter (Phase 4).
// Wire formats follow https://specs.optimism.io/protocol/derivation.html
package batcher

import (
	"encoding/binary"
	"encoding/hex"
	"fmt"
)

const (
	// BatcherTxVersionCalldata is version_byte 0: one or more frames.
	BatcherTxVersionCalldata = 0x00
	// FrameOverhead is channel_id(16) + frame_number(2) + frame_data_length(4) + is_last(1).
	FrameOverhead = 23
	// MaxFrameDataLen is the spec cap on frame_data_length.
	MaxFrameDataLen = 1_000_000
)

// Frame is one channel frame inside a version-0 batcher transaction.
type Frame struct {
	ChannelID   [16]byte
	FrameNumber uint16
	Data        []byte
	IsLast      bool
}

// ParseBatcherTxPayload parses version_byte ++ frames from L1 tx calldata/input.
func ParseBatcherTxPayload(payload []byte) (version byte, frames []Frame, err error) {
	if len(payload) < 1 {
		return 0, nil, fmt.Errorf("empty batcher payload")
	}
	version = payload[0]
	if version != BatcherTxVersionCalldata {
		return version, nil, fmt.Errorf("unsupported batcher tx version %d (only calldata version 0 in Phase 4)", version)
	}
	frames, err = ParseFrames(payload[1:])
	return version, frames, err
}

// ParseFrames decodes a concatenation of frames (no version byte).
func ParseFrames(b []byte) ([]Frame, error) {
	var frames []Frame
	off := 0
	for off < len(b) {
		if len(b)-off < FrameOverhead {
			return nil, fmt.Errorf("truncated frame header at offset %d (need %d bytes, have %d)", off, FrameOverhead, len(b)-off)
		}
		var f Frame
		copy(f.ChannelID[:], b[off:off+16])
		off += 16
		f.FrameNumber = binary.BigEndian.Uint16(b[off : off+2])
		off += 2
		dataLen := binary.BigEndian.Uint32(b[off : off+4])
		off += 4
		if dataLen > MaxFrameDataLen {
			return nil, fmt.Errorf("frame_data_length %d exceeds max %d", dataLen, MaxFrameDataLen)
		}
		if uint32(len(b)-off) < dataLen+1 {
			return nil, fmt.Errorf("truncated frame data at offset %d (need %d+1, have %d)", off, dataLen, len(b)-off)
		}
		f.Data = make([]byte, dataLen)
		copy(f.Data, b[off:off+int(dataLen)])
		off += int(dataLen)
		switch b[off] {
		case 0:
			f.IsLast = false
		case 1:
			f.IsLast = true
		default:
			return nil, fmt.Errorf("invalid is_last byte %d at offset %d", b[off], off)
		}
		off++
		frames = append(frames, f)
	}
	if len(frames) == 0 {
		return nil, fmt.Errorf("no frames in payload")
	}
	return frames, nil
}

// EncodeFrames concatenates frames (no version byte).
func EncodeFrames(frames []Frame) ([]byte, error) {
	var out []byte
	for i, f := range frames {
		if len(f.Data) > MaxFrameDataLen {
			return nil, fmt.Errorf("frame %d data length %d exceeds max", i, len(f.Data))
		}
		var meta [22]byte
		copy(meta[0:16], f.ChannelID[:])
		binary.BigEndian.PutUint16(meta[16:18], f.FrameNumber)
		binary.BigEndian.PutUint32(meta[18:22], uint32(len(f.Data)))
		out = append(out, meta[:]...)
		out = append(out, f.Data...)
		if f.IsLast {
			out = append(out, 1)
		} else {
			out = append(out, 0)
		}
	}
	return out, nil
}

// EncodeBatcherTxPayload builds version_byte ++ frames.
func EncodeBatcherTxPayload(frames []Frame) ([]byte, error) {
	body, err := EncodeFrames(frames)
	if err != nil {
		return nil, err
	}
	out := make([]byte, 1+len(body))
	out[0] = BatcherTxVersionCalldata
	copy(out[1:], body)
	return out, nil
}

// ChannelIDHex returns the channel id as 0x-prefixed hex.
func ChannelIDHex(id [16]byte) string {
	return "0x" + hex.EncodeToString(id[:])
}
