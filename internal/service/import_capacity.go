package service

import (
	"os"
	"path/filepath"
)

// Caller holds e.mu. Count retained originals across accounts: they all share
// the same device disk. Terminal files are deleted after durable confirmation.
func (e *Engine) importCapacity() map[string]any {
	var retained, releasable int64
	jobs := 0
	for _, j := range e.state.Jobs {
		switch j.State {
		case "completed", "cancelled":
			// Retry cleanup after transient filesystem failures, retaining receipts.
			if validID(j.ID) {
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
		switch j.State {
		case "pending", "preparing", "uploading", "committing":
			releasable += j.Total
		}
	}
	return map[string]any{"retainedBytes": retained, "releasableBytes": releasable, "retainedJobs": jobs, "paused": e.state.Options.Paused}
}
