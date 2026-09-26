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
	e.state.Options.Paused = true
	if !e.importCapacity()["paused"].(bool) {
		t.Fatal("pause not reported")
	}
	e.state.Jobs[0].State = "completed"
	if e.importCapacity()["retainedBytes"] != int64(500) {
		t.Fatal("completed bytes not released")
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
