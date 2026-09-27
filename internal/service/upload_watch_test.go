package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestStalledResumableUploadSchedulesContinuation(t *testing.T) {
	e := newEngine(t, func(ctx context.Context, _ []string, _, _ string, report func(Progress)) (string, error) {
		report(Progress{State: "uploading", Uploaded: 2})
		<-ctx.Done()
		return "", ctx.Err()
	})
	e.uploadIdleTimeout = 20 * time.Millisecond
	const size = 34 << 20
	value, err := e.begin(Request{Account: "a@example.com", Quality: "original", Resources: []Resource{{Name: "video.mp4", Size: size}}}, "googlephotos")
	if err != nil {
		t.Fatal(err)
	}
	j := e.find(value.(map[string]any)["id"].(string))
	j.State = "pending"
	file := filepath.Join(e.jobDir(j.ID), "video.mp4")
	if err = os.Truncate(file, size); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte("video.mp4"))
	name := ".upload-" + hex.EncodeToString(sum[:8]) + ".json"
	raw, _ := json.Marshal(map[string]any{"version": 1, "protocol": "scotty", "url": "https://photos.googleapis.com/data/upload/session?upload_id=synthetic", "size": size, "offset": 4 << 20})
	if err = os.WriteFile(filepath.Join(e.jobDir(j.ID), name), raw, 0600); err != nil {
		t.Fatal(err)
	}
	e.online = true
	e.wifi = true
	e.Tick()
	waitIdle(t, e)
	if j.State != "pending" || j.Error != "upload_resuming" || j.Next <= time.Now().Unix() {
		t.Fatal("resumable upload did not schedule recovery", j)
	}
	if len(e.active) != 0 {
		t.Fatal("stalled worker retained slot")
	}
	j.State = "failed"
	j.Error = "upload_stalled"
	if err = e.save(); err != nil {
		t.Fatal(err)
	}
	reopened, err := Open(e.root, nil)
	if err != nil {
		t.Fatal(err)
	}
	if reopened.find(j.ID).State != "pending" {
		t.Fatal("old stalled checkpoint was not recovered")
	}
	j.Attempts = e.state.Options.Retries + 1
	if err = e.save(); err != nil {
		t.Fatal(err)
	}
	reopened, err = Open(e.root, nil)
	if err != nil {
		t.Fatal(err)
	}
	if reopened.find(j.ID).State != "failed" {
		t.Fatal("recovery reset retry budget")
	}
}

func TestStalledUploadReleasesSlotWithoutRepeatedRetransmission(t *testing.T) {
	e := newEngine(t, func(ctx context.Context, _ []string, _, _ string, report func(Progress)) (string, error) {
		report(Progress{State: "uploading", Uploaded: 2})
		<-ctx.Done()
		return "", ctx.Err()
	})
	e.uploadIdleTimeout = 20 * time.Millisecond
	j := importTest(t, e, "original")
	e.online = true
	e.wifi = true
	e.Tick()
	waitIdle(t, e)
	if j.State != "failed" || j.Error != "upload_stalled" || len(e.active) != 0 || j.ProgressUpdated == 0 {
		t.Fatal(j)
	}
	if _, err := os.Stat(e.jobDir(j.ID)); err != nil {
		t.Fatal("lost retained file")
	}
	e.Tick()
	if len(e.active) != 0 {
		t.Fatal("silently restarted full upload")
	}
	if _, err := e.handle(Request{Op: "retry", ID: j.ID}, "photos"); err != nil {
		t.Fatal(err)
	}
}
func TestWatchResetsOnlyOnProgressAndStopsAtCommit(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	w := &uploadWatch{}
	go w.run(ctx, cancel, 100*time.Millisecond)
	for i := 0; i < 10; i++ {
		w.update(Progress{State: "uploading", Uploaded: int64(i)})
		time.Sleep(20 * time.Millisecond)
	}
	if ctx.Err() != nil {
		t.Fatal("cancelled progressing upload")
	}
	w.update(Progress{State: "committing", Uploaded: 10})
	time.Sleep(150 * time.Millisecond)
	if ctx.Err() != nil {
		t.Fatal("upload watchdog timed out commit")
	}
}
func TestLateNetworkProgressCannotRestoreFinishedUpload(t *testing.T) {
	callbacks := make(chan func(Progress), 1)
	e := newEngine(t, func(ctx context.Context, _ []string, _, _ string, report func(Progress)) (string, error) {
		callbacks <- report
		return "remote-key", nil
	})
	j := importTest(t, e, "original")
	e.online = true
	e.wifi = true
	e.Tick()
	waitIdle(t, e)
	late := <-callbacks
	late(Progress{State: "uploading", Uploaded: 1})
	if j.State != "completed" || j.Uploaded != j.Total {
		t.Fatal("late socket callback restored uploading", j)
	}
}
