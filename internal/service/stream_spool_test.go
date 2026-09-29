//go:build linux || darwin

package service

import (
	"app/backend"
	"bytes"
	"context"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/hex"
	"path/filepath"
	"testing"
)

func spoolReceipt(t *testing.T, path string, ack int64) {
	t.Helper()
	sum := sha256.Sum256([]byte(filepath.Base(path)))
	name := filepath.Join(filepath.Dir(path), ".upload-"+hex.EncodeToString(sum[:8])+".json")
	if err := atomicJSON(name, map[string]any{"version": 1, "streaming": true, "protocol": "scotty", "size": -1, "offset": ack, "granularity": 256 << 10, "account": "test", "url": "https://photos.googleapis.com/data/upload/test"}); err != nil {
		t.Fatal(err)
	}
}

func TestBoundedStreamWindowReleasesAndReplaysAfterRestart(t *testing.T) {
	e := newEngine(t, nil)
	e.online, e.wifi = true, true
	j := beginStreamTest(t, e, "bounded-original")
	j.StreamBounded = true
	block := bytes.Repeat([]byte("byte"), (1<<20)/4)
	want := sha1.New()
	for offset := int64(0); offset < backend.GunshotStreamWindow; offset += int64(len(block)) {
		appendStreamTest(t, e, j, offset, block)
		want.Write(block)
	}
	window, err := e.streamWindow(j)
	if err != nil || window.(map[string]any)["availableBytes"].(int64) != 0 {
		t.Fatal("window not bounded")
	}
	if e.AppendEmbedded(j.ID, 0, j.Total, []byte{1}) {
		t.Fatal("producer exceeded disk window")
	}
	e.preuploader = func(_ context.Context, path, _, _ string, available int64) (int64, error) {
		ack := available - (1 << 20)
		spoolReceipt(t, path, ack)
		return ack, nil
	}
	e.Tick()
	waitIdle(t, e)
	if j.StreamReclaimed != 64<<20 {
		t.Fatal("did not release server-confirmed prefix", j.StreamReclaimed, j.Error)
	}
	capacity := e.importCapacity()
	if capacity["retainedBytes"].(int64) != 1<<20 {
		t.Fatal("capacity counts holes as full original", capacity)
	}
	if err := e.suspendStream(j); err != nil {
		t.Fatal(err)
	}
	e.Close()
	next, err := Open(e.root, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer next.Close()
	j = beginStreamTest(t, next, "bounded-original")
	// Callback boundaries may change on replay, including straddling the hole.
	for offset := int64(0); offset < j.Total; {
		n := min(int64(700000), j.Total-offset)
		appendStreamTest(t, next, j, offset, bytes.Repeat([]byte("byte"), int(n)/4))
		offset += n
	}
	tail := []byte("new original tail")
	appendStreamTest(t, next, j, j.Total, tail)
	want.Write(tail)
	if _, err := next.seal(j); err != nil {
		t.Fatal(err)
	}
	got, err := backend.CalculateSHA1(context.Background(), filepath.Join(next.jobDir(j.ID), j.Resources[0].Name))
	if err != nil || !bytes.Equal(got, want.Sum(nil)) {
		t.Fatal("restart changed full-file hash", err)
	}
}

func TestBoundedReplayRejectsChangedDiscardedPrefix(t *testing.T) {
	e := newEngine(t, nil)
	defer e.Close()
	j := beginStreamTest(t, e, "changed-bounded-original")
	j.StreamBounded = true
	data := bytes.Repeat([]byte{0x41}, 1<<20)
	appendStreamTest(t, e, j, 0, data)
	appendStreamTest(t, e, j, int64(len(data)), []byte("retained"))
	path := filepath.Join(e.jobDir(j.ID), j.Resources[0].Name)
	spoolReceipt(t, path, 1<<20)
	if _, err := backend.GunshotReclaimStream(path, 1<<20); err != nil {
		t.Fatal(err)
	}
	j.StreamReclaimed = 1 << 20
	if err := e.suspendStream(j); err != nil {
		t.Fatal(err)
	}
	if _, err := e.resumeStream(j); err != nil {
		t.Fatal(err)
	}
	data[5] = 0x42
	if e.AppendEmbedded(j.ID, 0, 0, data) {
		t.Fatal("accepted changed prefix after deallocation")
	}
	if e.streamVerified[j.ID] != 0 {
		t.Fatal("failed verification advanced producer")
	}
	data[5] = 0x41
	appendStreamTest(t, e, j, 0, data)
	appendStreamTest(t, e, j, int64(len(data)), []byte("retained"))
	if _, err := e.seal(j); err != nil {
		t.Fatal(err)
	}
}

func TestLostStreamCanReimportButUncertainCommitCannot(t *testing.T) {
	e := newEngine(t, nil)
	defer e.Close()
	j := beginStreamTest(t, e, "lost-session")
	j.State, j.Error = "failed", "stream_reimport_required"
	replacement := beginStreamTest(t, e, "lost-session")
	if replacement.ID == j.ID || replacement.Total != 0 || j.State != "cancelled" {
		t.Fatal("no fresh producer after lost session")
	}
	replacement.State, replacement.Error = "failed", "commit_outcome_unknown"
	still := beginStreamTest(t, e, "lost-session")
	if still.ID != replacement.ID || still.Error != "commit_outcome_unknown" {
		t.Fatal("reimported uncertain commit")
	}
}
