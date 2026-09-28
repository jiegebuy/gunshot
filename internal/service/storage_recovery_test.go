package service

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestStorageRecoveryRequiresDurabilityAndPreservesCommitUncertainty(t *testing.T) {
	e := newEngine(t, func(context.Context, []string, string, string, func(Progress)) (string, error) {
		t.Error("network work started during persistence recovery")
		return "", nil
	})
	importTest(t, e, "original")
	j := e.state.Jobs[0]
	j.State = "importing"
	path := filepath.Join(e.root, "state.json")
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(path, 0700); err != nil {
		t.Fatal(err)
	}
	if e.save() == nil || !e.fault {
		t.Fatal("failed save did not latch")
	}
	var summary struct {
		OK   bool
		Data struct {
			Engine struct {
				StorageFault     bool
				LastStorageError string
			}
		}
	}
	if err := json.Unmarshal(e.HandleJSON([]byte(`{"op":"upload_summary"}`), "settings"), &summary); err != nil || !summary.OK || !summary.Data.Engine.StorageFault {
		t.Fatal("storage failure hid the live diagnostics", err)
	}
	if !strings.Contains(string(e.HandleJSON([]byte(`{"op":"accounts"}`), "settings")), "storage_fault") {
		t.Fatal("mutation/import gate did not report storage fault")
	}
	if e.recoverStorage(time.Now()) || !e.fault {
		t.Fatal("resumed before durable save")
	}
	if _, err := os.Stat(e.jobDir(j.ID)); err != nil {
		t.Fatal("deleted originals before durable recovery", err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	// Throttle recovery attempts, even when the storage problem disappears.
	if e.recoverStorage(time.Now()) {
		t.Fatal("ignored recovery backoff")
	}
	e.storageRetry = time.Time{}
	e.Tick()
	if e.fault || j.State != "cancelled" || j.Error != "import_interrupted" {
		t.Fatal("partial import not safely recovered")
	}
	if _, err := Open(e.root, nil); err != nil {
		t.Fatal("recovered state is not durable", err)
	}

	// A save can also fail at an upload phase boundary. Never replay a commit
	// with an unknown remote outcome, and wait for existing runners to settle.
	j.State = "committing"
	e.fault = true
	e.active[j.ID] = func() {}
	e.storageRetry = time.Time{}
	if e.recoverStorage(time.Now()) || j.State != "committing" {
		t.Fatal("recovered while runner still active")
	}
	delete(e.active, j.ID)
	if !e.recoverStorage(time.Now()) || j.State != "failed" || j.Error != "commit_outcome_unknown" {
		t.Fatal("uncertain commit replayed")
	}
	j.State = "preparing"
	e.fault = true
	e.storageRetry = time.Time{}
	if !e.recoverStorage(time.Now()) || j.State != "pending" {
		t.Fatal("pre-upload job could not resume")
	}
}

func TestStorageFailureCancelsRunnersAndReportsOnlySafeCodes(t *testing.T) {
	e := newEngine(t, nil)
	called := false
	e.active["fixture"] = func() { called = true }
	path := filepath.Join(e.root, "state.json")
	os.Remove(path)
	os.Mkdir(path, 0700)
	if e.save() == nil || !called {
		t.Fatal("failed persistence left network runners active")
	}
	for _, pair := range []struct {
		err  error
		code string
	}{
		{syscall.ENOSPC, "storage_full"}, {syscall.EIO, "storage_io"}, {os.ErrPermission, "storage_permission"},
	} {
		e.storageError = &os.PathError{Op: "write", Path: "private/filename", Err: pair.err}
		if storageErrorCode(e.storageError) != pair.code {
			t.Fatal("lost original error category")
		}
		raw := string(e.HandleJSON([]byte(`{"op":"upload_summary"}`), "settings"))
		if strings.Contains(raw, "private/filename") {
			t.Fatal("storage diagnostic leaked path")
		}
	}
}
