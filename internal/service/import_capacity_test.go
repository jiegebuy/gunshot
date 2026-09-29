package service

import (
	"os"
	"path/filepath"
	"testing"
)

func TestImportCapacityTracksRetainedFiles(t *testing.T) {
	e := newEngine(t, nil)
	for _, state := range []string{"pending", "preparing", "uploading", "committing", "importing", "failed", "completed", "cancelled"} {
		e.state.Jobs = append(e.state.Jobs, &Job{State: state, Total: 100})
	}
	s := e.importCapacity()
	if s["retainedBytes"] != int64(600) || s["releasableBytes"] != int64(400) || s["retainedJobs"] != 6 {
		t.Fatal(s)
	}
	if s["bufferedBytes"] != int64(500) || s["bufferedJobs"] != 5 {
		t.Fatal("failed files block active queue", s)
	}
	if s["smallBufferedBytes"] != int64(500) {
		t.Fatal("small photo reservation missing", s)
	}
	e.state.Options.Paused = true
	if !e.importCapacity()["paused"].(bool) {
		t.Fatal("pause not reported")
	}
	e.state.Jobs[0].State = "completed"
	if e.importCapacity()["retainedBytes"] != int64(500) {
		t.Fatal("completed bytes not released")
	}
}
func TestImportCapacitySeparatesSmallBufferFromOversizedImport(t *testing.T) {
	e := newEngine(t, nil)
	e.state.Jobs = []*Job{
		{State: "importing", Total: 9 << 30},
		{State: "importing", Total: 2 << 20},
		{State: "uploading", Total: 32 << 20},
		{State: "pending", Total: 33 << 20},
		{State: "failed", Total: 5 << 20},
		{State: "completed", Total: 6 << 20},
	}
	s := e.importCapacity()
	if s["smallBufferedBytes"] != int64(34<<20) || s["bufferedBytes"] != int64(9<<30+67<<20) || s["bufferedJobs"] != 4 {
		t.Fatal("staging must count complete reservation and exclude terminal files", s)
	}
}
func TestCapacityReclaimsTerminalFilesAndExcludesArchivedFailures(t *testing.T) {
	e := newEngine(t, nil)
	j := importTest(t, e, "original")
	j.State = "completed"
	if e.importCapacity()["retainedBytes"] != int64(0) {
		t.Fatal("completed still counted")
	}
	if _, err := os.Stat(e.jobDir(j.ID)); !os.IsNotExist(err) {
		t.Fatal("terminal cache not removed")
	}
	j.State = "failed"
	j.Error = "commit_outcome_unknown"
	if e.importCapacity()["retainedBytes"] != int64(0) {
		t.Fatal("archived original still counted")
	}
	os.MkdirAll(e.jobDir(j.ID), 0700)
	os.WriteFile(filepath.Join(e.jobDir(j.ID), j.Resources[0].Name), []byte("abc"), 0600)
	if e.importCapacity()["retainedBytes"] != int64(3) {
		t.Fatal("unresolved file not retained")
	}
}
