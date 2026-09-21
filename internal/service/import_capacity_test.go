package service

import "testing"

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
