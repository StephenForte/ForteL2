package batcher

import (
	"bytes"
	"testing"
)

func TestFrameRoundTrip(t *testing.T) {
	var ch [16]byte
	copy(ch[:], []byte("fortel2-channel!")) // 16 bytes
	frames := []Frame{
		{ChannelID: ch, FrameNumber: 0, Data: []byte("hello"), IsLast: false},
		{ChannelID: ch, FrameNumber: 1, Data: []byte("world"), IsLast: true},
	}
	payload, err := EncodeBatcherTxPayload(frames)
	if err != nil {
		t.Fatal(err)
	}
	if payload[0] != BatcherTxVersionCalldata {
		t.Fatalf("version byte: got %d", payload[0])
	}
	ver, got, err := ParseBatcherTxPayload(payload)
	if err != nil {
		t.Fatal(err)
	}
	if ver != BatcherTxVersionCalldata {
		t.Fatalf("parse version: %d", ver)
	}
	if len(got) != 2 {
		t.Fatalf("frame count: %d", len(got))
	}
	if !bytes.Equal(got[0].Data, []byte("hello")) || got[0].IsLast {
		t.Fatalf("frame0: %+v", got[0])
	}
	if !bytes.Equal(got[1].Data, []byte("world")) || !got[1].IsLast {
		t.Fatalf("frame1: %+v", got[1])
	}
	if got[0].FrameNumber != 0 || got[1].FrameNumber != 1 {
		t.Fatalf("frame numbers: %d %d", got[0].FrameNumber, got[1].FrameNumber)
	}
	if ChannelIDHex(got[0].ChannelID) != ChannelIDHex(ch) {
		t.Fatalf("channel id mismatch")
	}
}

func TestRejectBadIsLast(t *testing.T) {
	var ch [16]byte
	raw, err := EncodeFrames([]Frame{{ChannelID: ch, FrameNumber: 0, Data: []byte{1}, IsLast: true}})
	if err != nil {
		t.Fatal(err)
	}
	raw[len(raw)-1] = 2
	if _, err := ParseFrames(raw); err == nil {
		t.Fatal("expected error for bad is_last")
	}
}

func TestRejectEmpty(t *testing.T) {
	if _, _, err := ParseBatcherTxPayload(nil); err == nil {
		t.Fatal("expected error")
	}
	if _, _, err := ParseBatcherTxPayload([]byte{0}); err == nil {
		t.Fatal("expected error for version-only payload")
	}
}
