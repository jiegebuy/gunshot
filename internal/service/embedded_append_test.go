package service

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestEmbeddedAppend(t *testing.T) {
	e := newEngine(t, nil)
	payload := bytes.Repeat([]byte{0xff}, MaxEmbeddedChunk+137)
	begin := func(owner string) *Job {
		v, err := e.begin(Request{Account: "a@example.com", Quality: "original", Resources: []Resource{{Name: "large.tif", Size: int64(len(payload))}}}, owner)
		if err != nil {
			t.Fatal(err)
		}
		return e.find(v.(map[string]any)["id"].(string))
	}
	j := begin("googlephotos")
	if e.AppendEmbedded(j.ID, 0, 0, payload) || e.AppendEmbedded(j.ID, 2, 0, payload[:1]) || e.AppendEmbedded(j.ID, 0, 1, payload[:1]) || e.AppendEmbedded(j.ID, 0, 0, nil) {
		t.Fatal("accepted invalid append")
	}
	other := begin("photos")
	if e.AppendEmbedded(other.ID, 0, 0, payload[:1]) {
		t.Fatal("cross-owner append")
	}
	if !e.AppendEmbedded(j.ID, 0, 0, payload[:MaxEmbeddedChunk]) {
		t.Fatal("binary block rejected")
	}
	if e.AppendEmbedded(j.ID, 0, 0, payload[:1]) {
		t.Fatal("offset replay accepted")
	}
	if !e.AppendEmbedded(j.ID, 0, MaxEmbeddedChunk, payload[MaxEmbeddedChunk:]) {
		t.Fatal("tail rejected")
	}
	got, err := os.ReadFile(filepath.Join(e.jobDir(j.ID), "large.tif"))
	if err != nil || !bytes.Equal(got, payload) {
		t.Fatal("bytes changed", err)
	}
	if _, err = e.seal(j); err != nil {
		t.Fatal(err)
	}
	if e.AppendEmbedded(j.ID, 0, int64(len(payload)), payload[:1]) {
		t.Fatal("sealed job accepted")
	}
	e.fault = true
	if e.AppendEmbedded(other.ID, 0, 0, payload[:1]) {
		t.Fatal("fault ignored")
	}
}
