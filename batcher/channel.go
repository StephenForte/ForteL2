package batcher

import (
	"bytes"
	"compress/zlib"
	"crypto/rand"
	"fmt"
	"io"
)

// ChannelOptions controls channel compression / framing.
type ChannelOptions struct {
	// MaxFrameData is the max frame_data length (default 100_000 for learning; spec cap 1_000_000).
	MaxFrameData int
	// ChannelID if zeroed, a random id is generated.
	ChannelID [16]byte
}

func (o ChannelOptions) withDefaults() ChannelOptions {
	if o.MaxFrameData <= 0 {
		o.MaxFrameData = 100_000
	}
	if o.MaxFrameData > MaxFrameDataLen {
		o.MaxFrameData = MaxFrameDataLen
	}
	var zero [16]byte
	if o.ChannelID == zero {
		if _, err := rand.Read(o.ChannelID[:]); err != nil {
			// deterministic fallback for tests if entropy fails
			copy(o.ChannelID[:], []byte("fortel2-batcher!!"))
		}
	}
	return o
}

// BuildChannelZlib compresses singular (or already-typed) batches into a zlib channel body.
// Matches pre-Fjord / zlib-only channels observed on local ForteL2 (raw zlib, no channel version byte).
func BuildChannelZlib(typedBatches [][]byte) ([]byte, error) {
	if len(typedBatches) == 0 {
		return nil, fmt.Errorf("no batches")
	}
	var stream bytes.Buffer
	for i, tb := range typedBatches {
		enc, err := EncodeBatchForChannel(tb)
		if err != nil {
			return nil, fmt.Errorf("batch %d: %w", i, err)
		}
		stream.Write(enc)
	}
	var zbuf bytes.Buffer
	zw, err := zlib.NewWriterLevel(&zbuf, zlib.DefaultCompression)
	if err != nil {
		return nil, err
	}
	if _, err := zw.Write(stream.Bytes()); err != nil {
		_ = zw.Close()
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return zbuf.Bytes(), nil
}

// DecompressChannelZlib inflates a zlib channel body (no Fjord version prefix).
func DecompressChannelZlib(compressed []byte) ([]byte, error) {
	zr, err := zlib.NewReader(bytes.NewReader(compressed))
	if err != nil {
		return nil, err
	}
	defer zr.Close()
	return io.ReadAll(zr)
}

// SplitChannelFrames splits channel bytes into frames; the last frame has IsLast=true.
func SplitChannelFrames(channelID [16]byte, channel []byte, maxFrameData int) ([]Frame, error) {
	if maxFrameData <= 0 || maxFrameData > MaxFrameDataLen {
		return nil, fmt.Errorf("invalid maxFrameData %d", maxFrameData)
	}
	if len(channel) == 0 {
		return nil, fmt.Errorf("empty channel")
	}
	var frames []Frame
	for off, n := 0, 0; off < len(channel); n++ {
		end := off + maxFrameData
		if end > len(channel) {
			end = len(channel)
		}
		chunk := make([]byte, end-off)
		copy(chunk, channel[off:end])
		frames = append(frames, Frame{
			ChannelID:   channelID,
			FrameNumber: uint16(n),
			Data:        chunk,
			IsLast:      end == len(channel),
		})
		if n == 0xffff && end != len(channel) {
			return nil, fmt.Errorf("frame_number overflow")
		}
		off = end
	}
	return frames, nil
}

// JoinFrameData concatenates frame data in order (caller must ensure same channel / contiguous numbers).
func JoinFrameData(frames []Frame) ([]byte, error) {
	if len(frames) == 0 {
		return nil, fmt.Errorf("no frames")
	}
	var out []byte
	for i, f := range frames {
		if uint16(i) != f.FrameNumber {
			return nil, fmt.Errorf("frame_number gap: want %d got %d", i, f.FrameNumber)
		}
		out = append(out, f.Data...)
		if f.IsLast != (i == len(frames)-1) {
			return nil, fmt.Errorf("is_last mismatch at frame %d", i)
		}
	}
	return out, nil
}

// BuildBatcherTxFromSingularBatches encodes batches → zlib channel → frames → version-0 tx payload.
func BuildBatcherTxFromSingularBatches(batches []SingularBatch, opt ChannelOptions) (payload []byte, frames []Frame, err error) {
	opt = opt.withDefaults()
	typed := make([][]byte, len(batches))
	for i := range batches {
		typed[i], err = EncodeSingularBatch(batches[i])
		if err != nil {
			return nil, nil, err
		}
	}
	channel, err := BuildChannelZlib(typed)
	if err != nil {
		return nil, nil, err
	}
	frames, err = SplitChannelFrames(opt.ChannelID, channel, opt.MaxFrameData)
	if err != nil {
		return nil, nil, err
	}
	payload, err = EncodeBatcherTxPayload(frames)
	return payload, frames, err
}
