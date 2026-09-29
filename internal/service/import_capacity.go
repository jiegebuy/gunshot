package service

import (
	"os"
	"path/filepath"
	"time"
)

// Caller holds e.mu. Count retained originals across accounts: they all share
// the same device disk. Terminal files are deleted after durable confirmation.
// Preparation workers call this every second each, under the engine lock that
// every upload also needs, so it must stay in memory: sweeping every terminal
// job's directory here took the lock for thousands of syscalls per call.
func (e *Engine) importCapacity() map[string]any {
	var retained, releasable, buffered, smallBuffered int64
	bufferedJobs := 0
	jobs := 0
	// Retry cleanup after transient filesystem failures, retaining receipts.
	sweep := time.Since(e.terminalSwept) >= time.Minute
	if sweep {
		e.terminalSwept = time.Now()
	}
	for _, j := range e.state.Jobs {
		switch j.State {
		case "completed", "cancelled":
			if sweep && validID(j.ID) {
				_ = os.RemoveAll(e.jobDir(j.ID))
			}
			continue
		}
		size := j.Total
		if j.State == "failed" && validID(j.ID) {
			size = 0
			for _, r := range j.Resources {
				if !safeName(r.Name) {
					continue
				}
				if st, err := os.Stat(filepath.Join(e.jobDir(j.ID), r.Name)); err == nil {
					size += st.Size()
				} else if !os.IsNotExist(err) {
					size += r.Size
				}
			}
		}
		if size == 0 {
			continue
		}
		retained += size
		jobs++
		if j.State != "failed" {
			buffered += size
			bufferedJobs++
			if j.Total <= 32<<20 {
				smallBuffered += size
			}
		}
		switch j.State {
		case "pending", "preparing", "uploading", "committing":
			releasable += j.Total
		}
	}
	return map[string]any{"retainedBytes": retained, "bufferedBytes": buffered, "smallBufferedBytes": smallBuffered, "bufferedJobs": bufferedJobs, "releasableBytes": releasable, "retainedJobs": jobs, "paused": e.state.Options.Paused}
}
