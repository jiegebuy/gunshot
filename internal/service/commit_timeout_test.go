package service

import (
	"context"
	"os"
	"testing"
	"time"
)

func TestCommitTimeoutRetainsMediaAndReleasesSlot(t *testing.T) {
	e := newEngine(t, func(ctx context.Context, _ []string, _, _ string, report func(Progress)) (string, error) {
		report(Progress{State: "committing", Uploaded: 3})
		<-ctx.Done()
		return "", ctx.Err()
	})
	e.commitTimeout = 20 * time.Millisecond
	j := importTest(t, e, "original")
	e.online = true
	e.wifi = true
	e.Tick()
	waitIdle(t, e)
	if j.State != "failed" || j.Error != "commit_timeout_unknown" || j.CommitStarted == 0 || len(e.active) != 0 {
		t.Fatalf("bad timeout state: %+v", j)
	}
	if _, err := os.Stat(e.jobDir(j.ID)); err != nil {
		t.Fatal("unconfirmed original removed", err)
	}
	if _, err := e.handle(Request{Op: "retry", ID: j.ID}, "photos"); err == nil {
		t.Fatal("unsafe replay allowed")
	}
	if err := e.save(); err != nil {
		t.Fatal(err)
	}
	restored, err := Open(e.root, nil)
	if err != nil {
		t.Fatal(err)
	}
	if restored.find(j.ID).Error != "commit_timeout_unknown" {
		t.Fatal("timeout lost on restart")
	}
}
