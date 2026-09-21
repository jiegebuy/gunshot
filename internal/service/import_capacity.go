package service

// Caller holds e.mu. Count retained originals across accounts: they all share
// the same device disk. Terminal files are deleted after durable confirmation.
func (e *Engine) importCapacity() map[string]any {
	var retained, releasable int64
	jobs := 0
	for _, j := range e.state.Jobs {
		switch j.State {
		case "completed", "cancelled":
			continue
		}
		retained += j.Total
		jobs++
		switch j.State {
		case "pending", "preparing", "uploading", "committing":
			releasable += j.Total
		}
	}
	return map[string]any{"retainedBytes": retained, "releasableBytes": releasable, "retainedJobs": jobs, "paused": e.state.Options.Paused}
}
