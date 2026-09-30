//go:build linux || darwin

package service

import (
	"app/backend"
	"bytes"
	"context"
	"crypto/sha1"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func rangeRequest(size int64) Request {
	return Request{Account: "a@example.com", Quality: "original", SourceID: "range-original", Streaming: true, StreamBounded: true, StreamSourceVersion: strings.Repeat("ab", 32), StreamSourceSize: size, Resources: []Resource{{Name: "original.mov"}}}
}
func startRange(t *testing.T, e *Engine, r Request) (*Job, map[string]any) {
	t.Helper()
	v, err := e.begin(r, "googlephotos")
	if err != nil {
		t.Fatal(err)
	}
	reply := v.(map[string]any)
	return e.find(reply["id"].(string)), reply
}
func TestRangeSourceResumesReleasedPrefixWithoutReplay(t *testing.T) {
	e := newEngine(t, nil)
	data := bytes.Repeat([]byte("original-"), 300000)
	r := rangeRequest(int64(len(data)))
	j, _ := startRange(t, e, r)
	for offset := int64(0); offset < 2<<20; offset += 1 << 20 {
		appendStreamTest(t, e, j, offset, data[offset:offset+(1<<20)])
	}
	path := filepath.Join(e.jobDir(j.ID), j.Resources[0].Name)
	spoolReceipt(t, path, 1<<20)
	if _, err := backend.GunshotReclaimStream(path, 1<<20); err != nil {
		t.Fatal(err)
	}
	j.StreamReclaimed = 1 << 20
	if err := e.suspendStream(j); err != nil {
		t.Fatal(err)
	}
	e.Close()
	next, err := Open(e.root, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer next.Close()
	j, reply := startRange(t, next, r)
	if reply["resumeOffset"] != int64(2<<20) || next.streamVerified[j.ID] != 2<<20 {
		t.Fatal("resume restarted at zero", reply)
	}
	appendStreamTest(t, next, j, 2<<20, data[2<<20:])
	if _, err := next.seal(j); err != nil {
		t.Fatal(err)
	}
	got, err := backend.CalculateSHA1(context.Background(), path)
	want := sha1.Sum(data)
	if err != nil || !bytes.Equal(got, want[:]) {
		t.Fatal("resumed original changed", err)
	}
}

func TestRangeSourceLargeAppendIsDurableBeforeReturn(t *testing.T) {
	e := newEngine(t, nil)
	data := bytes.Repeat([]byte("original"), (8<<20)/8+17)
	r := rangeRequest(int64(len(data)))
	j, _ := startRange(t, e, r)
	appendStreamTest(t, e, j, 0, data[:8<<20])
	path := filepath.Join(e.jobDir(j.ID), j.Resources[0].Name)
	spoolReceipt(t, path, 4<<20)
	if _, err := backend.GunshotReclaimStream(path, 4<<20); err != nil {
		t.Fatal(err)
	}
	// Reopen without suspension/save: append's durable source checkpoint must
	// be enough to recover, including a released prefix inside the large block.
	e.Close()
	next, err := Open(e.root, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer next.Close()
	j, reply := startRange(t, next, r)
	if reply["resumeOffset"] != int64(8<<20) {
		t.Fatal("large append was not durably checkpointed", reply)
	}
	appendStreamTest(t, next, j, 8<<20, data[8<<20:])
	if _, err := next.seal(j); err != nil {
		t.Fatal(err)
	}
	got, err := backend.CalculateSHA1(context.Background(), path)
	want := sha1.Sum(data)
	if err != nil || !bytes.Equal(got, want[:]) {
		t.Fatal("large-block resume changed original", err)
	}
}
func TestRangeSourceRejectsChangedIdentityAndCorruptTail(t *testing.T) {
	for _, kind := range []string{"version", "size", "tail", "checkpoint", "missing-session", "missing-spool", "rewound-session"} {
		t.Run(kind, func(t *testing.T) {
			e := newEngine(t, nil)
			defer e.Close()
			r := rangeRequest(3 << 20)
			j, _ := startRange(t, e, r)
			appendStreamTest(t, e, j, 0, bytes.Repeat([]byte{33}, 1<<20))
			appendStreamTest(t, e, j, 1<<20, bytes.Repeat([]byte{71}, 1<<20))
			path := filepath.Join(e.jobDir(j.ID), j.Resources[0].Name)
			spoolReceipt(t, path, 1<<20)
			if _, err := backend.GunshotReclaimStream(path, 1<<20); err != nil {
				t.Fatal(err)
			}
			j.StreamReclaimed = 1 << 20
			if err := e.suspendStream(j); err != nil {
				t.Fatal(err)
			}
			switch kind {
			case "version":
				r.StreamSourceVersion = strings.Repeat("cd", 32)
			case "size":
				r.StreamSourceSize++
			case "tail":
				f, err := os.OpenFile(path, os.O_WRONLY, 0600)
				if err != nil {
					t.Fatal(err)
				}
				_, err = f.WriteAt([]byte{42}, (1<<20)+5)
				f.Close()
				if err != nil {
					t.Fatal(err)
				}
			case "checkpoint":
				if err := os.WriteFile(filepath.Join(e.jobDir(j.ID), ".source.json"), []byte("{}"), 0600); err != nil {
					t.Fatal(err)
				}
			case "missing-session", "missing-spool":
				pattern := ".upload-*.json"
				if kind == "missing-spool" {
					pattern += ".spool"
				}
				paths, _ := filepath.Glob(filepath.Join(e.jobDir(j.ID), pattern))
				if len(paths) != 1 {
					t.Fatal(paths)
				}
				if err := os.Remove(paths[0]); err != nil {
					t.Fatal(err)
				}
			case "rewound-session":
				spoolReceipt(t, path, 0)
			}
			if _, err := e.begin(r, "googlephotos"); err == nil {
				t.Fatal("unsafe resume accepted", kind)
			}
			if j.State != "failed" {
				t.Fatal("failed validation activated producer")
			}
		})
	}
}
func TestRangeSourceDiscardsUncheckpointedTail(t *testing.T) {
	e := newEngine(t, nil)
	defer e.Close()
	r := rangeRequest(2 << 20)
	j, _ := startRange(t, e, r)
	appendStreamTest(t, e, j, 0, bytes.Repeat([]byte{9}, 1<<20))
	if err := e.suspendStream(j); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(e.jobDir(j.ID), j.Resources[0].Name)
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	_, err = f.Write([]byte("interrupted append"))
	f.Close()
	if err != nil {
		t.Fatal(err)
	}
	j, reply := startRange(t, e, r)
	st, _ := os.Stat(path)
	if reply["resumeOffset"] != int64(1<<20) || st.Size() != 1<<20 {
		t.Fatal("undurable tail retained")
	}
	if _, err := e.seal(j); err == nil {
		t.Fatal("early EOF accepted")
	}
	if e.AppendEmbedded(j.ID, 0, 1<<20, bytes.Repeat([]byte{1}, (1<<20)+1)) {
		t.Fatal("oversized append accepted")
	}
}
func TestRangeSourceCheckpointFailureStopsPreupload(t *testing.T) {
	e := newEngine(t, nil)
	defer e.Close()
	j, _ := startRange(t, e, rangeRequest(2<<20))
	path := filepath.Join(e.jobDir(j.ID), ".source.json")
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(path, 0700); err != nil {
		t.Fatal(err)
	}
	if e.AppendEmbedded(j.ID, 0, 0, bytes.Repeat([]byte{1}, 1<<20)) {
		t.Fatal("failed checkpoint was acknowledged")
	}
	if j.State != "failed" {
		t.Fatal("undurable bytes can reach network worker")
	}
}

func TestRangeSourceRejectsCheckpointFilename(t *testing.T) {
	e := newEngine(t, nil)
	defer e.Close()
	r := rangeRequest(1 << 20)
	r.Resources[0].Name = ".source.json"
	if _, err := e.begin(r, "googlephotos"); err == nil {
		t.Fatal("resource collides with checkpoint")
	}
	legacy := r
	legacy.StreamSourceVersion, legacy.StreamSourceSize = "", 0
	v, err := e.begin(legacy, "googlephotos")
	if err != nil {
		t.Fatal(err)
	}
	j := e.find(v.(map[string]any)["id"].(string))
	if err := e.suspendStream(j); err != nil {
		t.Fatal(err)
	}
	if _, err := e.begin(r, "googlephotos"); err == nil {
		t.Fatal("legacy upgrade overwrites resource with checkpoint")
	}
	st, err := os.Stat(filepath.Join(e.jobDir(j.ID), ".source.json"))
	if err != nil || st.Size() != 0 || j.State != "failed" {
		t.Fatal("rejected upgrade modified legacy resource")
	}
}

func TestRangeSourceUpgradesLegacyZeroByteFailure(t *testing.T) {
	e := newEngine(t, nil)
	defer e.Close()
	j := beginStreamTest(t, e, "range-original")
	if err := e.suspendStream(j); err != nil {
		t.Fatal(err)
	}
	r := rangeRequest(2 << 20)
	upgraded, _ := startRange(t, e, r)
	if upgraded.ID != j.ID || upgraded.StreamSourceVersion != r.StreamSourceVersion {
		t.Fatal("legacy zero-byte job was not upgraded")
	}
	appendStreamTest(t, e, j, 0, bytes.Repeat([]byte{3}, 1<<20))
	if err := e.suspendStream(j); err != nil {
		t.Fatal(err)
	}
	_, reply := startRange(t, e, r)
	if reply["resumeOffset"] != int64(1<<20) {
		t.Fatal("upgraded source lost its resume checkpoint")
	}
}
