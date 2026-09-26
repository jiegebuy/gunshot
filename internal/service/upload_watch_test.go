package service

import (
	"context"
	"os"
	"testing"
	"time"
)

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
