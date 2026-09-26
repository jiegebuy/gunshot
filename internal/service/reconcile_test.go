package service

import (
	"context"
	"os"
	"testing"
)

func TestReconcileCommitWithoutReupload(t *testing.T) {
	for _, found := range []bool{false, true} {
		e := newEngine(t, func(context.Context, []string, string, string, func(Progress)) (string, error) {
			t.Error("must not reupload")
			return "", nil
		})
		j := importTest(t, e, "original")
		j.State = "failed"
		j.Error = "commit_outcome_unknown"
		j.OriginalPolicy = 1
		calls := 0
		e.reconciler = func(ctx context.Context, account string, digest []byte) (string, error) {
			calls++
			if len(digest) != 20 {
				t.Error("missing SHA1")
			}
			if found {
				return "verified-remote-key", nil
			}
			return "", nil
		}
		e.online = true
		e.wifi = true
		e.Tick()
		waitIdle(t, e)
		if calls != 1 || len(j.ContentSHA1) != 40 {
			t.Fatal("no lookup", calls, j)
		}
		if found {
			if j.State != "completed" || j.MediaKey == "" {
				t.Fatal(j)
			}
			if _, err := os.Stat(e.jobDir(j.ID)); !os.IsNotExist(err) {
				t.Fatal("media retained after confirmation")
			}
		} else {
			if !uncertainCommit(j) {
				t.Fatal("missing lookup became success", j)
			}
			e.Tick()
			if calls != 1 {
				t.Fatal("lookup busy loop")
			}
		}
	}
}

func TestReconcileArchivedOriginal(t *testing.T) {
	e := newEngine(t, nil)
	j := importTest(t, e, "original")
	j.State = "failed"
	j.Error = "commit_timeout_unknown"
	j.ContentSHA1 = "a9993e364706816aba3e25717850c26c9cd0d89d"
	j.OriginalPolicy = 1
	os.RemoveAll(e.jobDir(j.ID))
	e.reconciler = func(context.Context, string, []byte) (string, error) { return "confirmed", nil }
	e.online = true
	e.wifi = true
	e.Tick()
	waitIdle(t, e)
	if j.State != "completed" {
		t.Fatal(j)
	}
}
