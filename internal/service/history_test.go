package service

import (
	"fmt"
	"os"
	"testing"
	"time"
)

func TestFinishedHistoryIsBoundedWithoutLosingDeduplication(t *testing.T) {
	e := newEngine(t, nil)
	var rows []*Job
	add := func(j *Job) *Job {
		j.ID = fmt.Sprintf("%032x", len(rows)+1)
		e.state.Jobs = append(e.state.Jobs, j)
		e.jobsByID[j.ID] = j
		rows = append(rows, j)
		return j
	}
	// Oldest: a completed row without durable evidence must stay.
	unproven := add(&Job{State: "completed", SourceKey: "no-receipt"})
	live := add(&Job{State: "pending", Total: 3})
	for i := range terminalHistory + 40 {
		key := fmt.Sprintf("source-%d", i)
		e.sourceReceipts[key] = SourceReceipt{SourceKey: key}
		add(&Job{State: "completed", SourceKey: key})
	}
	cancelled := add(&Job{State: "cancelled"})
	newest := rows[len(rows)-2]
	e.compactHistory()

	terminal := 0
	for _, j := range e.state.Jobs {
		if j.State == "completed" || j.State == "cancelled" {
			terminal++
		}
	}
	if terminal != terminalHistory {
		t.Fatal("finished history not bounded", terminal)
	}
	if e.find(unproven.ID) != unproven || e.find(live.ID) != live || e.find(cancelled.ID) != cancelled || e.find(newest.ID) != newest {
		t.Fatal("compaction removed a live, unproven or recent row")
	}
	if e.state.Jobs[0] != unproven || e.state.Jobs[1] != live {
		t.Fatal("compaction reordered the queue")
	}
	if len(e.jobsByID) != len(e.state.Jobs) {
		t.Fatal("index kept removed rows")
	}
	// Removed rows keep their receipts, so their sources are never uploaded again.
	for i := range 40 {
		if _, ok := e.sourceReceipts[fmt.Sprintf("source-%d", i)]; !ok {
			t.Fatal("receipt lost")
		}
	}
}

func TestCapacityQueryDoesNotSweepDiskEachCall(t *testing.T) {
	e := newEngine(t, nil)
	j := importTest(t, e, "original")
	j.State = "completed"
	e.importCapacity() // First call sweeps.
	if _, err := os.Stat(e.jobDir(j.ID)); !os.IsNotExist(err) {
		t.Fatal("terminal cache not removed")
	}
	os.MkdirAll(e.jobDir(j.ID), 0700) // A removal that failed transiently.
	e.importCapacity()
	if _, err := os.Stat(e.jobDir(j.ID)); err != nil {
		t.Fatal("capacity query swept the disk again within a minute")
	}
	e.terminalSwept = time.Now().Add(-2 * time.Minute)
	e.importCapacity()
	if _, err := os.Stat(e.jobDir(j.ID)); !os.IsNotExist(err) {
		t.Fatal("failed cleanup never retried")
	}
}

func TestEngineReportsLockContention(t *testing.T) {
	e := newEngine(t, nil)
	e.HandleJSON([]byte(`{"op":"import_capacity"}`), "googlephotos")
	e.HandleJSON([]byte(`{"op":"import_capacity"}`), "googlephotos")
	e.mu.Lock()
	snapshot := e.lockSnapshot()
	e.mu.Unlock()
	op := snapshot["ops"].(map[string]any)["import_capacity"].(map[string]int64)
	if op["count"] != 2 || snapshot["saves"].(int64) < 1 {
		t.Fatal(snapshot)
	}
}
