package service

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestJobIndexSurvivesRestartAndHistoryCleanup(t *testing.T) {
	e := newEngine(t, nil)
	completed := importTest(t, e, "original")
	duplicate := importTest(t, e, "original")
	pending := importTest(t, e, "saver")
	failed := importTest(t, e, "quota")
	completed.State, completed.MediaKey, completed.OriginalPolicy = "completed", "completed-media-key", 1
	failed.State = "failed"
	if err := e.save(); err != nil {
		t.Fatal(err)
	}
	if len(e.jobsByID) != len(e.state.Jobs) || e.find(duplicate.ID) != duplicate {
		t.Fatal("new and duplicate imports are missing from the index")
	}

	reopened, err := Open(e.root, nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, job := range reopened.state.Jobs {
		if reopened.find(job.ID) != job {
			t.Fatal("restart did not index the recovered job object")
		}
	}
	backing := reopened.state.Jobs
	if _, err := reopened.handle(Request{Op: "clear_completed"}, "settings"); err != nil {
		t.Fatal(err)
	}
	if len(reopened.jobsByID) != 2 || len(reopened.state.Jobs) != 2 ||
		reopened.find(completed.ID) != nil || reopened.find(duplicate.ID) != nil ||
		reopened.state.Jobs[0].ID != pending.ID || reopened.state.Jobs[1].ID != failed.ID {
		t.Fatal("history cleanup lost live jobs, kept removed IDs, or reordered the queue")
	}
	for _, job := range backing[2:] {
		if job != nil {
			t.Fatal("removed job retained by the queue backing array")
		}
	}
	if state, err := reopened.handle(Request{Op: "job", ID: completed.ID}, "photos"); err != nil || state.(map[string]any)["mediaKey"] != completed.MediaKey {
		t.Fatal("completed receipt did not survive queue-history cleanup")
	}
	if _, err := reopened.handle(Request{Op: "job", ID: duplicate.ID}, "photos"); err == nil {
		t.Fatal("cancelled duplicate remains accessible through the protocol")
	}
	v, err := reopened.begin(Request{Account: "a@example.com", Quality: "original", Resources: []Resource{{Name: "fresh.jpg", Size: 4}}}, "photos")
	if err != nil {
		t.Fatal(err)
	}
	fresh := reopened.find(v.(map[string]any)["id"].(string))
	if err := reopened.appendChunk(fresh, Request{Index: 0, Offset: 0, Data: []byte("abcd")}); err != nil {
		t.Fatal(err)
	}
	if _, err := reopened.seal(fresh); err != nil {
		t.Fatal(err)
	}
	if fresh.State != "pending" || reopened.find(fresh.ID) != fresh {
		t.Fatal("new import after cleanup used a stale index")
	}
	final, err := Open(e.root, nil)
	if err != nil || len(final.state.Jobs) != 3 || final.find(fresh.ID) == nil {
		t.Fatalf("index or queue failed to survive a second restart: %v", err)
	}
}

func TestNoOpQueueCommandsDoNotRewriteState(t *testing.T) {
	for _, op := range []string{"configure", "clear_completed", "retry_failed"} {
		t.Run(op, func(t *testing.T) {
			e := newEngine(t, nil)
			importTest(t, e, "original")
			path := filepath.Join(e.root, "state.json")
			before, err := os.Stat(path)
			if err != nil {
				t.Fatal(err)
			}
			options := e.state.Options
			cancelled := false
			e.active["fixture"] = func() { cancelled = true }
			if _, err := e.handle(Request{Op: op, Options: &options}, "settings"); err != nil {
				t.Fatal(err)
			}
			after, err := os.Stat(path)
			if err != nil || !os.SameFile(before, after) {
				t.Fatalf("unchanged command rewrote the atomic state file: %v", err)
			}
			if op == "configure" && !cancelled {
				t.Fatal("unchanged options skipped cancellation required by network conditions")
			}
		})
	}
}

func TestChangedOptionsAndRetryArePersisted(t *testing.T) {
	e := newEngine(t, nil)
	job := importTest(t, e, "original")
	options := e.state.Options
	options.Concurrent = 2
	if _, err := e.handle(Request{Op: "configure", Options: &options}, "settings"); err != nil {
		t.Fatal(err)
	}
	for _, op := range []string{"retry", "retry_failed"} {
		job.State, job.Error, job.Attempts, job.Next, job.CancelRequested = "failed", "upload_failed_check_account_and_network", 4, 12345, true
		if err := e.save(); err != nil {
			t.Fatal(err)
		}
		if _, err := e.handle(Request{Op: op, ID: job.ID}, "settings"); err != nil {
			t.Fatal(err)
		}
		var state State
		data, err := os.ReadFile(filepath.Join(e.root, "state.json"))
		if err != nil || json.Unmarshal(data, &state) != nil {
			t.Fatal("cannot read persisted retry state")
		}
		saved := state.Jobs[0]
		if state.Options != options || saved.State != "pending" || saved.Attempts != 0 || saved.Next != 0 || saved.CancelRequested {
			t.Fatal("changed options or retry reset was not persisted")
		}
	}
}

var benchmarkJob *Job
var benchmarkSummary any

func benchmarkEngine(b *testing.B, count int) *Engine {
	b.Helper()
	state := State{Version: 1, Options: defaults(), Jobs: make([]*Job, count)}
	for i := range state.Jobs {
		state.Jobs[i] = &Job{ID: fmt.Sprintf("%032x", i), Account: "fixture@example.com", Quality: []string{"original", "saver", "quota"}[i%3], State: "pending", Owner: "photos", Resources: []Resource{{Name: "fixture.heic", Size: 3}}, Total: 3}
	}
	root := b.TempDir()
	if err := atomicJSON(filepath.Join(root, "state.json"), state); err != nil {
		b.Fatal(err)
	}
	e, err := Open(root, nil)
	if err != nil {
		b.Fatal(err)
	}
	return e
}

func BenchmarkJobLookup(b *testing.B) {
	for _, count := range []int{100, MaxJobs} {
		b.Run(fmt.Sprint(count), func(b *testing.B) {
			e := benchmarkEngine(b, count)
			id := e.state.Jobs[count-1].ID
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				benchmarkJob = e.find(id)
			}
		})
	}
}

func BenchmarkUploadSummary(b *testing.B) {
	e := benchmarkEngine(b, MaxJobs)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		benchmarkSummary = e.uploadSummary()
	}
}
